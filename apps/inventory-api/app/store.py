"""Estoque em memória com reservas idempotentes e fencing tokens.

LIMITAÇÃO DO MVP (intencional e documentada): o estado vive na memória de uma única
réplica. Um restart do Pod perde reservas e restaura o estoque inicial — NÃO há
durabilidade nem garantia de recuperação de reservas após restart.

Regras:
- Uma reserva é identificada por `reservation_id` (estável, derivado do pedido) e
  pela `Idempotency-Key`. Repetir a mesma reserva NÃO decrementa o estoque novamente.
- `fencing_token` (versão do registro de idempotência da Orders API) impede que um
  executor antigo libere/reative uma reserva da qual um executor mais novo depende.
- Todas as mutações são serializadas por um asyncio.Lock (réplica única, 1 processo).
"""

from __future__ import annotations

import asyncio
import hashlib
import json
from dataclasses import dataclass, field
from datetime import datetime, timezone
from decimal import Decimal
from enum import Enum


class ReservationStatus(str, Enum):
    RESERVED = "RESERVED"
    RELEASED = "RELEASED"


class Outcome(str, Enum):
    CREATED = "CREATED"
    REPLAYED = "REPLAYED"
    REACTIVATED = "REACTIVATED"
    RELEASED = "RELEASED"
    ALREADY_RELEASED = "ALREADY_RELEASED"
    NOT_FOUND = "NOT_FOUND"
    INSUFFICIENT_STOCK = "INSUFFICIENT_STOCK"
    UNKNOWN_SKU = "UNKNOWN_SKU"
    IDEMPOTENCY_KEY_REUSED = "IDEMPOTENCY_KEY_REUSED"
    RESERVATION_ID_CONFLICT = "RESERVATION_ID_CONFLICT"
    STALE_FENCING_TOKEN = "STALE_FENCING_TOKEN"


@dataclass
class Product:
    sku: str
    name: str
    unit_price: Decimal
    initial_stock: int
    available: int
    reserved: int = 0


@dataclass
class Reservation:
    reservation_id: str
    idempotency_key: str
    request_hash: str
    order_id: str | None
    items: list[tuple[str, int]]
    status: ReservationStatus
    fencing_token: int
    created_at: str
    updated_at: str
    history: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, object]:
        return {
            "reservation_id": self.reservation_id,
            "order_id": self.order_id,
            "status": self.status.value,
            "items": [{"sku": s, "quantity": q} for s, q in self.items],
            "fencing_token": self.fencing_token,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
        }


@dataclass
class Result:
    outcome: Outcome
    reservation: Reservation | None = None
    details: dict[str, object] = field(default_factory=dict)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def reservation_hash(reservation_id: str, order_id: str | None, items: list[tuple[str, int]]) -> str:
    canonical = {"reservation_id": reservation_id, "order_id": order_id, "items": sorted(items)}
    return hashlib.sha256(json.dumps(canonical, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def default_catalog(initial_stock: int, limited_stock: int) -> list[Product]:
    products = [
        Product(f"product-{i:03d}", f"Produto {i:03d}", Decimal("49.90") + Decimal(i), initial_stock, initial_stock)
        for i in range(1, 11)
    ]
    # SKU com estoque baixo para demonstrar INSUFFICIENT_STOCK.
    products.append(Product("product-limited", "Edição Limitada", Decimal("999.00"), limited_stock, limited_stock))
    return products


class InventoryStore:
    def __init__(self, catalog: list[Product]) -> None:
        self._catalog_template = catalog
        self._lock = asyncio.Lock()
        self.reset()

    def reset(self) -> None:
        self.products = {
            p.sku: Product(p.sku, p.name, p.unit_price, p.initial_stock, p.initial_stock) for p in self._catalog_template
        }
        self.reservations: dict[str, Reservation] = {}
        self.keys: dict[str, str] = {}

    def get_product(self, sku: str) -> Product | None:
        return self.products.get(sku)

    def stats(self) -> dict[str, object]:
        by_status: dict[str, int] = {}
        for r in self.reservations.values():
            by_status[r.status.value] = by_status.get(r.status.value, 0) + 1
        return {
            "reservations_total": len(self.reservations),
            "reservations_by_status": by_status,
            "products": {s: {"available": p.available, "reserved": p.reserved} for s, p in self.products.items()},
        }

    # ------------------------------------------------------------------ reserve
    async def reserve(
        self, *, reservation_id: str, idempotency_key: str, order_id: str | None, items: list[tuple[str, int]], fencing_token: int
    ) -> Result:
        request_hash = reservation_hash(reservation_id, order_id, items)
        async with self._lock:
            existing_id = self.keys.get(idempotency_key)
            if existing_id is not None and existing_id != reservation_id:
                return Result(Outcome.IDEMPOTENCY_KEY_REUSED)
            existing = self.reservations.get(reservation_id)
            if existing is not None:
                if existing.idempotency_key != idempotency_key:
                    return Result(Outcome.RESERVATION_ID_CONFLICT, existing)
                if existing.request_hash != request_hash:
                    return Result(Outcome.IDEMPOTENCY_KEY_REUSED, existing)
                if fencing_token < existing.fencing_token:
                    return Result(Outcome.STALE_FENCING_TOKEN, existing, {"current_fencing_token": existing.fencing_token})
                if existing.status == ReservationStatus.RESERVED:
                    existing.fencing_token = fencing_token
                    existing.updated_at = _now()
                    return Result(Outcome.REPLAYED, existing)
                # RELEASED: só pode ser reativada por um executor mais novo (token maior).
                if fencing_token == existing.fencing_token:
                    return Result(Outcome.STALE_FENCING_TOKEN, existing, {"current_fencing_token": existing.fencing_token})
                shortage = self._check_stock(items)
                if shortage:
                    return Result(shortage.outcome, existing, shortage.details)
                self._apply(items, -1)
                existing.status = ReservationStatus.RESERVED
                existing.fencing_token = fencing_token
                existing.updated_at = _now()
                existing.history.append(f"REACTIVATED@{fencing_token}")
                return Result(Outcome.REACTIVATED, existing)

            shortage = self._check_stock(items)
            if shortage:
                return shortage
            self._apply(items, -1)
            now = _now()
            reservation = Reservation(
                reservation_id, idempotency_key, request_hash, order_id, list(items),
                ReservationStatus.RESERVED, fencing_token, now, now, [f"RESERVED@{fencing_token}"],
            )
            self.reservations[reservation_id] = reservation
            self.keys[idempotency_key] = reservation_id
            return Result(Outcome.CREATED, reservation)

    # ------------------------------------------------------------------ release
    async def release(self, reservation_id: str, fencing_token: int | None) -> Result:
        async with self._lock:
            reservation = self.reservations.get(reservation_id)
            if reservation is None:
                return Result(Outcome.NOT_FOUND)
            if fencing_token is not None and fencing_token < reservation.fencing_token:
                return Result(Outcome.STALE_FENCING_TOKEN, reservation, {"current_fencing_token": reservation.fencing_token})
            if reservation.status == ReservationStatus.RELEASED:
                return Result(Outcome.ALREADY_RELEASED, reservation)
            self._apply(reservation.items, +1)
            reservation.status = ReservationStatus.RELEASED
            if fencing_token is not None:
                reservation.fencing_token = fencing_token
            reservation.updated_at = _now()
            reservation.history.append(f"RELEASED@{reservation.fencing_token}")
            return Result(Outcome.RELEASED, reservation)

    # ------------------------------------------------------------------ helpers
    def _check_stock(self, items: list[tuple[str, int]]) -> Result | None:
        requested: dict[str, int] = {}
        for sku, qty in items:
            requested[sku] = requested.get(sku, 0) + qty
        for sku, qty in requested.items():
            product = self.products.get(sku)
            if product is None:
                return Result(Outcome.UNKNOWN_SKU, details={"sku": sku})
            if product.available < qty:
                return Result(Outcome.INSUFFICIENT_STOCK, details={"sku": sku, "available": product.available, "requested": qty})
        return None

    def _apply(self, items: list[tuple[str, int]], sign: int) -> None:
        for sku, qty in items:
            product = self.products[sku]
            product.available += sign * qty
            product.reserved -= sign * qty
            assert product.available >= 0, "estoque negativo"
