"""Orquestração da criação de pedidos — modo STRICT com idempotência end-to-end.

Um pedido só recebe status CONFIRMED após (1) reserva de estoque confirmada e
(2) persistência atômica (pedido + finalização da idempotência) no DynamoDB.
"""

from __future__ import annotations

import asyncio
import logging
import math
import os
import time
from dataclasses import dataclass, field
from typing import Any

from opentelemetry import trace

from . import metrics as m
from .config import Settings
from .inventory_client import DependencyUnavailable, InventoryClient
from .models import CreateOrderRequest, new_order_id, reservation_id_for, reservation_key_for
from .repository import (
    DynamoUnavailable, IdempotencyRecord, IdemStatus, OrdersRepository, ReservationState, TransactionCancelled, _iso,
)
from workshop_common.http import error_body
from workshop_common.stress import burn_cpu

log = logging.getLogger("orders.service")
tracer = trace.get_tracer("orders-api")


@dataclass
class OrderResult:
    status: int
    body: dict[str, Any]
    headers: dict[str, str] = field(default_factory=dict)
    outcome: str = "created"


@dataclass
class RuntimeFaults:
    crash_after_reservation: bool = False


class OrderService:
    def __init__(self, settings: Settings, repo: OrdersRepository, inventory: InventoryClient) -> None:
        self.settings = settings
        self.repo = repo
        self.inventory = inventory
        self.faults = RuntimeFaults()

    # ================================================================== entrada
    async def create(self, customer_id: str, key: str, req: CreateOrderRequest) -> OrderResult:
        start = time.perf_counter()
        span = trace.get_current_span()
        span.set_attributes({"idempotency.key": key, "customer.id": customer_id})
        try:
            result = await self._create(customer_id, key, req)
        except DynamoUnavailable as exc:
            log.error("DynamoDB indisponível durante a criação do pedido",
                      extra={"idempotency.key": key, "error.message": str(exc), "http.response.status_code": 503})
            result = self._dependency_unavailable("dynamodb", 2, outcome="dynamodb_unavailable")
        replayed = result.headers.get("Idempotency-Replayed") == "true"
        result.headers.setdefault("Idempotency-Replayed", "false")
        span.set_attributes({"idempotency.replayed": replayed, "orders.outcome": result.outcome})
        m.orders_creation_duration.record((time.perf_counter() - start) * 1000, {"outcome": result.outcome})
        if result.status >= 400 and not replayed and result.outcome not in ("in_progress", "conflict"):
            m.orders_failed.add(1, {"reason": result.outcome})
        return result

    async def _create(self, customer_id: str, key: str, req: CreateOrderRequest) -> OrderResult:
        s = self.settings
        request_hash = req.request_hash()
        for _ in range(3):
            with tracer.start_as_current_span("Idempotency Claim") as span:
                claimed, record = await asyncio.to_thread(
                    self.repo.claim, customer_id=customer_id, key=key, request_hash=request_hash,
                    order_id=new_order_id(), lease_seconds=s.idempotency_lease_seconds, ttl_seconds=s.idempotency_ttl_seconds,
                )
                span.set_attribute("idempotency.claimed", claimed)
                if record is not None:
                    span.set_attributes({"idempotency.status": record.status.value, "idempotency.version": record.version,
                                         "order.id": record.order_id})
            if claimed:
                log.info("Idempotency record criado (IN_PROGRESS)", extra=self._ctx(record))
                return await self._execute(record, req)
            if record is None:
                continue  # removido entre a escrita condicional e a leitura; tentar novamente

            now = self.repo.clock()
            if record.expires_at <= now:
                # Janela de retenção (24h) expirada, TTL ainda não removeu o item: NOVA operação.
                fresh = await asyncio.to_thread(
                    self.repo.replace_expired, record, request_hash=request_hash, order_id=new_order_id(),
                    lease_seconds=s.idempotency_lease_seconds, ttl_seconds=s.idempotency_ttl_seconds,
                )
                if fresh:
                    log.info("Idempotency record expirado substituído por nova operação", extra=self._ctx(fresh))
                    return await self._execute(fresh, req)
                continue

            if record.request_hash != request_hash:
                m.idempotency_conflict.add(1)
                log.warning("Idempotency-Key reutilizada com payload diferente", extra=self._ctx(record))
                return OrderResult(409, error_body("IDEMPOTENCY_KEY_REUSED",
                                                   "Idempotency-Key já utilizada com um payload diferente"), outcome="conflict")

            if record.status in (IdemStatus.COMPLETED, IdemStatus.FAILED_TERMINAL):
                return self._replay(record)

            # IN_PROGRESS
            if record.lease_expires_at > now:
                m.idempotency_in_progress.add(1)
                m.idempotency_duplicate_prevented.add(1, {"stage": "in_progress"})
                retry_after = max(1, math.ceil(record.lease_expires_at - now))
                log.info("Operação em andamento para esta Idempotency-Key", extra=self._ctx(record))
                return OrderResult(409, error_body("ORDER_IN_PROGRESS", "Pedido com esta Idempotency-Key em processamento",
                                                   order_id=record.order_id),
                                   {"Retry-After": str(retry_after)}, outcome="in_progress")

            taken = await asyncio.to_thread(self.repo.takeover, record, s.idempotency_lease_seconds)
            if taken is not None:
                m.idempotency_recovery.add(1)
                log.warning("Lease expirado: operação IN_PROGRESS assumida por este executor (recovery)",
                            extra=self._ctx(taken))
                return await self._execute(taken, req)
        m.idempotency_in_progress.add(1)
        return OrderResult(409, error_body("ORDER_IN_PROGRESS", "Contenção na Idempotency-Key, tente novamente"),
                           {"Retry-After": "1"}, outcome="in_progress")

    # ================================================================== execução (executor dono)
    async def _execute(self, rec: IdempotencyRecord, req: CreateOrderRequest) -> OrderResult:
        trace.get_current_span().set_attributes({"order.id": rec.order_id, "idempotency.version": rec.version})
        with tracer.start_as_current_span("Validate Order") as span:
            total = req.total_amount()
            span.set_attributes({"order.items": len(req.items), "order.total_amount": str(total)})
            if self.settings.cpu_work_ms:
                await asyncio.to_thread(burn_cpu, self.settings.cpu_work_ms)

        reservation_id = reservation_id_for(rec.order_id)
        items = [{"sku": i.sku, "quantity": i.quantity} for i in req.items]

        # Pré-consulta de estoque apenas na PRIMEIRA tentativa: em recuperação, a reserva
        # pode já existir e consumir o próprio estoque (a reserva é a fonte de verdade).
        if self.settings.stock_precheck and rec.attempts == 1 and rec.reservation_state == ReservationState.PENDING:
            with tracer.start_as_current_span("Check Inventory"):
                try:
                    for item in req.items:
                        resp = await self.inventory.get_stock(item.sku)
                        if resp.status_code == 404:
                            return await self._terminal(rec, 422, "UNKNOWN_SKU", f"SKU {item.sku} inexistente", sku=item.sku)
                        if resp.status_code == 200 and int(resp.body.get("available", 0)) < item.quantity:
                            return await self._terminal(rec, 409, "INSUFFICIENT_STOCK", "Estoque insuficiente", sku=item.sku,
                                                        available=resp.body.get("available"), requested=item.quantity)
                except DependencyUnavailable as exc:
                    return await self._dependency_failure(rec, exc, ReservationState.PENDING)

        with tracer.start_as_current_span("Reserve Inventory") as span:
            span.set_attributes({"inventory.reservation_id": reservation_id, "inventory.fencing_token": rec.version})
            try:
                resp = await self.inventory.reserve(reservation_id, reservation_key_for(rec.order_id), rec.order_id,
                                                    items, fencing_token=rec.version)
            except DependencyUnavailable as exc:
                state = ReservationState.UNKNOWN if exc.outcome_unknown else rec.reservation_state
                return await self._dependency_failure(rec, exc, state)
            code = resp.body.get("error") or resp.body.get("outcome")
            span.set_attribute("inventory.outcome", str(code))

        if resp.status_code in (200, 201):
            if resp.status_code == 200:
                m.idempotency_duplicate_prevented.add(1, {"stage": "reservation"})
                log.info("Reserva já existente reutilizada (não decrementou estoque novamente)", extra=self._ctx(rec))
        elif resp.status_code == 409 and code == "INSUFFICIENT_STOCK":
            return await self._terminal(rec, 409, "INSUFFICIENT_STOCK", "Estoque insuficiente", sku=resp.body.get("sku"))
        elif resp.status_code == 422:
            return await self._terminal(rec, 422, "UNKNOWN_SKU", "SKU inexistente", sku=resp.body.get("sku"))
        elif resp.status_code == 409 and code == "STALE_FENCING_TOKEN":
            log.warning("Executor superado por outro (fencing token antigo); abortando sem efeitos", extra=self._ctx(rec))
            return await self._resolve_from_store(rec)
        else:
            log.error("Resposta inesperada da Inventory API", extra={**self._ctx(rec), "http.response.status_code": resp.status_code,
                                                                     "inventory.error": str(code)})
            await self._release_lease(rec, rec.reservation_state, f"inventory_unexpected_{resp.status_code}")
            return OrderResult(500, error_body("INTERNAL_ERROR", "Resposta inesperada da Inventory API"), outcome="internal_error")

        if self.faults.crash_after_reservation:
            log.critical("FALHA INJETADA: encerrando o processo após a reserva (simula crash do Pod)", extra=self._ctx(rec))
            logging.shutdown()
            os._exit(137)

        try:
            marked = await asyncio.to_thread(self.repo.update_owned, rec, reservation_state=ReservationState.RESERVED)
        except DynamoUnavailable:
            marked = rec  # segue: a transação abaixo decidirá (e a falha cairá na compensação)
        if marked is None:
            return await self._resolve_from_store(rec)
        rec = marked

        now = self.repo.clock()
        order = {
            "order_id": rec.order_id, "customer_id": req.customer_id, "status": "CONFIRMED",
            "items": [{"sku": i.sku, "quantity": i.quantity, "unit_price": str(i.unit_price)} for i in req.items],
            "total_amount": str(total), "currency": req.currency, "created_at": _iso(now), "reservation_id": reservation_id,
        }
        body = {k: order[k] for k in ("order_id", "customer_id", "items", "total_amount", "currency", "status", "created_at")}
        with tracer.start_as_current_span("Complete Order") as span:
            try:
                await asyncio.to_thread(self.repo.complete, rec, order, body)
            except TransactionCancelled as exc:
                span.set_attribute("dynamodb.cancellation_reasons", ",".join(exc.reasons))
                if exc.condition_failed:
                    return await self._resolve_from_store(rec)
                return await self._compensate(rec, f"transaction_cancelled:{exc}")
            except DynamoUnavailable as exc:
                span.set_status(trace.Status(trace.StatusCode.ERROR, str(exc)))
                log.error("Falha ao persistir pedido no DynamoDB após reserva",
                          extra={**self._ctx(rec), "error.message": str(exc), "http.response.status_code": 503})
                return await self._compensate(rec, str(exc))

        m.orders_created.add(1)
        log.info("Pedido CONFIRMED", extra={**self._ctx(rec), "order.total_amount": str(total)})
        return OrderResult(201, body, {"Idempotency-Replayed": "false", "Location": f"/orders/{rec.order_id}"})

    # ================================================================== compensação
    async def _compensate(self, rec: IdempotencyRecord, reason: str) -> OrderResult:
        """Reserva concluída + persistência falhou. Nunca compensa às cegas."""
        with tracer.start_as_current_span("Compensate Order") as span:
            span.set_attributes({"order.id": rec.order_id, "compensation.reason": reason[:200]})
            # 1-2. Consultar o estado atual: o pedido pode TER SIDO persistido (resultado desconhecido).
            try:
                current = await asyncio.to_thread(self.repo.get_record, rec.pk)
            except DynamoUnavailable:
                span.set_attribute("compensation.result", "state_unknown_kept_recoverable")
                log.error("Resultado desconhecido e estado inacessível: SEM compensação; lease expirará para recuperação",
                          extra=self._ctx(rec))
                return self._dependency_unavailable("dynamodb", math.ceil(self.settings.idempotency_lease_seconds))
            if current is not None and current.status == IdemStatus.COMPLETED and current.order_id == rec.order_id:
                span.set_attribute("compensation.result", "already_persisted")
                log.warning("Resultado desconhecido resolvido: o pedido JÁ estava persistido (sem compensação)",
                            extra=self._ctx(current))
                m.orders_created.add(1)
                return OrderResult(201, current.response_body or {}, {"Idempotency-Replayed": "false"})
            if current is None or current.owner_token != rec.owner_token or current.version != rec.version \
                    or current.status != IdemStatus.IN_PROGRESS:
                span.set_attribute("compensation.result", "ownership_lost")
                return await self._resolve_from_store(rec, current)

            # 3. FENCE: incrementa version. Uma transação "em voo" com a versão antiga nunca mais confirmará.
            try:
                fenced = await asyncio.to_thread(self.repo.update_owned, rec, bump_version=True, last_error=reason)
            except DynamoUnavailable:
                span.set_attribute("compensation.result", "fence_failed_kept_recoverable")
                return self._dependency_unavailable("dynamodb", math.ceil(self.settings.idempotency_lease_seconds))
            if fenced is None:
                return await self._resolve_from_store(rec)

            # 4. Liberação idempotente da reserva, com o novo fencing token.
            state = ReservationState.RELEASED
            try:
                resp = await self.inventory.release(reservation_id_for(rec.order_id), fenced.version)
                if resp.status_code == 409:
                    span.set_attribute("compensation.result", "stale_token")
                    return await self._resolve_from_store(fenced)
                m.compensations.add(1, {"result": "released"})
            except DependencyUnavailable:
                state = ReservationState.COMPENSATION_PENDING
                m.compensations.add(1, {"result": "pending"})
            span.set_attribute("compensation.result", state.value)
            log.warning("Compensação executada após falha de persistência", extra={**self._ctx(fenced),
                                                                                   "reservation.state": state.value})
            # 5. Mantém IN_PROGRESS (falha transitória ≠ FAILED_TERMINAL) e libera o lease para retry imediato.
            await self._release_lease(fenced, state, reason)
            return self._dependency_unavailable("dynamodb", 1)

    # ================================================================== helpers
    async def _terminal(self, rec: IdempotencyRecord, status: int, code: str, message: str, **extra: object) -> OrderResult:
        body = error_body(code, message, order_id=rec.order_id, **extra)
        body.pop("request_id", None)  # resposta armazenada não deve carregar o request_id da 1ª tentativa
        try:
            ok = await asyncio.to_thread(self.repo.finalize_terminal, rec, status, body)
        except DynamoUnavailable:
            ok = True  # resposta ainda é correta; o registro permanece IN_PROGRESS e será reavaliado
        if not ok:
            return await self._resolve_from_store(rec)
        log.warning("Pedido rejeitado (FAILED_TERMINAL)", extra={**self._ctx(rec), "error.code": code})
        return OrderResult(status, body, outcome=code.lower())

    async def _dependency_failure(self, rec: IdempotencyRecord, exc: DependencyUnavailable,
                                  state: ReservationState) -> OrderResult:
        log.error("Inventory API indisponível", extra={**self._ctx(rec), "dependency.reason": exc.reason,
                                                       "reservation.state": state.value, "http.response.status_code": 503})
        await self._release_lease(rec, state, f"inventory:{exc.reason}")
        return self._dependency_unavailable("inventory-api", max(1, math.ceil(exc.retry_after)),
                                            reason=exc.reason, outcome=f"inventory_{exc.reason.split(':')[0]}")

    async def _release_lease(self, rec: IdempotencyRecord, state: ReservationState, error: str) -> None:
        try:
            await asyncio.to_thread(self.repo.update_owned, rec, reservation_state=state, release_lease=True, last_error=error)
        except DynamoUnavailable:
            pass  # o lease expira sozinho

    async def _resolve_from_store(self, rec: IdempotencyRecord, current: IdempotencyRecord | None = None) -> OrderResult:
        """Perdemos a posse (fencing). Responde com base no estado persistido, sem efeitos colaterais."""
        if current is None:
            current = await asyncio.to_thread(self.repo.get_record, rec.pk)
        if current is not None and current.status in (IdemStatus.COMPLETED, IdemStatus.FAILED_TERMINAL):
            return self._replay(current)
        m.idempotency_in_progress.add(1)
        return OrderResult(409, error_body("ORDER_IN_PROGRESS", "Pedido sendo processado por outro executor",
                                           order_id=rec.order_id), {"Retry-After": "1"}, outcome="in_progress")

    def _replay(self, record: IdempotencyRecord) -> OrderResult:
        m.idempotency_hit.add(1, {"status": record.status.value})
        m.idempotency_duplicate_prevented.add(1, {"stage": "replay"})
        log.info("Replay de resposta idempotente", extra=self._ctx(record))
        return OrderResult(record.response_status or 500, record.response_body or {}, {"Idempotency-Replayed": "true"},
                           outcome="replayed")

    @staticmethod
    def _dependency_unavailable(dependency: str, retry_after: int, reason: str | None = None,
                                outcome: str = "dependency_unavailable") -> OrderResult:
        return OrderResult(503, error_body("DEPENDENCY_UNAVAILABLE", f"Dependência temporariamente indisponível: {dependency}",
                                           dependency=dependency, reason=reason),
                           {"Retry-After": str(retry_after)}, outcome=outcome)

    @staticmethod
    def _ctx(rec: IdempotencyRecord) -> dict[str, object]:
        return {"idempotency.key": rec.idempotency_key, "order.id": rec.order_id, "idempotency.status": rec.status.value,
                "idempotency.version": rec.version, "idempotency.attempts": rec.attempts,
                "reservation.state": rec.reservation_state.value}
