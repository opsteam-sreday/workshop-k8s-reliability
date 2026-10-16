"""BFF API — ponto de entrada externo. Valida formato básico e encaminha à Orders API.

Não acessa DynamoDB e não persiste pedidos. NÃO faz retry de POST /orders: o retry
é responsabilidade do cliente (com a mesma Idempotency-Key), evitando amplificação.
"""

from __future__ import annotations

import logging
import re
import uuid
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, Header, Request
from fastapi.responses import JSONResponse, Response

from workshop_common.config import env_bool, env_int, env_str
from workshop_common.context import current_request_id
from workshop_common.health import HealthState, health_admin_router, health_router
from workshop_common.http import ApiError, RequestContextMiddleware, install_error_handlers
from workshop_common.telemetry import instrument_fastapi, setup_telemetry

SERVICE_NAME = "bff-api"
telemetry = setup_telemetry(SERVICE_NAME)
log = logging.getLogger("bff")
health = HealthState()

ORDERS_URL = env_str("ORDERS_URL", "http://orders-api:8080")
_ID_RE = re.compile(r"^[A-Za-z0-9._:-]{1,64}$")
_PASSTHROUGH_HEADERS = ("idempotency-replayed", "retry-after", "location")


class Upstream:
    def __init__(self) -> None:
        self.timeout_ms = env_int("BFF_ORDERS_TIMEOUT_MS", 3000)
        pool = env_int("BFF_MAX_CONNECTIONS", 100)
        self.client = httpx.AsyncClient(
            base_url=ORDERS_URL,
            timeout=httpx.Timeout(self.timeout_ms / 1000),
            limits=httpx.Limits(max_connections=pool, max_keepalive_connections=pool // 2),
        )

    async def forward(self, method: str, path: str, headers: dict[str, str], **kwargs) -> Response:
        headers = {**headers, "X-Request-ID": current_request_id() or str(uuid.uuid4())}
        try:
            resp = await self.client.request(method, path, headers=headers, timeout=self.timeout_ms / 1000, **kwargs)
        except httpx.TimeoutException:
            log.error("Timeout chamando a Orders API", extra={"upstream": "orders-api", "timeout_ms": self.timeout_ms})
            raise ApiError(504, "UPSTREAM_TIMEOUT",
                           "Orders API não respondeu a tempo. Repita com a MESMA Idempotency-Key.")
        except httpx.TransportError as exc:
            log.error("Orders API inacessível", extra={"upstream": "orders-api", "error.type": type(exc).__name__})
            raise ApiError(503, "DEPENDENCY_UNAVAILABLE", "Orders API indisponível", {"Retry-After": "1"})
        out_headers = {k: v for k, v in resp.headers.items() if k.lower() in _PASSTHROUGH_HEADERS}
        return Response(resp.content, status_code=resp.status_code, headers=out_headers,
                        media_type=resp.headers.get("content-type", "application/json"))


upstream: Upstream | None = None


@asynccontextmanager
async def lifespan(_: FastAPI):
    global upstream
    upstream = Upstream()
    health.started = True
    yield
    await upstream.client.aclose()
    telemetry.shutdown()


app = FastAPI(title="BFF API", version="1.0.0", lifespan=lifespan)
app.add_middleware(RequestContextMiddleware, log_health=env_bool("LOG_HEALTH_REQUESTS", False))
install_error_handlers(app)
app.include_router(health_router(health))
instrument_fastapi(app)


def _identity_headers(x_customer_id: str | None) -> dict[str, str]:
    """Identidade SIMULADA: X-Customer-ID representa o usuário autenticado (em produção: JWT validado)."""
    if x_customer_id is None:
        return {}
    if not _ID_RE.match(x_customer_id):
        raise ApiError(400, "INVALID_CUSTOMER_ID", "X-Customer-ID inválido")
    return {"X-Customer-ID": x_customer_id}


# Só documentação (Swagger): a BFF lê o JSON cru e deixa a validação completa para a Orders API.
_ORDER_EXAMPLE = {"customer_id": "customer-123",
                  "items": [{"sku": "product-001", "quantity": 2, "unit_price": "49.90"}]}
_ORDER_BODY_OPENAPI = {"requestBody": {"required": True, "content": {"application/json": {
    "schema": {
        "type": "object", "required": ["customer_id", "items"],
        "properties": {
            "customer_id": {"type": "string", "maxLength": 64, "pattern": "^[A-Za-z0-9._:-]+$"},
            "items": {"type": "array", "minItems": 1, "maxItems": 50, "items": {
                "type": "object", "required": ["sku", "quantity", "unit_price"],
                "properties": {
                    "sku": {"type": "string", "description": "product-001 … product-010, product-limited"},
                    "quantity": {"type": "integer", "minimum": 1, "maximum": 1000},
                    "unit_price": {"type": "string", "description": "Decimal com até 2 casas", "example": "49.90"},
                }}},
            "currency": {"type": "string", "default": "BRL", "pattern": "^[A-Z]{3}$"},
        }},
    "example": _ORDER_EXAMPLE,
}}}}


@app.post("/orders", openapi_extra=_ORDER_BODY_OPENAPI)
async def create_order(request: Request, idempotency_key: str | None = Header(default=None),
                       x_customer_id: str | None = Header(default=None)):
    try:
        key = str(uuid.UUID(idempotency_key or ""))
        if key != (idempotency_key or "").strip().lower():
            raise ValueError
    except ValueError:
        raise ApiError(400, "INVALID_IDEMPOTENCY_KEY", "Header Idempotency-Key obrigatório (UUID)")
    try:
        body = await request.json()
    except ValueError:
        raise ApiError(400, "INVALID_PAYLOAD", "Corpo JSON inválido")
    if not isinstance(body, dict) or not isinstance(body.get("items"), list) or not body.get("items"):
        raise ApiError(400, "INVALID_PAYLOAD", "Payload deve conter customer_id e items[]")
    if x_customer_id is not None and body.get("customer_id") not in (None, x_customer_id):
        raise ApiError(403, "CUSTOMER_MISMATCH", "customer_id do payload difere da identidade autenticada")
    headers = {"Idempotency-Key": key, **_identity_headers(x_customer_id)}
    return await upstream.forward("POST", "/orders", headers, json=body)


@app.get("/orders")
async def list_orders(request: Request, x_customer_id: str | None = Header(default=None)):
    params = {k: v for k, v in request.query_params.items() if k in ("customer_id", "limit", "next_token")}
    return await upstream.forward("GET", "/orders", _identity_headers(x_customer_id), params=params)


@app.get("/orders/{order_id}")
async def get_order(order_id: str, x_customer_id: str | None = Header(default=None)):
    if not _ID_RE.match(order_id):
        raise ApiError(400, "INVALID_ORDER_ID", "order_id inválido")
    return await upstream.forward("GET", f"/orders/{order_id}", _identity_headers(x_customer_id))


admin_app = FastAPI(title="BFF Admin (workshop only)")
admin_app.include_router(health_admin_router(health))


@admin_app.get("/admin/faults")
async def get_faults():
    return {"orders_timeout_ms": upstream.timeout_ms}


@admin_app.put("/admin/faults")
async def put_faults(request: Request):
    patch = await request.json()
    timeout = int(patch.get("orders_timeout_ms", upstream.timeout_ms))
    if not 50 <= timeout <= 60_000:
        return JSONResponse({"error": "orders_timeout_ms fora do intervalo 50..60000"}, status_code=400)
    upstream.timeout_ms = timeout
    log.warning("Timeout da BFF alterado", extra={"orders_timeout_ms": timeout})
    return {"orders_timeout_ms": upstream.timeout_ms}


@admin_app.post("/admin/faults/reset")
async def reset_faults():
    upstream.timeout_ms = env_int("BFF_ORDERS_TIMEOUT_MS", 3000)
    return {"orders_timeout_ms": upstream.timeout_ms}
