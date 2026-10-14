"""Configuração do OpenTelemetry (traces, métricas e logs) para as APIs do workshop.

- Exportação OTLP/HTTP para o OpenTelemetry Collector (OTEL_EXPORTER_OTLP_ENDPOINT).
- Sampling 100% (ParentBased(ALWAYS_ON)) no MVP — ver docs para limitações em produção.
- Semântica HTTP estável (OTEL_SEMCONV_STABILITY_OPT_IN=http): métrica
  `http.server.request.duration` com http.request.method, http.route, http.response.status_code.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from typing import Iterable

from opentelemetry import metrics, trace
from opentelemetry.metrics import CallbackOptions, Observation
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.trace.sampling import ALWAYS_ON, ParentBased

from .config import env_bool, env_int, env_str
from .logging_setup import configure_logging

log = logging.getLogger(__name__)

# Precisa estar definido ANTES de importar/instrumentar FastAPI e httpx.
os.environ.setdefault("OTEL_SEMCONV_STABILITY_OPT_IN", "http")


@dataclass
class Telemetry:
    service_name: str
    tracer_provider: TracerProvider
    meter_provider: MeterProvider
    logger_provider: object | None
    exporting: bool

    def shutdown(self) -> None:
        for provider in (self.tracer_provider, self.meter_provider, self.logger_provider):
            if provider is None:
                continue
            try:
                provider.shutdown()  # type: ignore[attr-defined]
            except Exception:  # pragma: no cover - best effort no shutdown
                log.warning("Falha ao finalizar provider de telemetria", exc_info=True)


def _exporting_enabled() -> bool:
    if env_bool("OTEL_SDK_DISABLED", False):
        return False
    return bool(os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT"))


def setup_telemetry(service_name: str, service_version: str = "1.0.0") -> Telemetry:
    resource = Resource.create(
        {
            "service.name": service_name,
            "service.version": service_version,
            "service.namespace": "ecommerce",
            "deployment.environment.name": env_str("DEPLOYMENT_ENVIRONMENT", "workshop"),
        }
    )
    exporting = _exporting_enabled()

    tracer_provider = TracerProvider(resource=resource, sampler=ParentBased(ALWAYS_ON))
    readers = []
    logger_provider = None
    otel_log_handler = None

    if exporting:
        from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter
        from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
        from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
        from opentelemetry._logs import set_logger_provider
        from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
        from opentelemetry.sdk._logs.export import BatchLogRecordProcessor

        tracer_provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
        readers.append(
            PeriodicExportingMetricReader(
                OTLPMetricExporter(), export_interval_millis=env_int("OTEL_METRIC_EXPORT_INTERVAL", 10000)
            )
        )
        logger_provider = LoggerProvider(resource=resource)
        logger_provider.add_log_record_processor(BatchLogRecordProcessor(OTLPLogExporter()))
        set_logger_provider(logger_provider)
        otel_log_handler = LoggingHandler(level=logging.INFO, logger_provider=logger_provider)

    trace.set_tracer_provider(tracer_provider)
    meter_provider = MeterProvider(resource=resource, metric_readers=readers)
    metrics.set_meter_provider(meter_provider)

    configure_logging(service_name, env_str("LOG_LEVEL", "INFO"), otel_log_handler)

    from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor

    HTTPXClientInstrumentor().instrument()
    _register_cgroup_metrics(metrics.get_meter("workshop.runtime"))

    log.info("Telemetria inicializada", extra={"otel.exporting": exporting})
    return Telemetry(service_name, tracer_provider, meter_provider, logger_provider, exporting)


def instrument_fastapi(app) -> None:
    from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

    # Health checks não geram spans nem métricas HTTP (evita ruído e custo).
    FastAPIInstrumentor.instrument_app(app, excluded_urls="health/.*")


# --------------------------------------------------------------------------------------
# Métricas de cgroup v2: evidência direta de CPU throttling dentro do container.
# --------------------------------------------------------------------------------------
_CGROUP_CPU_STAT = "/sys/fs/cgroup/cpu.stat"
_CGROUP_MEMORY_CURRENT = "/sys/fs/cgroup/memory.current"


def read_cpu_stat(path: str = _CGROUP_CPU_STAT) -> dict[str, int]:
    try:
        with open(path, encoding="ascii") as fh:
            return {k: int(v) for k, v in (line.split() for line in fh if line.strip())}
    except (OSError, ValueError):
        return {}


def _register_cgroup_metrics(meter: metrics.Meter) -> None:
    if not os.path.exists(_CGROUP_CPU_STAT):
        return

    def throttled_periods(_: CallbackOptions) -> Iterable[Observation]:
        stat = read_cpu_stat()
        if "nr_throttled" in stat:
            yield Observation(stat["nr_throttled"])

    def throttled_time(_: CallbackOptions) -> Iterable[Observation]:
        stat = read_cpu_stat()
        if "throttled_usec" in stat:
            yield Observation(stat["throttled_usec"] / 1_000_000)

    def memory_current(_: CallbackOptions) -> Iterable[Observation]:
        try:
            with open(_CGROUP_MEMORY_CURRENT, encoding="ascii") as fh:
                yield Observation(int(fh.read().strip()))
        except (OSError, ValueError):
            return

    meter.create_observable_counter(
        "container.cpu.throttled_periods", [throttled_periods], unit="{period}",
        description="Períodos CFS em que o container foi throttled (cgroup v2 nr_throttled)",
    )
    meter.create_observable_counter(
        "container.cpu.throttled_time", [throttled_time], unit="s",
        description="Tempo total em throttling de CPU (cgroup v2 throttled_usec)",
    )
    meter.create_observable_gauge(
        "container.memory.cgroup_current", [memory_current], unit="By",
        description="Memória atual do cgroup do container (memory.current)",
    )
