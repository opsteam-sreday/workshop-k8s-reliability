"""Geradores controlados de CPU e memória para os laboratórios."""

from __future__ import annotations

import multiprocessing
import time


def burn_cpu(duration_ms: float) -> None:
    """Busy loop por `duration_ms` (executar via asyncio.to_thread)."""
    if duration_ms <= 0:
        return
    end = time.perf_counter() + duration_ms / 1000
    x = 0
    while time.perf_counter() < end:
        x = (x * 31 + 7) % 1_000_003


def _burn_forever() -> None:  # pragma: no cover - executado em processo filho
    while True:
        burn_cpu(1000)


class BackgroundCpuStress:
    """Processos filhos que consomem CPU continuamente (1 core por worker)."""

    def __init__(self) -> None:
        self._procs: list[multiprocessing.Process] = []

    @property
    def workers(self) -> int:
        self._procs = [p for p in self._procs if p.is_alive()]
        return len(self._procs)

    def set_workers(self, count: int) -> None:
        self.stop()
        ctx = multiprocessing.get_context("fork")
        for _ in range(count):
            proc = ctx.Process(target=_burn_forever, daemon=True)
            proc.start()
            self._procs.append(proc)

    def stop(self) -> None:
        for proc in self._procs:
            proc.terminate()
        for proc in self._procs:
            proc.join(timeout=2)
        self._procs = []


class MemoryBallast:
    """Aloca e mantém memória residente (páginas tocadas) para simular memory pressure."""

    CHUNK_MB = 16

    def __init__(self) -> None:
        self._chunks: list[bytearray] = []

    @property
    def allocated_mb(self) -> int:
        return len(self._chunks) * self.CHUNK_MB

    def grow_step(self, target_mb: int) -> bool:
        """Aloca um chunk em direção ao alvo. Retorna True se ainda falta alocar."""
        if self.allocated_mb > target_mb:
            while self._chunks and self.allocated_mb > target_mb:
                self._chunks.pop()
            return False
        if self.allocated_mb + self.CHUNK_MB > target_mb:
            return False
        chunk = bytearray(self.CHUNK_MB * 1024 * 1024)
        for i in range(0, len(chunk), 4096):
            chunk[i] = 1
        self._chunks.append(chunk)
        return self.allocated_mb + self.CHUNK_MB <= target_mb

    def release(self) -> None:
        self._chunks.clear()
