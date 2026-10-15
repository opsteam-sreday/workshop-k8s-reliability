# IMPLEMENTATION_PROGRESS — MVP

Status em **2026-10-14**. Regra seguida: só aparece como **validado** o que foi executado e teve o
resultado observado. Itens apenas implementados ou documentados aparecem como tal.

- **Ambiente real:** Amazon EKS 1.36 (`us-east-1`), node groups `apps` (2–5 × m6i.large) e
  `observability` (1 × m6i.xlarge), provisionado com `scripts/setup.sh` e removido com `scripts/teardown.sh`.
- **Ambiente local:** Python 3.12, DynamoDB Local (Docker) e ClickStack all-in-one 2.39.1 (Docker).
- **Relatório automático do EKS:** [`evidence/eks-validation-report.md`](evidence/eks-validation-report.md).
- **Evidências do LAB 02:** [`evidence/lab-02-hpa-cluster-autoscaler.txt`](evidence/lab-02-hpa-cluster-autoscaler.txt).

## Critérios de aceitação (seção 21)

| # | Critério | Status | Evidência |
|---|---|---|---|
| 1 | EKS provisionado | ✅ Validado (EKS) | `ACTIVE 1.36`; `setup.sh` concluiu em ~37 min na primeira execução |
| 2 | Managed Node Group operacional | ✅ Validado (EKS) | `apps=ACTIVE observability=ACTIVE nodes_ready=3` |
| 3 | Metrics Server funcionando | ✅ Validado (EKS) | `kubectl top nodes` OK; o HPA leu a CPU (`cpu: 250%/60%`) |
| 4 | Cluster Autoscaler funcionando | ✅ Validado (EKS) | imagem `cluster-autoscaler:v1.36.1`; scale-up e scale-down observados (item 16) |
| 5 | Três APIs Ready | ✅ Validado (EKS) | `bff-api=2/2 orders-api=2/2 inventory-api=1/1` |
| 6 | Pedido criado pela BFF | ✅ Validado (EKS) | `HTTP 201 replayed=false status=CONFIRMED` |
| 7 | Reserva de estoque funcionando | ✅ Validado (EKS + local) | `reservations_total` incrementado; 8 testes unitários da Inventory |
| 8 | Pedido persistido no DynamoDB | ✅ Validado (EKS) | `aws dynamodb get-item ORDER#<id>` → `CONFIRMED` |
| 9 | Pedido consultável | ✅ Validado (EKS) | `GET /orders/{id}` 200; `get-orders.js`: 1344 requisições, 0% de falha, p95 = 14 ms |
| 10 | Idempotência validada sob concorrência | ✅ Validado (EKS + local) | k6 `idempotency-concurrency.js` no cluster: 1 × 201, 19 × 409 `ORDER_IN_PROGRESS`, exatamente 1 pedido; teste de integração `test_02` |
| 11 | Retry não duplica pedido | ✅ Validado (EKS + local) | replay com a mesma chave → mesmo `order_id`, `Idempotency-Replayed: true`; testes `test_01_08`, `test_04` |
| 12 | Retry não duplica reserva | ✅ Validado (EKS + local) | EKS: timeout após reserva (`SLOW_AFTER_COMMIT`) → 503 com `reservation_state=UNKNOWN`, estoque −2; o retry deu 201 e o estoque continuou −2 (1 pedido); testes `test_05`, `test_06`, `test_07` |
| 13 | EKS Pod Identity validado | ✅ Validado (EKS) | `assumed-role/eks-orders-api-role/...`; GetItem/Query permitidos; Scan, DescribeTable, DeleteItem e ListTables negados (`AccessDeniedException`) |
| 14 | BFF e Inventory sem acesso ao DynamoDB | ✅ Validado (EKS) | `bff-api-sa` e `inventory-api-sa`: `NoCredentials`; IMDS bloqueado; Pod avulso com `orders-api-sa` negado pela VAP; `kubectl debug` negado |
| 15 | HPA demonstrando scale-out | ✅ Validado (EKS) | 2 → 6 → 12 réplicas em ~60 s (`SuccessfulRescale`); scale-down 12 → 2 após a janela de 120 s |
| 16 | Cluster Autoscaler demonstrando node scale-out | ✅ Validado (EKS) | `FailedScheduling: Insufficient cpu` → `TriggeredScaleUp 2->3 (max: 5)` → nó criado ~25 s depois; nó removido ~3 min após o fim da carga |
| 17 | QoS verificável | ✅ Validado (EKS) | `BestEffort`, `Burstable` e `Guaranteed` via `labs/lab-03/qos.sh`; throttling: `cpu.max 50000 100000`, `nr_throttled` 24 → 250 em 20 s; OOMKilled: exit 137, restart 1 e estado em memória perdido |
| 18 | Preemption reproduzível | ✅ Validado (EKS) | `inventory-api … Preempted by pod … on node …`; Inventory `Pending`; 82% das requisições falharam (990/1201); recuperação em 85 s após a correção (prioridade + CA) |
| 19 | Circuit Breaker CLOSED, OPEN e HALF_OPEN | ✅ Validado (EKS + local) | logs `HALF_OPEN -> OPEN`, `OPEN -> HALF_OPEN` (+15 s), `HALF_OPEN -> CLOSED`; fail-fast `reason=circuit_open`; teste de integração do ciclo completo |
| 20 | Métricas HTTP disponíveis no ClickStack | ✅ Validado (EKS + local) | `http.server.request.duration` com método, rota e status em `otel_metrics_histogram` |
| 21 | Logs por request disponíveis | ✅ Validado (EKS + local) | log `HTTP request completed` com `trace_id`/`span_id` reais, `request_id`, rota e status, correlacionado pelo teste `test_10` |
| 22 | Traces distribuídos completos | ✅ Validado (EKS + local) | um trace com 3 serviços (BFF → Orders → Inventory) e os spans Idempotency Claim, Validate Order, Check/Reserve Inventory, DynamoDB.\*, Complete Order |
| 23 | Quatro alertas implementados e testados | ✅ Validado (EKS + local) | os 4 em `ALERT` e entregues ao webhook (EKS 16:50: Orders Creation 1748, Orders Query 850, Inventory Creation 54, Inventory Query 84); resolução `OK` observada |
| 24 | Scripts k6 executáveis | ✅ Validado (EKS) | os 5 scripts rodaram no cluster via `scripts/k6.sh` (create, get, stress, inventory-errors, idempotency-concurrency) |
| 25 | Cinco laboratórios documentados | ✅ Documentado | `labs/lab-01..05/README.md` com as 13 seções; os comandos centrais de cada lab foram executados no EKS (itens 6–23) |
| 26 | Teardown completo | ✅ Validado (EKS) | `scripts/teardown.sh` → `TEARDOWN EXIT 0`, "Nenhum volume EBS remanescente", "Nenhuma stack CloudFormation remanescente"; verificação independente: 0 clusters, tabelas, roles, repositórios ECR, instâncias e NAT Gateways do workshop |

## Testes automatizados (locais)

```text
scripts/test.sh
==> unit: orders-api      32 passed
==> unit: inventory-api    8 passed
==> unit: bff-api          6 passed
==> integração            11 passed   (DynamoDB Local + 3 APIs em processos reais)
```

A integração cobre os 10 cenários da seção 6.10:

1. Duas requisições sequenciais com a mesma chave.
2. Vinte requisições concorrentes com a mesma chave.
3. Mesma chave com payload diferente (409).
4. Timeout da BFF após o sucesso.
5. Timeout após a reserva.
6. Falha do DynamoDB após a reserva, incluindo o resultado desconhecido após o commit.
7. Crash real do processo (exit 137) em `IN_PROGRESS`, com recuperação pelo lease.
8. Replay após `COMPLETED`.
9. Chaves diferentes geram pedidos distintos.
10. Correlação entre logs e traces.

Ela cobre ainda o ciclo completo do Circuit Breaker e os erros de validação.

## Achados da validação real (e o que foi corrigido)

| Achado | Impacto | Ação |
|---|---|---|
| A ValidatingAdmissionPolicy usava `request.subResource` sem `has()`, e a avaliação CEL falhava em Pods sem subrecurso | Com `failurePolicy: Fail`, novos Pods legítimos da Orders seriam negados (HPA quebrado) | Corrigido com `variables.isEphemeral` + `has()`; validado com rollout e scale-out reais |
| Inventory sem PriorityClass (prioridade 0) foi **preemptada** durante o scale-out do HPA no LAB 02 | Pedidos falharam durante o LAB 02 | O estado base passou a usar `critical-services`; o achado está documentado no LAB 02 e o anti-pattern ficou restrito ao LAB 03 |
| O nó de observabilidade ficou com 97% de CPU *requests* (MongoDB 1 CPU, operador 500m) | Pods do gateway OTel/k6 ficavam Pending | Requests reduzidos nos values (MongoDB 250m, operador 100m, ClickHouse 500m), ficando em 61% |
| `SeverityText` é normalizado para minúsculas no ClickStack | O filtro `SeverityText:"ERROR"` não casava | Os alertas passaram a usar o atributo `LogAttributes.level:"ERROR"` |
| BFF → Orders com keep-alive: o kube-proxy balanceia conexões (L4) | Em baixa taxa, uma réplica recebeu 100% do tráfego e o breaker de cada réplica divergiu | Documentado no LAB 04 (observação + challenge); correção prevista para a fase 2 |
| Breaker único para consulta e reserva | Com falha só em `RESERVATIONS`, o circuito oscila (os testes no HALF_OPEN usam o GET) | O LAB 04 usa falha em todas as rotas para o ciclo limpo; a variação virou challenge |
| `docker login`/push travando pelo credential helper do Docker Desktop | O deploy travava | `deploy.sh` ganhou watchdog + retry no push e a opção `DOCKER_ISOLATED_CONFIG=true`; a base passou a ser `public.ecr.aws/docker/library/python` |
| Bugs dos próprios scripts de validação (f-string, `exec` sem `-i`, subshell, Pods em terminação) | Falsos negativos | Corrigidos; a última execução completa do `validate.sh` passou 14/14 |

## Limitações conhecidas (MVP)

- Circuit Breaker local por réplica; o balanceamento L4 com keep-alive concentra tráfego.
- Inventory com réplica única e estado em memória: um restart perde reservas (validado: o OOMKilled zerou `reservations_total`).
- Reserva com resultado `UNKNOWN` só é resolvida pelo retry do cliente; não há reconciliação assíncrona (fase 2).
- Identidade simulada (`X-Customer-ID`/`customer_id`); `unit_price` é informado pelo cliente.
- Sampling de 100%; os alertas contam logs (anti-pattern intencional, com 2× a contagem real medida no EKS: 1356 logs vs 678 requisições).
- A consulta (d) do `compare-counts.sh` calcula o delta de contadores cumulativos e subestima a contagem em caso de restart na janela.
- Os nomes de métricas `k8s.*` dependem da versão do collector (0.162). Foram observados no EKS para `k8s.pod.phase` e `k8s.pod.cpu.usage`.

## Pendências

- Fase 2 (fora do escopo): veja o README.
- Não validado em cluster: o Challenge opcional de eviction por memory pressure com BestEffort (LAB 03) e a inspeção visual da UI do HyperDX. Os dados foram verificados por SQL/API, e os alertas e webhooks pela API v2.

## Teardown

Executado em 2026-10-14, levou ~25 min: PVCs/EBS, releases Helm, Pod Identity Association, role e policy IAM,
tabela DynamoDB, 3 repositórios ECR, node groups, add-ons e control plane (`all cluster resources were deleted`).
Custo aproximado da validação completa: ~3,5 h de cluster ≈ US$ 2–3.
