"""Health checks: liveness, readiness e startup com semânticas distintas.

- startup: a aplicação terminou a inicialização (pode depender de warm-up).
- liveness: o processo está respondendo (NÃO verifica dependências externas).
- readiness: a réplica aceita tráfego (inicializada e não está em shutdown).

Readiness intencionalmente NÃO verifica dependências downstream (ex.: Inventory API),
para não remover todas as réplicas do Service quando uma dependência falha (cascata).

health_admin_router (API admin, só loopback; LAB 02) força cada probe a falhar em UM Pod:
- PUT /admin/health {"ready": false}: readiness 503, liveness segue 200 (sai do Service, não reinicia).
- POST /admin/health/freeze?seconds=N: bloqueia o event loop; nenhuma probe responde (sai do Service e,
  pela liveness, é reiniciado).
"""

from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass, field

from fastapi import APIRouter, Query
from fastapi.responses import JSONResponse
from pydantic import BaseModel

log = logging.getLogger(__name__)


@dataclass
class HealthState:
    started: bool = False
    shutting_down: bool = False
    forced_not_ready: bool = False   # LAB 02: readiness falha de propósito (health_admin_router)
    details: dict[str, object] = field(default_factory=dict)


def health_router(state: HealthState) -> APIRouter:
    router = APIRouter()

    @router.get("/health/live", include_in_schema=False)
    async def live() -> JSONResponse:
        return JSONResponse({"status": "ok"})

    @router.get("/health/ready", include_in_schema=False)
    async def ready() -> JSONResponse:
        if state.started and not state.shutting_down and not state.forced_not_ready:
            return JSONResponse({"status": "ready"})
        return JSONResponse({"status": "not_ready", "shutting_down": state.shutting_down,
                             "forced_not_ready": state.forced_not_ready}, status_code=503)

    @router.get("/health/startup", include_in_schema=False)
    async def startup() -> JSONResponse:
        if state.started:
            return JSONResponse({"status": "started", **state.details})
        return JSONResponse({"status": "starting", **state.details}, status_code=503)

    return router


class _ReadyPatch(BaseModel):
    ready: bool


def health_admin_router(state: HealthState) -> APIRouter:
    router = APIRouter()

    def _state() -> dict[str, object]:
        return {"started": state.started, "shutting_down": state.shutting_down,
                "forced_not_ready": state.forced_not_ready}

    @router.get("/admin/health")
    async def get_health() -> dict[str, object]:
        return _state()

    @router.put("/admin/health")
    async def put_health(body: _ReadyPatch) -> dict[str, object]:
        state.forced_not_ready = not body.ready
        log.warning("Readiness forçada: %s", "ready" if body.ready else "NOT ready (liveness continua ok)")
        return _state()

    @router.post("/admin/health/freeze")
    async def freeze(seconds: int = Query(ge=1, le=300)) -> dict[str, object]:
        # time.sleep (síncrono) DENTRO do event loop: a API, a admin e as probes param de responder.
        # Agendado para depois desta resposta, para o chamador não ficar preso.
        log.warning("Congelando o event loop por %ss (simula processo travado)", seconds)
        asyncio.get_running_loop().call_later(0.2, time.sleep, seconds)
        return {"frozen_seconds": seconds}

    return router
