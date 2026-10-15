# Consultas HyperDX e ClickHouse

Consultas prontas para investigar o workshop no **ClickStack** (HyperDX + ClickHouse).
Todas as consultas SQL estão em [`queries.sql`](queries.sql) (identificadas como `[Q01]`…`[Q22]`)
e foram executadas com sucesso contra dados reais das três APIs, no ClickStack 2.39.1.

> As consultas `k8s.*` (Q17, Q19, Q20, Q21) dependem dos coletores `otel-agent`/`otel-gateway`
> no EKS. Localmente, só a sintaxe delas foi validada (retornam 0 linhas).

## 1. Acesso

### HyperDX (UI)

```bash
kubectl -n observability port-forward svc/clickstack-app 3000:3000
# abrir http://localhost:3000 — usuário/senha em .workshop/hyperdx-credentials.json (fornecidos pelo instrutor)
```

- **Search**: escolha a source `Logs` ou `Traces`, digite o filtro Lucene e ajuste o intervalo de tempo.
- **Chart Explorer / Dashboards**: escolha a source `Metrics` e selecione a métrica, a agregação e o `group by`.
- Ao clicar em um log com `TraceId`, a aba **Trace** abre a transação distribuída completa.

### SQL direto no ClickHouse

```bash
source scripts/lib/common.sh && source scripts/lib/cluster-helpers.sh
clickhouse_query "SELECT ServiceName, count() FROM otel_logs WHERE Timestamp > now() - INTERVAL 5 MINUTE GROUP BY 1"

# ou manualmente:
POD=$(kubectl -n observability get pods -o name | grep -m1 clickhouse-clickhouse | cut -d/ -f2)
kubectl -n observability exec -it "$POD" -- clickhouse-client --user app --password hyperdx
```

O usuário `app` é somente leitura. Sua senha padrão (`hyperdx`) vem do chart.

## 2. Modelo de dados (ClickStack)

| Tabela | Colunas principais |
|---|---|
| `otel_logs` | `Timestamp`, `ServiceName`, `SeverityText` (**minúsculas**: `error`, `warn`, `info`), `Body`, `LogAttributes` (Map), `ResourceAttributes` (Map), `TraceId`, `SpanId` |
| `otel_traces` | `Timestamp`, `TraceId`, `SpanId`, `ParentSpanId`, `ServiceName`, `SpanName`, `SpanKind` (`Server`/`Client`/`Internal`), `Duration` (**nanossegundos**), `StatusCode` (`Ok`/`Error`/`Unset`), `SpanAttributes` (Map) |
| `otel_metrics_gauge` / `otel_metrics_sum` | `MetricName`, `Attributes`, `ResourceAttributes`, `TimeUnix`, `Value` |
| `otel_metrics_histogram` | `MetricName`, `Attributes`, `ResourceAttributes`, `TimeUnix`, `Count`, `Sum`, `BucketCounts`, `ExplicitBounds` |

Atributos úteis emitidos pelas APIs:

- **Logs** (`LogAttributes`): `level` (`INFO`/`WARN`/`ERROR` — maiúsculas, controlado pelas APIs), `request_id`, `http.route`, `http.request.method`, `http.response.status_code`, `duration_ms`, `idempotency.key`, `order.id`, `circuit_breaker.from/to`.
- **Spans/métricas** (`ResourceAttributes`): `k8s.pod.name`, `k8s.namespace.name`, `k8s.node.name`, `k8s.deployment.name`.
- As métricas `Sum` (contadores) são **cumulativas por réplica**. Para obter o total de uma janela, calcule `max(Value) - min(Value)` por Pod e depois some os Pods (é o padrão usado em `queries.sql`).

**Sintaxe Lucene no HyperDX:**

- Chaves de Map usam ponto: `LogAttributes.http.route:"/orders"`.
- Aspas significam correspondência exata. Sem aspas, a busca é por "contém" e não diferencia maiúsculas de minúsculas.
- Comparação numérica: `LogAttributes.http.response.status_code:>499`.
- Negação: `-campo:valor`. Combinação: `AND` / `OR` e parênteses.

## 3. Consultas por tema

### HTTP Requests by Route

- **Lucene (Traces):** `SpanKind:"Server" ServiceName:"orders-api"`, com group by `SpanAttributes.http.route`.
- **Métrica (Chart Explorer):** `http.server.request.duration` (histogram), agregação `count`, group by `http.route` e `http.response.status_code`.
- **SQL:** Q01 (spans) e Q02 (métrica não amostrada).

### HTTP Error Rate

- **Lucene (Traces):** `SpanKind:"Server" SpanAttributes.http.response.status_code:>499`.
- **Lucene (Logs, anti-pattern dos alertas):** `LogAttributes.level:"ERROR" LogAttributes.http.response.status_code:>499`.
- **SQL:** Q03 (taxa de erro 5xx por minuto e rota).

### Latência p99

- **Via spans:** Q04 calcula `quantile(0.99)(Duration) / 1e6` em `otel_traces` com `SpanKind = 'Server'` (em ms).
- **Via histograma:** Q05 soma os `BucketCounts` do último ponto cumulativo de cada série e encontra o bucket do p99. O resultado tem a precisão dos buckets: é o limite superior do bucket, em ms.
- **HyperDX:** métrica `http.server.request.duration`, agregação `p99`, group by `http.route`.

### Orders Created

- **Métrica:** `orders.created` (Sum), total via Q06.
- **Falhas por motivo:** `orders.failed` (atributo `reason`), via Q07.
- **Lucene (Logs):** `ServiceName:"orders-api" Body:"Pedido CONFIRMED"`.

### Inventory Failures

- **Métrica:** `inventory.reservations.failed` por `reason` (Q08). Os 503 injetados acontecem **antes** da lógica de reserva, então aparecem em `inventory.faults.injected` e nos logs, não nessa métrica.
- **Lucene (Logs):** `ServiceName:"inventory-api" LogAttributes.level:"ERROR"`.
- **SQL:** Q09 (WARN/ERROR por rota e mensagem).

### Circuit Breaker State

- **Gauge:** `circuit_breaker.state` (0=CLOSED, 1=HALF_OPEN, 2=OPEN), um valor por réplica (Q10).
- **Transições:** logs `Body:"Circuit breaker transition"` (Q11), ou a métrica `circuit_breaker.transitions` com `from_state` e `to_state`.
- **Rejeições e retries:** `circuit_breaker.rejected_requests` e `inventory.retry.attempts` (Q12).
- **Lucene (Traces):** `SpanName:"Inventory reserve"`. Os eventos `retry`, `attempt.failed` e `circuit_breaker.open` aparecem no span.

### Distributed Transactions

- **Lucene (Traces):** `ServiceName:"orders-api" SpanName:"Complete Order"`. Clique em um resultado para ver o trace completo.
- **Trace esperado:**

  ```text
  POST /orders (bff-api)
   └── POST /orders (orders-api)
        ├── Idempotency Claim ── DynamoDB.PutItem
        ├── Validate Order
        ├── Check Inventory ── GET /inventory/{sku} (inventory-api)
        ├── Reserve Inventory ── POST /inventory/reservations (inventory-api) ── Reserve Stock
        ├── DynamoDB.UpdateItem (reservation_state=RESERVED)
        └── Complete Order ── DynamoDB.TransactWriteItems
  ```

- **SQL:** Q13 lista os traces recentes com o número de serviços e spans. Q14 mostra os spans de um `TraceId`.
- **Correlacionar tentativas de um mesmo pedido** (mesma Idempotency-Key):
  - Lucene: `ServiceName:"orders-api" LogAttributes.idempotency.key:"<uuid>"`.
  - SQL: Q15.
  - Métricas de idempotência: Q16.

### Kubernetes CPU e Memory

- **Métricas** (kubeletstats via `otel-agent`): `k8s.pod.cpu.usage` (cores), `k8s.pod.memory.working_set` (bytes), `k8s.pod.cpu_limit_utilization`, `k8s.pod.cpu_request_utilization`, `k8s.container.memory_limit_utilization`.
- **SQL:** Q17.
- **CPU throttling:** a métrica `container.cpu.throttled_time`, emitida pelas próprias APIs a partir do `cpu.stat` do cgroup v2 (Q18).

### Pod Restarts

- **Métrica** `k8s.container.restarts` (receiver `k8s_cluster`, no `otel-gateway`). Q19 mostra os containers com restart.
- **Lucene (Logs, eventos):** `Body:"BackOff"` ou `Body:"OOMKill"`.

### Pending Pods

- **Métrica** `k8s.pod.phase`: valor `1` = Pending (2=Running, 3=Succeeded, 4=Failed, 5=Unknown).
- **SQL:** Q20 conta os Pods Pending por namespace e minuto.
- **HyperDX:** métrica `k8s.pod.phase`, filtro `Value = 1`, agregação `count distinct` de `k8s.pod.name`.

### Eventos Kubernetes

O preset `kubernetesEvents` do `otel-gateway` usa o receiver `k8sobjects`, que envia os eventos para `otel_logs`.

- **Lucene (Logs):** `Body:"Preempted"`, `Body:"FailedScheduling"`, `Body:"OOMKilling"`, `Body:"TriggeredScaleUp"` ou `Body:"Evicted"`.
- **SQL:** Q21.
- **Logs do Cluster Autoscaler** (coletados pelo filelog do `otel-agent`): `ResourceAttributes.k8s.namespace.name:"kube-system" "scale-up"`.

### Anti-pattern dos alertas (LAB 05)

- **Q22** compara `count()` com `uniqExact(request_id)` para os logs ERROR com status 5xx. Na validação local, POST /orders da Orders API teve 678 logs ERROR para 339 requisições com falha (2×).
- O script `labs/lab-05/compare-counts.sh` executa a comparação completa: logs, requisições distintas, spans e métricas.
