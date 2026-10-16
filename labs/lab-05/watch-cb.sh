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
        # sem f-string com aspas escapadas: o python3 do macOS (3.9) não aceita "\" dentro de {}
        print("  %-40s %-9s falhas_consecutivas=%s open_restante=%ss"
              % (pod, s["state"], s["consecutive_failures"], s["open_remaining_seconds"]))
    except ValueError:
        print("  " + line.strip())'
  sleep 3
done
