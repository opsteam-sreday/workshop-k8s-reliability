#!/usr/bin/env bash
# Retorna o ambiente ao estado inicial ENTRE laboratórios (não remove infraestrutura).
source "$(dirname "$0")/lib/common.sh"
require kubectl

info "Removendo artefatos de laboratório"
kubectl -n loadtest delete jobs -l app.kubernetes.io/name=k6 --ignore-not-found --wait=false >/dev/null
kubectl -n loadtest delete pod noisy-neighbor --ignore-not-found >/dev/null
kubectl -n loadtest delete pod -l app.kubernetes.io/name=capacity-ballast --ignore-not-found >/dev/null
kubectl uncordon -l workload=apps >/dev/null   # LAB 03/04 drenam um nó apps
for n in $(kubectl get nodes -l workload=apps -o name); do   # LAB 04 F: taints no nó A ("not found" = já limpo)
  for t in dedicated maintenance; do kubectl taint "$n" "$t-" >/dev/null 2>&1 || true; done
done
kubectl -n ecommerce get pods -o name | grep "pod/iam-probe-" | xargs -r kubectl -n ecommerce delete --ignore-not-found >/dev/null || true

info "Restaurando manifests base (perfil Burstable, Inventory com critical-services, HPA, ORDERS_CPU_WORK_MS=0)"
if [[ -f "$OVERLAY_DIR/kustomization.yaml" ]]; then
  kubectl apply -k "$OVERLAY_DIR" >/dev/null
else
  # Ambiente criado pelo GitHub Actions: o overlay ficou no runner. As restaurações abaixo não dependem dele.
  warn "Overlay gerado ausente (ambiente criado pelo pipeline?): restaurando só o que os labs alteram"
fi
# Sempre, com ou sem overlay: `kubectl apply` não remove campos adicionados por `kubectl patch/set` fora do manifest,
# e sem overlay nada foi reaplicado. Valores iguais aos de kubernetes/apps/*.
kubectl -n ecommerce patch deploy inventory-api --patch-file "$REPO_ROOT/kubernetes/labs/priority/inventory-restore-priority.patch.yaml" >/dev/null
kubectl -n ecommerce set env deploy/orders-api ORDERS_CPU_WORK_MS- SHUTDOWN_DELAY_SECONDS- ORDERS_TABLE_NAME- >/dev/null 2>&1 || true
kubectl -n ecommerce patch deploy inventory-api --type json --patch-file "$REPO_ROOT/kubernetes/labs/qos/inventory-burstable.patch.json" >/dev/null
kubectl -n ecommerce patch deploy orders-api --patch-file "$REPO_ROOT/kubernetes/labs/rollout/orders-safe-rollout.patch.yaml" >/dev/null   # LAB 03
kubectl -n ecommerce patch pdb orders-api --type merge --patch-file "$REPO_ROOT/kubernetes/labs/rollout/orders-pdb-restore.patch.yaml" >/dev/null   # LAB 03
kubectl -n ecommerce patch hpa orders-api -p '{"spec":{"minReplicas":2}}' >/dev/null 2>&1 || true   # LAB 04/06 alteram o mínimo
# LAB 04: affinity e tolerations aplicadas por patch não estão no manifest (patch sem mudança não dispara rollout).
for d in bff-api orders-api inventory-api; do
  kubectl -n ecommerce patch deploy "$d" --patch-file "$REPO_ROOT/kubernetes/labs/scheduling/clear-affinity.patch.yaml" >/dev/null
  kubectl -n ecommerce patch deploy "$d" --patch-file "$REPO_ROOT/kubernetes/labs/scheduling/clear-tolerations.patch.yaml" >/dev/null
done

info "Cluster Autoscaler ativo (1 réplica)"
kubectl -n kube-system scale deploy -l app.kubernetes.io/name=aws-cluster-autoscaler --replicas=1 >/dev/null

for d in bff-api orders-api inventory-api; do kubectl -n ecommerce rollout status "deploy/$d" --timeout=5m >/dev/null; done
info "Limpando falhas injetadas e Circuit Breakers"
"$REPO_ROOT/scripts/fault.sh" all reset >/dev/null
"$REPO_ROOT/scripts/fault.sh" inventory reset-stock >/dev/null   # LAB 03 reinicia a Inventory (estoque em memória)
ok "Ambiente resetado"
