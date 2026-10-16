#!/usr/bin/env bash
# Injeção de falhas de laboratório via API admin (127.0.0.1:8081, acessível apenas por kubectl exec).
#
# Inventory API:
#   fault.sh inventory latency <ms> [ALL|RESERVATIONS|QUERIES]     atraso antes de processar
#   fault.sh inventory slow-after-commit <ms>                     aplica a reserva e atrasa a resposta
#   fault.sh inventory http-503 [ALL|RESERVATIONS|QUERIES]          sempre 503
#   fault.sh inventory error-rate <0..1> [ALL|RESERVATIONS|QUERIES] 503 aleatório
#   fault.sh inventory cpu-per-request <ms>                       CPU burn em cada requisição
#   fault.sh inventory cpu-burn <workers 0..4>                    processos consumindo 1 core cada
#   fault.sh inventory memory <MB>                                memory ballast (cresce 16 MiB/250 ms)
#   fault.sh inventory concurrency <n>                            limite de requisições simultâneas
#   fault.sh inventory state | reset-stock
# Orders API (aplica em TODOS os Pods em execução):
#   fault.sh orders cpu-work <ms> | db <NONE|FAIL_READS|FAIL_WRITES|FAIL_TRANSACT|TRANSACT_UNKNOWN_AFTER_COMMIT|FAIL_ALL>
#   fault.sh orders crash-after-reservation | inventory-timeout <ms> | cb | cb-reset
# BFF API:
#   fault.sh bff timeout <ms>
# Probes (LAB 02; <pod> obrigatório para não atingir todas as réplicas):
#   fault.sh <inventory|orders|bff> not-ready <pod>       readiness 503, liveness 200 (sai do Service, não reinicia)
#   fault.sh <inventory|orders|bff> ready [pod]           desfaz o not-ready (sem pod: todos)
#   fault.sh <inventory|orders|bff> freeze <s> <pod>      trava o event loop por <s> s (1..300): probes sem resposta
#   fault.sh <inventory|orders|bff> health [pod]          started / shutting_down / forced_not_ready
# Geral:
#   fault.sh <inventory|orders|bff> status|reset      fault.sh all reset
source "$(dirname "$0")/lib/common.sh"
require kubectl

svc="${1:?serviço: inventory|orders|bff|all}"; action="${2:-status}"; arg="${3:-}"
put() { admin_call "$1" PUT /admin/faults "$2"; }
deploy_of() { case "$1" in inventory) echo inventory-api ;; orders) echo orders-api ;; bff) echo bff-api ;; *) echo "" ;; esac; }

case "$action" in
  not-ready|ready|freeze|health)
    d="$(deploy_of "$svc")"; [[ -n "$d" ]] || fail "serviço inválido para ${action}: ${svc}"
    case "$action" in
      not-ready) ADMIN_POD="${arg:?pod}" admin_call "$d" PUT /admin/health '{"ready":false}' ;;
      ready)     ADMIN_POD="${arg:-}" admin_call "$d" PUT /admin/health '{"ready":true}' ;;
      freeze)    ADMIN_POD="${4:?pod}" admin_call "$d" POST "/admin/health/freeze?seconds=${arg:?segundos}" ;;
      health)    ADMIN_POD="${arg:-}" admin_call "$d" GET /admin/health ;;
    esac
    exit 0 ;;
esac

case "$svc:$action" in
  inventory:latency)            put inventory-api "{\"fault_mode\":\"LATENCY\",\"latency_ms\":${arg:?ms},\"fault_target\":\"${4:-ALL}\"}" ;;
  inventory:slow-after-commit)  put inventory-api "{\"fault_mode\":\"SLOW_AFTER_COMMIT\",\"latency_ms\":${arg:?ms},\"fault_target\":\"RESERVATIONS\"}" ;;
  inventory:http-503)           put inventory-api "{\"fault_mode\":\"HTTP_503\",\"fault_target\":\"${arg:-ALL}\"}" ;;
  inventory:error-rate)         put inventory-api "{\"fault_mode\":\"ERROR_RATE\",\"error_rate\":${arg:?rate},\"fault_target\":\"${4:-ALL}\"}" ;;
  inventory:cpu-per-request)    put inventory-api "{\"cpu_stress_enabled\":true,\"cpu_stress_duration_ms\":${arg:?ms}}" ;;
  inventory:cpu-burn)           put inventory-api "{\"cpu_stress_workers\":${arg:?workers}}" ;;
  inventory:memory)             put inventory-api "{\"memory_stress_mb\":${arg:?MB}}" ;;
  inventory:concurrency)        put inventory-api "{\"max_concurrent_requests\":${arg:?n}}" ;;
  inventory:state)              admin_call inventory-api GET /admin/state ;;
  inventory:reset-stock)        admin_call inventory-api POST /admin/reset-stock ;;
  orders:cpu-work)              put orders-api "{\"cpu_work_ms\":${arg:?ms}}" ;;
  orders:db)                    put orders-api "{\"db_fault_mode\":\"${arg:?modo}\"}" ;;
  orders:crash-after-reservation) put orders-api '{"crash_after_reservation":true}' ;;
  orders:inventory-timeout)     put orders-api "{\"inventory_timeout_ms\":${arg:?ms}}" ;;
  orders:cb)                    admin_call orders-api GET /admin/circuit-breaker ;;
  orders:cb-reset)              admin_call orders-api POST /admin/circuit-breaker/reset ;;
  bff:timeout)                  put bff-api "{\"orders_timeout_ms\":${arg:?ms}}" ;;
  inventory:status)             admin_call inventory-api GET /admin/faults ;;
  orders:status)                admin_call orders-api GET /admin/faults ;;
  bff:status)                   admin_call bff-api GET /admin/faults ;;
  inventory:reset)              admin_call inventory-api POST /admin/faults/reset ;;
  orders:reset)                 admin_call orders-api POST /admin/faults/reset ;;
  bff:reset)                    admin_call bff-api POST /admin/faults/reset ;;
  all:reset)
    for d in inventory-api orders-api bff-api; do
      admin_call "$d" POST /admin/faults/reset
      admin_call "$d" PUT /admin/health '{"ready":true}'
    done
    admin_call orders-api POST /admin/circuit-breaker/reset ;;
  *) sed -n '2,27p' "$0"; exit 1 ;;
esac
