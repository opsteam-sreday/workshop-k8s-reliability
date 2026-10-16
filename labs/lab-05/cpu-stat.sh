#!/usr/bin/env bash
# Mostra o throttling de CPU (cgroup v2) do container da Inventory API a cada 5s.
source "$(dirname "$0")/../../scripts/lib/common.sh"
set +e   # painel contínuo: erros transitórios do kubectl não devem encerrar o loop
pod="$(kubectl -n ecommerce get pod -l app.kubernetes.io/name=inventory-api -o jsonpath='{.items[0].metadata.name}')"
while true; do
  stat="$(kubectl -n ecommerce exec "$pod" -c app -- cat /sys/fs/cgroup/cpu.stat 2>/dev/null | tr '\n' ' ')"
  max="$(kubectl -n ecommerce exec "$pod" -c app -- cat /sys/fs/cgroup/cpu.max 2>/dev/null)"
  printf '%s cpu.max=[%s] %s\n' "$(date +%T)" "$max" "$(grep -oE '(nr_periods|nr_throttled|throttled_usec) [0-9]+' <<<"$stat" | tr '\n' ' ')"
  sleep 5
done
