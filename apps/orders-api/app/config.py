"""Configuração da Orders API (variáveis de ambiente)."""

from __future__ import annotations

from dataclasses import dataclass

from workshop_common.config import env_bool, env_float, env_int, env_str


@dataclass
class Settings:
    table_name: str
    aws_region: str
    dynamodb_endpoint: str | None
    inventory_url: str
    inventory_timeout_ms: int
    inventory_max_retries: int
    inventory_retry_base_ms: int
    inventory_retry_max_backoff_ms: int
    inventory_call_budget_ms: int
    inventory_max_concurrent_requests: int
    bulkhead_acquire_timeout_ms: int
    cb_failure_threshold: int
    cb_recovery_timeout_seconds: float
    cb_half_open_max_calls: int
    stock_precheck: bool
    idempotency_ttl_seconds: int
    idempotency_lease_seconds: float
    cpu_work_ms: int

    @classmethod
    def from_env(cls) -> "Settings":
        return cls(
            table_name=env_str("ORDERS_TABLE_NAME", "workshop-orders"),
            aws_region=env_str("AWS_REGION", "us-east-1"),
            dynamodb_endpoint=env_str("DYNAMODB_ENDPOINT", "") or None,
            inventory_url=env_str("INVENTORY_URL", "http://inventory-api:8080"),
            inventory_timeout_ms=env_int("INVENTORY_TIMEOUT_MS", 500),
            inventory_max_retries=env_int("INVENTORY_MAX_RETRIES", 2),
            inventory_retry_base_ms=env_int("INVENTORY_RETRY_BASE_MS", 50),
            inventory_retry_max_backoff_ms=env_int("INVENTORY_RETRY_MAX_BACKOFF_MS", 400),
            inventory_call_budget_ms=env_int("INVENTORY_CALL_BUDGET_MS", 2000),
            inventory_max_concurrent_requests=env_int("INVENTORY_MAX_CONCURRENT_REQUESTS", 10),
            bulkhead_acquire_timeout_ms=env_int("INVENTORY_BULKHEAD_TIMEOUT_MS", 100),
            cb_failure_threshold=env_int("CB_FAILURE_THRESHOLD", 5),
            cb_recovery_timeout_seconds=env_float("CB_RECOVERY_TIMEOUT_SECONDS", 15),
            cb_half_open_max_calls=env_int("CB_HALF_OPEN_MAX_CALLS", 2),
            stock_precheck=env_bool("ORDERS_STOCK_PRECHECK", True),
            idempotency_ttl_seconds=env_int("IDEMPOTENCY_TTL_SECONDS", 24 * 3600),
            idempotency_lease_seconds=env_float("IDEMPOTENCY_LEASE_SECONDS", 10),
            cpu_work_ms=env_int("ORDERS_CPU_WORK_MS", 0),
        )
