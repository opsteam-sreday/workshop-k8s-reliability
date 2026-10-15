"""Inventory API — consulta e reserva de estoque (réplica única, estado em memória)."""

from __future__ import annotations

import logging
import re
from contextlib import asynccontextmanager
from typing import Iterable

from fastapi import FastAPI, Header, Query, Request
from fastapi.responses import JSONResponse
from opentelemetry import metrics, trace
from opentelemetry.metrics import CallbackOptions, Observation
from pydantic import BaseModel, Field, field_validator

from workshop_common.config import env_bool, env_int
from workshop_common.health import HealthState, health_router
from workshop_common.http import ApiError, RequestContextMiddleware, install_error_handlers
from workshop_common.telemetry import instrument_fastapi, setup_telemetry

from .faults import FaultConfig, FaultInjector, FaultTarget
from .store import InventoryStore, Outcome, default_catalog

SERVICE_NAME = "inventory-api"
telemetry = setup_telemetry(SERVICE_NAME)
log = logging.getLogger("inventory")
tracer = trace.get_tracer("inventory-api")
meter = metrics.get_meter("inventory-api")

reservations_success = meter.create_counter("inventory.reservations.success", unit="{reservation}")
reservations_failed = meter.create_counter("inventory.reservations.failed", unit="{reservation}")
releases = meter.create_counter("inventory.reservations.released", unit="{reservation}")
faults_injected = meter.create_counter("inventory.faults.injected", unit="{fault}")

store = InventoryStore(default_catalog(env_int("INVENTORY_INITIAL_STOCK", 1_000_000), env_int("INVENTORY_LIMITED_STOCK", 5)))
faults = FaultInjector(FaultConfig.from_env(), on_fault=lambda kind: faults_injected.add(1, {"fault.type": kind}))
health = HealthState()


def _stock_gauge(_: CallbackOptions) -> Iterable[Observation]:
    for product in store.products.values():  # SKUs: catálogo pequeno e fixo (cardinalidade controlada)
        yield Observation(product.available, {"sku": product.sku})


meter.create_observable_gauge("inventory.stock.available", [_stock_gauge], unit="{item}")

_KEY_RE = re.compile(r"^[A-Za-z0-9._:-]{8,128}$")


class ReservationItem(BaseModel):
    sku: str = Field(min_length=1, max_length=64)
    quantity: int = Field(gt=0, le=1000)


class ReservationRequest(BaseModel):
    reservation_id: str = Field(min_length=4, max_length=128, pattern=r"^[A-Za-z0-9._:-]+$")
    order_id: str | None = Field(default=None, max_length=128)
    items: list[ReservationItem] = Field(min_length=1, max_length=50)
    fencing_token: int = Field(default=0, ge=0)

    @field_validator("items")
    @classmethod
    def unique_skus(cls, items: list[ReservationItem]) -> list[ReservationItem]:
        if len({i.sku for i in items}) != len(items):
            raise ValueError("SKUs duplicados na reserva")
        return items


@asynccontextmanager
async def lifespan(_: FastAPI):
    await faults.start()
    health.started = True
    log.info("Inventory API iniciada", extra={"products": len(store.products)})
    yield
    await faults.stop()
    telemetry.shutdown()


app = FastAPI(title="Inventory API", version="1.0.0", lifespan=lifespan)
app.add_middleware(RequestContextMiddleware, log_health=env_bool("LOG_HEALTH_REQUESTS", False))
install_error_handlers(app)
app.include_router(health_router(health))
instrument_fastapi(app)


@app.get("/inventory/{sku}")
async def get_inventory(sku: str):
    async with faults.track():
        await faults.before(FaultTarget.QUERIES)
        product = store.get_product(sku)
        if product is None:
            raise ApiError(404, "PRODUCT_NOT_FOUND", f"SKU {sku} não encontrado")
        return {"sku": product.sku, "name": product.name, "unit_price": str(product.unit_price),
                "available": product.available, "reserved": product.reserved}


_FAILURE_STATUS = {
    Outcome.INSUFFICIENT_STOCK: (409, "Estoque insuficiente"),
    Outcome.UNKNOWN_SKU: (422, "SKU inexistente"),
    Outcome.IDEMPOTENCY_KEY_REUSED: (409, "Idempotency-Key reutilizada com payload diferente"),
    Outcome.RESERVATION_ID_CONFLICT: (409, "reservation_id já associado a outra Idempotency-Key"),
    Outcome.STALE_FENCING_TOKEN: (409, "Fencing token desatualizado"),
}


@app.post("/inventory/reservations")
async def create_reservation(body: ReservationRequest, idempotency_key: str | None = Header(default=None)):
    async with faults.track():
        if not idempotency_key or not _KEY_RE.match(idempotency_key):
            raise ApiError(400, "INVALID_IDEMPOTENCY_KEY", "Header Idempotency-Key ausente ou inválido")
        await faults.before(FaultTarget.RESERVATIONS)
        with tracer.start_as_current_span("Reserve Stock") as span:
            span.set_attributes({"inventory.reservation_id": body.reservation_id, "inventory.fencing_token": body.fencing_token,
                                 "inventory.items": len(body.items)})
            result = await store.reserve(
                reservation_id=body.reservation_id, idempotency_key=idempotency_key, order_id=body.order_id,
                items=[(i.sku, i.quantity) for i in body.items], fencing_token=body.fencing_token,
            )
            span.set_attribute("inventory.outcome", result.outcome.value)

        if result.outcome in _FAILURE_STATUS:
            status, message = _FAILURE_STATUS[result.outcome]
            reservations_failed.add(1, {"reason": result.outcome.value})
            log.warning("Reserva rejeitada", extra={"inventory.outcome": result.outcome.value,
                                                    "inventory.reservation_id": body.reservation_id, **result.details})
            raise ApiError(status, result.outcome.value, message, **result.details)

        reservations_success.add(1, {"outcome": result.outcome.value})
        replayed = result.outcome == Outcome.REPLAYED
        log.info("Reserva processada", extra={"inventory.outcome": result.outcome.value,
                                              "inventory.reservation_id": body.reservation_id,
                                              "inventory.fencing_token": body.fencing_token})
        await faults.after_commit(FaultTarget.RESERVATIONS)
        return JSONResponse(
            {**result.reservation.to_dict(), "outcome": result.outcome.value},
            status_code=200 if replayed else 201,
            headers={"Idempotency-Replayed": str(replayed).lower()},
        )


@app.delete("/inventory/reservations/{reservation_id}")
async def release_reservation(reservation_id: str, fencing_token: int | None = Query(default=None, ge=0)):
    async with faults.track():
        await faults.before(FaultTarget.RESERVATIONS)
        with tracer.start_as_current_span("Release Stock") as span:
            span.set_attributes({"inventory.reservation_id": reservation_id, "inventory.fencing_token": fencing_token or -1})
            result = await store.release(reservation_id, fencing_token)
            span.set_attribute("inventory.outcome", result.outcome.value)
        if result.outcome == Outcome.STALE_FENCING_TOKEN:
            raise ApiError(409, result.outcome.value, "Fencing token desatualizado", **result.details)
        if result.outcome == Outcome.NOT_FOUND:
            # Idempotente: liberar algo que não existe não é erro para o chamador.
            return JSONResponse({"reservation_id": reservation_id, "status": "NOT_FOUND", "outcome": result.outcome.value},
                                status_code=404)
        if result.outcome == Outcome.RELEASED:
            releases.add(1)
        log.info("Reserva liberada", extra={"inventory.outcome": result.outcome.value, "inventory.reservation_id": reservation_id})
        return {**result.reservation.to_dict(), "outcome": result.outcome.value}


# --------------------------------------------------------------------------------------
# API administrativa de laboratório: escuta apenas em 127.0.0.1 (ver workshop_common.server)
# --------------------------------------------------------------------------------------
admin_app = FastAPI(title="Inventory Admin (workshop only)")


@admin_app.get("/admin/faults")
async def get_faults():
    return faults.status()


@admin_app.put("/admin/faults")
async def put_faults(request: Request):
    patch = await request.json()
    merged = {**faults.config.model_dump(mode="json"), **patch}
    await faults.apply_config(FaultConfig(**merged))
    return faults.status()


@admin_app.post("/admin/faults/reset")
async def reset_faults():
    await faults.apply_config(FaultConfig.from_env())
    return faults.status()


@admin_app.get("/admin/state")
async def state():
    return store.stats()


@admin_app.post("/admin/reset-stock")
async def reset_stock():
    store.reset()
    log.warning("Estoque e reservas reiniciados via admin")
    return store.stats()

