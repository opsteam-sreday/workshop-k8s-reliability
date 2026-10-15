#!/usr/bin/env bash
# Painel de terminal do LAB 02: HPA, Pods da Orders API, Pods Pending e nós (atualiza a cada 5s).
source "$(dirname "$0")/../../scripts/lib/common.sh"
set +e   # painel contínuo: erros transitórios do kubectl não devem encerrar o loop
while true; do
  clear
  date '+%H:%M:%S'
  echo "── HPA ──────────────────────────────────────────────"; kubectl -n ecommerce get hpa orders-api
  echo "── Orders API (réplicas) ────────────────────────────"
  kubectl -n ecommerce get pods -l app.kubernetes.io/name=orders-api --no-headers \
    | awk '{print $3}' | sort | uniq -c
  echo "── Pods Pending (todos os namespaces) ───────────────"
  kubectl get pods -A --field-selector=status.phase=Pending --no-headers 2>/dev/null | head -10
  echo "── Nós apps ─────────────────────────────────────────"; kubectl get nodes -l workload=apps
  echo "── CPU (Metrics Server) ─────────────────────────────"; kubectl -n ecommerce top pods -l app.kubernetes.io/name=orders-api 2>/dev/null | head -14
  sleep 5
done
