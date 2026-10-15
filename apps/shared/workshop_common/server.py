"""Executa a API principal (0.0.0.0) e a API administrativa de laboratório (127.0.0.1).

A API administrativa (injeção de falhas) escuta SOMENTE em loopback: não é acessível
pela rede do cluster, nem pelo Service. Acesso apenas via `kubectl exec`/`port-forward`
por quem tem RBAC para isso. Ela só é habilitada com WORKSHOP_MODE=true.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import signal

import uvicorn

from .config import env_bool, env_float, env_int
from .health import HealthState

log = logging.getLogger(__name__)


class _Server(uvicorn.Server):
    @contextlib.contextmanager
    def capture_signals(self):  # sinais tratados centralmente em run()
        yield


def run(app, admin_app, health: HealthState) -> None:
    asyncio.run(_serve(app, admin_app, health))


async def _serve(app, admin_app, health: HealthState) -> None:
    servers = [
        _Server(
            uvicorn.Config(
                app, host="0.0.0.0", port=env_int("PORT", 8080), log_config=None, access_log=False,
                timeout_keep_alive=env_int("HTTP_KEEPALIVE_SECONDS", 30), timeout_graceful_shutdown=20,
            )
        )
    ]
    if admin_app is not None and env_bool("WORKSHOP_MODE", False):
        servers.append(
            _Server(
                uvicorn.Config(
                    admin_app, host="127.0.0.1", port=env_int("ADMIN_PORT", 8081), log_config=None, access_log=False,
                )
            )
        )

    loop = asyncio.get_running_loop()
    shutdown_delay = env_float("SHUTDOWN_DELAY_SECONDS", 5)

    async def graceful_shutdown() -> None:
        # Readiness passa a falhar; aguardamos a remoção dos endpoints antes de parar.
        health.shutting_down = True
        log.warning("SIGTERM recebido: readiness=false, aguardando %.1fs antes de encerrar", shutdown_delay)
        await asyncio.sleep(shutdown_delay)
        for server in servers:
            server.should_exit = True

    def on_signal() -> None:
        if not health.shutting_down:
            loop.create_task(graceful_shutdown())

    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, on_signal)

    await asyncio.gather(*(server.serve() for server in servers))
