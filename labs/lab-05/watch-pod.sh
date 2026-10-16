#!/usr/bin/env bash
# Painel do LAB 05: a cada 1 s, READY e RESTARTS de UM Pod e se ele recebe tráfego (EndpointSlice do Service).
# Só imprime quando algo muda, com o segundo em que mudou.
# Uso: labs/lab-05/watch-pod.sh <pod> [service=orders-api]
source "$(dirname "$0")/../../scripts/lib/common.sh"
require kubectl
pod="${1:?uso: watch-pod.sh <pod> [service]}"; svc="${2:-orders-api}"
set +e   # painel contínuo: erros transitórios do kubectl (Pod reiniciando) não devem encerrar o loop
t0=$(date +%s); last=""
echo "Observando ${pod} (Service ${svc}). Ctrl+C para sair."
while true; do
  read -r ip ready restarts <<<"$(kubectl -n ecommerce get pod "$pod" \
    -o jsonpath='{.status.podIP} {.status.containerStatuses[0].ready} {.status.containerStatuses[0].restartCount}' 2>/dev/null)"
  ep="$(kubectl -n ecommerce get endpointslices -l "kubernetes.io/service-name=${svc}" \
    -o jsonpath="{range .items[*].endpoints[?(@.addresses[0]==\"${ip}\")]}{.conditions.ready}{end}" 2>/dev/null)"
  now="READY=${ready:-?}  RESTARTS=${restarts:-?}  recebe-tráfego=${ep:-não (fora do EndpointSlice)}"
  if [[ "$now" != "$last" ]]; then
    printf '%s  t=%3ss  %s\n' "$(date +%T)" "$(( $(date +%s) - t0 ))" "$now"; last="$now"
  fi
  sleep 1
done
