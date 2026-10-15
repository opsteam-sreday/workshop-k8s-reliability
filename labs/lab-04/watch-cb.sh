#!/usr/bin/env bash
# Mostra o estado do Circuit Breaker de CADA réplica da Orders API a cada 3s.
source "$(dirname "$0")/../../scripts/lib/common.sh"
set +e   # painel contínuo: erros transitórios do kubectl não devem encerrar o loop
while true; do
  printf '\n%s\n' "$(date +%T)"
  admin_call orders-api GET /admin/circuit-breaker 2>/dev/null | python3 -c '
import json, sys
for line in sys.stdin:
    pod, _, body = line.partition(": ")
    try:
        s = json.loads(body)
        print(f"  {pod:<40} {s[\"state\"]:<9} falhas_consecutivas={s[\"consecutive_failures\"]} open_restante={s[\"open_remaining_seconds\"]}s")
    except ValueError:
        print("  " + line.strip())'
  sleep 3
done
