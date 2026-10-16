# Guia do Aluno — Kubernetes: Reliability ou Chaos?

> **Kubernetes não cria resiliência automaticamente. Ele automatiza aquilo que configuramos — inclusive nossos erros.**

Todos os laboratórios seguem o mesmo ciclo:

**Break it → Observe it → Understand it → Fix it → Validate it**

## 1. Pré-requisitos

| Ferramenta | Uso |
|---|---|
| `kubectl` (≥ 1.34) | operar o cluster EKS |
| `aws` CLI v2 | consultar DynamoDB/IAM e atualizar o kubeconfig |
| `bash`, `python3`, `curl` | scripts do workshop |
| Navegador | HyperDX (UI do ClickStack) |

**Turma com um ambiente por aluno.** O instrutor envia o seu `STUDENT_ID` (ex.: `aluno07`) e um bloco para o
`~/.aws/config`. Você entra pelo SSO e assume a **sua** role, que só enxerga o seu cluster `rw-<id>`, a sua tabela
`rw-<id>-orders` e as suas credenciais do HyperDX:

```bash
aws sso login --profile workshop-sso
export AWS_PROFILE=workshop STUDENT_ID=aluno07       # use o seu ID
aws sts get-caller-identity                          # assumed-role/rw-aluno07-student/...
aws eks update-kubeconfig --name rw-$STUDENT_ID --region us-east-1
make hyperdx-credentials-pull                        # login do HyperDX do seu ambiente
kubectl get nodes -L workload                        # nós "apps" e "observability"
kubectl -n ecommerce get pods                        # bff-api, orders-api, inventory-api
```

Com `STUDENT_ID` exportado, os scripts e o `make` usam automaticamente os seus nomes (`CLUSTER_NAME=rw-<id>`,
`TABLE_NAME=rw-<id>-orders`, role `rw-<id>-orders-api`); sem ele, os scripts param pedindo o ID. Os nomes
derivados estão em `scripts/lib/common.sh`.

## 2. Arquitetura

```text
                          k6 Load Generator
                                  |
                                  v
                              BFF API
                                  |
                                  | HTTP/REST
                                  v
                             Orders API
                              /      \
                             /        \
                   HTTP/REST           AWS SDK
                           /            \
                          v              v
                    Inventory API     DynamoDB
                    Stock/Reserve      Orders
                          ^
                          |
                  Circuit Breaker
                  na Orders API


                  OBSERVABILITY PIPELINE

             BFF API ──────────────┐
             Orders API ───────────┼── OTLP
             Inventory API ────────┘     |
                                        v
                               OTel Collector
                                        |
                                        v
                                    ClickStack
                              ClickHouse + HyperDX
```

| Componente | Namespace / nó | Observação |
|---|---|---|
| BFF API (2 réplicas) | `ecommerce` / apps | PriorityClass `critical-services`. Sem acesso AWS |
| Orders API (2–12 réplicas, HPA) | `ecommerce` / apps | `critical-services`. **Única** com acesso ao DynamoDB (Pod Identity) |
| Inventory API (1 réplica) | `ecommerce` / apps | Estado **em memória**. Perfil Burstable por padrão |
| ClickStack, OTel gateway, Cluster Autoscaler, k6 | `observability` / `loadtest` / nó observability | Isolados dos experimentos por taint |

**Modo STRICT:** um pedido só fica `CONFIRMED` depois de duas etapas bem-sucedidas: a reserva de estoque e a gravação atômica no DynamoDB. Se a Inventory API cai, **nenhum pedido é criado**.

## 3. Conceitos-chave por pilar

| Pilar | O que lembrar |
|---|---|
| **QoS** | A QoSClass é derivada de requests/limits. **Guaranteed**: requests = limits em todos os recursos. **Burstable**: algum request definido. **BestEffort**: nada definido. Define **quem sofre primeiro** sob pressão do nó (eviction/OOM) |
| **CPU throttling × OOMKilled × Eviction** | Throttling: o limite de CPU (CFS quota) desacelera o processo, sem matá-lo. OOMKilled: o limite de memória é excedido e o kernel mata o container, que reinicia. Eviction: o kubelet remove Pods quando o **nó** está sob pressão (memória ou disco) |
| **PriorityClass** | Define **quem é agendado primeiro** e **quem pode ser removido** (preemption) quando falta capacidade. Não tem relação com QoS: um Pod Guaranteed de baixa prioridade também é preemptado |
| **HPA** | Utilização = uso real ÷ `requests.cpu`. Sem requests, o HPA não funciona. Usa `behavior` (scaleUp/scaleDown) e `stabilizationWindowSeconds` |
| **Cluster Autoscaler** | Reage a **Pods Pending** (FailedScheduling) adicionando nós. HPA escala Pods; CA escala nós. Os dois têm latências bem diferentes (segundos × minutos) |
| **Circuit Breaker** | CLOSED → OPEN após 5 falhas consecutivas. Em OPEN, rejeita na hora por 15 s e depois passa a HALF_OPEN, que permite 2 chamadas de teste e volta a CLOSED se ambas tiverem sucesso. O estado é **local a cada réplica** |
| **Retry** | Somente a Orders API faz retry: no máximo 2, com backoff exponencial + jitter e orçamento total de 2 s. O retry para quando o circuito abre (evita retry amplification) |
| **Idempotência** | `Idempotency-Key` (UUID) + hash canônico do payload + registro no DynamoDB com lease e fencing. Retries **nunca** duplicam pedido nem reserva |
| **Pod Identity** | A ServiceAccount `orders-api-sa` está associada à IAM Role `rw-<id>-orders-api`. As outras SAs não têm credenciais e o IMDS do nó é bloqueado (hop limit 1 + NetworkPolicy) |
| **Observabilidade** | OpenTelemetry nas três APIs envia métricas, logs e traces via OTLP. No ClickStack, tudo é consultado no HyperDX. Um trace conecta BFF → Orders → Inventory → DynamoDB |

## 4. Contrato da API (`POST /orders`)

```bash
curl -s -X POST localhost:8080/orders \
  -H 'Content-Type: application/json' \
  -H "Idempotency-Key: $(uuidgen | tr A-Z a-z)" \
  -d '{"customer_id":"customer-123","items":[{"sku":"product-001","quantity":2,"unit_price":"49.90"}]}'
```

| Situação | HTTP | `error` |
|---|---|---|
| Primeira criação bem-sucedida | 201 | — (`Idempotency-Replayed: false`) |
| Retry após sucesso | 201 | — (mesmo corpo, `Idempotency-Replayed: true`) |
| Operação em andamento | 409 | `ORDER_IN_PROGRESS` + `Retry-After` |
| Mesma chave com payload diferente | 409 | `IDEMPOTENCY_KEY_REUSED` |
| Idempotency-Key ausente ou inválida | 400 | `INVALID_IDEMPOTENCY_KEY` |
| Estoque insuficiente (ex.: `product-limited`) | 409 | `INSUFFICIENT_STOCK` |
| Dependência temporariamente indisponível | 503 | `DEPENDENCY_UNAVAILABLE` + `Retry-After` |
| BFF não recebeu resposta a tempo | 504 | `UPSTREAM_TIMEOUT` (repita com a **mesma** chave) |

| Header | Direção | Significado |
|---|---|---|
| `Idempotency-Key` | requisição | UUID que identifica a **intenção**. Retenção lógica de 24h |
| `Idempotency-Replayed` | resposta | `true` quando a resposta é o resultado já persistido |
| `Retry-After` | resposta | segundos até a próxima tentativa (409 em andamento / 503) |
| `X-Request-ID` | ambos | correlation ID de cada tentativa, presente em todos os logs |
| `X-Customer-ID` | requisição | identidade **simulada** do cliente autenticado. Se informado, deve coincidir com `customer_id` |

Outras rotas:

- `GET /orders?customer_id=...&limit=20&next_token=...` (paginação via Query no GSI1)
- `GET /orders/{order_id}`
- `GET /health/live`, `/health/ready` e `/health/startup`

SKUs disponíveis: `product-001` a `product-010`, com estoque alto, e `product-limited`, com estoque 5.

## 5. Cheat-sheet

```bash
# Acesso local à BFF e ao HyperDX
kubectl -n ecommerce port-forward svc/bff-api 8080:8080
kubectl -n observability port-forward svc/clickstack-app 3000:3000      # http://localhost:3000

# Carga (Job k6 dentro do cluster)
scripts/k6.sh create-orders.js RATE=5 DURATION=2m
scripts/k6.sh get-orders.js VUS=10 DURATION=1m
scripts/k6.sh stress-orders.js RATE=60 DURATION=6m
scripts/k6.sh inventory-errors.js RATE=5 DURATION=3m
scripts/k6.sh idempotency-concurrency.js CONCURRENCY=20

# Injeção de falhas (API admin em 127.0.0.1, via kubectl exec)
scripts/fault.sh inventory latency 800 RESERVATIONS
scripts/fault.sh inventory http-503 [ALL|RESERVATIONS|QUERIES]
scripts/fault.sh inventory error-rate 0.5
scripts/fault.sh inventory cpu-burn 2          # 2 processos consumindo 1 core cada
scripts/fault.sh inventory memory 700          # memory ballast (MB)
scripts/fault.sh orders db FAIL_READS
scripts/fault.sh orders cb                     # estado do Circuit Breaker por réplica
scripts/fault.sh all reset

# Observação
kubectl -n ecommerce get hpa,pods -o wide
kubectl get events -A --sort-by=.lastTimestamp | tail -20
kubectl -n ecommerce top pods
labs/lab-04/watch-cb.sh

# Reset entre laboratórios
scripts/reset.sh
```

## 6. Usando o HyperDX

1. Abra `http://localhost:3000`, usando o port-forward acima. Faça login com as credenciais fornecidas pelo instrutor.
2. Em **Search**, escolha a source **Logs** ou **Traces** e defina o intervalo de tempo (ex.: *Last 15 minutes*).
3. Exemplos de filtros Lucene:
   - `ServiceName:"orders-api" LogAttributes.level:"ERROR"`
   - `LogAttributes.http.route:"/orders" LogAttributes.http.response.status_code:>499`
   - `LogAttributes.idempotency.key:"<uuid>"`: todas as tentativas de um pedido.
   - `SpanName:"Complete Order"` na source Traces. Clique em um resultado para ver o trace completo.
   - `Body:"Circuit breaker transition"`
4. Para métricas, use **Chart Explorer** com a source **Metrics**:
   - `http.server.request.duration` (p99 por `http.route`)
   - `orders.created`
   - `circuit_breaker.state`
   - `k8s.pod.cpu.usage`
5. Consultas prontas: [`observability/queries/README.md`](../observability/queries/README.md).

## 7. Laboratórios (nesta ordem)

1. [LAB 01 — First Successful Order](../labs/lab-01/README.md): pedido, reserva, DynamoDB, Pod Identity, trace e idempotência.
2. [LAB 02 — CPU Stress & Autoscaling](../labs/lab-02/README.md): HPA, Pods Pending e Cluster Autoscaler.
3. [LAB 03 — QoS & PriorityClass](../labs/lab-03/README.md): throttling, OOMKilled, eviction e preemption.
4. [LAB 04 — Circuit Breaker](../labs/lab-04/README.md): timeout, retry, OPEN, HALF_OPEN e CLOSED.
5. [LAB 05 — ClickStack Alerting](../labs/lab-05/README.md): quatro alertas e o anti-pattern de contagem de logs.
6. [LAB 06 — Probes, Graceful Shutdown & Topology Spread](../labs/lab-06/README.md): readiness × liveness × startup, rollout sem erro, deploy quebrado e drain de nó.

Execute `scripts/reset.sh` ao terminar cada laboratório.

## 8. Glossário

| Termo | Definição |
|---|---|
| **Bulkhead** | Limite de chamadas simultâneas a uma dependência. Isola a falha e evita filas ilimitadas |
| **Compensação** | Desfazer um efeito já aplicado (ex.: liberar uma reserva) quando um passo posterior falha |
| **Fencing token** | Versão crescente que impede um executor antigo de sobrescrever o trabalho de um mais novo |
| **Lease** | "Posse" temporária de uma operação IN_PROGRESS. Se expirar, outro executor pode assumir |
| **Preemption** | O scheduler remove Pods de menor prioridade para agendar um de maior prioridade |
| **Eviction** | O kubelet remove Pods por pressão de recursos no nó |
| **Retry amplification** | Retries em várias camadas multiplicam a carga sobre uma dependência já degradada |
| **Fail fast** | Rejeitar imediatamente em vez de esperar o timeout (circuito OPEN) |
| **Pod Identity** | Mecanismo do EKS que entrega credenciais IAM a uma ServiceAccount específica |
| **IMDS** | Instance Metadata Service do EC2 (`169.254.169.254`). Bloqueado para os Pods |
| **OTLP** | Protocolo do OpenTelemetry para enviar métricas, logs e traces |
| **Trace / Span** | Uma transação distribuída e cada operação que a compõe |
| **QoSClass** | Guaranteed, Burstable ou BestEffort, derivada de requests/limits |
