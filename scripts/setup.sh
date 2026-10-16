#!/usr/bin/env bash
# Provisiona TODA a infraestrutura do workshop, explicando cada comando (EXPLAIN=false para silenciar):
#   EKS (2 node groups) + add-ons (VPC CNI c/ Network Policy, Pod Identity Agent, Metrics Server, EBS CSI)
#   DynamoDB + IAM/Pod Identity da Orders API
#   Cluster Autoscaler (Helm) + ClickStack (Helm) + OpenTelemetry Collectors (Helm) + alertas
# Idempotente: pode ser executado novamente para completar etapas pendentes.
source "$(dirname "$0")/lib/common.sh"
require aws kubectl eksctl helm python3 perl
require_aws_session
account_id >/dev/null

cat <<INFO
${c_blue}Kubernetes Reliability Workshop — setup${c_off}
  Conta AWS ........ ${AWS_ACCOUNT_ID}
  Região ........... ${AWS_REGION}
  Cluster .......... ${CLUSTER_NAME} (Kubernetes ${K8S_VERSION})
  VPC .............. $("$REPO_ROOT/infrastructure/vpc/vpc.sh" plan | sed -n 2p | sed 's/^VPC *\.* //') (2 públicas: control plane + NAT · 2 privadas: nós)
  Node groups ...... apps: 2-5 x ${APPS_INSTANCE_TYPE} | observability: 1 x ${OBS_INSTANCE_TYPE}
  DynamoDB ......... ${TABLE_NAME} (PAY_PER_REQUEST)
  Custo estimado ... ~US\$ 0.55/h em repouso; ~US\$ 0.85/h com 5 nós apps (ver README › Custos)
INFO
confirm "Criar/atualizar estes recursos na AWS (geram custo)?" || fail "Cancelado"

# ---------------------------------------------------------------- 1. EKS
section "1/9 · VPC e cluster Amazon EKS"
if cluster_exists; then
  ok "Cluster $CLUSTER_NAME já existe — etapa ignorada"
else
  run "Criar a VPC do cluster (≈3 min)" \
    "Plano de endereçamento: $("$REPO_ROOT/infrastructure/vpc/vpc.sh" plan | sed -n 2p | sed 's/^VPC *\.* //'). Duas subnets públicas (control plane do EKS e NAT Gateway) e duas privadas (node groups, saída pela NAT) em 2 AZs — ver infrastructure/vpc/README.md." \
    "$REPO_ROOT/infrastructure/vpc/vpc.sh" create
  eval "$("$REPO_ROOT/infrastructure/vpc/vpc.sh" env)"
  export VPC_ID PUBLIC_SUBNET_A PUBLIC_SUBNET_B PRIVATE_SUBNET_A PRIVATE_SUBNET_B
  render "$REPO_ROOT/infrastructure/eksctl.yaml" > "$STATE_DIR/eksctl.rendered.yaml"
  run "Criar o cluster EKS (≈15-20 min)" \
    "O eksctl lê infrastructure/eksctl.yaml (renderizado com conta, região e os IDs da VPC acima) e cria via CloudFormation: control plane com as ENIs nas subnets públicas, endpoint público + privado, control plane Kubernetes ${K8S_VERSION}, os add-ons (VPC CNI com Network Policy, CoreDNS, kube-proxy, Pod Identity Agent, Metrics Server, EBS CSI) e dois Managed Node Groups: 'apps' (onde rodam as APIs e o Cluster Autoscaler atua) e 'observability' (com taint, isolando o ClickStack dos experimentos de pressão). Também cria a Pod Identity Association do Cluster Autoscaler." \
    eksctl create cluster -f "$STATE_DIR/eksctl.rendered.yaml"
fi
# Logo após criar o cluster (e não no fim): se uma etapa seguinte falhar, os admins já conseguem investigar.
if [[ -n "${EKS_ADMIN_PRINCIPAL_ARNS:-}" ]]; then
  read -r -a admin_arns <<<"$EKS_ADMIN_PRINCIPAL_ARNS"
  run "Conceder acesso admin ao cluster (EKS_ADMIN_PRINCIPAL_ARNS)" \
    "Cria um EKS access entry com AmazonEKSClusterAdminPolicy para cada ARN IAM informado (separados por espaço). O criador do cluster já é admin; isto dá acesso a outros (ex.: instrutor quando quem cria é o pipeline)." \
    "$REPO_ROOT/infrastructure/access-entry.sh" grant "${admin_arns[@]}"
fi
run "Configurar o kubectl para o novo cluster" \
  "Grava no ~/.kube/config as credenciais do cluster (autenticação via IAM) com o alias ${CLUSTER_NAME}." \
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" --alias "$CLUSTER_NAME"
run "Selecionar o contexto do cluster" \
  "Garante que todos os comandos kubectl seguintes atuem neste cluster, e não em outro configurado na máquina." \
  kubectl config use-context "$CLUSTER_NAME"
run "Conferir os nós" \
  "Esperado: 2 nós workload=apps e 1 nó workload=observability, todos Ready." \
  kubectl get nodes -L workload

# ---------------------------------------------------------------- 2. DynamoDB + Pod Identity
section "2/9 · DynamoDB e identidade IAM da Orders API"
run "Criar a tabela DynamoDB" \
  "Tabela única (PK/SK) para pedidos e registros de idempotência, cobrança PAY_PER_REQUEST, índice GSI1 para listar pedidos por cliente sem Scan e TTL no atributo expires_at (retenção de 24h das chaves de idempotência)." \
  "$REPO_ROOT/infrastructure/dynamodb.sh" create
run "Criar policy, role e Pod Identity Association" \
  "Somente a ServiceAccount ecommerce/orders-api-sa recebe a role ${ORDERS_ROLE_NAME}, com GetItem/PutItem/UpdateItem/Query apenas nesta tabela e no GSI1. BFF e Inventory ficam sem nenhuma permissão AWS." \
  "$REPO_ROOT/infrastructure/pod-identity.sh" create

# ---------------------------------------------------------------- 3. StorageClass + namespaces
section "3/9 · Armazenamento, namespaces e prioridades"
run "Criar a StorageClass gp3 padrão" \
  "Os volumes do ClickHouse, Keeper e MongoDB serão discos EBS gp3 criptografados, provisionados pelo EBS CSI driver. reclaimPolicy=Delete: apagar o PVC apaga o disco (importante para o teardown não deixar custo)." \
  kubectl apply -f "$REPO_ROOT/observability/clickstack/storageclass.yaml"
if kubectl get storageclass gp2 >/dev/null 2>&1; then
  run "Remover gp2 como StorageClass padrão" \
    "Evita duas StorageClasses 'default' ao mesmo tempo (o comportamento passaria a ser ambíguo)." \
    kubectl annotate storageclass gp2 storageclass.kubernetes.io/is-default-class=false --overwrite
fi
run "Criar o namespace observability" \
  "Namespace do ClickStack, dos OpenTelemetry Collectors e do webhook de alertas (dry-run + apply = idempotente)." \
  bash -c 'kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -'
run "Criar as PriorityClasses" \
  "critical-services (1000) para BFF/Orders/Inventory e low-priority-services (100), usada no anti-pattern do LAB 05. Elas definem quem é agendado primeiro e quem pode ser preemptado quando falta capacidade." \
  kubectl apply -f "$REPO_ROOT/kubernetes/platform/priorityclasses.yaml"

# ---------------------------------------------------------------- 4. Helm repos
section "4/9 · Repositórios Helm"
for repo in "autoscaler https://kubernetes.github.io/autoscaler" \
            "clickstack https://clickhouse.github.io/ClickStack-helm-charts" \
            "open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts"; do
  set -- $repo
  run "Adicionar o repositório Helm '$1'" "Fonte oficial dos charts usados a seguir." \
    bash -c "helm repo add $1 $2 >/dev/null 2>&1 || true; helm repo list | grep '^$1'"
done
run "Atualizar o índice dos repositórios" "Baixa a lista das versões disponíveis dos charts." helm repo update

# ---------------------------------------------------------------- 5. Cluster Autoscaler
section "5/9 · Cluster Autoscaler"
run "Instalar o Cluster Autoscaler ${CLUSTER_AUTOSCALER_IMAGE_TAG}" \
  "Observa Pods Pending por falta de recursos e aumenta o Auto Scaling Group do node group 'apps' (2→5 nós); remove nós ociosos depois de 2 min (valor acelerado para o workshop). Descobre os node groups pelas tags k8s.io/cluster-autoscaler/*, usa credenciais via Pod Identity e roda no nó de observabilidade para não ser afetado pelos experimentos. A versão precisa acompanhar a minor do Kubernetes." \
  helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler -n kube-system \
    --version "$CLUSTER_AUTOSCALER_CHART_VERSION" -f "$REPO_ROOT/infrastructure/cluster-autoscaler-values.yaml" \
    --set autoDiscovery.clusterName="$CLUSTER_NAME" --set awsRegion="$AWS_REGION" \
    --set image.tag="$CLUSTER_AUTOSCALER_IMAGE_TAG" --wait --timeout 5m

# ---------------------------------------------------------------- 6. ClickStack
section "6/9 · ClickStack (ClickHouse + HyperDX + OTel Collector + MongoDB)"
run "Instalar os operadores do ClickStack ${CLICKSTACK_OPERATORS_CHART_VERSION}" \
  "No chart 3.x o ClickHouse e o MongoDB são recursos customizados (CRDs) gerenciados por operadores. Por isso os operadores são instalados primeiro." \
  helm upgrade --install clickstack-operators clickstack/clickstack-operators -n observability \
    --version "$CLICKSTACK_OPERATORS_CHART_VERSION" -f "$REPO_ROOT/observability/clickstack/operators-values.yaml" \
    --wait --timeout 10m
run "Instalar o ClickStack ${CLICKSTACK_CHART_VERSION}" \
  "ClickHouse (armazena logs, métricas e traces), HyperDX (UI e alertas), o OTel Collector do ClickStack (recebe OTLP e grava no ClickHouse) e MongoDB (metadados da UI). Tudo no node group observability, com requests de CPU reduzidos para o laboratório." \
  helm upgrade --install clickstack clickstack/clickstack -n observability \
    --version "$CLICKSTACK_CHART_VERSION" -f "$REPO_ROOT/observability/clickstack/values.yaml" --timeout 15m
run "Aguardar o HyperDX ficar disponível" "A UI depende do MongoDB e do ClickHouse estarem prontos." \
  kubectl -n observability rollout status deploy/clickstack-app --timeout=15m
run "Aguardar o OTel Collector do ClickStack" "Reinícios iniciais são esperados enquanto o ClickHouse sobe." \
  kubectl -n observability rollout status deploy/clickstack-otel-collector --timeout=10m
run "Ver os componentes do ClickStack" "Todos devem estar Running (o pod 'version-probe' fica Completed)." \
  kubectl -n observability get pods

# ---------------------------------------------------------------- 7. HyperDX bootstrap
section "7/9 · HyperDX: usuário instrutor e ingestion key"
source "$REPO_ROOT/scripts/lib/hyperdx-port-forward.sh"
start_hyperdx_port_forward
ok "Port-forward temporário para o HyperDX em localhost:${HDX_APP_PORT} (UI) e localhost:${HDX_API_PORT} (API v2)"
INGESTION_KEY="$(run "Registrar o usuário instrutor e obter a ingestion key" \
  "O primeiro usuário cria a equipe no HyperDX; a partir daí o collector EXIGE a ingestion key da equipe no header 'authorization'. As credenciais geradas ficam em .workshop/hyperdx-credentials.json (a chave em si não é exibida)." \
  python3 "$REPO_ROOT/observability/clickstack/bootstrap.py" --app-url "http://localhost:${HDX_APP_PORT}" \
    --api-url "http://localhost:${HDX_API_PORT}" --creds "$STATE_DIR/hyperdx-credentials.json" | tail -1)"
[[ -n "$INGESTION_KEY" ]] || fail "Não foi possível obter a ingestion key"
run "Guardar a ingestion key em um Secret" \
  "O gateway OTel lê a chave deste Secret (variável CLICKSTACK_INGESTION_KEY), sem expô-la em values ou ConfigMaps." \
  bash -c "kubectl -n observability create secret generic clickstack-ingestion --from-literal=api-key='$INGESTION_KEY' --dry-run=client -o yaml | kubectl apply -f -"
run "Publicar o nome do cluster para o gateway" "Vira o atributo k8s.cluster.name em toda a telemetria." \
  bash -c "kubectl -n observability create configmap otel-cluster-info --from-literal=cluster-name='$CLUSTER_NAME' --dry-run=client -o yaml | kubectl apply -f -"

# ---------------------------------------------------------------- 8. OpenTelemetry Collectors
section "8/9 · OpenTelemetry Collectors"
run "Instalar o OTel Collector gateway (Deployment)" \
  "Recebe OTLP das 3 APIs, enriquece com metadados Kubernetes (k8sattributes), coleta métricas do cluster (Pods Pending, restarts, réplicas) e eventos (FailedScheduling, Preempted, OOMKilling) e envia tudo ao ClickStack com a ingestion key." \
  helm upgrade --install otel-gateway open-telemetry/opentelemetry-collector -n observability \
    --version "$OTEL_COLLECTOR_CHART_VERSION" -f "$REPO_ROOT/observability/otel/gateway-values.yaml" --wait --timeout 5m
run "Instalar o OTel Collector agent (DaemonSet)" \
  "Um por nó: métricas do kubelet (CPU/memória por Pod e uso vs requests/limits) e logs de containers dos outros namespaces (ex.: Cluster Autoscaler). O namespace ecommerce é excluído porque as APIs já mandam logs via OTLP (evita duplicidade)." \
  helm upgrade --install otel-agent open-telemetry/opentelemetry-collector -n observability \
    --version "$OTEL_COLLECTOR_CHART_VERSION" -f "$REPO_ROOT/observability/otel/agent-values.yaml" --wait --timeout 5m
run "Reiniciar o gateway" "Garante que ele leia a versão atual do Secret da ingestion key (relevante em reexecuções)." \
  kubectl -n observability rollout restart deploy/otel-gateway

# ---------------------------------------------------------------- 9. Webhook + alertas
section "9/9 · Webhook e os 4 alertas (anti-pattern intencional)"
run "Publicar o código do receptor de webhooks" "ConfigMap com observability/alerts/webhook/receiver.py (só stdlib, sem imagem própria)." \
  bash -c "kubectl -n observability create configmap alert-webhook-code --from-file=receiver.py='$REPO_ROOT/observability/alerts/webhook/receiver.py' --dry-run=client -o yaml | kubectl apply -f -"
run "Implantar o receptor de webhooks" "O HyperDX enviará os alertas para http://alert-webhook.observability:8080/alerts." \
  kubectl apply -f "$REPO_ROOT/observability/alerts/webhook.yaml"
run "Aguardar o receptor" "Readiness em /healthz." \
  kubectl -n observability rollout status deploy/alert-webhook --timeout=3m
run "Criar webhook, saved searches e os 4 alertas no HyperDX" \
  "Via External API v2. Cada alerta conta logs ERROR por serviço/rota (≥5 em 5 min) — um ANTI-PATTERN INTENCIONAL que o LAB X1 desmonta: uma requisição pode gerar vários logs e outra pode falhar sem log nenhum." \
  python3 "$REPO_ROOT/observability/alerts/create_alerts.py" --app-url "http://localhost:${HDX_APP_PORT}" \
    --api-url "http://localhost:${HDX_API_PORT}" --creds "$STATE_DIR/hyperdx-credentials.json" \
    --webhook-url "http://alert-webhook.observability.svc.cluster.local:8080/alerts"
stop_hyperdx_port_forward

ok "Setup concluído. Próximo passo: scripts/deploy.sh (ou make deploy)"
