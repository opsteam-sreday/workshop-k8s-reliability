import uuid

from app.models import CreateOrderRequest
from app.repository import DbFaultMode, IdemStatus, ReservationState, idempotency_pk
from helpers import build

PAYLOAD = {"customer_id": "customer-123", "items": [{"sku": "product-001", "quantity": 2, "unit_price": "49.90"}]}


def req(payload=PAYLOAD):
    return CreateOrderRequest.model_validate(payload)


def stock(inv, sku="product-001"):
    return inv.store.products[sku].available


async def test_sequential_retries_create_single_order_and_replay_same_response(dynamodb, clock):
    svc, repo, inv = build(dynamodb, clock)
    key = str(uuid.uuid4())
    before = stock(inv)
    first = await svc.create("customer-123", key, req())
    second = await svc.create("customer-123", key, req())
    assert first.status == second.status == 201
    assert first.headers["Idempotency-Replayed"] == "false" and second.headers["Idempotency-Replayed"] == "true"
    assert first.body == second.body and first.body["status"] == "CONFIRMED" and first.body["total_amount"] == "99.80"
    assert stock(inv) == before - 2
    orders, _ = repo.list_orders("customer-123", 10, None)
    assert len(orders) == 1


async def test_same_key_different_payload_returns_409(dynamodb, clock):
    svc, _, _ = build(dynamodb, clock)
    key = str(uuid.uuid4())
    assert (await svc.create("customer-123", key, req())).status == 201
    other = {**PAYLOAD, "items": [{"sku": "product-001", "quantity": 3, "unit_price": "49.90"}]}
    result = await svc.create("customer-123", key, req(other))
    assert result.status == 409 and result.body["error"] == "IDEMPOTENCY_KEY_REUSED"


async def test_different_keys_create_distinct_orders(dynamodb, clock):
    svc, repo, _ = build(dynamodb, clock)
    a = await svc.create("customer-123", str(uuid.uuid4()), req())
    b = await svc.create("customer-123", str(uuid.uuid4()), req())
    assert a.body["order_id"] != b.body["order_id"]
    assert len(repo.list_orders("customer-123", 10, None)[0]) == 2


async def test_dynamodb_failure_after_reservation_compensates_and_retry_does_not_duplicate(dynamodb, clock):
    svc, repo, inv = build(dynamodb, clock)
    key = str(uuid.uuid4())
    before = stock(inv)
    repo.fault_mode = DbFaultMode.FAIL_TRANSACT
    failed = await svc.create("customer-123", key, req())
    assert failed.status == 503 and failed.body["error"] == "DEPENDENCY_UNAVAILABLE"
    record = repo.get_record(idempotency_pk("customer-123", key))
    assert record.status == IdemStatus.IN_PROGRESS  # transitório != FAILED_TERMINAL
    assert record.reservation_state == ReservationState.RELEASED
    assert stock(inv) == before  # compensado
    repo.fault_mode = DbFaultMode.NONE
    ok = await svc.create("customer-123", key, req())
    assert ok.status == 201
    assert stock(inv) == before - 2  # exatamente uma reserva efetiva
    assert len(inv.store.reservations) == 1
    assert len(repo.list_orders("customer-123", 10, None)[0]) == 1


async def test_unknown_outcome_after_commit_is_resolved_without_compensation(dynamodb, clock):
    svc, repo, inv = build(dynamodb, clock)
    key = str(uuid.uuid4())
    before = stock(inv)
    repo.fault_mode = DbFaultMode.TRANSACT_UNKNOWN_AFTER_COMMIT
    result = await svc.create("customer-123", key, req())
    repo.fault_mode = DbFaultMode.NONE
    assert result.status == 201  # re-leitura descobriu que o commit aconteceu
    assert stock(inv) == before - 2  # NÃO houve compensação cega
    replay = await svc.create("customer-123", key, req())
    assert replay.headers["Idempotency-Replayed"] == "true" and replay.body == result.body


async def test_insufficient_stock_is_terminal_and_replayed(dynamodb, clock):
    svc, _, inv = build(dynamodb, clock)
    key = str(uuid.uuid4())
    payload = {"customer_id": "customer-123", "items": [{"sku": "product-limited", "quantity": 50, "unit_price": "999.00"}]}
    first = await svc.create("customer-123", key, req(payload))
    second = await svc.create("customer-123", key, req(payload))
    assert first.status == second.status == 409 and first.body["error"] == "INSUFFICIENT_STOCK"
    assert second.headers["Idempotency-Replayed"] == "true"


async def test_crashed_executor_is_recovered_after_lease_without_duplicate_reservation(dynamodb, clock):
    svc, repo, inv = build(dynamodb, clock)
    key = str(uuid.uuid4())
    before = stock(inv)
    order_req = req()
    # Simula um Pod que criou o registro, reservou o estoque e morreu antes de persistir.
    _, rec = repo.claim(customer_id="customer-123", key=key, request_hash=order_req.request_hash(), order_id="ord-crashed",
                        lease_seconds=10, ttl_seconds=86400)
    await svc.inventory.reserve("res-ord-crashed", "reserve-ord-crashed", "ord-crashed",
                                [{"sku": "product-001", "quantity": 2}], fencing_token=rec.version)
    assert stock(inv) == before - 2

    in_progress = await svc.create("customer-123", key, order_req)
    assert in_progress.status == 409 and in_progress.body["error"] == "ORDER_IN_PROGRESS"
    assert int(in_progress.headers["Retry-After"]) >= 1

    clock.advance(11)
    recovered = await svc.create("customer-123", key, order_req)
    assert recovered.status == 201 and recovered.body["order_id"] == "ord-crashed"
    assert stock(inv) == before - 2  # reserva reutilizada, não duplicada
    assert repo.get_record(rec.pk).version == 2


async def test_inventory_outage_opens_circuit_and_fails_fast(dynamodb, clock):
    from app.circuit_breaker import CircuitState
    from inventory_app.faults import FaultConfig, FaultMode

    svc, repo, inv = build(dynamodb, clock, stock_precheck=False)
    await inv.faults.apply_config(FaultConfig(fault_mode=FaultMode.HTTP_503))
    try:
        results = [await svc.create("customer-123", str(uuid.uuid4()), req()) for _ in range(3)]
        assert all(r.status == 503 for r in results)
        assert svc.inventory.circuit.state == CircuitState.OPEN
        fast = await svc.create("customer-123", str(uuid.uuid4()), req())
        assert fast.status == 503 and fast.body["reason"] == "circuit_open"
    finally:
        await inv.faults.apply_config(FaultConfig())
