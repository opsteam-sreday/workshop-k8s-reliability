"""Modelos de pedido, validação e hash canônico da requisição (idempotência)."""

from __future__ import annotations

import hashlib
import json
import re
import uuid
from decimal import Decimal

from pydantic import BaseModel, ConfigDict, Field, field_validator

CENTS = Decimal("0.01")
_ID_RE = re.compile(r"^[A-Za-z0-9._:-]{1,64}$")


class OrderItem(BaseModel):
    model_config = ConfigDict(extra="forbid")

    sku: str = Field(min_length=1, max_length=64, pattern=r"^[A-Za-z0-9._:-]+$")
    quantity: int = Field(gt=0, le=1000)
    unit_price: Decimal = Field(gt=0, le=Decimal("1000000"))

    @field_validator("unit_price", mode="before")
    @classmethod
    def parse_price(cls, value: object) -> Decimal:
        # Aceita "49.90", "49.9" ou 49.9 (JSON number) — sempre via str para não herdar erro de float.
        if isinstance(value, bool):
            raise ValueError("unit_price inválido")
        try:
            return Decimal(str(value))
        except Exception as exc:  # noqa: BLE001
            raise ValueError("unit_price inválido") from exc

    @field_validator("unit_price")
    @classmethod
    def max_two_decimals(cls, value: Decimal) -> Decimal:
        if value != value.quantize(CENTS):
            raise ValueError("unit_price deve ter no máximo 2 casas decimais")
        return value.quantize(CENTS)


class CreateOrderRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    customer_id: str = Field(min_length=1, max_length=64, pattern=r"^[A-Za-z0-9._:-]+$")
    items: list[OrderItem] = Field(min_length=1, max_length=50)
    currency: str = Field(default="BRL", pattern=r"^[A-Z]{3}$")

    @field_validator("items")
    @classmethod
    def unique_skus(cls, items: list[OrderItem]) -> list[OrderItem]:
        if len({i.sku for i in items}) != len(items):
            raise ValueError("cada SKU deve aparecer uma única vez")
        return items

    def total_amount(self) -> Decimal:
        return sum((i.unit_price * i.quantity for i in self.items), Decimal("0")).quantize(CENTS)

    def canonical(self) -> dict[str, object]:
        """Representação canônica: itens ordenados por SKU, preços com 2 casas, defaults explícitos."""
        return {
            "customer_id": self.customer_id,
            "currency": self.currency,
            "items": [
                {"quantity": i.quantity, "sku": i.sku, "unit_price": str(i.unit_price.quantize(CENTS))}
                for i in sorted(self.items, key=lambda it: it.sku)
            ],
        }

    def request_hash(self) -> str:
        payload = json.dumps(self.canonical(), sort_keys=True, separators=(",", ":"), ensure_ascii=True)
        return hashlib.sha256(payload.encode()).hexdigest()


def normalize_idempotency_key(raw: str | None) -> str | None:
    """Idempotency-Key deve ser um UUID; retorna a forma canônica minúscula ou None se inválida."""
    if not raw:
        return None
    try:
        parsed = uuid.UUID(raw.strip())
    except ValueError:
        return None
    if str(parsed) != raw.strip().lower():
        return None
    return str(parsed)


def valid_identifier(value: str | None) -> bool:
    return bool(value) and bool(_ID_RE.match(value))


def new_order_id() -> str:
    return f"ord-{uuid.uuid4().hex}"


def reservation_id_for(order_id: str) -> str:
    return f"res-{order_id}"


def reservation_key_for(order_id: str) -> str:
    return f"reserve-{order_id}"
