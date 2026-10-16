#!/usr/bin/env bash
# Aplica um perfil de QoS na Inventory API e mostra a QoSClass resultante.
# Uso: labs/lab-05/qos.sh besteffort|burstable|guaranteed
source "$(dirname "$0")/../../scripts/lib/common.sh"
profile="${1:?uso: qos.sh besteffort|burstable|guaranteed}"
kubectl -n ecommerce patch deploy inventory-api --type json --patch-file "$REPO_ROOT/kubernetes/labs/qos/inventory-${profile}.patch.json"
kubectl -n ecommerce rollout status deploy/inventory-api --timeout=3m
kubectl -n ecommerce get pod -l app.kubernetes.io/name=inventory-api \
  -o custom-columns=POD:.metadata.name,QOS:.status.qosClass,NODE:.spec.nodeName,REQUESTS:.spec.containers[0].resources.requests,LIMITS:.spec.containers[0].resources.limits
