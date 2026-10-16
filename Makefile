# =============================================================================
# Kubernetes Reliability Workshop — atalhos para cada etapa.
#
#   make help            lista todos os alvos
#   make up              setup + deploy + validate (ambiente completo)
#   make lab06-start     inicia um passo específico de um laboratório
#
# Variáveis (sobrescreva na linha de comando):
#   make setup CLUSTER_ID=aluno01 AWS_REGION=us-west-2
#   make k6-stress RATE=80 DURATION=8m
# Compatível com GNU Make 3.81 (padrão do macOS).
# =============================================================================
SHELL := /bin/bash
.DEFAULT_GOAL := help

export AWS_REGION   ?= us-east-1
# CLUSTER_ID=aluno01 => cluster rw-aluno01 e recursos com esse prefixo (turma: scripts/fleet.sh)
export CLUSTER_ID   ?= $(STUDENT_ID)   # STUDENT_ID: nome antigo, ainda aceito
export CLUSTER_NAME ?= $(if $(CLUSTER_ID),rw-$(CLUSTER_ID))
# true = DOCKER_CONFIG temporário sem credsStore (evita travas do credential helper do Docker Desktop)
export DOCKER_ISOLATED_CONFIG ?= true
# ASSUME_YES=true pula as confirmações interativas de setup/teardown
ASSUME_YES ?= false

# Parâmetros de carga (k6) e falhas
RATE      ?=
DURATION  ?=
VUS       ?=
PROFILE   ?= burstable
MS        ?= 800
TARGET    ?= ALL
MB        ?= 700
WORKERS   ?= 2
SLACK     ?= 100
MINUTES   ?= 15
PRINCIPALS ?=

K6_ARGS = $(if $(RATE),RATE=$(RATE)) $(if $(DURATION),DURATION=$(DURATION)) $(if $(VUS),VUS=$(VUS))
NS = kubectl -n ecommerce
CA_SCALE = kubectl -n kube-system scale deploy -l app.kubernetes.io/name=aws-cluster-autoscaler

.PHONY: help
help: ## Lista os alvos disponíveis
	@awk 'BEGIN {FS = ":.*##"} /^##@/ {printf "\n\033[1m%s\033[0m\n", substr($$0, 5)} \
	  /^[a-zA-Z0-9_-]+:.*##/ {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo ""
	@echo "Variáveis: AWS_REGION=$(AWS_REGION) CLUSTER_NAME=$(CLUSTER_NAME) ASSUME_YES=$(ASSUME_YES) DOCKER_ISOLATED_CONFIG=$(DOCKER_ISOLATED_CONFIG)"

##@ Pré-requisitos e testes locais (sem AWS)
.PHONY: check test local-stack lock
check: ## Verifica ferramentas e credenciais AWS
	@for t in aws kubectl eksctl helm docker python3 perl; do \
	  if command -v $$t >/dev/null; then printf '  ✔ %s\n' $$t; else printf '  ✘ %s (ausente)\n' $$t; missing=1; fi; done; \
	  aws sts get-caller-identity --query '[Account,Arn]' --output text || missing=1; \
	  test -z "$$missing"

test: ## Testes unitários + integração (DynamoDB Local via Docker)
	scripts/test.sh

local-stack: ## Sobe DynamoDB Local + 3 APIs localmente (Ctrl+C para parar)
	@test -x .venv/bin/python || scripts/test.sh >/dev/null
	.venv/bin/python scripts/local/stack.py

lock: ## Regenera apps/*/requirements.lock (todas as dependências com hash; rode após editar requirements*.txt)
	scripts/lock.sh

##@ Ciclo de vida do ambiente (AWS — gera custo)
.PHONY: up setup images deploy deploy-only validate validate-quick validate-iam reset teardown status
up: setup deploy validate ## Ambiente completo: setup + deploy + validate

setup: ## Provisiona EKS, add-ons, DynamoDB, Pod Identity, CA, ClickStack, OTel e alertas (~40 min)
	ASSUME_YES=$(ASSUME_YES) scripts/setup.sh

images: ## Build/push multi-arch (amd64 + arm64) das imagens que ainda não estão no ECR
	scripts/images.sh all

deploy: ## Build/push das imagens multi-arch que faltam no ECR + deploy das 3 APIs e do HPA
	scripts/deploy.sh

deploy-only: ## Reaplica os manifests sem rebuild das imagens
	scripts/deploy.sh --skip-build

validate: ## Valida os critérios de aceitação baseline (inclui k6 de concorrência)
	scripts/validate.sh

validate-quick: ## Validação sem o teste k6
	scripts/validate.sh --quick

validate-iam: ## Testes positivos/negativos de Pod Identity e isolamento IAM
	scripts/validate-iam.sh

reset: ## Volta ao estado inicial entre laboratórios
	scripts/reset.sh

teardown: ## Remove TODOS os recursos AWS do workshop
	ASSUME_YES=$(ASSUME_YES) scripts/teardown.sh

status: ## Nós, Pods, HPA e estado do Circuit Breaker
	kubectl get nodes -L workload
	$(NS) get pods -o wide
	$(NS) get hpa
	-@scripts/fault.sh orders cb

##@ Infraestrutura (etapas isoladas)
.PHONY: dynamodb dynamodb-delete pod-identity pod-identity-delete alerts
dynamodb: ## Cria a tabela DynamoDB (+TTL)
	infrastructure/dynamodb.sh create

dynamodb-delete: ## Remove a tabela DynamoDB
	infrastructure/dynamodb.sh delete

pod-identity: ## Cria policy, role e Pod Identity Association da Orders API
	infrastructure/pod-identity.sh create

pod-identity-delete: ## Remove a Pod Identity Association, a role e a policy
	infrastructure/pod-identity.sh delete

alerts: ## (Re)cria webhook, saved searches e os 4 alertas no HyperDX
	@source scripts/lib/common.sh && source scripts/lib/hyperdx-port-forward.sh && start_hyperdx_port_forward && \
	  python3 observability/alerts/create_alerts.py --app-url http://localhost:$$HDX_APP_PORT \
	    --api-url http://localhost:$$HDX_API_PORT --creds .workshop/hyperdx-credentials.json

##@ Turma: um ambiente isolado por aluno (ROSTER=infrastructure/students.csv)
ROSTER ?= infrastructure/students.csv
.PHONY: fleet-quotas fleet-up fleet-access fleet-status fleet-down fleet-profile identity-center student-up student-down
fleet-quotas: ## Quotas da região x necessário para a turma
	scripts/fleet.sh quotas $(ROSTER)

identity-center: ## [conta de GERENCIAMENTO] permission set + usuários + atribuição (WORKSHOP_ACCOUNT_ID=...)
	infrastructure/identity-center.sh apply $(ROSTER)

fleet-up: ## Build único + 1 ambiente por aluno em paralelo (PARALLEL=8)
	ASSUME_YES=$(ASSUME_YES) scripts/fleet.sh up $(ROSTER)

fleet-access: ## (Re)cria role exclusiva + access entry de cada aluno
	scripts/fleet.sh access $(ROSTER)

fleet-status: ## Estado do cluster e da validação de cada aluno
	scripts/fleet.sh status $(ROSTER)

fleet-down: ## Remove os ambientes da turma (DELETE_IMAGES=true remove as imagens)
	ASSUME_YES=$(ASSUME_YES) scripts/fleet.sh down $(ROSTER)

student-up: ## Um aluno do roster: imagens + setup/deploy/acesso/validação, em primeiro plano (CLUSTER_ID=aluno07)
	ASSUME_YES=$(ASSUME_YES) scripts/fleet.sh up-one $(ROSTER) $(CLUSTER_ID)

student-down: ## Remove o ambiente de um aluno do roster (CLUSTER_ID=aluno07)
	ASSUME_YES=$(ASSUME_YES) scripts/fleet.sh down-one $(ROSTER) $(CLUSTER_ID)

fleet-profile: ## ~/.aws/config de um aluno (CLUSTER_ID=aluno01)
	@scripts/fleet.sh profile $(ROSTER) $(CLUSTER_ID)

##@ GitHub Actions (.github/workflows/workshop-up.yml e workshop-down.yml)
.PHONY: gha-role gha-role-delete access-entry hyperdx-credentials-pull hyperdx-credentials-push
gha-role: ## Cria a policy restrita do workshop + role OIDC do pipeline
	infrastructure/github-actions.sh create

gha-role-delete: ## Remove a role do pipeline e o OIDC provider criado por ela
	infrastructure/github-actions.sh delete

access-entry: ## Dá acesso admin ao cluster (PRINCIPALS="arn ..."; vazio = você)
	infrastructure/access-entry.sh grant $(PRINCIPALS)

hyperdx-credentials-pull: ## Baixa do Secrets Manager as credenciais do HyperDX (ambiente criado pelo pipeline)
	scripts/hyperdx-credentials.sh pull

hyperdx-credentials-push: ## Envia ao Secrets Manager as credenciais do HyperDX (ambiente criado localmente)
	scripts/hyperdx-credentials.sh push

##@ Acesso
.PHONY: hyperdx bff-url bff-port-forward hyperdx-credentials
hyperdx: ## Port-forward do HyperDX em http://localhost:3000
	@echo "Credenciais: .workshop/hyperdx-credentials.json"
	kubectl -n observability port-forward svc/clickstack-app 3000:3000

hyperdx-credentials: ## Mostra as credenciais do HyperDX
	@cat .workshop/hyperdx-credentials.json

bff-url: ## URL pública da BFF (NLB) e do Swagger
	@h=$$($(NS) get svc bff-api-public -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'); \
	  test -n "$$h" || { echo "NLB sem hostname ainda: kubectl -n ecommerce describe svc bff-api-public"; exit 1; }; \
	  echo "BFF:     http://$$h"; echo "Swagger: http://$$h/docs"; echo "export BFF=http://$$h"

bff-port-forward: ## Alternativa ao NLB: port-forward da BFF em http://localhost:8080
	$(NS) port-forward svc/bff-api 8080:8080

##@ Carga (k6 dentro do cluster) — variáveis: RATE, DURATION, VUS
.PHONY: k6-create k6-get k6-stress k6-errors k6-idempotency
k6-create: ## create-orders.js
	scripts/k6.sh create-orders.js $(K6_ARGS)

k6-get: ## get-orders.js
	scripts/k6.sh get-orders.js $(K6_ARGS)

k6-stress: ## stress-orders.js (rampa para HPA/CA)
	scripts/k6.sh stress-orders.js $(K6_ARGS)

k6-errors: ## inventory-errors.js (tráfego durante falhas injetadas)
	scripts/k6.sh inventory-errors.js $(K6_ARGS)

k6-idempotency: ## 20 requisições concorrentes com a mesma Idempotency-Key
	scripts/k6.sh idempotency-concurrency.js

##@ Falhas
.PHONY: faults-status faults-reset
faults-status: ## Estado das falhas injetadas em cada API
	scripts/fault.sh inventory status; scripts/fault.sh orders status; scripts/fault.sh bff status

faults-reset: ## Remove todas as falhas e reseta os Circuit Breakers
	scripts/fault.sh all reset

##@ LAB 01 — First Successful Order
.PHONY: lab01 lab01-order lab01-timeout lab01-timeout-retry
lab01: validate validate-iam k6-idempotency ## Pedido, DynamoDB, Pod Identity e idempotência

lab01-order: ## Cria um pedido via BFF e repete com a mesma chave (replay)
	@source scripts/lib/common.sh && source scripts/lib/cluster-helpers.sh && \
	  key=$$(python3 -c 'import uuid;print(uuid.uuid4())') && echo "Idempotency-Key=$$key" && \
	  body='{"customer_id":"customer-123","items":[{"sku":"product-001","quantity":2,"unit_price":"49.90"}]}' && \
	  echo "1ª tentativa: $$(bff_request POST /orders "$$body" "$$key")" && \
	  echo "retry:        $$(bff_request POST /orders "$$body" "$$key")"

lab01-timeout: ## Falha: timeout da BFF (300 ms) com Orders lenta (700 ms)
	scripts/fault.sh bff timeout 300
	scripts/fault.sh orders cpu-work 700

lab01-timeout-retry: ## Remove a falha do LAB 01 (repita o POST com a MESMA chave)
	scripts/fault.sh bff reset
	scripts/fault.sh orders reset

##@ LAB 02 — Probes & Graceful Shutdown (POD=<pod da Orders>)
.PHONY: lab02-load lab02-watch lab02-not-ready lab02-ready lab02-freeze lab02-rollout lab02-break lab02-undo
lab02-load: ## Carga contínua com retry do cliente (RATE=10 DURATION=30m)
	scripts/k6.sh create-orders.js RATE=$(or $(RATE),10) DURATION=$(or $(DURATION),30m)

lab02-watch: ## Painel do Pod: READY, RESTARTS e se recebe tráfego (POD=...)
	labs/lab-02/watch-pod.sh $(POD)

lab02-not-ready: ## A1: readiness 503 / liveness 200 em UM Pod (POD=...)
	scripts/fault.sh orders not-ready $(POD)

lab02-ready: ## Desfaz o not-ready (todas as réplicas)
	scripts/fault.sh orders ready

lab02-freeze: ## A2: trava o event loop de UM Pod por 90 s (POD=...)
	scripts/fault.sh orders freeze 90 $(POD)

lab02-rollout: ## B: rollout da Orders sob carga
	kubectl -n ecommerce rollout restart deploy/orders-api
	kubectl -n ecommerce rollout status deploy/orders-api

lab02-break: ## C: deploy quebrado (tabela inexistente)
	kubectl -n ecommerce set env deploy/orders-api ORDERS_TABLE_NAME=tabela-que-nao-existe

lab02-undo: ## C: desfaz o deploy quebrado
	kubectl -n ecommerce rollout undo deploy/orders-api
	kubectl -n ecommerce rollout status deploy/orders-api

##@ LAB 03 — RollingUpdate & PodDisruptionBudget (NODE_A=<nó apps>)
.PHONY: lab03-load lab03-rollout lab03-aggressive lab03-safe lab03-recreate lab03-pdb-zero lab03-pdb-restore lab03-drain lab03-restore
lab03-load: ## Carga contínua com retry do cliente (RATE=10 DURATION=30m)
	scripts/k6.sh create-orders.js RATE=$(or $(RATE),10) DURATION=$(or $(DURATION),30m)

lab03-rollout: ## A: rollout seguro da Orders (maxSurge 1 / maxUnavailable 0)
	$(NS) rollout restart deploy/orders-api
	$(NS) rollout status deploy/orders-api

lab03-aggressive: ## B: estratégia agressiva (maxSurge 0 / maxUnavailable 100%) + rollout
	$(NS) patch deploy orders-api --patch-file kubernetes/labs/rollout/orders-aggressive-rollout.patch.yaml
	$(NS) rollout restart deploy/orders-api
	$(NS) rollout status deploy/orders-api

lab03-safe: ## B: volta a estratégia segura (1/0)
	$(NS) patch deploy orders-api --patch-file kubernetes/labs/rollout/orders-safe-rollout.patch.yaml

lab03-recreate: ## C: rollout da Inventory (strategy Recreate)
	$(NS) rollout restart deploy/inventory-api
	$(NS) rollout status deploy/inventory-api

lab03-pdb-zero: ## D: PDB da Orders com maxUnavailable 0 (bloqueia drain)
	$(NS) patch pdb orders-api --type merge --patch-file kubernetes/labs/rollout/orders-pdb-zero.patch.yaml

lab03-pdb-restore: ## D: PDB da Orders de volta a maxUnavailable 1
	$(NS) patch pdb orders-api --type merge --patch-file kubernetes/labs/rollout/orders-pdb-restore.patch.yaml

lab03-drain: ## D/E: CA off + drain do nó A (timeout 60 s) (NODE_A=...)
	$(CA_SCALE) --replicas=0
	kubectl drain $(NODE_A) --ignore-daemonsets --delete-emptydir-data --timeout=60s

lab03-restore: ## Uncordon + redistribui BFF/Orders + CA on + estoque inicial
	kubectl uncordon -l workload=apps
	$(NS) rollout restart deploy/orders-api deploy/bff-api
	$(CA_SCALE) --replicas=1
	scripts/fault.sh inventory reset-stock

##@ LAB 04 — Affinity, Anti-affinity, Topology Spread & Taints (NODE_A=<nó apps>, ZONE_A=<zona do nó A>, N=<réplicas>)
.PHONY: lab04-load lab04-watch lab04-zone-required-missing lab04-zone-preferred-missing lab04-zone-required lab04-anti-naive lab04-anti-required lab04-anti-preferred lab04-replicas lab04-affinity-preferred lab04-affinity-required lab04-clear lab04-spread-fill lab04-spread-release lab04-drain lab04-rebalance lab04-taint lab04-tolerate lab04-noexecute-prep lab04-noexecute lab04-untaint
lab04-load: ## Carga contínua com retry do cliente (RATE=10 DURATION=45m)
	scripts/k6.sh create-orders.js RATE=$(or $(RATE),10) DURATION=$(or $(DURATION),45m)

lab04-watch: ## Painel: Pods e o nó de cada um
	$(NS) get pods -w -o 'custom-columns=POD:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName'

lab04-zone-required-missing: ## A1: BFF exige uma zona inexistente (required)
	$(NS) patch deploy bff-api --patch-file kubernetes/labs/scheduling/bff-zone-required-missing.patch.yaml

lab04-zone-preferred-missing: ## A2: BFF prefere uma zona inexistente (preferred)
	$(NS) patch deploy bff-api --patch-file kubernetes/labs/scheduling/bff-zone-preferred-missing.patch.yaml

lab04-zone-required: ## A3: BFF exige a zona do nó A (ZONE_A=...)
	$(NS) patch deploy bff-api --type strategic --patch "$$(sed "s/__ZONE__/$(ZONE_A)/" kubernetes/labs/scheduling/bff-zone-required.patch.yaml)"

lab04-anti-naive: ## B1: CA off + anti-affinity required na Orders SEM matchLabelKeys
	$(CA_SCALE) --replicas=0
	$(NS) patch deploy orders-api --patch-file kubernetes/labs/scheduling/orders-anti-required-naive.patch.yaml

lab04-anti-required: ## B2: anti-affinity required na Orders (com matchLabelKeys)
	$(NS) patch deploy orders-api --patch-file kubernetes/labs/scheduling/orders-anti-required.patch.yaml

lab04-anti-preferred: ## C: anti-affinity preferred na Orders
	$(NS) patch deploy orders-api --patch-file kubernetes/labs/scheduling/orders-anti-preferred.patch.yaml

lab04-replicas: ## Orders com N réplicas mínimas no HPA (N=3)
	$(NS) patch hpa orders-api -p '{"spec":{"minReplicas":$(or $(N),3)}}'

lab04-affinity-preferred: ## D1: BFF prefere o nó da Inventory (podAffinity preferred)
	$(NS) patch deploy bff-api --patch-file kubernetes/labs/scheduling/bff-affinity-inventory-preferred.patch.yaml

lab04-affinity-required: ## D2: BFF exige o nó da Inventory (podAffinity required)
	$(NS) patch deploy bff-api --patch-file kubernetes/labs/scheduling/bff-affinity-inventory-required.patch.yaml

lab04-clear: ## Remove as afinidades e tolerations das 3 APIs + CA on
	for d in bff-api orders-api inventory-api; do $(NS) patch deploy $$d --patch-file kubernetes/labs/scheduling/clear-affinity.patch.yaml; done
	for d in bff-api orders-api inventory-api; do $(NS) patch deploy $$d --patch-file kubernetes/labs/scheduling/clear-tolerations.patch.yaml; done
	$(CA_SCALE) --replicas=1

lab04-spread-fill: ## E2: CA off + ocupa só o nó A + Orders com 4 réplicas (NODE_A=...)
	$(CA_SCALE) --replicas=0
	labs/lab-05/fill-capacity.py --node $(NODE_A) --slack 100
	$(NS) patch hpa orders-api -p '{"spec":{"minReplicas":4}}'

lab04-spread-release: ## E2: remove o ballast e volta a Orders para 2 réplicas
	kubectl -n loadtest delete pod -l app.kubernetes.io/name=capacity-ballast
	$(NS) patch hpa orders-api -p '{"spec":{"minReplicas":2}}'

lab04-drain: ## E3: drena o nó A (NODE_A=...)
	kubectl drain $(NODE_A) --ignore-daemonsets --delete-emptydir-data

lab04-rebalance: ## E3: uncordon do nó A + rollout restart (redistribui) + CA on (NODE_A=...)
	kubectl uncordon $(NODE_A)
	$(NS) rollout restart deploy/orders-api deploy/bff-api
	$(NS) rollout status deploy/orders-api
	$(NS) rollout status deploy/bff-api
	$(CA_SCALE) --replicas=1

lab04-taint: ## F2: taint dedicated=lab04:NoSchedule no nó A + rollout restart da Orders (NODE_A=...)
	kubectl taint nodes $(NODE_A) dedicated=lab04:NoSchedule
	$(NS) rollout restart deploy/orders-api
	$(NS) rollout status deploy/orders-api

lab04-tolerate: ## F3: Orders tolera o taint dedicated do nó A
	$(NS) patch deploy orders-api --patch-file kubernetes/labs/scheduling/orders-tolerate-dedicated.patch.yaml
	$(NS) rollout status deploy/orders-api

lab04-noexecute-prep: ## F4: tira o taint da F2, BFF tolera NoExecute por 60 s, PDB da Orders em 0 (NODE_A=...)
	kubectl taint nodes $(NODE_A) dedicated- || true
	$(NS) patch deploy orders-api --patch-file kubernetes/labs/scheduling/clear-tolerations.patch.yaml
	$(NS) patch deploy bff-api --patch-file kubernetes/labs/scheduling/bff-tolerate-maintenance.patch.yaml
	$(NS) rollout status deploy/orders-api
	$(NS) rollout status deploy/bff-api
	$(NS) patch pdb orders-api --type merge --patch-file kubernetes/labs/rollout/orders-pdb-zero.patch.yaml

lab04-noexecute: ## F4: taint maintenance=lab04:NoExecute no nó A (despeja sem PDB) (NODE_A=...)
	kubectl taint nodes $(NODE_A) maintenance=lab04:NoExecute

lab04-untaint: ## F: remove os taints dos nós apps, tolerations e PDB 0 + rollout restart (redistribui)
	for n in $$(kubectl get nodes -l workload=apps -o name); do for t in dedicated maintenance; do kubectl taint $$n $$t- 2>/dev/null || true; done; done
	$(NS) patch pdb orders-api --type merge --patch-file kubernetes/labs/rollout/orders-pdb-restore.patch.yaml
	for d in bff-api orders-api; do $(NS) patch deploy $$d --patch-file kubernetes/labs/scheduling/clear-tolerations.patch.yaml; done
	$(NS) rollout restart deploy/orders-api deploy/bff-api
	$(NS) rollout status deploy/orders-api
	$(NS) rollout status deploy/bff-api

##@ LAB 05 — QoS & PriorityClass
.PHONY: lab05-qos lab05-throttle lab05-cpustat lab05-oom lab05-noisy lab05-preempt lab05-load lab05-observe lab05-fix
lab05-qos: ## Aplica perfil de QoS (PROFILE=besteffort|burstable|guaranteed)
	labs/lab-05/qos.sh $(PROFILE)

lab05-throttle: ## CPU burn na Inventory (WORKERS=2)
	scripts/fault.sh inventory cpu-burn $(WORKERS)

lab05-cpustat: ## Observa throttling (cgroup cpu.stat)
	labs/lab-05/cpu-stat.sh

lab05-oom: ## Memory ballast acima do limit (MB=700) => OOMKilled
	scripts/fault.sh inventory memory $(MB)
	@sleep 15; $(NS) get pod -l app.kubernetes.io/name=inventory-api \
	  -o jsonpath='{range .items[*]}{.metadata.name} restarts={.status.containerStatuses[0].restartCount} last={.status.containerStatuses[0].lastState.terminated.reason}{"\n"}{end}'

lab05-noisy: ## Vizinho barulhento BestEffort no nó da Inventory
	kubectl apply -f kubernetes/labs/qos/noisy-neighbor.yaml

lab05-preempt: ## Cenário de preemption (Guaranteed + low priority + CA off + ballast + Orders +2)
	labs/lab-05/qos.sh guaranteed
	$(CA_SCALE) --replicas=0
	$(NS) patch deploy inventory-api --patch-file kubernetes/labs/priority/inventory-low-priority.patch.yaml
	$(NS) rollout status deploy/inventory-api --timeout=3m
	labs/lab-05/fill-capacity.py --slack $(SLACK)
	$(NS) delete hpa orders-api --ignore-not-found
	@replicas=$$($(NS) get deploy orders-api -o jsonpath='{.spec.replicas}'); \
	  echo "Orders: $$replicas -> $$((replicas+2)) réplicas"; \
	  $(NS) scale deploy orders-api --replicas=$$((replicas+2))

lab05-load: ## Tráfego durante a preemption (RATE=5 DURATION=4m)
	scripts/k6.sh create-orders.js RATE=$(or $(RATE),5) DURATION=$(or $(DURATION),4m) RETRY_ON_ERROR=false

lab05-observe: ## Eventos Preempted/FailedScheduling e prioridades dos Pods
	kubectl get events -A --field-selector reason=Preempted -o custom-columns=TIME:.lastTimestamp,POD:.involvedObject.name,MSG:.message
	$(NS) get pods -o custom-columns=POD:.metadata.name,STATUS:.status.phase,PRIO:.spec.priority,NODE:.spec.nodeName

lab05-fix: ## Correção: prioridade crítica na Inventory + CA ativo
	$(NS) patch deploy inventory-api --patch-file kubernetes/labs/priority/inventory-restore-priority.patch.yaml
	$(CA_SCALE) --replicas=1

##@ LAB 06 — CPU Stress & Autoscaling
.PHONY: lab06-start lab06-load lab06-watch lab06-verify lab06-stop
lab06-start: ## Ativa 40 ms de CPU por pedido na Orders (novos Pods herdam)
	$(NS) set env deploy/orders-api ORDERS_CPU_WORK_MS=40
	$(NS) rollout status deploy/orders-api --timeout=3m

lab06-load: ## Carga de estresse (padrão RATE=60 DURATION=6m)
	scripts/k6.sh stress-orders.js RATE=$(or $(RATE),60) DURATION=$(or $(DURATION),6m)

lab06-watch: ## Painel: HPA, Pods Pending e nós
	labs/lab-06/watch.sh

lab06-verify: ## Coleta evidências de HPA e Cluster Autoscaler
	labs/lab-06/verify.sh

lab06-stop: ## Remove o CPU stress da Orders
	$(NS) set env deploy/orders-api ORDERS_CPU_WORK_MS-

##@ LAB 07 — Circuit Breaker
.PHONY: lab07-load lab07-watch lab07-latency lab07-503 lab07-slow-commit lab07-recover
lab07-load: ## Tráfego sem retry do cliente (RATE=5 DURATION=5m)
	scripts/k6.sh create-orders.js RATE=$(or $(RATE),5) DURATION=$(or $(DURATION),5m) RETRY_ON_ERROR=false

lab07-watch: ## Estado do Circuit Breaker por réplica
	labs/lab-07/watch-cb.sh

lab07-latency: ## Latência na Inventory (MS=800 TARGET=ALL|RESERVATIONS|QUERIES)
	scripts/fault.sh inventory latency $(MS) $(TARGET)

lab07-503: ## HTTP 503 na Inventory (TARGET=ALL|RESERVATIONS|QUERIES)
	scripts/fault.sh inventory http-503 $(TARGET)

lab07-slow-commit: ## Reserva aplicada + resposta lenta (MS=800)
	scripts/fault.sh inventory slow-after-commit $(MS)

lab07-recover: ## Remove falhas da Inventory (CB: HALF_OPEN -> CLOSED)
	scripts/fault.sh inventory reset

##@ LAB X1 (extra, labs/.extras/lab-x1) — ClickStack Alerting
.PHONY: labx1-trigger labx1-load labx1-webhook labx1-compare labx1-crash labx1-stop
labx1-trigger: ## Injeta falhas que disparam os 4 alertas
	scripts/fault.sh inventory error-rate 0.5
	scripts/fault.sh orders db FAIL_READS

labx1-load: ## Tráfego de erros (RATE=4 DURATION=3m)
	scripts/k6.sh inventory-errors.js RATE=$(or $(RATE),4) DURATION=$(or $(DURATION),3m)

labx1-webhook: ## Alertas recebidos pelo webhook
	kubectl -n observability exec deploy/alert-webhook -- python -c "import json,urllib.request; \
	d=json.loads(urllib.request.urlopen('http://127.0.0.1:8080/alerts').read()); print('recebidos:', d['count']); \
	[print(a['received_at'][11:19], a['payload'].get('alert'), a['payload'].get('state'), 'value=' + str(a['payload'].get('value'))) for a in d['alerts']]"

labx1-compare: ## COUNT(logs) vs requisições reais (MINUTES=15)
	labs/.extras/lab-x1/compare-counts.sh $(MINUTES)

labx1-crash: ## Falha sem log ERROR: crash da Orders após a reserva
	scripts/fault.sh orders crash-after-reservation

labx1-stop: ## Remove as falhas do LAB X1
	scripts/fault.sh all reset
