"""Cliente da Inventory API com timeout, retry (backoff exponencial + full jitter),
bulkhead (limite de concorrência) e Circuit Breaker.

Proteções contra retry amplification:
- Apenas a Orders API faz retry para a Inventory (a BFF não faz retry de POST).
- No máximo INVENTORY_MAX_RETRIES retries, apenas para falhas transitórias.
- Orçamento total por chamada (INVENTORY_CALL_BUDGET_MS): não inicia retry que estoure o prazo.
- Circuit OPEN interrompe imediatamente qualquer retry.
- Bulkhead cheio => falha rápida, sem fila ilimitada.
"""

from __future__ import annotations

import asyncio
import logging
import random
import time
from dataclasses import dataclass
from typing import Awaitable, Callable

import httpx
from opentelemetry import trace
from opentelemetry.metrics import Observation

from . import metrics as m
from .circuit_breaker import STATE_VALUE, CircuitBreaker, CircuitOpenError
from .config import Settings

log = logging.getLogger("orders.inventory_client")
tracer = trace.get_tracer("orders-api")

TRANSIENT_STATUS = {500, 502, 503, 504}


class DependencyUnavailable(Exception):
    """Falha transitória da Inventory API após retries / circuito aberto / bulkhead cheio.

    `outcome_unknown=True` quando ao menos uma tentativa pode ter sido aplicada no
    servidor (timeout de leitura) — o efeito (reserva) pode ter ocorrido.
    """

    def __init__(self, reason: str, outcome_unknown: bool, retry_after: float = 1.0) -> None:
        super().__init__(reason)
        self.reason = reason
        self.outcome_unknown = outcome_unknown
        self.retry_after = retry_after


class _Transient(Exception):
    def __init__(self, reason: str, maybe_applied: bool) -> None:
        super().__init__(reason)
        self.reason = reason
        self.maybe_applied = maybe_applied


class BulkheadFull(Exception):
    pass


@dataclass
class InventoryResponse:
    status_code: int
    body: dict


class InventoryClient:
    def __init__(self, settings: Settings, transport: httpx.AsyncBaseTransport | None = None) -> None:
        self.settings = settings
        self.timeout_ms = settings.inventory_timeout_ms
        self._client = httpx.AsyncClient(
            base_url=settings.inventory_url,
            transport=transport,
            timeout=httpx.Timeout(settings.inventory_timeout_ms / 1000),
            limits=httpx.Limits(max_connections=settings.inventory_max_concurrent_requests * 2,
                                max_keepalive_connections=settings.inventory_max_concurrent_requests),
        )
        self._bulkhead = asyncio.Semaphore(settings.inventory_max_concurrent_requests)
        self.circuit = CircuitBreaker(
            "inventory-api",
            failure_threshold=settings.cb_failure_threshold,
            recovery_timeout=settings.cb_recovery_timeout_seconds,
            half_open_max_calls=settings.cb_half_open_max_calls,
            on_transition=lambda old, new: m.cb_transitions.add(
                1, {"circuit_breaker.name": "inventory-api", "from_state": old.value, "to_state": new.value}),
            on_reject=lambda state: m.cb_rejected.add(1, {"circuit_breaker.name": "inventory-api", "state": state.value}),
        )
        m.meter.create_observable_gauge(
            "circuit_breaker.state",
            [lambda _opts: [Observation(STATE_VALUE[self.circuit.state], {"circuit_breaker.name": "inventory-api"})]],
            description="0=CLOSED, 1=HALF_OPEN, 2=OPEN",
        )

    async def close(self) -> None:
        await self._client.aclose()

    # ------------------------------------------------------------------ operations
    async def get_stock(self, sku: str) -> InventoryResponse:
        return await self._call("get_stock", lambda timeout: self._client.get(f"/inventory/{sku}", timeout=timeout),
                                mutating=False)

    async def reserve(self, reservation_id: str, idempotency_key: str, order_id: str, items: list[dict],
                      fencing_token: int) -> InventoryResponse:
        payload = {"reservation_id": reservation_id, "order_id": order_id, "items": items, "fencing_token": fencing_token}
        return await self._call(
            "reserve",
            lambda timeout: self._client.post("/inventory/reservations", json=payload, timeout=timeout,
                                              headers={"Idempotency-Key": idempotency_key}),
            mutating=True,
        )

    async def release(self, reservation_id: str, fencing_token: int) -> InventoryResponse:
        return await self._call(
            "release",
            lambda timeout: self._client.delete(f"/inventory/reservations/{reservation_id}",
                                                params={"fencing_token": fencing_token}, timeout=timeout),
            mutating=True,
        )

    # ------------------------------------------------------------------ core
    async def _call(self, operation: str, send: Callable[[float], Awaitable[httpx.Response]], mutating: bool) -> InventoryResponse:
        s = self.settings
        deadline = time.monotonic() + s.inventory_call_budget_ms / 1000
        maybe_applied = False
        last_reason = "unknown"
        attempts = s.inventory_max_retries + 1
        with tracer.start_as_current_span(f"Inventory {operation}") as span:
            span.set_attribute("inventory.operation", operation)
            for attempt in range(attempts):
                if attempt > 0:
                    backoff = random.uniform(0, min(s.inventory_retry_max_backoff_ms, s.inventory_retry_base_ms * 2 ** (attempt - 1))) / 1000
                    if time.monotonic() + backoff + 0.01 >= deadline:
                        span.add_event("retry.budget_exhausted", {"attempt": attempt})
                        break
                    m.inventory_retry_attempts.add(1, {"operation": operation})
                    span.add_event("retry", {"attempt": attempt, "backoff_ms": round(backoff * 1000, 1), "reason": last_reason})
                    log.warning("Retry para Inventory API", extra={"inventory.operation": operation, "retry.attempt": attempt,
                                                                   "retry.backoff_ms": round(backoff * 1000, 1), "retry.reason": last_reason})
                    await asyncio.sleep(backoff)
                remaining = deadline - time.monotonic()
                timeout = max(0.05, min(self.timeout_ms / 1000, remaining))
                try:
                    response = await self._attempt(send, timeout)
                except CircuitOpenError as exc:
                    span.set_attribute("circuit_breaker.rejected", True)
                    span.add_event("circuit_breaker.open", {"retry_after": round(exc.retry_after, 2)})
                    raise DependencyUnavailable("circuit_open", maybe_applied, max(1.0, exc.retry_after)) from exc
                except BulkheadFull as exc:
                    m.bulkhead_rejected.add(1, {"operation": operation})
                    raise DependencyUnavailable("bulkhead_full", maybe_applied) from exc
                except _Transient as exc:
                    last_reason = exc.reason
                    maybe_applied = maybe_applied or (mutating and exc.maybe_applied)
                    span.add_event("attempt.failed", {"attempt": attempt, "reason": exc.reason})
                    continue
                span.set_attributes({"inventory.attempts": attempt + 1, "http.response.status_code": response.status_code})
                return response
            span.set_attributes({"inventory.attempts": attempts, "inventory.outcome_unknown": maybe_applied})
            span.set_status(trace.Status(trace.StatusCode.ERROR, last_reason))
            raise DependencyUnavailable(last_reason, maybe_applied)

    async def _attempt(self, send: Callable[[float], Awaitable[httpx.Response]], timeout: float) -> InventoryResponse:
        try:
            await asyncio.wait_for(self._bulkhead.acquire(), timeout=self.settings.bulkhead_acquire_timeout_ms / 1000)
        except asyncio.TimeoutError as exc:
            raise BulkheadFull() from exc
        try:
            admitted = self.circuit.before_call()
            try:
                response = await send(timeout)
            except httpx.TimeoutException as exc:
                self.circuit.record_failure(admitted)
                # Timeout de conexão: requisição não chegou. Timeout de leitura: pode ter sido aplicada.
                raise _Transient("timeout", maybe_applied=not isinstance(exc, httpx.ConnectTimeout)) from exc
            except httpx.TransportError as exc:
                self.circuit.record_failure(admitted)
                raise _Transient(f"transport_error:{type(exc).__name__}", maybe_applied=not isinstance(exc, httpx.ConnectError)) from exc
            except BaseException:
                self.circuit.release(admitted)
                raise
            if response.status_code in TRANSIENT_STATUS:
                self.circuit.record_failure(admitted)
                raise _Transient(f"http_{response.status_code}", maybe_applied=response.status_code != 503)
            self.circuit.record_success(admitted)
            try:
                body = response.json()
            except ValueError:
                body = {}
            return InventoryResponse(response.status_code, body)
        finally:
            self._bulkhead.release()
