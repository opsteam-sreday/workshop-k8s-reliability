import json
import uuid

import httpx
import pytest

from app import main

KEY = "8d5e0cf2-2a6e-47bb-9149-dc3e60498d14"
PAYLOAD = {"customer_id": "customer-123", "items": [{"sku": "product-001", "quantity": 2, "unit_price": "49.90"}]}


@pytest.fixture
async def client():
    seen = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(201, json={"order_id": "ord-1"}, headers={"Idempotency-Replayed": "true", "X-Internal": "no"})

    main.upstream = main.Upstream()
    main.upstream.client = httpx.AsyncClient(base_url="http://orders", transport=httpx.MockTransport(handler))
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=main.app), base_url="http://bff") as c:
        c.seen = seen
        yield c


async def test_forwards_idempotency_request_id_and_passthrough_headers(client):
    r = await client.post("/orders", json=PAYLOAD, headers={"Idempotency-Key": KEY, "X-Request-ID": "req-123"})
    assert r.status_code == 201 and r.headers["Idempotency-Replayed"] == "true"
    assert "X-Internal" not in r.headers and r.headers["X-Request-ID"] == "req-123"
    upstream = client.seen[0]
    assert upstream.headers["Idempotency-Key"] == KEY and upstream.headers["X-Request-ID"] == "req-123"
    assert json.loads(upstream.content) == PAYLOAD


@pytest.mark.parametrize("key", [None, "abc", "8d5e0cf22a6e47bb9149dc3e60498d14"])
async def test_invalid_idempotency_key(client, key):
    headers = {"Idempotency-Key": key} if key else {}
    r = await client.post("/orders", json=PAYLOAD, headers=headers)
    assert r.status_code == 400 and r.json()["error"] == "INVALID_IDEMPOTENCY_KEY"
    assert client.seen == []


async def test_identity_mismatch_rejected(client):
    r = await client.post("/orders", json=PAYLOAD, headers={"Idempotency-Key": str(uuid.uuid4()), "X-Customer-ID": "other"})
    assert r.status_code == 403


async def test_openapi_documents_order_body(client):
    body = (await client.get("/openapi.json")).json()["paths"]["/orders"]["post"]["requestBody"]
    assert body["required"] and body["content"]["application/json"]["example"]["items"]


async def test_upstream_timeout_returns_504():
    def handler(request):
        raise httpx.ReadTimeout("timeout", request=request)

    main.upstream = main.Upstream()
    main.upstream.client = httpx.AsyncClient(base_url="http://orders", transport=httpx.MockTransport(handler))
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=main.app), base_url="http://bff") as c:
        r = await c.post("/orders", json=PAYLOAD, headers={"Idempotency-Key": KEY})
    assert r.status_code == 504 and r.json()["error"] == "UPSTREAM_TIMEOUT"


async def test_forced_not_ready_fails_only_readiness():
    main.health.started = True
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=main.admin_app), base_url="http://admin") as admin, \
            httpx.AsyncClient(transport=httpx.ASGITransport(app=main.app), base_url="http://bff") as c:
        try:
            assert (await admin.put("/admin/health", json={"ready": False})).json()["forced_not_ready"] is True
            ready = await c.get("/health/ready")
            assert ready.status_code == 503 and ready.json()["forced_not_ready"] is True
            assert (await c.get("/health/live")).status_code == 200
        finally:
            await admin.put("/admin/health", json={"ready": True})
        assert (await c.get("/health/ready")).status_code == 200


async def test_freeze_blocks_the_event_loop_after_responding(monkeypatch):
    scheduled = []
    loop = __import__("asyncio").get_running_loop()
    monkeypatch.setattr(loop, "call_later", lambda delay, fn, *args: scheduled.append((delay, fn, args)))
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=main.admin_app), base_url="http://admin") as admin:
        r = await admin.post("/admin/health/freeze", params={"seconds": 30})
        assert r.status_code == 200 and r.json() == {"frozen_seconds": 30}
        assert (await admin.post("/admin/health/freeze", params={"seconds": 0})).status_code == 422
    assert scheduled == [(0.2, __import__("time").sleep, (30,))]
