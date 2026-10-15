from decimal import Decimal

import pytest
from pydantic import ValidationError

from app.models import CreateOrderRequest, normalize_idempotency_key


def make(items, **kw):
    return CreateOrderRequest.model_validate({"customer_id": "customer-123", "items": items, **kw})


def test_hash_is_canonical_for_item_order_price_format_and_defaults():
    a = make([{"sku": "product-001", "quantity": 2, "unit_price": "49.90"},
              {"sku": "product-002", "quantity": 1, "unit_price": "10"}])
    b = make([{"sku": "product-002", "quantity": 1, "unit_price": 10.0},
              {"sku": "product-001", "quantity": 2, "unit_price": 49.9}], currency="BRL")
    assert a.request_hash() == b.request_hash()


def test_hash_changes_when_intent_changes():
    a = make([{"sku": "product-001", "quantity": 2, "unit_price": "49.90"}])
    b = make([{"sku": "product-001", "quantity": 3, "unit_price": "49.90"}])
    assert a.request_hash() != b.request_hash()


def test_total_uses_decimal():
    req = make([{"sku": "product-001", "quantity": 3, "unit_price": "0.10"}])
    assert req.total_amount() == Decimal("0.30")


@pytest.mark.parametrize("price", ["49.999", "-1", "0", "abc", True])
def test_invalid_prices_rejected(price):
    with pytest.raises(ValidationError):
        make([{"sku": "product-001", "quantity": 1, "unit_price": price}])


def test_duplicate_skus_rejected():
    with pytest.raises(ValidationError):
        make([{"sku": "product-001", "quantity": 1, "unit_price": "1"}, {"sku": "product-001", "quantity": 1, "unit_price": "1"}])


def test_unknown_fields_rejected():
    with pytest.raises(ValidationError):
        make([{"sku": "product-001", "quantity": 1, "unit_price": "1"}], discount="10")


@pytest.mark.parametrize("raw,expected", [
    ("8d5e0cf2-2a6e-47bb-9149-dc3e60498d14", "8d5e0cf2-2a6e-47bb-9149-dc3e60498d14"),
    ("8D5E0CF2-2A6E-47BB-9149-DC3E60498D14", "8d5e0cf2-2a6e-47bb-9149-dc3e60498d14"),
    ("not-a-uuid", None), ("", None), (None, None), ("8d5e0cf22a6e47bb9149dc3e60498d14", None),
])
def test_idempotency_key_normalization(raw, expected):
    assert normalize_idempotency_key(raw) == expected
