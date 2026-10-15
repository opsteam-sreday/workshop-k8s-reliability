#!/usr/bin/env bash
# Helpers que executam dentro do cluster.

# HTTP via BFF a partir do próprio Pod da BFF (rede do cluster, sem port-forward).
# Uso: bff_request METHOD PATH [JSON] [IDEMPOTENCY_KEY]  -> imprime "STATUS<TAB>REPLAYED<TAB>BODY"
bff_request() {
  local pod
  pod="$(kubectl -n ecommerce get pod -l app.kubernetes.io/name=bff-api --field-selector=status.phase=Running -o go-template='{{range .items}}{{if not .metadata.deletionTimestamp}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | head -1)"
  kubectl -n ecommerce exec "$pod" -c app -- python -c '
import sys, urllib.request, urllib.error
method, path, body, key = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
headers = {"Content-Type": "application/json"}
if key: headers["Idempotency-Key"] = key
req = urllib.request.Request("http://127.0.0.1:8080" + path, method=method, data=body.encode() if body else None, headers=headers)
try:
    r = urllib.request.urlopen(req, timeout=15); status, h, data = r.status, r.headers, r.read()
except urllib.error.HTTPError as e:
    status, h, data = e.code, e.headers, e.read()
print(status, h.get("Idempotency-Replayed") or "", data.decode(), sep="\t")
' "$1" "$2" "${3:-}" "${4:-}"
}

# Consulta SQL no ClickHouse do ClickStack (usuário somente leitura "app").
clickhouse_query() {
  local pod
  pod="$(kubectl -n observability get pod -l app.kubernetes.io/name=clickhouse-server -o name 2>/dev/null | head -1 | cut -d/ -f2 || true)"
  [[ -n "$pod" ]] || pod="$(kubectl -n observability get pods -o name | grep -m1 'clickhouse-clickhouse-' | cut -d/ -f2 || true)"
  kubectl -n observability exec "$pod" -- clickhouse-client --user app --password "${CLICKHOUSE_APP_PASSWORD:-hyperdx}" \
    --format TSV --query "$1"
}

json_field() { python3 -c "import json,sys; print(json.loads(sys.stdin.read())$1)"; }
