#!/usr/bin/env bash
# Remove TODOS os recursos do workshop (Kubernetes, volumes EBS, IAM, DynamoDB, ECR e EKS).
source "$(dirname "$0")/lib/common.sh"
require aws kubectl eksctl helm
account_id >/dev/null
# Imagens ECR são compartilhadas pelos clusters da conta: só saem no ambiente único ou com DELETE_IMAGES=true.
DELETE_IMAGES="${DELETE_IMAGES:-$([[ "$CLUSTER_NAME" == "reliability-workshop" ]] && echo true || echo false)}"
warn "Isto removerá o cluster ${CLUSTER_NAME}, a tabela ${TABLE_NAME}, as roles ${ORDERS_ROLE_NAME}/${STUDENT_ROLE_NAME}$([[ "$DELETE_IMAGES" == true ]] && echo ", os repositórios ECR ${ECR_PREFIX}/*") e os volumes EBS do workshop (conta ${AWS_ACCOUNT_ID}, ${AWS_REGION})."
confirm "Confirmar remoção definitiva?" || fail "Cancelado"

if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" --alias "$CLUSTER_NAME" >/dev/null
  kubectl config use-context "$CLUSTER_NAME" >/dev/null
  info "Removendo workloads e releases Helm"
  kubectl delete namespace ecommerce loadtest --ignore-not-found --wait=true --timeout=5m || true
  for rel in otel-agent otel-gateway clickstack; do helm uninstall "$rel" -n observability --wait --timeout 10m 2>/dev/null || true; done
  # Os volumes EBS só são apagados quando os PVCs são removidos (reclaimPolicy: Delete).
  kubectl -n observability delete pvc --all --wait=true --timeout=10m 2>/dev/null || true
  helm uninstall clickstack-operators -n observability --wait --timeout 5m 2>/dev/null || true
  helm uninstall cluster-autoscaler -n kube-system --wait 2>/dev/null || true
  kubectl delete namespace observability --ignore-not-found --wait=true --timeout=5m || true
  kubectl delete validatingadmissionpolicybinding,validatingadmissionpolicy restrict-orders-api-sa --ignore-not-found || true
  info "Aguardando liberação dos volumes EBS"
  for _ in $(seq 1 30); do
    [[ "$(kubectl get pv --no-headers 2>/dev/null | wc -l | tr -d ' ')" == 0 ]] && break; sleep 10
  done
fi

"$REPO_ROOT/infrastructure/pod-identity.sh" delete || true
"$REPO_ROOT/infrastructure/student-access.sh" delete || true
"$REPO_ROOT/infrastructure/dynamodb.sh" delete || true
"$REPO_ROOT/scripts/hyperdx-credentials.sh" delete || true

if [[ "$DELETE_IMAGES" == true ]]; then
  for svc in bff-api orders-api inventory-api; do
    aws ecr delete-repository --repository-name "${ECR_PREFIX}/${svc}" --region "$AWS_REGION" --force >/dev/null 2>&1 \
      && ok "ECR ${ECR_PREFIX}/${svc} removido" || true
  done
else
  ok "Imagens ECR ${ECR_PREFIX}/* mantidas (compartilhadas; DELETE_IMAGES=true para remover)"
fi

if eksctl get cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  info "Removendo cluster EKS (≈10-15 min)"
  eksctl delete cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --wait --disable-nodegroup-eviction
fi
# A VPC é criada fora do eksctl (infrastructure/vpc/), então sai depois do cluster.
"$REPO_ROOT/infrastructure/vpc/vpc.sh" delete || warn "VPC ${CLUSTER_NAME}-vpc não removida (ENIs ainda em uso? repita o teardown)"

info "Verificando recursos remanescentes"
left_vol="$(aws ec2 describe-volumes --region "$AWS_REGION" --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" --query 'Volumes[].VolumeId' --output text)"
left_stacks="$(aws cloudformation list-stacks --region "$AWS_REGION" --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_FAILED --query "StackSummaries[?starts_with(StackName, 'eksctl-${CLUSTER_NAME}') || StackName=='${CLUSTER_NAME}-vpc'].StackName" --output text)"
[[ -z "$left_vol" ]] && ok "Nenhum volume EBS remanescente" || warn "Volumes EBS remanescentes: $left_vol (remova com aws ec2 delete-volume)"
[[ -z "$left_stacks" ]] && ok "Nenhuma stack CloudFormation remanescente" || warn "Stacks remanescentes: $left_stacks"
rm -rf "$OVERLAY_DIR"
ok "Teardown concluído"
