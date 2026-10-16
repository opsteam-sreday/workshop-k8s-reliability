#!/usr/bin/env bash
# Configuração e funções compartilhadas por todos os scripts do workshop.
# Sobrescreva qualquer variável exportando-a antes de executar os scripts.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

export AWS_REGION="${AWS_REGION:-us-east-1}"
# Um cluster por aluno (mesma conta), inclusive o instrutor (ex.: aluno01): STUDENT_ID=aluno01 => cluster
# rw-aluno01 e TODOS os recursos com esse prefixo (tabela, role/policy da Orders API, role do aluno, secret do
# HyperDX). Ver scripts/fleet.sh. Scripts que não operam um cluster (imagens, locks, pipeline, Identity Center)
# definem WORKSHOP_NO_CLUSTER=true antes de carregar este arquivo.
if [[ -n "${STUDENT_ID:-}" ]]; then
  [[ "$STUDENT_ID" =~ ^[a-z0-9]{1,16}$ ]] || { echo "STUDENT_ID inválido: '$STUDENT_ID' (use [a-z0-9], até 16)" >&2; exit 1; }
  export CLUSTER_NAME="${CLUSTER_NAME:-rw-${STUDENT_ID}}"
fi
if [[ -z "${CLUSTER_NAME:-}" && "${WORKSHOP_NO_CLUSTER:-false}" != true ]]; then
  echo "Defina STUDENT_ID (ex.: export STUDENT_ID=aluno01 => cluster rw-aluno01; o instrutor usa o dele)" >&2; exit 1
fi
export CLUSTER_NAME="${CLUSTER_NAME:-}"
export K8S_VERSION="${K8S_VERSION:-1.36}"
export TABLE_NAME="${TABLE_NAME:-${CLUSTER_NAME}-orders}"
export ORDERS_ROLE_NAME="${ORDERS_ROLE_NAME:-${CLUSTER_NAME}-orders-api}"
export ORDERS_POLICY_NAME="${ORDERS_POLICY_NAME:-${CLUSTER_NAME}-orders-dynamodb}"
export STUDENT_ROLE_NAME="${STUDENT_ROLE_NAME:-${CLUSTER_NAME}-student}"
# Imagens compartilhadas por todos os clusters da conta (build único; os nós só fazem pull).
export ECR_PREFIX="${ECR_PREFIX:-reliability-workshop}"
export APPS_INSTANCE_TYPE="${APPS_INSTANCE_TYPE:-m6i.large}"
export OBS_INSTANCE_TYPE="${OBS_INSTANCE_TYPE:-m6i.xlarge}"
# Imagens: ver scripts/images.sh. Uma tag por app; cada tag é um índice multi-arch (amd64 + arm64).
APPS=(bff-api orders-api inventory-api)
IMAGE_ARCHS=(amd64 arm64)
# Tag = hash git do que entra no build da app (apps/<app>: código, Dockerfile, lock; apps/shared; .dockerignore).
# Muda só quando isso muda e é igual em qualquer clone/commit (inclusive shallow). IMAGE_TAG fixa uma tag manual.
image_tag() {
  [[ -n "${IMAGE_TAG:-}" ]] && { echo "$IMAGE_TAG"; return; }
  local trees
  trees="$(git -C "$REPO_ROOT" rev-parse "HEAD:apps/$1" HEAD:apps/shared HEAD:apps/.dockerignore 2>/dev/null)" || return 1
  git hash-object --stdin <<<"$trees" | cut -c1-12
}
export WORKSHOP_OWNER="${WORKSHOP_OWNER:-${USER:-workshop}}"

# Versões fixadas (verificadas em 2026-10-14 — ver README, seção "Versões").
export CLUSTER_AUTOSCALER_CHART_VERSION="${CLUSTER_AUTOSCALER_CHART_VERSION:-9.59.0}"
export CLUSTER_AUTOSCALER_IMAGE_TAG="${CLUSTER_AUTOSCALER_IMAGE_TAG:-v1.36.1}"
export CLICKSTACK_OPERATORS_CHART_VERSION="${CLICKSTACK_OPERATORS_CHART_VERSION:-1.1.0}"
export CLICKSTACK_CHART_VERSION="${CLICKSTACK_CHART_VERSION:-3.4.0}"
export OTEL_COLLECTOR_CHART_VERSION="${OTEL_COLLECTOR_CHART_VERSION:-0.176.0}"
export K6_IMAGE="${K6_IMAGE:-grafana/k6:2.3.0}"

# STATE_DIR / OVERLAY_DIR / KUBECONFIG podem ser isolados por cluster (scripts/fleet.sh faz isso para rodar
# vários setups em paralelo sem um sobrescrever o estado, o overlay ou o contexto kubectl do outro).
STATE_DIR="${STATE_DIR:-$REPO_ROOT/.workshop}"
mkdir -p "$STATE_DIR"
export STATE_DIR
export OVERLAY_DIR="${OVERLAY_DIR:-$REPO_ROOT/kubernetes/overlays/generated}"

c_blue=$'\033[1;34m'; c_green=$'\033[1;32m'; c_yellow=$'\033[1;33m'; c_red=$'\033[1;31m'; c_off=$'\033[0m'
info()  { echo "${c_blue}==>${c_off} $*"; }
ok()    { echo "${c_green}✔${c_off} $*"; }
warn()  { echo "${c_yellow}⚠${c_off} $*" >&2; }
fail()  { echo "${c_red}✘${c_off} $*" >&2; exit 1; }

require() {
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || fail "Ferramenta obrigatória ausente: $bin (ver README › Pré-requisitos)"
  done
}

account_id() {
  if [[ -z "${AWS_ACCOUNT_ID:-}" ]]; then
    AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
    export AWS_ACCOUNT_ID
  fi
  echo "$AWS_ACCOUNT_ID"
}

ecr_registry() { echo "$(account_id).dkr.ecr.${AWS_REGION}.amazonaws.com"; }

# Substitui ${VAR} pelo valor da variável de ambiente (sem depender de envsubst).
render() { perl -pe 's/\$\{(\w+)\}/exists $ENV{$1} ? $ENV{$1} : "\${$1}"/ge' "$1"; }

# Modo didático: run "Título" "Explicação" comando [args...]
# Mostra o que será feito, por quê, o comando exato, executa e informa o resultado.
# EXPLAIN=false desliga; EXPLAIN_PAUSE=true pausa antes de cada comando.
run() {
  local title="$1" why="$2"; shift 2
  "$REPO_ROOT/scripts/lib/explain.sh" "$title" "$why" -- "$@"
}

# Seção (agrupa vários passos)
section() { [[ "${EXPLAIN:-true}" == "false" ]] && return 0; printf '\n\033[1;35m━━━ %s ━━━\033[0m\n' "$*"; }

# Executa um comando com limite de tempo (portável: macOS não tem `timeout`).
with_timeout() { local secs="$1"; shift; perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; }

confirm() {
  local prompt="$1"
  if [[ "${ASSUME_YES:-false}" == "true" ]]; then return 0; fi
  read -r -p "$prompt [y/N] " answer
  [[ "$answer" =~ ^[yYsS]$ ]]
}

# Executa uma chamada HTTP na API administrativa (127.0.0.1:8081) de CADA Pod do deployment.
# Uso: admin_call <deployment> <METHOD> <path> [json]
admin_call() {   # ADMIN_POD=<nome> restringe a um único Pod (padrão: todos os Pods do Deployment)
  local deploy="$1" method="$2" path="$3" body="${4:-}"
  local pods
  # Somente Pods Running que NÃO estão em terminação (rollouts deixam Pods "Terminating" como Running).
  pods="$(kubectl -n ecommerce get pods -l "app.kubernetes.io/name=${deploy}" --field-selector=status.phase=Running \
    -o go-template='{{range .items}}{{if not .metadata.deletionTimestamp}}{{.metadata.name}} {{end}}{{end}}')"
  [[ -n "$pods" ]] || fail "Nenhum Pod Running para ${deploy}"
  if [[ -n "${ADMIN_POD:-}" ]]; then
    [[ " $pods " == *" ${ADMIN_POD} "* ]] || fail "Pod ${ADMIN_POD} não é um Pod Running de ${deploy} (disponíveis: ${pods})"
    pods="$ADMIN_POD"
  fi
  for pod in $pods; do
    printf '%s: ' "$pod"
    kubectl -n ecommerce exec "$pod" -c app -- python -c '
import sys, urllib.request
method, path, body = sys.argv[1], sys.argv[2], sys.argv[3]
req = urllib.request.Request("http://127.0.0.1:8081" + path, method=method,
                             data=body.encode() if body else None, headers={"Content-Type": "application/json"})
try:
    print(urllib.request.urlopen(req, timeout=10).read().decode())
except urllib.error.HTTPError as e:
    print(e.code, e.read().decode())
' "$method" "$path" "$body" || warn "falha ao chamar ${pod} (Pod reiniciando?)"
  done
}
