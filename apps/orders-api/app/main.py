"""Orders API — lógica de negócio, idempotência, Circuit Breaker e persistência no DynamoDB."""

from __future__ import annotations

import asyncio
import base64
import json
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, Header, Query, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, ValidationError

from workshop_common.config import env_bool
from workshop_common.health import HealthState, health_router
from workshop_common.http import ApiError, RequestContextMiddleware, error_body, install_error_handlers
from workshop_common.stress import burn_cpu
from workshop_common.telemetry import instrument_fastapi, setup_telemetry

SERVICE_NAME = "orders-api"
telemetry = setup_telemetry(SERVICE_NAME)

from opentelemetry.instrumentation.botocore import BotocoreInstrumentor  # noqa: E402

BotocoreInstrumentor().instrument()

import boto3  # noqa: E402
from botocore.config import Config  # noqa: E402

from .config import Settings  # noqa: E402
from .inventory_client import InventoryClient  # noqa: E402
from .models import CreateOrderRequest, normalize_idempotency_key, valid_identifier  # noqa: E402
from .repository import DbFaultMode, DynamoUnavailable, OrdersRepository  # noqa: E402
from .service import OrderService  # noqa: E402

log = logging.getLogger("orders")
settings = Settings.from_env()
health = HealthState()


def build_dynamodb_client(s: Settings):
    return boto3.client(
        "dynamodb", region_name=s.aws_region, endpoint_url=s.dynamodb_endpoint,
        config=Config(connect_timeout=1, read_timeout=2, retries={"mode": "standard", "max_attempts": 3},
                      max_pool_connections=50),
    )


repo = OrdersRepository(build_dynamodb_client(settings), settings.table_name)
inventory = InventoryClient(settings)
service = OrderService(settings, repo, inventory)


async def _warmup() -> None:
    """Startup: valida credenciais (Pod Identity) e acesso à tabela com um GetItem barato."""
    delay = 1.0
    while not health.started:
        try:
            await asyncio.to_thread(repo.get_order, "__warmup__")
            health.started = True
            health.details.pop("last_error", None)
            log.info("Warm-up do DynamoDB concluído", extra={"dynamodb.table": settings.table_name})
        except Exception as exc:  # noqa: BLE001
            health.details["last_error"] = f"{type(exc).__name__}: {exc}"[:300]
            log.error("Warm-up do DynamoDB falhou; nova tentativa", extra={"error.message": str(exc)[:300]})
            await asyncio.sleep(delay)
            delay = min(delay * 2, 10)


@asynccontextmanager
async def lifespan(_: FastAPI):
    task = asyncio.create_task(_warmup())
    yield
    task.cancel()
    await inventory.close()
    telemetry.shutdown()


app = FastAPI(title="Orders API", version="1.0.0", lifespan=lifespan)
app.add_middleware(RequestContextMiddleware, log_health=env_bool("LOG_HEALTH_REQUESTS", False))
install_error_handlers(app)
app.include_router(health_router(health))
instrument_fastapi(app)


def _identity(header_customer: str | None, body_customer: str | None) -> str:
    """Identidade SIMULADA do workshop: X-Customer-ID (injetado pela BFF) ou customer_id do body.

    Em produção a identidade deve vir de um token autenticado (ex.: JWT validado), nunca do body.
    """
    if header_customer is not None:
        if not valid_identifier(header_customer):
            raise ApiError(400, "INVALID_CUSTOMER_ID", "X-Customer-ID inválido")
        if body_customer is not None and body_customer != header_customer:
            raise ApiError(403, "CUSTOMER_MISMATCH", "customer_id do payload difere da identidade autenticada")
        return header_customer
    if body_customer is None:
        raise ApiError(400, "CUSTOMER_ID_REQUIRED", "customer_id é obrigatório")
    return body_customer


@app.post("/orders")
async def create_order(request: Request, idempotency_key: str | None = Header(default=None),
                       x_customer_id: str | None = Header(default=None)):
    key = normalize_idempotency_key(idempotency_key)
    if key is None:
        raise ApiError(400, "INVALID_IDEMPOTENCY_KEY", "Header Idempotency-Key ausente ou não é um UUID válido")
    try:
        payload = await request.json()
        order_req = CreateOrderRequest.model_validate(payload)
    except (ValueError, ValidationError) as exc:
        details = exc.errors(include_url=False, include_input=False) if isinstance(exc, ValidationError) else str(exc)
        raise ApiError(400, "INVALID_PAYLOAD", "Payload inválido", details=json.loads(json.dumps(details, default=str)))
    customer_id = _identity(x_customer_id, order_req.customer_id)
    result = await service.create(customer_id, key, order_req)
    return JSONResponse(result.body, status_code=result.status, headers=result.headers)


@app.get("/orders")
async def list_orders(customer_id: str | None = Query(default=None), limit: int = Query(default=20, ge=1, le=100),
                      next_token: str | None = Query(default=None), x_customer_id: str | None = Header(default=None)):
    customer = _identity(x_customer_id, customer_id)
    if not valid_identifier(customer):
        raise ApiError(400, "INVALID_CUSTOMER_ID", "customer_id inválido")
    if next_token:
        try:
            decoded = json.loads(base64.urlsafe_b64decode(next_token.encode()).decode())
            if decoded.get("GSI1PK", {}).get("S") != f"CUSTOMER#{customer}":
                raise ValueError("token de outro cliente")
        except Exception as exc:  # noqa: BLE001
            raise ApiError(400, "INVALID_NEXT_TOKEN", "next_token inválido") from exc
    if service.settings.cpu_work_ms:
        await asyncio.to_thread(burn_cpu, service.settings.cpu_work_ms)
    try:
        orders, token = await asyncio.to_thread(repo.list_orders, customer, limit, next_token)
    except DynamoUnavailable as exc:
        log.error("DynamoDB indisponível ao listar pedidos", extra={"error.message": str(exc), "http.response.status_code": 503})
        raise ApiError(503, "DEPENDENCY_UNAVAILABLE", "DynamoDB temporariamente indisponível", {"Retry-After": "2"})
    return {"orders": orders, "next_token": token, "count": len(orders)}


@app.get("/orders/{order_id}")
async def get_order(order_id: str, x_customer_id: str | None = Header(default=None)):
    if not valid_identifier(order_id):
        raise ApiError(400, "INVALID_ORDER_ID", "order_id inválido")
    try:
        order = await asyncio.to_thread(repo.get_order, order_id)
    except DynamoUnavailable as exc:
        log.error("DynamoDB indisponível ao consultar pedido",
                  extra={"error.message": str(exc), "order.id": order_id, "http.response.status_code": 503})
        raise ApiError(503, "DEPENDENCY_UNAVAILABLE", "DynamoDB temporariamente indisponível", {"Retry-After": "2"})
    if order is None or (x_customer_id is not None and order["customer_id"] != x_customer_id):
        raise ApiError(404, "ORDER_NOT_FOUND", "Pedido não encontrado")
    return order


# --------------------------------------------------------------------------------------
# API administrativa de laboratório: escuta apenas em 127.0.0.1
# --------------------------------------------------------------------------------------
admin_app = FastAPI(title="Orders Admin (workshop only)")


class OrdersFaults(BaseModel):
    cpu_work_ms: int = Field(ge=0, le=2000)
    db_fault_mode: DbFaultMode
    crash_after_reservation: bool
    inventory_timeout_ms: int = Field(ge=50, le=30_000)


def _faults() -> dict:
    return {"cpu_work_ms": service.settings.cpu_work_ms, "db_fault_mode": repo.fault_mode.value,
            "crash_after_reservation": service.faults.crash_after_reservation,
            "inventory_timeout_ms": inventory.timeout_ms}


@admin_app.get("/admin/faults")
async def get_faults():
    return _faults()


@admin_app.put("/admin/faults")
async def put_faults(request: Request):
    cfg = OrdersFaults(**{**_faults(), **(await request.json())})
    service.settings.cpu_work_ms = cfg.cpu_work_ms
    repo.fault_mode = cfg.db_fault_mode
    service.faults.crash_after_reservation = cfg.crash_after_reservation
    inventory.timeout_ms = cfg.inventory_timeout_ms
    log.warning("Configuração de falhas alterada", extra={"faults": _faults()})
    return _faults()


@admin_app.post("/admin/faults/reset")
async def reset_faults():
    fresh = Settings.from_env()
    service.settings.cpu_work_ms = fresh.cpu_work_ms
    repo.fault_mode = DbFaultMode.NONE
    service.faults.crash_after_reservation = False
    inventory.timeout_ms = fresh.inventory_timeout_ms
    return _faults()


@admin_app.get("/admin/circuit-breaker")
async def circuit_breaker():
    return inventory.circuit.snapshot()


@admin_app.post("/admin/circuit-breaker/reset")
async def circuit_breaker_reset():
    inventory.circuit.reset()
    return inventory.circuit.snapshot()


@admin_app.get("/admin/idempotency/{customer_id}/{key}")
async def idempotency_record(customer_id: str, key: str):
    from .repository import idempotency_pk

    record = await asyncio.to_thread(repo.get_record, idempotency_pk(customer_id, key))
    if record is None:
        return JSONResponse(error_body("NOT_FOUND", "registro inexistente"), status_code=404)
    data = {k: v for k, v in record.__dict__.items() if k not in ("raw", "owner_token")}
    return json.loads(json.dumps(data, default=str))
