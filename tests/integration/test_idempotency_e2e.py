"""Testes obrigatórios de idempotência (seção 6.10) contra processos reais.

BFF -> Orders -> Inventory, com DynamoDB Local. Executar: scripts/test.sh
"""

from __future__ import annotations

import asyncio
import time
import uuid

import httpx
import pytest

pytestmark = pytest.mark.integration


def payload(customer: str, qty: int = 2, sku: str = "product-001") -> dict:
    return {"customer_id": customer, "items": [{"sku": sku, "quantity": qty, "unit_price": "49.90"}]}


def post(env, key: str, body: dict, timeout: float = 15) -> httpx.Response:
    return httpx.post(f"{env.bff.url}/orders", json=body, headers={"Idempotency-Key": key}, timeout=timeout)


def new_customer() -> str:
    return f"customer-{uuid.uuid4().hex[:8]}"


# 1 e 8 -------------------------------------------------------------------------------
def test_01_08_sequential_same_key_creates_one_order_and_replays_same_response(env):
    customer, key = new_customer(), str(uuid.uuid4())
    before = env.stock()
    first = post(env, key, payload(customer))
    second = post(env, key, payload(customer))
    assert first.status_code == 201 and second.status_code == 201
    assert first.headers["Idempotency-Replayed"] == "false"
    assert second.headers["Idempotency-Replayed"] == "true"
    assert first.json() == second.json() and first.json()["status"] == "CONFIRMED"
    assert len(env.dynamo.orders_for(customer)) == 1
    assert env.stock() == before - 2
    got = httpx.get(f"{env.bff.url}/orders/{first.json()['order_id']}")
    assert got.status_code == 200 and got.json()["total_amount"] == "99.80"
    listed = httpx.get(f"{env.bff.url}/orders", params={"customer_id": customer})
    assert listed.json()["count"] == 1


# 2 -----------------------------------------------------------------------------------
def test_02_twenty_concurrent_requests_same_key_create_one_order_and_one_reservation(env):
    customer, key = new_customer(), str(uuid.uuid4())
    before = env.stock()
    reservations_before = env.reservations()["reservations_total"]

    async def burst():
        async with httpx.AsyncClient(timeout=15) as client:
            return await asyncio.gather(*(client.post(f"{env.bff.url}/orders", json=payload(customer),
                                                      headers={"Idempotency-Key": key}) for _ in range(20)))

    responses = asyncio.run(burst())
    codes = [r.status_code for r in responses]
    assert set(codes) <= {201, 409}, codes
    created = [r for r in responses if r.status_code == 201]
    assert created, codes
    assert len({r.json()["order_id"] for r in created}) == 1
    assert all(r.json()["error"] == "ORDER_IN_PROGRESS" and "Retry-After" in r.headers
               for r in responses if r.status_code == 409)
    assert len(env.dynamo.orders_for(customer)) == 1
    assert env.reservations()["reservations_total"] == reservations_before + 1
    assert env.stock() == before - 2


# 3 -----------------------------------------------------------------------------------
def test_03_same_key_different_payload_returns_409(env):
    customer, key = new_customer(), str(uuid.uuid4())
    assert post(env, key, payload(customer)).status_code == 201
    r = post(env, key, payload(customer, qty=5))
    assert r.status_code == 409 and r.json()["error"] == "IDEMPOTENCY_KEY_REUSED"
    assert len(env.dynamo.orders_for(customer)) == 1


# 4 -----------------------------------------------------------------------------------
def test_04_bff_timeout_after_success_does_not_duplicate(env):
    customer, key = new_customer(), str(uuid.uuid4())
    env.admin(env.bff, "PUT", "/admin/faults", {"orders_timeout_ms": 300})
    env.admin(env.orders, "PUT", "/admin/faults", {"cpu_work_ms": 700})
    r = post(env, key, payload(customer))
    assert r.status_code == 504 and r.json()["error"] == "UPSTREAM_TIMEOUT"
    time.sleep(1.5)  # a Orders API conclui o pedido após a BFF desistir
    env.reset()
    retry = post(env, key, payload(customer))
    assert retry.status_code == 201 and retry.headers["Idempotency-Replayed"] == "true"
    assert len(env.dynamo.orders_for(customer)) == 1


# 5 -----------------------------------------------------------------------------------
def test_05_timeout_after_reservation_does_not_duplicate_reservation(env):
    customer, key = new_customer(), str(uuid.uuid4())
    before = env.stock()
    env.admin(env.inventory, "PUT", "/admin/faults",
              {"fault_mode": "SLOW_AFTER_COMMIT", "fault_target": "RESERVATIONS", "latency_ms": 800})
    r = post(env, key, payload(customer))
    assert r.status_code == 503 and r.json()["error"] == "DEPENDENCY_UNAVAILABLE"
    record = env.admin(env.orders, "GET", f"/admin/idempotency/{customer}/{key}")
    assert record["status"] == "IN_PROGRESS" and record["reservation_state"] == "UNKNOWN"
    assert env.stock() == before - 2  # a reserva FOI aplicada, apesar do timeout (sem compensação cega)
    env.reset()
    retry = post(env, key, payload(customer))
    assert retry.status_code == 201
    assert env.stock() == before - 2  # retries reutilizaram a mesma reserva
    assert len(env.dynamo.orders_for(customer)) == 1


# 6 -----------------------------------------------------------------------------------
def test_06_dynamodb_failure_after_reservation_compensates_without_duplicates(env):
    customer, key = new_customer(), str(uuid.uuid4())
    before = env.stock()
    env.admin(env.orders, "PUT", "/admin/faults", {"db_fault_mode": "FAIL_TRANSACT"})
    r = post(env, key, payload(customer))
    assert r.status_code == 503
    record = env.admin(env.orders, "GET", f"/admin/idempotency/{customer}/{key}")
    assert record["status"] == "IN_PROGRESS" and record["reservation_state"] == "RELEASED"
    assert env.stock() == before
    env.reset()
    retry = post(env, key, payload(customer))
    assert retry.status_code == 201
    assert env.stock() == before - 2
    assert len(env.dynamo.orders_for(customer)) == 1

    # Resultado desconhecido APÓS commit: re-leitura resolve, sem compensação.
    key2 = str(uuid.uuid4())
    env.admin(env.orders, "PUT", "/admin/faults", {"db_fault_mode": "TRANSACT_UNKNOWN_AFTER_COMMIT"})
    r2 = post(env, key2, payload(customer))
    assert r2.status_code == 201
    assert env.stock() == before - 4
    assert len(env.dynamo.orders_for(customer)) == 2


# 7 -----------------------------------------------------------------------------------
def test_07_pod_crash_in_progress_allows_controlled_recovery(env):
    customer, key = new_customer(), str(uuid.uuid4())
    before = env.stock()
    env.admin(env.orders, "PUT", "/admin/faults", {"crash_after_reservation": True})
    r = post(env, key, payload(customer))
    assert r.status_code == 503  # BFF: conexão com a Orders API caiu
    assert env.orders.wait_exit() == 137
    env.orders.start()  # "Pod" reiniciado (estado de falhas volta ao default)

    in_progress = post(env, key, payload(customer))
    assert in_progress.status_code == 409 and in_progress.json()["error"] == "ORDER_IN_PROGRESS"
    retry_after = int(in_progress.headers["Retry-After"])
    assert 1 <= retry_after <= 3
    time.sleep(retry_after + 0.5)

    recovered = post(env, key, payload(customer))
    assert recovered.status_code == 201
    record = env.admin(env.orders, "GET", f"/admin/idempotency/{customer}/{key}")
    assert record["status"] == "COMPLETED" and record["attempts"] == 2 and record["version"] == 2
    assert env.stock() == before - 2
    assert len(env.dynamo.orders_for(customer)) == 1


# 9 -----------------------------------------------------------------------------------
def test_09_different_keys_create_distinct_orders(env):
    customer = new_customer()
    a = post(env, str(uuid.uuid4()), payload(customer))
    b = post(env, str(uuid.uuid4()), payload(customer))
    assert a.status_code == b.status_code == 201 and a.json()["order_id"] != b.json()["order_id"]
    assert len(env.dynamo.orders_for(customer)) == 2


# 10 ----------------------------------------------------------------------------------
def test_10_logs_and_traces_correlate_all_attempts(env):
    customer, key = new_customer(), str(uuid.uuid4())
    request_ids = [f"it-{uuid.uuid4().hex[:12]}" for _ in range(3)]
    for rid in request_ids:
        httpx.post(f"{env.bff.url}/orders", json=payload(customer),
                   headers={"Idempotency-Key": key, "X-Request-ID": rid}, timeout=15)
    time.sleep(0.5)
    bff_logs = {l["request_id"]: l for l in env.bff.logs() if l.get("message") == "HTTP request completed"
                and l.get("request_id") in request_ids}
    orders_logs = [l for l in env.orders.logs() if l.get("request_id") in request_ids]
    assert set(bff_logs) == set(request_ids)
    for rid in request_ids:
        bff_trace = bff_logs[rid]["trace_id"]
        assert bff_trace and len(bff_trace) == 32
        related = [l for l in orders_logs if l["request_id"] == rid]
        assert related and all(l["trace_id"] == bff_trace for l in related)  # W3C trace context propagado
        assert any(l.get("idempotency.key") == key for l in related)       # todas as tentativas pela chave
    completion = [l for l in orders_logs if l.get("message") == "HTTP request completed"]
    assert {l["http.route"] for l in completion} == {"/orders"}
    assert all(l["span_id"] and l["http.response.status_code"] == 201 for l in completion)


# Circuit Breaker ------------------------------------------------------------------------
def test_circuit_breaker_closed_open_half_open_closed(env):
    customer = new_customer()
    env.admin(env.inventory, "PUT", "/admin/faults", {"fault_mode": "HTTP_503"})
    for _ in range(3):
        assert post(env, str(uuid.uuid4()), payload(customer)).status_code == 503
    assert env.admin(env.orders, "GET", "/admin/circuit-breaker")["state"] == "OPEN"
    start = time.perf_counter()
    fast = post(env, str(uuid.uuid4()), payload(customer))
    assert fast.status_code == 503 and fast.json()["reason"] == "circuit_open"
    assert time.perf_counter() - start < 0.5  # fail fast
    env.admin(env.inventory, "POST", "/admin/faults/reset")
    time.sleep(3.2)
    assert env.admin(env.orders, "GET", "/admin/circuit-breaker")["state"] == "HALF_OPEN"
    assert post(env, str(uuid.uuid4()), payload(customer)).status_code == 201
    assert env.admin(env.orders, "GET", "/admin/circuit-breaker")["state"] == "CLOSED"
    transitions = [(l["circuit_breaker.from"], l["circuit_breaker.to"]) for l in env.orders.logs()
                   if l.get("message") == "Circuit breaker transition"]
    assert transitions[-3:] == [("CLOSED", "OPEN"), ("OPEN", "HALF_OPEN"), ("HALF_OPEN", "CLOSED")]


def test_validation_errors(env):
    r = httpx.post(f"{env.bff.url}/orders", json=payload("c"), headers={"Idempotency-Key": "nope"})
    assert r.status_code == 400 and r.json()["error"] == "INVALID_IDEMPOTENCY_KEY"
    r = post(env, str(uuid.uuid4()), {"customer_id": "c", "items": [{"sku": "product-001", "quantity": 1, "unit_price": "1.001"}]})
    assert r.status_code == 400 and r.json()["error"] == "INVALID_PAYLOAD"
    r = post(env, str(uuid.uuid4()), payload(new_customer(), qty=100, sku="product-limited"))
    assert r.status_code == 409 and r.json()["error"] == "INSUFFICIENT_STOCK"
