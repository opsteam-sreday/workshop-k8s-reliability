"""Context variables propagadas por requisição (correlation IDs)."""

from __future__ import annotations

from contextvars import ContextVar

request_id_var: ContextVar[str | None] = ContextVar("request_id", default=None)
# Escopo ASGI da requisição atual: permite anexar http.route/http.request.method a QUALQUER log.
http_scope_var: ContextVar[dict | None] = ContextVar("http_scope", default=None)


def current_request_id() -> str | None:
    return request_id_var.get()
