import asyncio

import httpx
import pytest

from app.faults import FaultConfig, FaultMode, FaultTarget
from app.main import app, faults, store
from app.store import Outcome

ITEMS = [{"sku": "product-001", "quantity": 2}]


@pytest.fixture(autouse=True)
async def reset():
    store.reset()
    await faults.apply_config(FaultConfig(max_concurrent_requests=1000))
    yield
    await faults.apply_config(FaultConfig())


@pytest.fixture
async def client():
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://inventory") as c:
        yield c


def reserve(client, rid="res-ord-1", key="reserve-ord-1", token=1, items=ITEMS):
    return client.post("/inventory/reservations", headers={"Idempotency-Key": key},
                       json={"reservation_id": rid, "order_id": "ord-1", "items": items, "fencing_token": token})


async def test_twenty_concurrent_identical_reservations_decrement_once(client):
    before = store.products["product-001"].available
    responses = await asyncio.gather(*(reserve(client) for _ in range(20)))
    assert sorted(r.status_code for r in responses) == [200] * 19 + [201]
    assert store.products["product-001"].available == before - 2
    assert len(store.reservations) == 1


async def test_same_key_different_payload_conflicts(client):
    assert (await reserve(client)).status_code == 201
    r = await reserve(client, items=[{"sku": "product-001", "quantity": 3}])
    assert r.status_code == 409 and r.json()["error"] == "IDEMPOTENCY_KEY_REUSED"


async def test_release_is_idempotent_and_fenced(client):
    before = store.products["product-001"].available
    await reserve(client, token=1)
    assert (await reserve(client, token=3)).status_code == 200  # token sobe para 3
    stale = await client.delete("/inventory/reservations/res-ord-1", params={"fencing_token": 2})
    assert stale.status_code == 409 and stale.json()["error"] == "STALE_FENCING_TOKEN"
    for _ in range(2):
        r = await client.delete("/inventory/reservations/res-ord-1", params={"fencing_token": 3})
        assert r.status_code == 200
    assert store.products["product-001"].available == before
    assert (await client.delete("/inventory/reservations/res-unknown")).status_code == 404


async def test_released_reservation_only_reactivated_by_newer_token(client):
    before = store.products["product-001"].available
    await reserve(client, token=1)
    await client.delete("/inventory/reservations/res-ord-1", params={"fencing_token": 2})
    assert (await reserve(client, token=2)).status_code == 409
    r = await reserve(client, token=3)
    assert r.status_code == 201 and r.json()["outcome"] == Outcome.REACTIVATED.value
    assert store.products["product-001"].available == before - 2


async def test_never_negative_stock(client):
    items = [{"sku": "product-limited", "quantity": 3}]
    results = await asyncio.gather(*(reserve(client, rid=f"res-{i}", key=f"reserve-{i:04d}", items=items) for i in range(5)))
    assert sorted(r.status_code for r in results) == [201, 409, 409, 409, 409]
    assert store.products["product-limited"].available == 2


async def test_fault_injection_http_503_targets_queries_only(client):
    await faults.apply_config(FaultConfig(fault_mode=FaultMode.HTTP_503, fault_target=FaultTarget.QUERIES))
    assert (await client.get("/inventory/product-001")).status_code == 503
    assert (await reserve(client)).status_code == 201


async def test_concurrency_limit_sheds_load(client):
    await faults.apply_config(FaultConfig(fault_mode=FaultMode.LATENCY, latency_ms=200, max_concurrent_requests=2))
    results = await asyncio.gather(*(client.get("/inventory/product-001") for _ in range(5)))
    codes = sorted(r.status_code for r in results)
    assert codes == [200, 200, 503, 503, 503]
    assert results[[r.status_code for r in results].index(503)].json()["error"] == "TOO_MANY_CONCURRENT_REQUESTS"


async def test_missing_idempotency_key_rejected(client):
    r = await client.post("/inventory/reservations", json={"reservation_id": "res-1", "items": ITEMS})
    assert r.status_code == 400
