#!/usr/bin/env bash
# Executa um script k6 DENTRO do cluster (Job no namespace loadtest, nó de observabilidade),
# isolando o gerador de carga dos nós "apps" e evitando gargalos de port-forward.
# Uso: scripts/k6.sh <script.js> [VAR=valor ...]
#  ex: scripts/k6.sh stress-orders.js RATE=60 DURATION=6m
source "$(dirname "$0")/lib/common.sh"
require kubectl
script="${1:?uso: scripts/k6.sh <script.js> [VAR=valor ...]}"; shift
[[ -f "$REPO_ROOT/load-tests/$script" ]] || fail "Script inexistente: load-tests/$script"

name="k6-$(basename "$script" .js | tr '_' '-')-$(date +%H%M%S)"
args=("run" "--quiet" "/scripts/$script" "-e" "BASE_URL=http://bff-api.ecommerce.svc.cluster.local:8080" "-e" "RUN_ID=$name")
for kv in "$@"; do args+=("-e" "$kv"); done

files=()
for f in "$REPO_ROOT"/load-tests/*.js; do files+=("--from-file=$(basename "$f")=$f"); done
files+=("--from-file=lib__common.js=$REPO_ROOT/load-tests/lib/common.js")
kubectl -n loadtest create configmap k6-scripts "${files[@]}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

items="$(for f in "$REPO_ROOT"/load-tests/*.js; do b=$(basename "$f"); printf '{"key":"%s","path":"%s"},' "$b" "$b"; done)"
items="${items}{\"key\":\"lib__common.js\",\"path\":\"lib/common.js\"}"
json_args="$(printf '"%s",' "${args[@]}")"; json_args="[${json_args%,}]"

kubectl apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${name}
  namespace: loadtest
  labels: {app.kubernetes.io/name: k6, app.kubernetes.io/part-of: reliability-workshop}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels: {app.kubernetes.io/name: k6}
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      nodeSelector: {workload: observability}
      tolerations: [{key: workload, operator: Equal, value: observability, effect: NoSchedule}]
      securityContext: {runAsNonRoot: true, runAsUser: 12345, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: k6
          image: ${K6_IMAGE}
          args: ${json_args}
          resources: {requests: {cpu: 250m, memory: 256Mi}, limits: {cpu: "1", memory: 1Gi}}
          securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
          volumeMounts: [{name: scripts, mountPath: /scripts}, {name: tmp, mountPath: /tmp}]
      volumes:
        - name: scripts
          configMap: {name: k6-scripts, items: [${items}]}
        - name: tmp
          emptyDir: {}
YAML
info "Job loadtest/${name} criado; acompanhando logs (Ctrl+C não interrompe o Job)"
kubectl -n loadtest wait --for=condition=Ready pod -l "job-name=${name}" --timeout=180s >/dev/null 2>&1 || true
kubectl -n loadtest logs -f "job/${name}" || true
for _ in $(seq 1 30); do
  succeeded="$(kubectl -n loadtest get job "$name" -o jsonpath='{.status.succeeded}')"
  failed="$(kubectl -n loadtest get job "$name" -o jsonpath='{.status.failed}')"
  [[ "$succeeded" == "1" ]] && { ok "k6 concluído com sucesso (thresholds OK)"; exit 0; }
  [[ "$failed" == "1" ]] && fail "k6 terminou com falha (thresholds/checks violados) — Job ${name}"
  sleep 2
done
warn "Job ${name} ainda em execução"
