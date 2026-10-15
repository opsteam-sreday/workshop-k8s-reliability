"""Métricas de negócio da Orders API.

NUNCA usar Idempotency-Key, order_id ou customer_id como atributo de métrica
(cardinalidade ilimitada). Esses valores vão para logs e spans.
"""

from __future__ import annotations

from opentelemetry import metrics

meter = metrics.get_meter("orders-api")

orders_created = meter.create_counter("orders.created", unit="{order}", description="Pedidos CONFIRMED criados")
orders_failed = meter.create_counter("orders.failed", unit="{order}", description="Falhas na criação de pedidos")
orders_creation_duration = meter.create_histogram(
    "orders.creation.duration", unit="ms", description="Duração da criação de pedidos (POST /orders)"
)

idempotency_hit = meter.create_counter("orders.idempotency.hit", description="Replays de resultado já finalizado")
idempotency_conflict = meter.create_counter("orders.idempotency.conflict", description="Mesma chave com payload diferente")
idempotency_in_progress = meter.create_counter("orders.idempotency.in_progress", description="Requisição concorrente com operação em andamento")
idempotency_recovery = meter.create_counter("orders.idempotency.recovery", description="Lease expirado assumido por outro executor")
idempotency_duplicate_prevented = meter.create_counter(
    "orders.idempotency.duplicate_prevented", description="Tentativas que NÃO criaram pedido/reserva duplicados"
)

cb_transitions = meter.create_counter("circuit_breaker.transitions", description="Transições de estado do circuit breaker")
cb_rejected = meter.create_counter("circuit_breaker.rejected_requests", description="Chamadas rejeitadas (fail fast)")
inventory_retry_attempts = meter.create_counter("inventory.retry.attempts", description="Retries para a Inventory API")
bulkhead_rejected = meter.create_counter("inventory.bulkhead.rejected", description="Chamadas rejeitadas pelo bulkhead")
compensations = meter.create_counter("orders.compensations", description="Compensações (liberação de reserva)")
