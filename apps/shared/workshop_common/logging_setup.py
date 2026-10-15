"""Logs estruturados em JSON (stdout) + exportação OTLP com trace_id/span_id reais.

Os logs das APIs são enviados ao ClickStack SOMENTE via OTLP. O stdout em JSON existe
para `kubectl logs`; o coletor de logs de arquivos (filelog) exclui o namespace
`ecommerce` para evitar ingestão duplicada.
"""

from __future__ import annotations

import json
import logging
import sys
import traceback
from datetime import datetime, timezone

from opentelemetry import trace

from .context import current_request_id, http_scope_var

# Atributos padrão de LogRecord que não devem ser repetidos como campos extras.
_RESERVED = set(vars(logging.LogRecord("", 0, "", 0, "", (), None)).keys()) | {"message", "asctime", "taskName"}
_LEVEL_NAMES = {"WARNING": "WARN", "CRITICAL": "FATAL"}


def level_name(levelno: int) -> str:
    name = logging.getLevelName(levelno)
    return _LEVEL_NAMES.get(name, name)


class JsonFormatter(logging.Formatter):
    def __init__(self, service_name: str) -> None:
        super().__init__()
        self.service_name = service_name

    def format(self, record: logging.LogRecord) -> str:
        span_ctx = trace.get_current_span().get_span_context()
        payload: dict[str, object] = {
            "timestamp": datetime.fromtimestamp(record.created, tz=timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
            "level": level_name(record.levelno),
            "service.name": self.service_name,
            "trace_id": format(span_ctx.trace_id, "032x") if span_ctx.is_valid else None,
            "span_id": format(span_ctx.span_id, "016x") if span_ctx.is_valid else None,
            "request_id": getattr(record, "request_id", None) or current_request_id(),
            "logger": record.name,
            "message": record.getMessage(),
        }
        for key, value in record.__dict__.items():
            if key not in _RESERVED and key not in payload and not key.startswith("_"):
                payload[key] = value
        if record.exc_info:
            exc_type, exc, tb = record.exc_info
            payload["exception.type"] = exc_type.__name__ if exc_type else None
            payload["exception.message"] = str(exc)
            payload["exception.stacktrace"] = "".join(traceback.format_exception(exc_type, exc, tb))
        return json.dumps(payload, default=str, ensure_ascii=False)


class ContextFilter(logging.Filter):
    """Adiciona request_id e level normalizado como atributos (também exportados via OTLP)."""

    def filter(self, record: logging.LogRecord) -> bool:
        if not getattr(record, "request_id", None):
            record.request_id = current_request_id()
        record.level = level_name(record.levelno)
        scope = http_scope_var.get()
        if scope is not None:
            from .http import resolve_route

            if not hasattr(record, "http.route"):
                setattr(record, "http.route", resolve_route(scope))
            if not hasattr(record, "http.request.method"):
                setattr(record, "http.request.method", scope.get("method"))
        return True


def configure_logging(service_name: str, level: str = "INFO", otel_handler: logging.Handler | None = None) -> None:
    root = logging.getLogger()
    root.handlers.clear()
    root.setLevel(level.upper())

    stdout_handler = logging.StreamHandler(sys.stdout)
    stdout_handler.setFormatter(JsonFormatter(service_name))
    stdout_handler.addFilter(ContextFilter())
    root.addHandler(stdout_handler)

    if otel_handler is not None:
        otel_handler.addFilter(ContextFilter())
        root.addHandler(otel_handler)

    # Logs de bibliotecas muito verbosas ficam em WARN para evitar ruído/custo de ingestão.
    for noisy in ("uvicorn.access", "botocore", "boto3", "urllib3", "httpx", "httpcore"):
        logging.getLogger(noisy).setLevel(logging.WARNING)
