#!/usr/bin/env bash
# Valida os critérios de aceitação "baseline" do MVP no cluster real e gera
# .workshop/validation-report.md. HPA, Cluster Autoscaler, QoS, preemption e Circuit
# Breaker são validados pelos laboratórios (labs/lab-0X/verify.sh).
# Uso: scripts/validate.sh [--quick]   (--quick pula o teste k6 de concorrência)
source "$(dirname "$0")/lib/common.sh"
source "$REPO_ROOT/scripts/lib/cluster-helpers.sh"
require aws kubectl python3
REPORT="$STATE_DIR/validation-report.md"
declare -a ROWS
check() { # nome, comando...
  local name="$1"; shift
  if out="$("$@" 2>&1)"; then ok "$name"; ROWS+=("| ✅ | $name | ${out//|/\\|} |")
  else warn "$name"; ROWS+=("| ❌ | $name | ${out//|/\\|} |"); fi
}

cluster_active() { s="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.[status,version]' --output text)"; echo "$s"; [[ "$s" == ACTIVE* ]]; }
nodegroups_ok() {
  for ng in apps observability; do
    st="$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" --region "$AWS_REGION" --query nodegroup.status --output text)"
    echo -n "$ng=$st "; [[ "$st" == ACTIVE ]] || return 1
  done
  ready="$(kubectl get nodes --no-headers | awk '$2=="Ready"' | wc -l | tr -d ' ')"; echo "nodes_ready=$ready"; [[ "$ready" -ge 3 ]]
}
metrics_server() { kubectl top nodes --no-headers | head -3 | tr '\n' ';'; }
cluster_autoscaler() { kubectl -n kube-system rollout status deploy -l app.kubernetes.io/name=aws-cluster-autoscaler --timeout=10s >/dev/null && kubectl -n kube-system get deploy -l app.kubernetes.io/name=aws-cluster-autoscaler -o jsonpath='{.items[0].spec.template.spec.containers[0].image}'; }
apis_ready() {
  for d in bff-api orders-api inventory-api; do
    r="$(kubectl -n ecommerce get deploy "$d" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}')"; echo -n "$d=$r "
    [[ "${r%/*}" == "${r#*/}" && "${r%/*}" -ge 1 ]] || return 1
  done
}

KEY="$(python3 -c 'import uuid; print(uuid.uuid4())')"
CUSTOMER="customer-validate-$(date +%s)"
PAYLOAD="{\"customer_id\":\"$CUSTOMER\",\"items\":[{\"sku\":\"product-001\",\"quantity\":2,\"unit_price\":\"49.90\"}]}"
create_order() {
  IFS=$'\t' read -r status replayed body < <(bff_request POST /orders "$PAYLOAD" "$KEY")
  echo "HTTP $status replayed=$replayed"; [[ "$status" == 201 ]] || { echo "$body"; return 1; }
  # check() executa em subshell: o order_id é compartilhado via arquivo.
  json_field "['order_id']" <<<"$body" > "$STATE_DIR/validate-order-id"
  echo "order_id=$(cat "$STATE_DIR/validate-order-id") status=$(json_field "['status']" <<<"$body")"
}
order_id() { cat "$STATE_DIR/validate-order-id"; }
reservation_ok() { admin_call inventory-api GET /admin/state | grep -oE '"reservations_total": *[0-9]+'; }
persisted() { aws dynamodb get-item --region "$AWS_REGION" --table-name "$TABLE_NAME" --key "{\"PK\":{\"S\":\"ORDER#$(order_id)\"},\"SK\":{\"S\":\"META\"}}" --query 'Item.status.S' --output text | grep CONFIRMED; }
queryable() { IFS=$'\t' read -r status _ body < <(bff_request GET "/orders/$(order_id)"); echo "HTTP $status"; [[ "$status" == 200 ]]; }
replay() {
  IFS=$'\t' read -r status replayed body < <(bff_request POST /orders "$PAYLOAD" "$KEY")
  echo "HTTP $status replayed=$replayed"; [[ "$status" == 201 && "$replayed" == true && "$(json_field "['order_id']" <<<"$body")" == "$(order_id)" ]]
}
concurrency() { "$REPO_ROOT/scripts/k6.sh" idempotency-concurrency.js | grep -E "pedidos persistidos|idempotency_violations|✓|✗" | tr '\n' ' '; }
iam() { "$REPO_ROOT/scripts/validate-iam.sh" | tail -1; }
telemetry() {
  q="SELECT ServiceName, count() FROM otel_logs WHERE Timestamp > now() - INTERVAL 30 MINUTE AND ServiceName IN ('bff-api','orders-api','inventory-api') GROUP BY 1 ORDER BY 1"
  logs="$(clickhouse_query "$q" | tr '\t\n' '= ')"; echo -n "logs: $logs; "
  traces="$(clickhouse_query "SELECT uniqExact(ServiceName) FROM otel_traces WHERE Timestamp > now() - INTERVAL 30 MINUTE AND TraceId IN (SELECT TraceId FROM otel_traces WHERE ServiceName='inventory-api' AND Timestamp > now() - INTERVAL 30 MINUTE) AND ServiceName IN ('bff-api','orders-api','inventory-api')")"
  echo -n "serviços por trace=$traces; "
  http="$(clickhouse_query "SELECT count() FROM otel_metrics_histogram WHERE MetricName='http.server.request.duration' AND TimeUnix > now() - INTERVAL 30 MINUTE")"
  k8s="$(clickhouse_query "SELECT count() FROM otel_metrics_gauge WHERE MetricName IN ('k8s.pod.phase','k8s.pod.cpu.usage') AND TimeUnix > now() - INTERVAL 30 MINUTE")"
  echo "http_metrics=$http k8s_metrics=$k8s"
  [[ "$traces" -ge 3 && "$http" -gt 0 && "$k8s" -gt 0 && "$logs" == *orders-api* ]]
}
alerts() {
  source "$REPO_ROOT/scripts/lib/hyperdx-port-forward.sh"; start_hyperdx_port_forward
  n="$(python3 - "$HDX_APP_PORT" "$HDX_API_PORT" "$STATE_DIR/hyperdx-credentials.json" <<'PY'
import os, sys; from pathlib import Path
sys.path.insert(0, os.environ["REPO_ROOT"] + "/observability/clickstack")
from hyperdx import connect
h = connect(f"http://localhost:{sys.argv[1]}", f"http://localhost:{sys.argv[2]}", Path(sys.argv[3]))
names = {"Orders Creation Errors", "Orders Query Errors", "Inventory Creation Errors", "Inventory Query Errors"}
found = [a for a in h.v2("GET", "/alerts") if a.get("name") in names]
print(len(found), ";".join(f"{a['name']}={a.get('state')}" for a in found))
PY
)"; stop_hyperdx_port_forward; echo "$n"; [[ "$n" == 4* ]]
}

info "Validando ambiente ${CLUSTER_NAME} (${AWS_REGION})"
check "EKS provisionado" cluster_active
check "Managed Node Groups operacionais" nodegroups_ok
check "Metrics Server funcionando" metrics_server
check "Cluster Autoscaler em execução" cluster_autoscaler
check "Três APIs Ready" apis_ready
check "Pedido criado pela BFF (CONFIRMED)" create_order
check "Reserva de estoque registrada" reservation_ok
check "Pedido persistido no DynamoDB" persisted
check "Pedido consultável (GET /orders/{id})" queryable
check "Retry com mesma chave = replay do mesmo pedido" replay
[[ "${1:-}" == "--quick" ]] || check "Idempotência sob concorrência (k6, 20 requisições)" concurrency
check "EKS Pod Identity + isolamento IAM" iam
check "Métricas, logs e traces no ClickStack" telemetry
check "Quatro alertas configurados no HyperDX" alerts

{
  echo "# Relatório de validação — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo; echo "Cluster: \`${CLUSTER_NAME}\` · Região: \`${AWS_REGION}\` · Conta: \`$(account_id)\`"; echo
  echo "| | Critério | Evidência |"; echo "|---|---|---|"
  printf '%s\n' "${ROWS[@]}"
} > "$REPORT"
info "Relatório: $REPORT"
! grep -q '| ❌ |' "$REPORT"
