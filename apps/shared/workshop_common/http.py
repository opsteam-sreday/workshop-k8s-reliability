"""Middleware HTTP: X-Request-ID, log de conclusão por requisição e tratamento de exceções."""

from __future__ import annotations

import json
import logging
import re
import time
import uuid

from starlette.datastructures import MutableHeaders
from starlette.routing import Match
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from .context import request_id_var

log = logging.getLogger("http.server")

_REQUEST_ID_RE = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")


def error_body(code: str, message: str, **extra: object) -> dict[str, object]:
    body: dict[str, object] = {"error": code, "message": message, "request_id": request_id_var.get()}
    body.update(extra)
    return body


def resolve_route(scope: Scope) -> str:
    """Retorna a rota normalizada (ex.: /orders/{order_id}); nunca o path com IDs."""
    route = scope.get("route")
    if route is not None and getattr(route, "path", None):
        return route.path
    app = scope.get("app")
    router = getattr(app, "router", None)
    for candidate in getattr(router, "routes", []):
        match, _ = candidate.matches(scope)
        if match == Match.FULL:
            return getattr(candidate, "path", "UNMATCHED")
    return "UNMATCHED"


class RequestContextMiddleware:
    """Define X-Request-ID, captura exceções não tratadas e emite um log por requisição.

    Executa DENTRO do span HTTP SERVER criado pela instrumentação FastAPI, portanto
    os logs carregam trace_id/span_id reais.
    """

    def __init__(self, app: ASGIApp, log_health: bool = False) -> None:
        self.app = app
        self.log_health = log_health

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        incoming = None
        for name, value in scope.get("headers", []):
            if name == b"x-request-id":
                incoming = value.decode("latin-1")
                break
        request_id = incoming if incoming and _REQUEST_ID_RE.match(incoming) else str(uuid.uuid4())
        token = request_id_var.set(request_id)

        state = {"status": 500, "started": False}

        async def send_wrapper(message: Message) -> None:
            if message["type"] == "http.response.start":
                state["status"] = message["status"]
                state["started"] = True
                MutableHeaders(scope=message)["X-Request-ID"] = request_id
            await send(message)

        start = time.perf_counter()
        try:
            await self.app(scope, receive, send_wrapper)
        except Exception:
            log.exception(
                "Unhandled exception",
                extra={"http.request.method": scope.get("method"), "http.route": resolve_route(scope)},
            )
            if not state["started"]:
                body = json.dumps(error_body("INTERNAL_ERROR", "Erro interno inesperado")).encode()
                await send_wrapper(
                    {
                        "type": "http.response.start",
                        "status": 500,
                        "headers": [(b"content-type", b"application/json"), (b"content-length", str(len(body)).encode())],
                    }
                )
                await send({"type": "http.response.body", "body": body})
        finally:
            duration_ms = round((time.perf_counter() - start) * 1000, 2)
            route = resolve_route(scope)
            if self.log_health or not route.startswith("/health"):
                status = state["status"]
                level = logging.ERROR if status >= 500 else logging.WARNING if status >= 400 else logging.INFO
                log.log(
                    level,
                    "HTTP request completed",
                    extra={
                        "http.request.method": scope.get("method"),
                        "http.route": route,
                        "http.response.status_code": status,
                        "duration_ms": duration_ms,
                    },
                )
            request_id_var.reset(token)


class ApiError(Exception):
    """Erro de negócio/HTTP com código estável no corpo da resposta."""

    def __init__(self, status: int, code: str, message: str, headers: dict[str, str] | None = None, **extra: object):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.headers = headers or {}
        self.extra = extra


def install_error_handlers(app) -> None:
    from fastapi.exceptions import RequestValidationError
    from fastapi.responses import JSONResponse

    @app.exception_handler(ApiError)
    async def _api_error(_request, exc: ApiError):
        return JSONResponse(error_body(exc.code, exc.message, **exc.extra), status_code=exc.status, headers=exc.headers)

    @app.exception_handler(RequestValidationError)
    async def _validation_error(_request, exc: RequestValidationError):
        details = [{"loc": list(e.get("loc", [])), "msg": e.get("msg")} for e in exc.errors()]
        return JSONResponse(error_body("INVALID_PAYLOAD", "Payload inválido", details=details), status_code=400)
