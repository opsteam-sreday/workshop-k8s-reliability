# =============================================================================
# Kubernetes Reliability Workshop — atalhos para cada etapa.
#
#   make help            lista todos os alvos
#   make up              setup + deploy + validate (ambiente completo)
#   make lab02-start     inicia um passo específico de um laboratório
#
# Variáveis (sobrescreva na linha de comando):
#   make setup AWS_REGION=us-west-2 CLUSTER_NAME=meu-cluster
#   make k6-stress RATE=80 DURATION=8m
# Compatível com GNU Make 3.81 (padrão do macOS).
# =============================================================================
SHELL := /bin/bash
.DEFAULT_GOAL := help

export AWS_REGION   ?= us-east-1
# STUDENT_ID=aluno01 => cluster rw-aluno01 e recursos com esse prefixo (turma: scripts/fleet.sh)
export STUDENT_ID   ?=
export CLUSTER_NAME ?= $(if $(STUDENT_ID),rw-$(STUDENT_ID),reliability-workshop)
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
.PHONY: fleet-quotas fleet-up fleet-access fleet-status fleet-down fleet-profile identity-center
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

fleet-profile: ## ~/.aws/config de um aluno (STUDENT_ID=aluno01)
	@scripts/fleet.sh profile $(ROSTER) $(STUDENT_ID)

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
.PHONY: hyperdx bff-port-forward hyperdx-credentials
hyperdx: ## Port-forward do HyperDX em http://localhost:3000
	@echo "Credenciais: .workshop/hyperdx-credentials.json"
	kubectl -n observability port-forward svc/clickstack-app 3000:3000

hyperdx-credentials: ## Mostra as credenciais do HyperDX
	@cat .workshop/hyperdx-credentials.json

bff-port-forward: ## Port-forward da BFF em http://localhost:8080
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

##@ LAB 02 — CPU Stress & Autoscaling
.PHONY: lab02-start lab02-load lab02-watch lab02-verify lab02-stop
lab02-start: ## Ativa 40 ms de CPU por pedido na Orders (novos Pods herdam)
	$(NS) set env deploy/orders-api ORDERS_CPU_WORK_MS=40
	$(NS) rollout status deploy/orders-api --timeout=3m

lab02-load: ## Carga de estresse (padrão RATE=60 DURATION=6m)
	scripts/k6.sh stress-orders.js RATE=$(or $(RATE),60) DURATION=$(or $(DURATION),6m)

lab02-watch: ## Painel: HPA, Pods Pending e nós
	labs/lab-02/watch.sh

lab02-verify: ## Coleta evidências de HPA e Cluster Autoscaler
	labs/lab-02/verify.sh

lab02-stop: ## Remove o CPU stress da Orders
	$(NS) set env deploy/orders-api ORDERS_CPU_WORK_MS-

##@ LAB 03 — QoS & PriorityClass
.PHONY: lab03-qos lab03-throttle lab03-cpustat lab03-oom lab03-noisy lab03-preempt lab03-load lab03-observe lab03-fix
lab03-qos: ## Aplica perfil de QoS (PROFILE=besteffort|burstable|guaranteed)
	labs/lab-03/qos.sh $(PROFILE)

lab03-throttle: ## CPU burn na Inventory (WORKERS=2)
	scripts/fault.sh inventory cpu-burn $(WORKERS)

lab03-cpustat: ## Observa throttling (cgroup cpu.stat)
	labs/lab-03/cpu-stat.sh

lab03-oom: ## Memory ballast acima do limit (MB=700) => OOMKilled
	scripts/fault.sh inventory memory $(MB)
	@sleep 15; $(NS) get pod -l app.kubernetes.io/name=inventory-api \
	  -o jsonpath='{range .items[*]}{.metadata.name} restarts={.status.containerStatuses[0].restartCount} last={.status.containerStatuses[0].lastState.terminated.reason}{"\n"}{end}'

lab03-noisy: ## Vizinho barulhento BestEffort no nó da Inventory
	kubectl apply -f kubernetes/labs/qos/noisy-neighbor.yaml

lab03-preempt: ## Cenário de preemption (Guaranteed + low priority + CA off + ballast + Orders +2)
	labs/lab-03/qos.sh guaranteed
	$(CA_SCALE) --replicas=0
	$(NS) patch deploy inventory-api --patch-file kubernetes/labs/priority/inventory-low-priority.patch.yaml
	$(NS) rollout status deploy/inventory-api --timeout=3m
	labs/lab-03/fill-capacity.py --slack $(SLACK)
	$(NS) delete hpa orders-api --ignore-not-found
	@replicas=$$($(NS) get deploy orders-api -o jsonpath='{.spec.replicas}'); \
	  echo "Orders: $$replicas -> $$((replicas+2)) réplicas"; \
	  $(NS) scale deploy orders-api --replicas=$$((replicas+2))

lab03-load: ## Tráfego durante a preemption (RATE=5 DURATION=4m)
	scripts/k6.sh create-orders.js RATE=$(or $(RATE),5) DURATION=$(or $(DURATION),4m) RETRY_ON_ERROR=false

lab03-observe: ## Eventos Preempted/FailedScheduling e prioridades dos Pods
	kubectl get events -A --field-selector reason=Preempted -o custom-columns=TIME:.lastTimestamp,POD:.involvedObject.name,MSG:.message
	$(NS) get pods -o custom-columns=POD:.metadata.name,STATUS:.status.phase,PRIO:.spec.priority,NODE:.spec.nodeName

lab03-fix: ## Correção: prioridade crítica na Inventory + CA ativo
	$(NS) patch deploy inventory-api --patch-file kubernetes/labs/priority/inventory-restore-priority.patch.yaml
	$(CA_SCALE) --replicas=1

##@ LAB 04 — Circuit Breaker
.PHONY: lab04-load lab04-watch lab04-latency lab04-503 lab04-slow-commit lab04-recover
lab04-load: ## Tráfego sem retry do cliente (RATE=5 DURATION=5m)
	scripts/k6.sh create-orders.js RATE=$(or $(RATE),5) DURATION=$(or $(DURATION),5m) RETRY_ON_ERROR=false

lab04-watch: ## Estado do Circuit Breaker por réplica
	labs/lab-04/watch-cb.sh

lab04-latency: ## Latência na Inventory (MS=800 TARGET=ALL|RESERVATIONS|QUERIES)
	scripts/fault.sh inventory latency $(MS) $(TARGET)

lab04-503: ## HTTP 503 na Inventory (TARGET=ALL|RESERVATIONS|QUERIES)
	scripts/fault.sh inventory http-503 $(TARGET)

lab04-slow-commit: ## Reserva aplicada + resposta lenta (MS=800)
	scripts/fault.sh inventory slow-after-commit $(MS)

lab04-recover: ## Remove falhas da Inventory (CB: HALF_OPEN -> CLOSED)
	scripts/fault.sh inventory reset

##@ LAB 05 — ClickStack Alerting
.PHONY: lab05-trigger lab05-load lab05-webhook lab05-compare lab05-crash lab05-stop
lab05-trigger: ## Injeta falhas que disparam os 4 alertas
	scripts/fault.sh inventory error-rate 0.5
	scripts/fault.sh orders db FAIL_READS

lab05-load: ## Tráfego de erros (RATE=4 DURATION=3m)
	scripts/k6.sh inventory-errors.js RATE=$(or $(RATE),4) DURATION=$(or $(DURATION),3m)

lab05-webhook: ## Alertas recebidos pelo webhook
	kubectl -n observability exec deploy/alert-webhook -- python -c "import json,urllib.request; \
	d=json.loads(urllib.request.urlopen('http://127.0.0.1:8080/alerts').read()); print('recebidos:', d['count']); \
	[print(a['received_at'][11:19], a['payload'].get('alert'), a['payload'].get('state'), 'value=' + str(a['payload'].get('value'))) for a in d['alerts']]"

lab05-compare: ## COUNT(logs) vs requisições reais (MINUTES=15)
	labs/lab-05/compare-counts.sh $(MINUTES)

lab05-crash: ## Falha sem log ERROR: crash da Orders após a reserva
	scripts/fault.sh orders crash-after-reservation

lab05-stop: ## Remove as falhas do LAB 05
	scripts/fault.sh all reset
