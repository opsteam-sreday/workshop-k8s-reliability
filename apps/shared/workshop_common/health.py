"""Health checks: liveness, readiness e startup com semânticas distintas.

- startup: a aplicação terminou a inicialização (pode depender de warm-up).
- liveness: o processo está respondendo (NÃO verifica dependências externas).
- readiness: a réplica aceita tráfego (inicializada e não está em shutdown).

Readiness intencionalmente NÃO verifica dependências downstream (ex.: Inventory API),
para não remover todas as réplicas do Service quando uma dependência falha (cascata).
"""

from __future__ import annotations

from dataclasses import dataclass, field

from fastapi import APIRouter
from fastapi.responses import JSONResponse


@dataclass
class HealthState:
    started: bool = False
    shutting_down: bool = False
    details: dict[str, object] = field(default_factory=dict)


def health_router(state: HealthState) -> APIRouter:
    router = APIRouter()

    @router.get("/health/live", include_in_schema=False)
    async def live() -> JSONResponse:
        return JSONResponse({"status": "ok"})

    @router.get("/health/ready", include_in_schema=False)
    async def ready() -> JSONResponse:
        if state.started and not state.shutting_down:
            return JSONResponse({"status": "ready"})
        return JSONResponse({"status": "not_ready", "shutting_down": state.shutting_down}, status_code=503)

    @router.get("/health/startup", include_in_schema=False)
    async def startup() -> JSONResponse:
        if state.started:
            return JSONResponse({"status": "started", **state.details})
        return JSONResponse({"status": "starting", **state.details}, status_code=503)

    return router
