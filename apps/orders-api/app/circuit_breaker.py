"""Circuit Breaker local (por réplica) para chamadas da Orders API à Inventory API.

Política:
- CLOSED: conta falhas CONSECUTIVAS; ao atingir `failure_threshold` -> OPEN.
- OPEN: rejeita imediatamente (fail fast) até `recovery_timeout` -> HALF_OPEN.
- HALF_OPEN: permite no máximo `half_open_max_calls` chamadas de teste simultâneas.
  Se `half_open_max_calls` chamadas tiverem sucesso -> CLOSED. Qualquer falha -> OPEN.

LIMITAÇÃO DO MVP: o estado é local a cada réplica (cada Pod abre/fecha seu próprio
circuito). Com N réplicas, a Inventory API pode receber até N x half_open_max_calls
chamadas de teste.
"""

from __future__ import annotations

import logging
import time
from enum import Enum
from typing import Callable

log = logging.getLogger("orders.circuit_breaker")


class CircuitState(str, Enum):
    CLOSED = "CLOSED"
    OPEN = "OPEN"
    HALF_OPEN = "HALF_OPEN"


STATE_VALUE = {CircuitState.CLOSED: 0, CircuitState.HALF_OPEN: 1, CircuitState.OPEN: 2}


class CircuitOpenError(Exception):
    def __init__(self, name: str, retry_after: float) -> None:
        super().__init__(f"circuit {name} is open")
        self.retry_after = retry_after


class CircuitBreaker:
    def __init__(
        self,
        name: str,
        failure_threshold: int = 5,
        recovery_timeout: float = 15.0,
        half_open_max_calls: int = 2,
        clock: Callable[[], float] = time.monotonic,
        on_transition: Callable[[CircuitState, CircuitState], None] | None = None,
        on_reject: Callable[[CircuitState], None] | None = None,
    ) -> None:
        self.name = name
        self.failure_threshold = failure_threshold
        self.recovery_timeout = recovery_timeout
        self.half_open_max_calls = half_open_max_calls
        self._clock = clock
        self._on_transition = on_transition or (lambda a, b: None)
        self._on_reject = on_reject or (lambda s: None)
        self._state = CircuitState.CLOSED
        self._consecutive_failures = 0
        self._opened_at = 0.0
        self._half_open_in_flight = 0
        self._half_open_successes = 0

    @property
    def state(self) -> CircuitState:
        if self._state == CircuitState.OPEN and self._clock() - self._opened_at >= self.recovery_timeout:
            self._transition(CircuitState.HALF_OPEN)
        return self._state

    def snapshot(self) -> dict[str, object]:
        state = self.state
        return {
            "name": self.name,
            "state": state.value,
            "consecutive_failures": self._consecutive_failures,
            "half_open_in_flight": self._half_open_in_flight,
            "half_open_successes": self._half_open_successes,
            "open_remaining_seconds": max(0.0, round(self.recovery_timeout - (self._clock() - self._opened_at), 2))
            if state == CircuitState.OPEN else 0.0,
            "failure_threshold": self.failure_threshold,
            "recovery_timeout_seconds": self.recovery_timeout,
            "half_open_max_calls": self.half_open_max_calls,
        }

    def before_call(self) -> CircuitState:
        """Reserva permissão para uma chamada ou lança CircuitOpenError."""
        state = self.state
        if state == CircuitState.OPEN:
            self._on_reject(state)
            raise CircuitOpenError(self.name, self.recovery_timeout - (self._clock() - self._opened_at))
        if state == CircuitState.HALF_OPEN:
            if self._half_open_in_flight >= self.half_open_max_calls:
                self._on_reject(state)
                raise CircuitOpenError(self.name, 1.0)
            self._half_open_in_flight += 1
        return state

    def record_success(self, admitted_in: CircuitState) -> None:
        if admitted_in == CircuitState.HALF_OPEN:
            self._half_open_in_flight = max(0, self._half_open_in_flight - 1)
            if self._state == CircuitState.HALF_OPEN:
                self._half_open_successes += 1
                if self._half_open_successes >= self.half_open_max_calls:
                    self._transition(CircuitState.CLOSED)
            return
        if self._state == CircuitState.CLOSED:
            self._consecutive_failures = 0

    def record_failure(self, admitted_in: CircuitState) -> None:
        if admitted_in == CircuitState.HALF_OPEN:
            self._half_open_in_flight = max(0, self._half_open_in_flight - 1)
            if self._state == CircuitState.HALF_OPEN:
                self._transition(CircuitState.OPEN)
            return
        if self._state == CircuitState.CLOSED:
            self._consecutive_failures += 1
            if self._consecutive_failures >= self.failure_threshold:
                self._transition(CircuitState.OPEN)

    def release(self, admitted_in: CircuitState) -> None:
        """Chamada admitida que não produziu resultado (ex.: cancelada): libera a vaga."""
        if admitted_in == CircuitState.HALF_OPEN:
            self._half_open_in_flight = max(0, self._half_open_in_flight - 1)

    def reset(self) -> None:
        self._transition(CircuitState.CLOSED)

    def _transition(self, new_state: CircuitState) -> None:
        old = self._state
        if old == new_state:
            return
        self._state = new_state
        if new_state == CircuitState.OPEN:
            self._opened_at = self._clock()
        if new_state == CircuitState.CLOSED:
            self._consecutive_failures = 0
        if new_state in (CircuitState.HALF_OPEN, CircuitState.OPEN, CircuitState.CLOSED):
            self._half_open_successes = 0
        if new_state != CircuitState.HALF_OPEN:
            self._half_open_in_flight = 0
        level = logging.WARNING if new_state != CircuitState.CLOSED else logging.INFO
        log.log(level, "Circuit breaker transition", extra={
            "circuit_breaker.name": self.name, "circuit_breaker.from": old.value, "circuit_breaker.to": new_state.value,
        })
        self._on_transition(old, new_state)
