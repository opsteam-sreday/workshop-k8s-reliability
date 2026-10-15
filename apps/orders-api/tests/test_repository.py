import pytest

from app.repository import IdemStatus, OrdersRepository, ReservationState, TransactionCancelled

KW = dict(customer_id="c1", key="k1", request_hash="h1", lease_seconds=10, ttl_seconds=86400)


def order(record):
    return {"order_id": record.order_id, "customer_id": "c1", "status": "CONFIRMED", "currency": "BRL",
            "items": [{"sku": "product-001", "quantity": 1, "unit_price": "1.00"}], "total_amount": "1.00",
            "created_at": "2026-10-14T10:00:00.000Z", "reservation_id": "res-x"}


def test_claim_is_exclusive(dynamodb, clock):
    repo = OrdersRepository(dynamodb, "test-orders", clock)
    claimed, rec = repo.claim(order_id="ord-1", **KW)
    assert claimed and rec.status == IdemStatus.IN_PROGRESS and rec.version == 1
    claimed2, existing = repo.claim(order_id="ord-2", **KW)
    assert not claimed2
    assert existing.order_id == "ord-1"  # o segundo NÃO cria outro pedido


def test_takeover_only_after_lease_expiry_and_fences_old_owner(dynamodb, clock):
    repo = OrdersRepository(dynamodb, "test-orders", clock)
    _, old = repo.claim(order_id="ord-1", **KW)
    assert repo.takeover(old, 10) is None  # lease ainda válido
    clock.advance(11)
    new = repo.takeover(old, 10)
    assert new is not None and new.version == 2 and new.owner_token != old.owner_token and new.attempts == 2
    # O executor antigo não consegue mais confirmar (fencing).
    with pytest.raises(TransactionCancelled) as exc:
        repo.complete(old, order(old), {"order_id": old.order_id})
    assert exc.value.condition_failed
    assert repo.update_owned(old, reservation_state=ReservationState.RESERVED) is None
    repo.complete(new, order(new), {"order_id": new.order_id})
    assert repo.get_record(new.pk).status == IdemStatus.COMPLETED
    assert repo.get_order("ord-1")["status"] == "CONFIRMED"


def test_complete_is_atomic_and_single(dynamodb, clock):
    repo = OrdersRepository(dynamodb, "test-orders", clock)
    _, rec = repo.claim(order_id="ord-1", **KW)
    repo.complete(rec, order(rec), {"order_id": "ord-1"})
    with pytest.raises(TransactionCancelled):
        repo.complete(rec, order(rec), {"order_id": "ord-1"})
    orders, _ = repo.list_orders("c1", 10, None)
    assert len(orders) == 1


def test_expired_retention_allows_new_operation(dynamodb, clock):
    repo = OrdersRepository(dynamodb, "test-orders", clock)
    _, rec = repo.claim(order_id="ord-1", **KW)
    repo.complete(rec, order(rec), {"order_id": "ord-1"})
    clock.advance(86401)
    _, existing = repo.claim(order_id="ord-2", **KW)
    fresh = repo.replace_expired(existing, request_hash="h2", order_id="ord-2", lease_seconds=10, ttl_seconds=86400)
    assert fresh is not None and fresh.order_id == "ord-2" and fresh.version == existing.version + 1
    assert repo.replace_expired(existing, request_hash="h2", order_id="ord-3", lease_seconds=10, ttl_seconds=86400) is None


def test_pagination(dynamodb, clock):
    repo = OrdersRepository(dynamodb, "test-orders", clock)
    for i in range(5):
        _, rec = repo.claim(order_id=f"ord-{i}", **{**KW, "key": f"k{i}"})
        o = order(rec)
        o["created_at"] = f"2026-10-14T10:00:0{i}.000Z"
        repo.complete(rec, o, {"order_id": rec.order_id})
    page1, token = repo.list_orders("c1", 3, None)
    page2, token2 = repo.list_orders("c1", 3, token)
    assert [o["order_id"] for o in page1] == ["ord-4", "ord-3", "ord-2"]
    assert [o["order_id"] for o in page2] == ["ord-1", "ord-0"] and token2 is None
