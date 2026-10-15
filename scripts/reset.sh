#!/usr/bin/env bash
# Retorna o ambiente ao estado inicial ENTRE laboratórios (não remove infraestrutura).
source "$(dirname "$0")/lib/common.sh"
require kubectl

info "Removendo artefatos de laboratório"
kubectl -n loadtest delete jobs -l app.kubernetes.io/name=k6 --ignore-not-found --wait=false >/dev/null
kubectl -n loadtest delete pod noisy-neighbor --ignore-not-found >/dev/null
kubectl -n loadtest delete pod -l app.kubernetes.io/name=capacity-ballast --ignore-not-found >/dev/null
kubectl -n ecommerce get pods -o name | grep "pod/iam-probe-" | xargs -r kubectl -n ecommerce delete --ignore-not-found >/dev/null || true

info "Restaurando manifests base (perfil Burstable, Inventory com critical-services, HPA, ORDERS_CPU_WORK_MS=0)"
if [[ -f "$OVERLAY_DIR/kustomization.yaml" ]]; then
  kubectl apply -k "$OVERLAY_DIR" >/dev/null
  # `kubectl apply` não remove campos adicionados por `kubectl patch/set` fora do manifest.
  kubectl -n ecommerce patch deploy inventory-api --patch-file "$REPO_ROOT/kubernetes/labs/priority/inventory-restore-priority.patch.yaml" >/dev/null
  kubectl -n ecommerce set env deploy/orders-api ORDERS_CPU_WORK_MS- >/dev/null 2>&1 || true
  kubectl -n ecommerce patch deploy inventory-api --type json --patch-file "$REPO_ROOT/kubernetes/labs/qos/inventory-burstable.patch.json" >/dev/null
else
  warn "Overlay gerado ausente — execute scripts/deploy.sh"
fi

info "Cluster Autoscaler ativo (1 réplica)"
kubectl -n kube-system scale deploy -l app.kubernetes.io/name=aws-cluster-autoscaler --replicas=1 >/dev/null

for d in bff-api orders-api inventory-api; do kubectl -n ecommerce rollout status "deploy/$d" --timeout=5m >/dev/null; done
info "Limpando falhas injetadas e Circuit Breakers"
"$REPO_ROOT/scripts/fault.sh" all reset >/dev/null
ok "Ambiente resetado"
