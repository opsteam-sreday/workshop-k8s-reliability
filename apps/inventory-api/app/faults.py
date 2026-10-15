"""Injeção de falhas controlada da Inventory API (somente ambiente de workshop)."""

from __future__ import annotations

import asyncio
import logging
import random
from enum import Enum

from pydantic import BaseModel, Field

from workshop_common.config import env_bool, env_float, env_int, env_str
from workshop_common.http import ApiError
from workshop_common.stress import BackgroundCpuStress, MemoryBallast, burn_cpu

log = logging.getLogger("inventory.faults")

MEMORY_STRESS_MAX_MB = env_int("INVENTORY_MEMORY_STRESS_MAX_MB", 2048)


class FaultMode(str, Enum):
    NONE = "NONE"
    LATENCY = "LATENCY"                      # atraso ANTES de processar
    SLOW_AFTER_COMMIT = "SLOW_AFTER_COMMIT"  # efeito aplicado, resposta atrasada (timeout perigoso)
    HTTP_503 = "HTTP_503"                    # sempre 503
    ERROR_RATE = "ERROR_RATE"                # 503 com probabilidade error_rate
    LATENCY_AND_ERRORS = "LATENCY_AND_ERRORS"


class FaultTarget(str, Enum):
    ALL = "ALL"
    RESERVATIONS = "RESERVATIONS"  # POST/DELETE /inventory/reservations
    QUERIES = "QUERIES"            # GET /inventory/{sku}


class FaultConfig(BaseModel):
    fault_mode: FaultMode = FaultMode.NONE
    fault_target: FaultTarget = FaultTarget.ALL
    latency_ms: int = Field(0, ge=0, le=30_000)
    error_rate: float = Field(0.0, ge=0.0, le=1.0)
    cpu_stress_enabled: bool = False
    cpu_stress_duration_ms: int = Field(0, ge=0, le=5_000)
    cpu_stress_workers: int = Field(0, ge=0, le=4)
    memory_stress_mb: int = Field(0, ge=0, le=MEMORY_STRESS_MAX_MB)
    max_concurrent_requests: int = Field(10, ge=1, le=10_000)

    @classmethod
    def from_env(cls) -> "FaultConfig":
        return cls(
            fault_mode=FaultMode(env_str("INVENTORY_FAULT_MODE", "NONE").upper()),
            fault_target=FaultTarget(env_str("INVENTORY_FAULT_TARGET", "ALL").upper()),
            latency_ms=env_int("INVENTORY_LATENCY_MS", 0),
            error_rate=env_float("INVENTORY_ERROR_RATE", 0.0),
            cpu_stress_enabled=env_bool("INVENTORY_CPU_STRESS_ENABLED", False),
            cpu_stress_duration_ms=env_int("INVENTORY_CPU_STRESS_DURATION_MS", 0),
            cpu_stress_workers=env_int("INVENTORY_CPU_STRESS_WORKERS", 0),
            memory_stress_mb=env_int("INVENTORY_MEMORY_STRESS_MB", 0),
            max_concurrent_requests=env_int("INVENTORY_MAX_CONCURRENT_REQUESTS", 10),
        )


class FaultInjector:
    def __init__(self, config: FaultConfig, on_fault=None) -> None:
        self.config = config
        self.in_flight = 0
        self._on_fault = on_fault or (lambda kind: None)
        self._cpu = BackgroundCpuStress()
        self._ballast = MemoryBallast()
        self._memory_task: asyncio.Task | None = None

    # ------------------------------------------------------------------ runtime
    async def apply_config(self, config: FaultConfig) -> None:
        self.config = config
        if self._cpu.workers != config.cpu_stress_workers:
            await asyncio.to_thread(self._cpu.set_workers, config.cpu_stress_workers)
        if self._memory_task is None or self._memory_task.done():
            self._memory_task = asyncio.create_task(self._memory_loop())
        log.warning("Configuração de falhas alterada", extra={"faults": config.model_dump(mode="json")})

    async def start(self) -> None:
        await self.apply_config(self.config)

    async def stop(self) -> None:
        self._cpu.stop()
        if self._memory_task:
            self._memory_task.cancel()

    def status(self) -> dict[str, object]:
        return {
            **self.config.model_dump(mode="json"),
            "in_flight": self.in_flight,
            "cpu_stress_workers_running": self._cpu.workers,
            "memory_allocated_mb": self._ballast.allocated_mb,
        }

    async def _memory_loop(self) -> None:
        # Cresce gradualmente (16 MiB a cada 250 ms) para que o efeito seja observável.
        while True:
            target = self.config.memory_stress_mb
            if target == 0 and self._ballast.allocated_mb:
                self._ballast.release()
                log.warning("Memory ballast liberado")
            elif self._ballast.grow_step(target):
                await asyncio.sleep(0.25)
                continue
            await asyncio.sleep(1)

    # ------------------------------------------------------------------ requests
    def _targets(self, kind: FaultTarget) -> bool:
        return self.config.fault_target in (FaultTarget.ALL, kind)

    async def before(self, kind: FaultTarget) -> None:
        """Executado no início de cada requisição de negócio."""
        if self.in_flight > self.config.max_concurrent_requests:  # in_flight já inclui esta requisição
            self._on_fault("concurrency_limit")
            raise ApiError(503, "TOO_MANY_CONCURRENT_REQUESTS", "Limite de concorrência atingido", {"Retry-After": "1"})
        cfg = self.config
        if not self._targets(kind):
            return
        if cfg.fault_mode in (FaultMode.LATENCY, FaultMode.LATENCY_AND_ERRORS) and cfg.latency_ms:
            self._on_fault("latency")
            await asyncio.sleep(cfg.latency_ms / 1000)
        if cfg.cpu_stress_enabled and cfg.cpu_stress_duration_ms:
            self._on_fault("cpu_stress")
            await asyncio.to_thread(burn_cpu, cfg.cpu_stress_duration_ms)
        fail = cfg.fault_mode == FaultMode.HTTP_503 or (
            cfg.fault_mode in (FaultMode.ERROR_RATE, FaultMode.LATENCY_AND_ERRORS) and random.random() < cfg.error_rate
        )
        if fail:
            self._on_fault("http_503")
            log.error("Falha injetada: respondendo HTTP 503", extra={"http.response.status_code": 503,
                                                                     "fault.mode": cfg.fault_mode.value})
            raise ApiError(503, "INJECTED_FAULT", "Falha HTTP 503 injetada (laboratório)", {"Retry-After": "1"})

    async def after_commit(self, kind: FaultTarget) -> None:
        if self._targets(kind) and self.config.fault_mode == FaultMode.SLOW_AFTER_COMMIT and self.config.latency_ms:
            self._on_fault("slow_after_commit")
            await asyncio.sleep(self.config.latency_ms / 1000)

    def track(self):
        injector = self

        class _Track:
            async def __aenter__(self):
                injector.in_flight += 1

            async def __aexit__(self, *exc):
                injector.in_flight -= 1

        return _Track()
