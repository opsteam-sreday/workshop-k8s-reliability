#!/usr/bin/env bash
# Port-forward temporário para o HyperDX (UI/API interna 3000 e External API v2 8000).
HDX_APP_PORT="${HDX_APP_PORT:-3000}"
HDX_API_PORT="${HDX_API_PORT:-8000}"

start_hyperdx_port_forward() {
  kubectl -n observability port-forward svc/clickstack-app "${HDX_APP_PORT}:3000" "${HDX_API_PORT}:8000" \
    >"$STATE_DIR/port-forward.log" 2>&1 &
  HDX_PF_PID=$!
  trap stop_hyperdx_port_forward EXIT
  for _ in $(seq 1 60); do
    curl -fs "http://localhost:${HDX_APP_PORT}/api/installation" >/dev/null 2>&1 && return 0
    sleep 2
  done
  fail "HyperDX não respondeu via port-forward (ver $STATE_DIR/port-forward.log)"
}

stop_hyperdx_port_forward() {
  if [[ -n "${HDX_PF_PID:-}" ]]; then kill "$HDX_PF_PID" 2>/dev/null || true; HDX_PF_PID=""; fi
}
