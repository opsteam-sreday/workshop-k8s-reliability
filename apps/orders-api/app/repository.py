"""Acesso ao DynamoDB: pedidos + registros de idempotência na MESMA tabela.

Chaves:
  PK = IDEMP#<customer_id>#<idempotency_key>   SK = META   (registro de idempotência, com TTL)
  PK = ORDER#<order_id>                        SK = META   (pedido)
  GSI1PK = CUSTOMER#<customer_id>  GSI1SK = CREATED#<created_at>#<order_id>  (listagem por cliente)

Exclusão mútua SEMPRE por escrita condicional (nunca GetItem seguido de PutItem sem condição).
Fencing: `version` é incrementada a cada takeover/fence; toda escrita do executor exige
`owner_token` + `version` iguais aos que ele detém.
"""

from __future__ import annotations

import base64
import json
import logging
import time
import uuid
from dataclasses import dataclass, field
from decimal import Decimal
from enum import Enum
from typing import Any, Callable

from boto3.dynamodb.types import TypeDeserializer, TypeSerializer
from botocore.exceptions import BotoCoreError, ClientError

log = logging.getLogger("orders.repository")

_ser = TypeSerializer()
_de = TypeDeserializer()


class IdemStatus(str, Enum):
    IN_PROGRESS = "IN_PROGRESS"
    COMPLETED = "COMPLETED"
    FAILED_TERMINAL = "FAILED_TERMINAL"


class ReservationState(str, Enum):
    PENDING = "PENDING"            # ainda não tentada
    UNKNOWN = "UNKNOWN"            # tentativa com resultado desconhecido (timeout)
    RESERVED = "RESERVED"          # confirmada pela Inventory API
    RELEASED = "RELEASED"          # compensada (liberada)
    COMPENSATION_PENDING = "COMPENSATION_PENDING"  # liberação falhou; retry/reconciliação necessária
    CONFIRMED = "CONFIRMED"        # pedido persistido


class DbFaultMode(str, Enum):
    NONE = "NONE"
    FAIL_READS = "FAIL_READS"
    FAIL_WRITES = "FAIL_WRITES"
    FAIL_TRANSACT = "FAIL_TRANSACT"
    TRANSACT_UNKNOWN_AFTER_COMMIT = "TRANSACT_UNKNOWN_AFTER_COMMIT"
    FAIL_ALL = "FAIL_ALL"


class DynamoUnavailable(Exception):
    """Falha transitória/indeterminada do DynamoDB. Para escritas, o resultado é DESCONHECIDO."""


class TransactionCancelled(Exception):
    """A transação foi cancelada — garantidamente NÃO aplicada."""

    def __init__(self, reasons: list[str]) -> None:
        super().__init__(",".join(reasons))
        self.reasons = reasons

    @property
    def condition_failed(self) -> bool:
        return "ConditionalCheckFailed" in self.reasons


@dataclass
class IdempotencyRecord:
    pk: str
    idempotency_key: str
    customer_id: str
    request_hash: str
    order_id: str
    status: IdemStatus
    owner_token: str
    version: int
    lease_expires_at: float
    expires_at: int
    created_at: str
    updated_at: str
    attempts: int = 1
    reservation_state: ReservationState = ReservationState.PENDING
    response_status: int | None = None
    response_body: dict | None = None
    last_error: str | None = None
    raw: dict = field(default_factory=dict, repr=False)

    @classmethod
    def from_item(cls, item: dict[str, Any]) -> "IdempotencyRecord":
        body = item.get("response_body")
        return cls(
            pk=item["PK"],
            idempotency_key=item["idempotency_key"],
            customer_id=item["customer_id"],
            request_hash=item["request_hash"],
            order_id=item["order_id"],
            status=IdemStatus(item["status"]),
            owner_token=item.get("owner_token", ""),
            version=int(item["version"]),
            lease_expires_at=float(item.get("lease_expires_at", 0)),
            expires_at=int(item["expires_at"]),
            created_at=item["created_at"],
            updated_at=item["updated_at"],
            attempts=int(item.get("attempts", 1)),
            reservation_state=ReservationState(item.get("reservation_state", "PENDING")),
            response_status=int(item["response_status"]) if "response_status" in item else None,
            response_body=json.loads(body) if body else None,
            last_error=item.get("last_error"),
            raw=item,
        )


def idempotency_pk(customer_id: str, key: str) -> str:
    return f"IDEMP#{customer_id}#{key}"


def order_pk(order_id: str) -> str:
    return f"ORDER#{order_id}"


def _num(value: float) -> Decimal:
    return Decimal(str(round(value, 3)))


def _serialize(item: dict[str, Any]) -> dict[str, Any]:
    return {k: _ser.serialize(v) for k, v in item.items() if v is not None}


def _deserialize(item: dict[str, Any]) -> dict[str, Any]:
    return {k: _de.deserialize(v) for k, v in item.items()}


def _iso(ts: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(ts)) + f".{int(ts * 1000) % 1000:03d}Z"


def _is_conditional_failure(exc: ClientError) -> bool:
    return exc.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException"


class OrdersRepository:
    def __init__(self, client, table_name: str, clock: Callable[[], float] = time.time) -> None:
        self.client = client
        self.table = table_name
        self.clock = clock
        self.fault_mode = DbFaultMode.NONE

    # ------------------------------------------------------------------ faults
    def _maybe_fail(self, kind: str) -> None:
        mode = self.fault_mode
        if mode == DbFaultMode.FAIL_ALL or (mode == DbFaultMode.FAIL_READS and kind == "read") \
                or (mode == DbFaultMode.FAIL_WRITES and kind in ("write", "transact")) \
                or (mode == DbFaultMode.FAIL_TRANSACT and kind == "transact"):
            raise DynamoUnavailable(f"falha DynamoDB simulada ({mode.value})")

    def _call(self, kind: str, fn, **kwargs):
        self._maybe_fail(kind)
        try:
            return fn(**kwargs)
        except ClientError as exc:
            if _is_conditional_failure(exc) or exc.response.get("Error", {}).get("Code") == "TransactionCanceledException":
                raise
            raise DynamoUnavailable(f"{exc.response.get('Error', {}).get('Code')}: {exc}") from exc
        except BotoCoreError as exc:
            raise DynamoUnavailable(f"{type(exc).__name__}: {exc}") from exc

    # ------------------------------------------------------------------ idempotency
    def get_record(self, pk: str) -> IdempotencyRecord | None:
        resp = self._call("read", self.client.get_item, TableName=self.table, Key=_serialize({"PK": pk, "SK": "META"}),
                          ConsistentRead=True)
        item = resp.get("Item")
        return IdempotencyRecord.from_item(_deserialize(item)) if item else None

    def claim(self, *, customer_id: str, key: str, request_hash: str, order_id: str, lease_seconds: float,
              ttl_seconds: int) -> tuple[bool, IdempotencyRecord | None]:
        """Cria o registro IN_PROGRESS se não existir. Retorna (claimed, registro_existente_ou_novo)."""
        now = self.clock()
        pk = idempotency_pk(customer_id, key)
        item = {
            "PK": pk, "SK": "META", "entity": "IDEMPOTENCY", "idempotency_key": key, "customer_id": customer_id,
            "request_hash": request_hash, "order_id": order_id, "status": IdemStatus.IN_PROGRESS.value,
            "owner_token": uuid.uuid4().hex, "version": 1, "attempts": 1,
            "lease_expires_at": _num(now + lease_seconds), "expires_at": int(now + ttl_seconds),
            "reservation_state": ReservationState.PENDING.value, "created_at": _iso(now), "updated_at": _iso(now),
        }
        try:
            self._call("write", self.client.put_item, TableName=self.table, Item=_serialize(item),
                       ConditionExpression="attribute_not_exists(PK)", ReturnValuesOnConditionCheckFailure="ALL_OLD")
            return True, IdempotencyRecord.from_item(item)
        except ClientError as exc:
            if not _is_conditional_failure(exc):
                raise
            old = exc.response.get("Item")
            return False, IdempotencyRecord.from_item(_deserialize(old)) if old else self.get_record(pk)

    def replace_expired(self, old: IdempotencyRecord, *, request_hash: str, order_id: str, lease_seconds: float,
                        ttl_seconds: int) -> IdempotencyRecord | None:
        """Retenção lógica expirada (TTL ainda não removeu o item): inicia NOVA operação, condicionalmente."""
        now = self.clock()
        item = {
            "PK": old.pk, "SK": "META", "entity": "IDEMPOTENCY", "idempotency_key": old.idempotency_key,
            "customer_id": old.customer_id, "request_hash": request_hash, "order_id": order_id,
            "status": IdemStatus.IN_PROGRESS.value, "owner_token": uuid.uuid4().hex, "version": old.version + 1,
            "attempts": 1, "lease_expires_at": _num(now + lease_seconds), "expires_at": int(now + ttl_seconds),
            "reservation_state": ReservationState.PENDING.value, "created_at": _iso(now), "updated_at": _iso(now),
        }
        try:
            self._call("write", self.client.put_item, TableName=self.table, Item=_serialize(item),
                       ConditionExpression="version = :v AND expires_at <= :now",
                       ExpressionAttributeValues=_serialize({":v": old.version, ":now": int(now)}))
            return IdempotencyRecord.from_item(item)
        except ClientError as exc:
            if _is_conditional_failure(exc):
                return None
            raise

    def takeover(self, record: IdempotencyRecord, lease_seconds: float) -> IdempotencyRecord | None:
        """Assume uma operação IN_PROGRESS cujo lease expirou (ex.: Pod morreu). Incrementa version (fencing)."""
        now = self.clock()
        try:
            resp = self._call(
                "write", self.client.update_item, TableName=self.table, Key=_serialize({"PK": record.pk, "SK": "META"}),
                UpdateExpression="SET owner_token = :tok, version = version + :one, lease_expires_at = :lease, "
                                 "attempts = attempts + :one, updated_at = :now_iso",
                ConditionExpression="#s = :inprog AND version = :v AND lease_expires_at <= :now",
                ExpressionAttributeNames={"#s": "status"},
                ExpressionAttributeValues=_serialize({
                    ":tok": uuid.uuid4().hex, ":one": 1, ":lease": _num(now + lease_seconds), ":now_iso": _iso(now),
                    ":inprog": IdemStatus.IN_PROGRESS.value, ":v": record.version, ":now": _num(now),
                }),
                ReturnValues="ALL_NEW",
            )
            return IdempotencyRecord.from_item(_deserialize(resp["Attributes"]))
        except ClientError as exc:
            if _is_conditional_failure(exc):
                return None
            raise

    def update_owned(self, record: IdempotencyRecord, *, reservation_state: ReservationState | None = None,
                     bump_version: bool = False, release_lease: bool = False, last_error: str | None = None
                     ) -> IdempotencyRecord | None:
        """Atualização condicional exigindo posse (owner_token + version + IN_PROGRESS).

        bump_version=True funciona como FENCE: qualquer escrita em voo com a versão antiga falhará.
        Retorna None se a posse foi perdida.
        """
        now = self.clock()
        sets = ["updated_at = :now_iso"]
        values: dict[str, Any] = {":now_iso": _iso(now), ":tok": record.owner_token, ":v": record.version,
                                  ":inprog": IdemStatus.IN_PROGRESS.value}
        if reservation_state is not None:
            sets.append("reservation_state = :rs")
            values[":rs"] = reservation_state.value
        if bump_version:
            sets.append("version = version + :one")
            values[":one"] = 1
        if release_lease:
            sets.append("lease_expires_at = :lease")
            values[":lease"] = _num(now)
        if last_error is not None:
            sets.append("last_error = :err")
            values[":err"] = last_error[:500]
        try:
            resp = self._call(
                "write", self.client.update_item, TableName=self.table, Key=_serialize({"PK": record.pk, "SK": "META"}),
                UpdateExpression="SET " + ", ".join(sets),
                ConditionExpression="owner_token = :tok AND version = :v AND #s = :inprog",
                ExpressionAttributeNames={"#s": "status"},
                ExpressionAttributeValues=_serialize(values), ReturnValues="ALL_NEW",
            )
            return IdempotencyRecord.from_item(_deserialize(resp["Attributes"]))
        except ClientError as exc:
            if _is_conditional_failure(exc):
                return None
            raise

    def finalize_terminal(self, record: IdempotencyRecord, response_status: int, response_body: dict) -> bool:
        now = self.clock()
        try:
            self._call(
                "write", self.client.update_item, TableName=self.table, Key=_serialize({"PK": record.pk, "SK": "META"}),
                UpdateExpression="SET #s = :failed, response_status = :rs, response_body = :rb, updated_at = :now_iso",
                ConditionExpression="owner_token = :tok AND version = :v AND #s = :inprog",
                ExpressionAttributeNames={"#s": "status"},
                ExpressionAttributeValues=_serialize({
                    ":failed": IdemStatus.FAILED_TERMINAL.value, ":rs": response_status,
                    ":rb": json.dumps(response_body, separators=(",", ":")), ":now_iso": _iso(now),
                    ":tok": record.owner_token, ":v": record.version, ":inprog": IdemStatus.IN_PROGRESS.value,
                }),
            )
            return True
        except ClientError as exc:
            if _is_conditional_failure(exc):
                return False
            raise

    def complete(self, record: IdempotencyRecord, order: dict[str, Any], response_body: dict) -> None:
        """Persiste o pedido e finaliza a idempotência ATOMICAMENTE (TransactWriteItems)."""
        now = self.clock()
        order_item = {
            "PK": order_pk(order["order_id"]), "SK": "META", "entity": "ORDER",
            "GSI1PK": f"CUSTOMER#{order['customer_id']}", "GSI1SK": f"CREATED#{order['created_at']}#{order['order_id']}",
            "order_id": order["order_id"], "customer_id": order["customer_id"], "status": order["status"],
            "items": order["items"], "total_amount": order["total_amount"], "currency": order["currency"],
            "created_at": order["created_at"], "reservation_id": order["reservation_id"],
            "idempotency_key": record.idempotency_key,
        }
        request = dict(
            TransactItems=[
                {"Put": {"TableName": self.table, "Item": _serialize(order_item),
                         "ConditionExpression": "attribute_not_exists(PK)"}},
                {"Update": {
                    "TableName": self.table, "Key": _serialize({"PK": record.pk, "SK": "META"}),
                    "UpdateExpression": "SET #s = :completed, response_status = :rs, response_body = :rb, "
                                        "reservation_state = :confirmed, updated_at = :now_iso",
                    "ConditionExpression": "owner_token = :tok AND version = :v AND #s = :inprog",
                    "ExpressionAttributeNames": {"#s": "status"},
                    "ExpressionAttributeValues": _serialize({
                        ":completed": IdemStatus.COMPLETED.value, ":rs": 201,
                        ":rb": json.dumps(response_body, separators=(",", ":")),
                        ":confirmed": ReservationState.CONFIRMED.value, ":now_iso": _iso(now),
                        ":tok": record.owner_token, ":v": record.version, ":inprog": IdemStatus.IN_PROGRESS.value,
                    }),
                }},
            ],
            # Token estável por (pedido, versão): retries do SDK não reaplicam a transação.
            # NÃO é o mecanismo de idempotência de 24h da aplicação (ele vale ~10 minutos).
            ClientRequestToken=str(uuid.uuid5(uuid.NAMESPACE_URL, f"{order['order_id']}:{record.version}")),
        )
        try:
            self._call("transact", self.client.transact_write_items, **request)
        except ClientError as exc:
            if exc.response.get("Error", {}).get("Code") == "TransactionCanceledException":
                reasons = [r.get("Code", "None") for r in exc.response.get("CancellationReasons", [])]
                raise TransactionCancelled(reasons) from exc
            raise
        if self.fault_mode == DbFaultMode.TRANSACT_UNKNOWN_AFTER_COMMIT:
            raise DynamoUnavailable("timeout simulado APÓS commit (resultado desconhecido para o chamador)")

    # ------------------------------------------------------------------ orders
    def get_order(self, order_id: str) -> dict[str, Any] | None:
        resp = self._call("read", self.client.get_item, TableName=self.table,
                          Key=_serialize({"PK": order_pk(order_id), "SK": "META"}))
        item = resp.get("Item")
        return order_view(_deserialize(item)) if item else None

    def list_orders(self, customer_id: str, limit: int, next_token: str | None) -> tuple[list[dict], str | None]:
        kwargs: dict[str, Any] = dict(
            TableName=self.table, IndexName="GSI1", KeyConditionExpression="GSI1PK = :pk",
            ExpressionAttributeValues=_serialize({":pk": f"CUSTOMER#{customer_id}"}), Limit=limit, ScanIndexForward=False,
        )
        if next_token:
            kwargs["ExclusiveStartKey"] = json.loads(base64.urlsafe_b64decode(next_token.encode()).decode())
        resp = self._call("read", self.client.query, **kwargs)
        orders = [order_view(_deserialize(i)) for i in resp.get("Items", [])]
        lek = resp.get("LastEvaluatedKey")
        token = base64.urlsafe_b64encode(json.dumps(lek).encode()).decode() if lek else None
        return orders, token


def order_view(item: dict[str, Any]) -> dict[str, Any]:
    return {
        "order_id": item["order_id"],
        "customer_id": item["customer_id"],
        "items": [{"sku": i["sku"], "quantity": int(i["quantity"]), "unit_price": i["unit_price"]} for i in item["items"]],
        "total_amount": item["total_amount"],
        "currency": item.get("currency", "BRL"),
        "status": item["status"],
        "created_at": item["created_at"],
    }
