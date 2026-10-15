import pytest

from app.circuit_breaker import CircuitBreaker, CircuitOpenError, CircuitState


class Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t


def make(clock, **kw):
    transitions = []
    cb = CircuitBreaker("test", failure_threshold=3, recovery_timeout=10, half_open_max_calls=2, clock=clock,
                        on_transition=lambda a, b: transitions.append((a.value, b.value)), **kw)
    return cb, transitions


def fail(cb):
    cb.record_failure(cb.before_call())


def succeed(cb):
    cb.record_success(cb.before_call())


def test_opens_after_consecutive_failures_and_rejects_fast():
    clock = Clock()
    cb, transitions = make(clock)
    fail(cb), fail(cb)
    succeed(cb)  # sucesso zera falhas consecutivas
    fail(cb), fail(cb)
    assert cb.state == CircuitState.CLOSED
    fail(cb)
    assert cb.state == CircuitState.OPEN
    with pytest.raises(CircuitOpenError):
        cb.before_call()
    assert transitions == [("CLOSED", "OPEN")]


def test_half_open_limits_trial_calls_and_closes_after_successes():
    clock = Clock()
    cb, transitions = make(clock)
    for _ in range(3):
        fail(cb)
    clock.t = 10
    assert cb.state == CircuitState.HALF_OPEN
    a = cb.before_call()
    b = cb.before_call()
    with pytest.raises(CircuitOpenError):
        cb.before_call()  # máximo de 2 chamadas de teste simultâneas
    cb.record_success(a)
    assert cb.state == CircuitState.HALF_OPEN
    cb.record_success(b)
    assert cb.state == CircuitState.CLOSED
    assert transitions == [("CLOSED", "OPEN"), ("OPEN", "HALF_OPEN"), ("HALF_OPEN", "CLOSED")]


def test_half_open_failure_reopens():
    clock = Clock()
    cb, transitions = make(clock)
    for _ in range(3):
        fail(cb)
    clock.t = 10
    fail(cb)
    assert cb.state == CircuitState.OPEN
    clock.t = 15
    assert cb.state == CircuitState.OPEN  # novo recovery_timeout a partir da reabertura
    clock.t = 20
    assert cb.state == CircuitState.HALF_OPEN
    assert transitions[-2:] == [("HALF_OPEN", "OPEN"), ("OPEN", "HALF_OPEN")]
