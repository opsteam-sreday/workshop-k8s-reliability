# Kubernetes: Reliability ou Chaos? — Workshop hands-on (MVP)

> **Kubernetes não cria resiliência automaticamente. Ele automatiza aquilo que configuramos — inclusive nossos erros.**

Laboratório completo e reproduzível em **Amazon EKS** para engenheiros DevOps, SRE e Cloud.
Cada exercício segue a metodologia:

**Break it → Observe it → Understand it → Fix it → Validate it.**

Este repositório entrega o **MVP** (Minimum Executable Workshop): três APIs Python/FastAPI
reais, idempotência end-to-end, EKS Pod Identity, HPA, Cluster Autoscaler, QoS, PriorityClass,
Circuit Breaker, OpenTelemetry + ClickStack, quatro alertas (anti-pattern intencional),
scripts k6 e cinco laboratórios. O status de validação de cada item está em
[`IMPLEMENTATION_PROGRESS.md`](IMPLEMENTATION_PROGRESS.md).

---

## Arquitetura

```text
                          k6 Load Generator (Job no namespace loadtest)
                                  |
                                  v
                              BFF API
                                  | HTTP/REST (Idempotency-Key, X-Request-ID, W3C traceparent)
                                  v
                             Orders API ─────────── AWS SDK (EKS Pod Identity) ──> DynamoDB
                                  |                                                (pedidos + idempotência, TTL)
                       Circuit Breaker + retry + bulkhead
                                  v
                            Inventory API (réplica única, estado em memória)

             BFF / Orders / Inventory ── OTLP ──> OTel Collector gateway ──> ClickStack
             OTel Collector agent (kubelet, logs de nós) ──┘          (ClickHouse + HyperDX)
```

| Componente | Onde | Destaques |
|---|---|---|
| BFF API | `apps/bff-api` | valida formato, propaga `Idempotency-Key`, `X-Request-ID`, trace context; timeout + pool; **não** faz retry de POST |
| Orders API | `apps/orders-api` | modo STRICT, contrato idempotente (DynamoDB, lease + fencing, `TransactWriteItems`), compensação segura, Circuit Breaker, retry com backoff + jitter, bulkhead |
| Inventory API | `apps/inventory-api` | reservas idempotentes com fencing token, liberação idempotente, injeção de falhas (latência, 503, CPU, memória, concorrência) |
| Código compartilhado | `apps/shared/workshop_common` | OpenTelemetry (traces, métricas, logs), logs JSON com `trace_id`/`span_id` reais, health checks, API admin em loopback |
| Infra AWS | `infrastructure/` | `eksctl.yaml` (EKS 1.36, 2 node groups), DynamoDB, IAM + Pod Identity, valores do Cluster Autoscaler |
| Kubernetes | `kubernetes/` | base (Deployments, Services, NetworkPolicies, ValidatingAdmissionPolicy), QoS, PriorityClass, HPA |
| Observabilidade | `observability/` | ClickStack (Helm), OTel Collectors, alertas + webhook, consultas HyperDX/SQL |
| Carga | `load-tests/` | 5 scripts k6 (inclui 20 requisições concorrentes com a mesma chave) |
| Laboratórios | `labs/lab-01..06` | 13 seções cada + scripts de apoio/verificação |

## Estrutura do repositório

```text
eks-reliability-workshop/
├── README.md · IMPLEMENTATION_PROGRESS.md · pytest.ini
├── infrastructure/   vpc/ (VPC por cluster, plano 10.201–10.240.0.0/16) · eksctl.yaml · dynamodb.sh · dynamodb-table.json · pod-identity.sh
│                     orders-dynamodb-policy.json · pod-identity-trust.json · cluster-autoscaler-values.yaml
├── apps/             shared/workshop_common · bff-api · orders-api · inventory-api (app/, tests/, Dockerfile)
├── kubernetes/       platform/ (namespaces, PriorityClasses, otel-config, NetworkPolicies do namespace)
│                     apps/<app>/ (Deployment, Service, SA, ConfigMap, NetworkPolicy; orders-api: + HPA, admission)
│                     base/ (agrega platform + apps) · overlays/generated (gerado pelo deploy.sh)
│                     labs/ (patches de QoS/prioridade e noisy-neighbor — não são estado desejado)
├── observability/    clickstack/ (values, bootstrap) · otel/ (gateway, agent) · alerts/ · queries/
├── load-tests/       create-orders.js · get-orders.js · stress-orders.js · inventory-errors.js
│                     idempotency-concurrency.js · lib/common.js
├── labs/             lab-01 … lab-06 (README + scripts)
├── scripts/          setup.sh · deploy.sh · validate.sh · validate-iam.sh · reset.sh · teardown.sh
│                     fault.sh · k6.sh · test.sh · local/stack.py · lib/
├── tests/integration (processos reais + DynamoDB Local)
├── instructor-guide/ · student-guide/
```

## Pré-requisitos

| Ferramenta | Versão testada | Uso |
|---|---|---|
| AWS CLI v2 | 2.27 | credenciais com permissão para EKS, EC2, IAM, CloudFormation, DynamoDB, ECR |
| eksctl | 0.231.0 | criação/remoção do cluster |
| kubectl | 1.34+ | operação do cluster |
| Helm | 3.x ou 4.x (testado 4.3.0) | Cluster Autoscaler, ClickStack, OTel Collectors |
| Docker (buildx) | 29 | build das imagens multi-arch `linux/amd64` + `linux/arm64` (Docker Desktop já emula arm64/amd64; no Linux: `docker run --privileged --rm tonistiigi/binfmt --install arm64`) |
| Python | 3.9+ no host (scripts) · 3.12 para testes locais | bootstrap do HyperDX, alertas, testes |
| k6 (opcional) | 2.3.0 | os testes rodam DENTRO do cluster via `scripts/k6.sh`; local é opcional |

Configure a AWS CLI (`aws configure` ou SSO) e confirme: `aws sts get-caller-identity`.

## Versões fixadas (verificadas em 2026-10-14)

| Componente | Versão |
|---|---|
| Amazon EKS / Kubernetes | 1.36 (standard support até 2027-08) |
| Cluster Autoscaler | chart 9.59.0 · imagem v1.36.1 (ainda não existe CA 1.37) |
| Add-ons EKS | vpc-cni (Network Policy habilitada), coredns, kube-proxy, eks-pod-identity-agent, metrics-server, aws-ebs-csi-driver |
| ClickStack | `clickstack-operators` 1.1.0 + `clickstack` 3.4.0 (HyperDX 2.39.1, ClickHouse 25.7) |
| OpenTelemetry Collector | chart 0.176.0 (`otel/opentelemetry-collector-k8s`) |
| Python libs | FastAPI 0.143, uvicorn 0.54, httpx 0.28.1, pydantic 2.14, boto3 1.43, OTel SDK 1.45.1 / contrib 0.66b1 |
| k6 | `grafana/k6:2.3.0` |

Todas as versões ficam em `scripts/lib/common.sh` e podem ser sobrescritas por variáveis de ambiente.

## Custos estimados (us-east-1, sob demanda)

| Recurso | Quantidade | US$/h |
|---|---|---|
| EKS control plane | 1 | 0,10 |
| m6i.large (node group `apps`) | 2 (até 5 com o CA) | 0,192 (até 0,48) |
| m6i.xlarge (node group `observability`, isolado por taint) | 1 | 0,192 |
| NAT Gateway | 1 | 0,045 + dados |
| EBS gp3 (nós + PVCs ClickHouse/Keeper/MongoDB ≈ 145 GB) | — | ≈ 0,02 |
| DynamoDB on-demand, ECR | — | centavos |
| **Total** | | **≈ 0,55/h em repouso · ≈ 0,85/h no pico do LAB 02** |

Uma turma de 4 h custa ≈ US$ 3–4. **Execute `scripts/teardown.sh` ao final.**

## Quick start (instrutor)

Atalho via `Makefile` (`make help` lista todos os alvos, por etapa e por laboratório):

```bash
make check            # ferramentas + credenciais AWS
make up               # setup + deploy + validate
make lab02-start lab02-load    # exemplo: passos do LAB 02
make reset            # entre laboratórios
make teardown         # remove tudo (ASSUME_YES=true para não perguntar)
```

Ou diretamente pelos scripts:

```bash
git clone <este-repo> && cd eks-reliability-workshop
aws sts get-caller-identity                 # confirme conta e região
export AWS_REGION=us-east-1                  # opcional (padrão us-east-1)
export STUDENT_ID=aluno01                    # obrigatório: cluster rw-aluno01 (o instrutor usa o dele)

scripts/setup.sh      # ≈ 35–45 min: EKS, add-ons, DynamoDB, Pod Identity, CA, ClickStack, OTel, alertas
scripts/deploy.sh     # build multi-arch + push ECR (só o que mudou) + deploy das 3 APIs + HPA
scripts/validate.sh   # critérios de aceitação baseline → .workshop/validation-report.md
```

> Se o `docker login`/push travar (credential helper do Docker Desktop), use
> `DOCKER_ISOLATED_CONFIG=true scripts/deploy.sh` — um `DOCKER_CONFIG` temporário sem credsStore.

**BFF pública:** todo cluster expõe a BFF num NLB internet-facing (`bff-api-public`, porta 80, **sem autenticação**,
aberto para `0.0.0.0/0`); Orders e Inventory continuam internas. O `deploy.sh` imprime a URL
(`http://<nlb>/docs` = Swagger); depois: `kubectl -n ecommerce get svc bff-api-public`. Swagger de Orders/Inventory:
`kubectl -n ecommerce port-forward svc/orders-api 8081:8080` → `http://localhost:8081/docs`.

Acesso ao HyperDX (credenciais geradas em `.workshop/hyperdx-credentials.json`):

```bash
kubectl -n observability port-forward svc/clickstack-app 3000:3000   # http://localhost:3000
```

Acesso à BFF a partir da sua máquina (NLB público `bff-api-public`, porta 80; ou `make bff-url`):

```bash
export BFF=http://$(kubectl -n ecommerce get svc bff-api-public -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s -X POST $BFF/orders -H "Idempotency-Key: $(uuidgen | tr A-Z a-z)" -H 'Content-Type: application/json' \
  -d '{"customer_id":"customer-123","items":[{"sku":"product-001","quantity":2,"unit_price":"49.90"}]}' -i
```

## Laboratórios

| Lab | Tema | Comando-chave | Verificação |
|---|---|---|---|
| [LAB 01](labs/lab-01/README.md) | First Successful Order (pedido, DynamoDB, Pod Identity, trace, idempotência) | `scripts/k6.sh idempotency-concurrency.js` | `scripts/validate.sh`, `scripts/validate-iam.sh` |
| [LAB 02](labs/lab-02/README.md) | CPU Stress & Autoscaling (HPA + Cluster Autoscaler) | `kubectl -n ecommerce set env deploy/orders-api ORDERS_CPU_WORK_MS=40` + `scripts/k6.sh stress-orders.js RATE=60 DURATION=6m` | `labs/lab-02/verify.sh` |
| [LAB 03](labs/lab-03/README.md) | QoS & PriorityClass (throttling, OOMKilled, preemption) | `labs/lab-03/qos.sh …`, `labs/lab-03/fill-capacity.py` | ver README |
| [LAB 04](labs/lab-04/README.md) | Circuit Breaker (CLOSED → OPEN → HALF_OPEN → CLOSED) | `scripts/fault.sh inventory latency 800 RESERVATIONS` + `labs/lab-04/watch-cb.sh` | ver README |
| [LAB 05](labs/lab-05/README.md) | ClickStack Alerting (4 alertas, anti-pattern) | `scripts/fault.sh inventory http-503 …` + `scripts/k6.sh inventory-errors.js` | `labs/lab-05/compare-counts.sh` |
| [LAB 06](labs/lab-06/README.md) | Probes, Graceful Shutdown & Topology Spread (readiness × liveness × startup, rollout, deploy quebrado, drain de nó) | `scripts/fault.sh orders not-ready\|freeze <s> <pod>` + `scripts/k6.sh create-orders.js` | `labs/lab-06/watch-pod.sh`, `labs/lab-06/count-responses.sh` |

**Turma com um ambiente por aluno** (mesma conta, isolamento por cluster/tabela/role + login via IAM Identity Center):
`make fleet-quotas` · `make identity-center` · `make fleet-up` · `make fleet-down` — passo a passo no
[guia do instrutor › 2.1](instructor-guide/README.md#21-turma-um-ambiente-isolado-por-aluno-mesma-conta).

Entre laboratórios: `scripts/reset.sh`. Guias: [instrutor](instructor-guide/README.md) · [aluno](student-guide/README.md) ·
[consultas HyperDX/SQL](observability/queries/README.md).

## Contrato de idempotência (resumo)

`POST /orders` exige `Idempotency-Key` (UUID). Semântica HTTP:

| Situação | HTTP | Código |
|---|---|---|
| Primeira criação | 201 | `Idempotency-Replayed: false` |
| Retry após sucesso | 201 | mesmo corpo, `Idempotency-Replayed: true` |
| Operação em andamento | 409 | `ORDER_IN_PROGRESS` + `Retry-After` |
| Mesma chave, payload diferente | 409 | `IDEMPOTENCY_KEY_REUSED` |
| Chave inválida/ausente | 400 | `INVALID_IDEMPOTENCY_KEY` |
| Estoque insuficiente | 409 | `INSUFFICIENT_STOCK` (resultado terminal, também é "replayed") |
| Dependência indisponível | 503 | `DEPENDENCY_UNAVAILABLE` + `Retry-After` |

Como funciona (detalhes em `apps/orders-api/app/service.py` e `repository.py`):

1. **Claim** com `PutItem` + `ConditionExpression=attribute_not_exists(PK)` em `IDEMP#<customer>#<key>` (estado `IN_PROGRESS`, lease de 10 s, `version` = fencing token, `expires_at` = 24 h para o TTL).
2. Requisição concorrente com lease válido → `409 ORDER_IN_PROGRESS`; lease expirado (Pod morreu) → **takeover condicional** que incrementa `version`.
3. Reserva na Inventory com `reservation_id = res-<order_id>` e `Idempotency-Key = reserve-<order_id>` (estáveis) e `fencing_token = version`.
4. **`TransactWriteItems`** atômico: `Put ORDER#<id>` (condição `attribute_not_exists`) + `Update` do registro de idempotência para `COMPLETED` (condição: mesmo `owner_token`, mesma `version`, ainda `IN_PROGRESS`).
5. Falha de persistência após a reserva → **compensação segura**: relê o estado; se o pedido foi persistido, responde 201; senão aplica *fence* (`version+1`), libera a reserva com o novo token e mantém `IN_PROGRESS` com o lease liberado. Resultado desconhecido sem acesso ao estado ⇒ **nenhuma compensação cega**.
6. A identidade do cliente é **simulada** (`X-Customer-ID` ou `customer_id` do body) — em produção, use um token autenticado.

## Segurança do ambiente

- **EKS Pod Identity**: somente `ecommerce/orders-api-sa` recebe a role `rw-<id>-orders-api` (GetItem, PutItem, UpdateItem, Query na tabela e no GSI1; ABAC por namespace/SA/cluster). BFF e Inventory têm ServiceAccounts próprias **sem** permissões AWS.
- **IMDS bloqueado** para Pods: `disablePodIMDS` (hop limit 1) + NetworkPolicy de egress negando `169.254.169.254`.
- **ValidatingAdmissionPolicy** `restrict-orders-api-sa`: só o ReplicaSet controller cria Pods com `orders-api-sa`, com a imagem `orders-api`; `kubectl debug` (containers efêmeros) negado.
- **NetworkPolicies** de ingress: k6 → BFF → Orders → Inventory.
- **API de injeção de falhas** escuta somente em `127.0.0.1:8081` dentro de cada Pod (acesso via `kubectl exec` por quem tem RBAC). Habilitada apenas com `WORKSHOP_MODE=true`.
- Pod Security Admission `restricted`, containers non-root, `readOnlyRootFilesystem`, `drop: [ALL]`.

## Provisionamento via GitHub Actions

Três workflows executam os mesmos scripts do Quick start em um runner descartável:

| Workflow | Equivale a | Entradas |
|---|---|---|
| `images` | `scripts/images.sh all` — um job por app, passo a passo: tag → lock → testes → build amd64 → build arm64 → índice multi-arch. Roda em push na `main` que mexa em `apps/**`, manualmente ou chamado pelo `workshop-up` | região |
| `workshop-up` | `make up` (chama `images`, depois setup + deploy + validate) | região, `student_id` (obrigatório; o instrutor usa o dele), `student_username`, validate on/off |
| `workshop-down` | `make teardown` | região, `student_id`, `confirm` = `rw-<student_id>` |
| `fleet-up` | `make fleet-up`: build único + um `workshop-up` por aluno em paralelo (matrix) | `students` (`id:username …`), região, `max_parallel`, validate on/off |

`workshop-up` e `workshop-down` usam o mesmo grupo de `concurrency` por cluster (nunca rodam up e down ao mesmo tempo).

**Um ambiente por aluno:** com `student_id=aluno07`, o workflow cria o cluster `rw-aluno07` com os nomes derivados dele
(tabela, roles, secret, VPC `10.207.0.0/16`), igual a `STUDENT_ID=aluno07 make up`. Com `student_username`, também cria
a role exclusiva do aluno + access entry (`infrastructure/student-access.sh`; exige o permission set já atribuído à
conta: `make identity-center`). Execuções de alunos diferentes rodam em paralelo. A role do pipeline cobre só os
ambientes `rw-*` (o instrutor usa um deles, ex.: `aluno01`); rode `make gha-role` após atualizar este repositório.

**Imagens:** cada app tem a própria tag (hash git de `apps/<app>` + `apps/shared`), então mexer em uma app só
rebuilda ela. No ECR (repositórios `IMMUTABLE`) ficam `<tag>-amd64`, `<tag>-arm64` e `<tag>`, o índice multi-arch que os
clusters usam (cada nó puxa a sua arquitetura). Tag já publicada = o job pula o build. Os jobs de `images` também
usam o environment `workshop`: com *Required reviewers*, aprove os 3 jobs (bff, orders, inventory) de uma vez.

**Configuração (uma vez por conta/repositório):**

1. Crie a role OIDC do pipeline, escolhendo **explicitamente** a policy anexada (sem padrão — ver
   `infrastructure/github-actions/oidc-role.yaml`). A trust policy só aceita jobs deste repositório no environment `workshop`:
   ```bash
   make gha-role   # policy restrita do workshop (ou GITHUB_ACTIONS_POLICY_ARN=<arn> para outra); imprime o ARN da role
   ```
2. No GitHub: **Settings › Environments › New environment** `workshop` (recomendado: *Required reviewers*) com as variáveis:
   - `AWS_ROLE_ARN` = ARN impresso no passo 1;
   - `EKS_ADMIN_PRINCIPAL_ARNS` (opcional) = ARNs IAM, separados por espaço, que também devem administrar o cluster
     (ex.: `arn:aws:iam::<conta>:role/<sua-role>`; roles do SSO com o path `aws-reserved/sso.amazonaws.com/`).
     O `scripts/setup.sh` concede o acesso logo após criar o cluster, antes das demais etapas (localmente, exporte a
     mesma variável). Sem isso, só o pipeline acessa um cluster que ele criou.
3. **Actions › workshop-up › Run workflow.** O resumo do job traz o `update-kubeconfig` e o relatório de validação.

**Estado entre execuções:** as credenciais do HyperDX (`.workshop/hyperdx-credentials.json`) ficam no AWS Secrets
Manager (`reliability-workshop/<cluster>/hyperdx-credentials`), nunca em artifacts. Para usar localmente
um ambiente criado pelo pipeline: `make hyperdx-credentials-pull`. Para o pipeline assumir um ambiente criado
localmente: `make hyperdx-credentials-push` (o workflow concede a si mesmo acesso ao cluster via EKS access entry).

## Testes locais (sem AWS)

```bash
scripts/test.sh                          # 46 testes unitários + 11 de integração (DynamoDB Local via Docker)
.venv/bin/python scripts/local/stack.py  # sobe DynamoDB Local + 3 APIs em processos reais (ver --help para OTLP)
```

Os testes de integração cobrem os 10 cenários obrigatórios de idempotência (seção 6.10), incluindo
20 requisições concorrentes, timeout da BFF após sucesso, timeout após reserva, falha do DynamoDB após
reserva, crash real do processo em `IN_PROGRESS` com recuperação por lease e correlação de logs/traces,
além do ciclo completo do Circuit Breaker.

## Limitações conhecidas do MVP

- Circuit Breaker com estado **local por réplica**.
- Inventory API em **réplica única com estado em memória**: um restart perde reservas e restaura o estoque (sem durabilidade).
- Reserva com resultado desconhecido fica `IN_PROGRESS`/`UNKNOWN` até um retry do cliente — **não há reconciliação assíncrona** (fase 2).
- Identidade simulada; `unit_price` informado pelo cliente.
- Sampling de traces 100% (inadequado para produção em alto volume).
- Alertas por **contagem de logs** — anti-pattern **intencional**, corrigido na fase 2.
- TTL do DynamoDB é assíncrono; a aplicação aplica a janela de 24 h logicamente (`expires_at`).

## Teardown

```bash
scripts/teardown.sh   # remove namespaces, PVCs/EBS, Helm releases, IAM, DynamoDB, ECR e o cluster; verifica sobras
```

## Fora do escopo (fase 2)

VPA, PodDisruptionBudget, TopologySpreadConstraints, anti-affinity avançada, Blue/Green e Canary,
Chaos Engineering avançado, Inventory distribuída, DEGRADED mode, reconciliação assíncrona,
alertas corrigidos (traces/métricas), dashboards avançados, error budgets, postmortems e a simulação de Black Friday.
