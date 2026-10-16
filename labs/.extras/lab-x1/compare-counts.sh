#!/usr/bin/env bash
# LAB X1 — compara, para os últimos N minutos, três formas de "contar erros" da Orders API:
#   (a) COUNT(logs ERROR)        -> o que os alertas do MVP usam (anti-pattern)
#   (b) requisições distintas    -> uniqExact(request_id) dos logs ERROR
#   (c) spans HTTP SERVER 5xx    -> verdade operacional por rota/status
#   (d) métrica http.server.request.duration (count de 5xx)
source "$(dirname "$0")/../../../scripts/lib/common.sh"
source "$REPO_ROOT/scripts/lib/cluster-helpers.sh"
MIN="${1:-15}"
echo "== (a) COUNT(logs ERROR) por serviço/rota (janela ${MIN} min)"
clickhouse_query "SELECT ServiceName, LogAttributes['http.request.method'] AS method, LogAttributes['http.route'] AS route, count() AS error_logs
FROM otel_logs WHERE Timestamp > now() - INTERVAL ${MIN} MINUTE AND LogAttributes['level'] = 'ERROR'
  AND toUInt16OrZero(LogAttributes['http.response.status_code']) >= 500 GROUP BY ALL ORDER BY 1, 3"
echo; echo "== (b) requisições DISTINTAS com log ERROR (uniqExact(request_id))"
clickhouse_query "SELECT ServiceName, LogAttributes['http.request.method'], LogAttributes['http.route'], uniqExact(LogAttributes['request_id']) AS requests
FROM otel_logs WHERE Timestamp > now() - INTERVAL ${MIN} MINUTE AND LogAttributes['level'] = 'ERROR'
  AND toUInt16OrZero(LogAttributes['http.response.status_code']) >= 500 GROUP BY ALL ORDER BY 1, 3"
echo; echo "== (c) spans HTTP SERVER com status >= 500 (fonte recomendada na fase 2)"
clickhouse_query "SELECT ServiceName, SpanName, count() AS failed_requests FROM otel_traces
WHERE Timestamp > now() - INTERVAL ${MIN} MINUTE AND SpanKind = 'Server'
  AND toUInt16OrZero(SpanAttributes['http.response.status_code']) >= 500 GROUP BY ALL ORDER BY 1, 2"
echo; echo "== (d) métrica http.server.request.duration — contagem de 5xx (delta na janela, por réplica somada)"
clickhouse_query "SELECT ServiceName, Attributes['http.request.method'] AS method, Attributes['http.route'] AS route, Attributes['http.response.status_code'] AS status,
  sum(c) AS requests FROM (
    SELECT ServiceName, Attributes, ResourceAttributes['k8s.pod.name'] AS pod, max(Count) - min(Count) AS c
    FROM otel_metrics_histogram WHERE MetricName = 'http.server.request.duration' AND TimeUnix > now() - INTERVAL ${MIN} MINUTE
      AND toUInt16OrZero(Attributes['http.response.status_code']) >= 500 GROUP BY ServiceName, Attributes, pod)
GROUP BY ALL ORDER BY 1, 3"
echo; echo "== (e) Falhas SEM log ERROR: requisições 5xx na BFF cuja Orders API não registrou ERROR"
clickhouse_query "SELECT count() FROM otel_traces b WHERE b.Timestamp > now() - INTERVAL ${MIN} MINUTE AND b.ServiceName = 'bff-api'
  AND b.SpanKind = 'Server' AND toUInt16OrZero(b.SpanAttributes['http.response.status_code']) >= 500
  AND b.TraceId NOT IN (SELECT TraceId FROM otel_logs WHERE Timestamp > now() - INTERVAL ${MIN} MINUTE AND ServiceName = 'orders-api' AND LogAttributes['level'] = 'ERROR')"
