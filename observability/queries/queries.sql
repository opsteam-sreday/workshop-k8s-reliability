-- ============================================================================
-- Consultas SQL (ClickHouse / ClickStack) do workshop.
-- Executar: source scripts/lib/cluster-helpers.sh; clickhouse_query "<SQL>"
-- Tabelas: otel_logs, otel_traces, otel_metrics_gauge, otel_metrics_sum, otel_metrics_histogram
-- Janela padrão: últimos 15 minutos (ajuste o INTERVAL).
-- ============================================================================

-- [Q01] HTTP Requests by Route (spans HTTP SERVER)
SELECT ServiceName, SpanAttributes['http.request.method'] AS method, SpanAttributes['http.route'] AS route,
       SpanAttributes['http.response.status_code'] AS status, count() AS requests
FROM otel_traces
WHERE Timestamp > now() - INTERVAL 15 MINUTE AND SpanKind = 'Server'
GROUP BY ALL ORDER BY ServiceName, route, status;

-- [Q02] HTTP Requests by Route (métrica http.server.request.duration — contador não amostrado)
-- Count é cumulativo por réplica: delta = max - min por (pod, atributos).
SELECT ServiceName, Attributes['http.request.method'] AS method, Attributes['http.route'] AS route,
       Attributes['http.response.status_code'] AS status, sum(c) AS requests
FROM (
  SELECT ServiceName, Attributes, ResourceAttributes['k8s.pod.name'] AS pod, max(Count) - min(Count) AS c
  FROM otel_metrics_histogram
  WHERE MetricName = 'http.server.request.duration' AND TimeUnix > now() - INTERVAL 15 MINUTE
  GROUP BY ServiceName, Attributes, pod)
GROUP BY ALL ORDER BY ServiceName, route, status;

-- [Q03] HTTP Error Rate por serviço/rota (spans, 5xx / total), em janelas de 1 minuto
SELECT toStartOfMinute(Timestamp) AS minute, ServiceName, SpanAttributes['http.route'] AS route,
       countIf(toUInt16OrZero(SpanAttributes['http.response.status_code']) >= 500) AS errors_5xx,
       count() AS total, round(errors_5xx / total * 100, 2) AS error_rate_pct
FROM otel_traces
WHERE Timestamp > now() - INTERVAL 15 MINUTE AND SpanKind = 'Server'
GROUP BY ALL ORDER BY minute, ServiceName, route;

-- [Q04] Latência p50/p95/p99 (ms) a partir dos spans HTTP SERVER (Duration em nanossegundos)
SELECT ServiceName, SpanName,
       round(quantile(0.50)(Duration) / 1e6, 1) AS p50_ms,
       round(quantile(0.95)(Duration) / 1e6, 1) AS p95_ms,
       round(quantile(0.99)(Duration) / 1e6, 1) AS p99_ms,
       count() AS requests
FROM otel_traces
WHERE Timestamp > now() - INTERVAL 15 MINUTE AND SpanKind = 'Server'
GROUP BY ALL ORDER BY ServiceName, SpanName;

-- [Q05] Latência p99 (ms) a partir do HISTOGRAMA http.server.request.duration (segundos)
-- Usa o último ponto cumulativo de cada série (pod+atributos) e soma os buckets entre réplicas.
-- Resultado = limite superior do bucket onde o p99 cai (precisão limitada aos buckets).
WITH series AS (
  SELECT ServiceName, Attributes['http.route'] AS route, ResourceAttributes['k8s.pod.name'] AS pod,
         argMax(BucketCounts, TimeUnix) AS buckets, argMax(ExplicitBounds, TimeUnix) AS bounds
  FROM otel_metrics_histogram
  WHERE MetricName = 'http.server.request.duration' AND TimeUnix > now() - INTERVAL 15 MINUTE
  GROUP BY ServiceName, Attributes, pod
),
agg AS (
  SELECT ServiceName, route, sumForEach(buckets) AS b, any(bounds) AS bounds
  FROM series GROUP BY ServiceName, route
)
SELECT ServiceName, route, arraySum(b) AS requests,
       arrayFirstIndex(x -> x >= 0.99 * arraySum(b), arrayCumSum(b)) AS idx,
       if(idx <= length(bounds), round(bounds[idx] * 1000, 1), NULL) AS p99_le_ms
FROM agg ORDER BY ServiceName, route;

-- [Q06] Orders Created (contador orders.created, delta na janela por réplica)
SELECT ServiceName, sum(d) AS orders_created FROM (
  SELECT ServiceName, ResourceAttributes['k8s.pod.name'] AS pod, max(Value) - min(Value) AS d
  FROM otel_metrics_sum
  WHERE MetricName = 'orders.created' AND TimeUnix > now() - INTERVAL 15 MINUTE
  GROUP BY ServiceName, pod)
GROUP BY ServiceName;

-- [Q07] Orders Failed por motivo (orders.failed, atributo reason)
SELECT Attributes['reason'] AS reason, sum(d) AS failures FROM (
  SELECT Attributes, ResourceAttributes['k8s.pod.name'] AS pod, max(Value) - min(Value) AS d
  FROM otel_metrics_sum
  WHERE MetricName = 'orders.failed' AND TimeUnix > now() - INTERVAL 15 MINUTE
  GROUP BY Attributes, pod)
GROUP BY reason ORDER BY failures DESC;

-- [Q08] Inventory Failures — métrica inventory.reservations.failed por reason
SELECT Attributes['reason'] AS reason, sum(d) AS failures FROM (
  SELECT Attributes, ResourceAttributes['k8s.pod.name'] AS pod, max(Value) - min(Value) AS d
  FROM otel_metrics_sum
  WHERE MetricName = 'inventory.reservations.failed' AND TimeUnix > now() - INTERVAL 15 MINUTE
  GROUP BY Attributes, pod)
GROUP BY reason ORDER BY failures DESC;

-- [Q09] Inventory Failures — logs WARN/ERROR da Inventory API por rota e mensagem
SELECT LogAttributes['http.route'] AS route, LogAttributes['level'] AS level, Body, count() AS logs
FROM otel_logs
WHERE Timestamp > now() - INTERVAL 15 MINUTE AND ServiceName = 'inventory-api'
  AND LogAttributes['level'] IN ('WARN', 'ERROR')
GROUP BY ALL ORDER BY logs DESC LIMIT 20;

-- [Q10] Circuit Breaker State (gauge: 0=CLOSED, 1=HALF_OPEN, 2=OPEN) por réplica, último valor por minuto
SELECT toStartOfMinute(TimeUnix) AS minute, ResourceAttributes['k8s.pod.name'] AS pod,
       ResourceAttributes['service.instance.id'] AS instance,
       argMax(Value, TimeUnix) AS state
FROM otel_metrics_gauge
WHERE MetricName = 'circuit_breaker.state' AND TimeUnix > now() - INTERVAL 15 MINUTE
GROUP BY ALL ORDER BY minute, pod;

-- [Q11] Circuit Breaker — transições registradas em log
SELECT Timestamp, ResourceAttributes['k8s.pod.name'] AS pod,
       LogAttributes['circuit_breaker.from'] AS from_state, LogAttributes['circuit_breaker.to'] AS to_state
FROM otel_logs
WHERE Timestamp > now() - INTERVAL 15 MINUTE AND ServiceName = 'orders-api' AND Body = 'Circuit breaker transition'
ORDER BY Timestamp DESC LIMIT 50;

-- [Q12] Circuit Breaker — rejeições (fail fast) e retries
SELECT MetricName, sum(d) AS total FROM (
  SELECT MetricName, Attributes, ResourceAttributes['k8s.pod.name'] AS pod, max(Value) - min(Value) AS d
  FROM otel_metrics_sum
  WHERE MetricName IN ('circuit_breaker.rejected_requests', 'circuit_breaker.transitions', 'inventory.retry.attempts')
    AND TimeUnix > now() - INTERVAL 15 MINUTE
  GROUP BY MetricName, Attributes, pod)
GROUP BY MetricName;

-- [Q13] Distributed Transactions — últimos pedidos com trace completo (BFF → Orders → Inventory)
SELECT TraceId, min(Timestamp) AS started, uniqExact(ServiceName) AS services, count() AS spans,
       round(max(Duration) / 1e6, 1) AS root_ms
FROM otel_traces
WHERE Timestamp > now() - INTERVAL 15 MINUTE
  AND TraceId IN (SELECT TraceId FROM otel_traces WHERE Timestamp > now() - INTERVAL 15 MINUTE
                  AND ServiceName = 'orders-api' AND SpanName = 'Complete Order')
GROUP BY TraceId ORDER BY started DESC LIMIT 10;

-- [Q14] Distributed Transactions — spans de UM trace (substitua o TraceId)
SELECT ServiceName, SpanKind, SpanName, round(Duration / 1e6, 1) AS ms, StatusCode
FROM otel_traces WHERE TraceId = '<trace_id>' ORDER BY Timestamp;

-- [Q15] Correlação de tentativas por Idempotency-Key (logs da Orders API)
SELECT Timestamp, TraceId, LogAttributes['request_id'] AS request_id, Body,
       LogAttributes['idempotency.status'] AS idem_status, LogAttributes['idempotency.version'] AS version
FROM otel_logs
WHERE Timestamp > now() - INTERVAL 60 MINUTE AND ServiceName = 'orders-api'
  AND LogAttributes['idempotency.key'] = '<idempotency_key>'
ORDER BY Timestamp;

-- [Q16] Métricas de idempotência
SELECT MetricName, sum(d) AS total FROM (
  SELECT MetricName, Attributes, ResourceAttributes['k8s.pod.name'] AS pod, max(Value) - min(Value) AS d
  FROM otel_metrics_sum
  WHERE MetricName LIKE 'orders.idempotency.%' AND TimeUnix > now() - INTERVAL 15 MINUTE
  GROUP BY MetricName, Attributes, pod)
GROUP BY MetricName ORDER BY MetricName;

-- [Q17] Kubernetes CPU e Memory por Pod (kubeletstats via otel-agent)
SELECT toStartOfMinute(TimeUnix) AS minute, ResourceAttributes['k8s.pod.name'] AS pod,
       round(avgIf(Value, MetricName = 'k8s.pod.cpu.usage'), 3) AS cpu_cores,
       round(maxIf(Value, MetricName = 'k8s.pod.memory.working_set') / 1048576, 1) AS memory_mib,
       round(avgIf(Value, MetricName = 'k8s.pod.cpu_limit_utilization') * 100, 1) AS cpu_pct_of_limit,
       round(avgIf(Value, MetricName = 'k8s.pod.cpu_request_utilization') * 100, 1) AS cpu_pct_of_request
FROM otel_metrics_gauge
WHERE TimeUnix > now() - INTERVAL 15 MINUTE AND ResourceAttributes['k8s.namespace.name'] = 'ecommerce'
  AND MetricName IN ('k8s.pod.cpu.usage', 'k8s.pod.memory.working_set', 'k8s.pod.cpu_limit_utilization', 'k8s.pod.cpu_request_utilization')
GROUP BY ALL ORDER BY minute, pod;

-- [Q18] CPU throttling (cgroup v2, emitido pelas próprias APIs)
SELECT ServiceName, ResourceAttributes['k8s.pod.name'] AS pod,
       max(Value) - min(Value) AS throttled_seconds_in_window
FROM otel_metrics_sum
WHERE MetricName = 'container.cpu.throttled_time' AND TimeUnix > now() - INTERVAL 15 MINUTE
GROUP BY ALL ORDER BY throttled_seconds_in_window DESC;

-- [Q19] Pod Restarts (k8s_cluster: k8s.container.restarts, último valor)
SELECT ResourceAttributes['k8s.namespace.name'] AS ns, ResourceAttributes['k8s.pod.name'] AS pod,
       ResourceAttributes['k8s.container.name'] AS container, argMax(Value, TimeUnix) AS restarts
FROM otel_metrics_gauge
WHERE MetricName = 'k8s.container.restarts' AND TimeUnix > now() - INTERVAL 15 MINUTE
GROUP BY ALL HAVING restarts > 0 ORDER BY restarts DESC;

-- [Q20] Pending Pods (k8s_cluster: k8s.pod.phase — 1=Pending, 2=Running, 3=Succeeded, 4=Failed, 5=Unknown)
SELECT toStartOfMinute(TimeUnix) AS minute, ResourceAttributes['k8s.namespace.name'] AS ns,
       uniqExactIf(ResourceAttributes['k8s.pod.name'], Value = 1) AS pending_pods
FROM otel_metrics_gauge
WHERE MetricName = 'k8s.pod.phase' AND TimeUnix > now() - INTERVAL 15 MINUTE
GROUP BY ALL ORDER BY minute, ns;

-- [Q21] Eventos Kubernetes (k8sobjects → logs): Preempted, FailedScheduling, OOMKilling, TriggeredScaleUp...
SELECT Timestamp, Body FROM otel_logs
WHERE Timestamp > now() - INTERVAL 30 MINUTE
  AND (Body ILIKE '%Preempt%' OR Body ILIKE '%FailedScheduling%' OR Body ILIKE '%OOMKill%'
       OR Body ILIKE '%TriggeredScaleUp%' OR Body ILIKE '%Evicted%' OR Body ILIKE '%BackOff%')
ORDER BY Timestamp DESC LIMIT 50;

-- [Q22] Anti-pattern (LAB 05): COUNT(logs ERROR) vs requisições distintas por rota
SELECT ServiceName, LogAttributes['http.request.method'] AS method, LogAttributes['http.route'] AS route,
       count() AS error_logs, uniqExact(LogAttributes['request_id']) AS distinct_requests
FROM otel_logs
WHERE Timestamp > now() - INTERVAL 15 MINUTE AND LogAttributes['level'] = 'ERROR'
  AND toUInt16OrZero(LogAttributes['http.response.status_code']) >= 500
GROUP BY ALL ORDER BY ServiceName, route;
