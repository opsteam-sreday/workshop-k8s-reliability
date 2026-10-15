#!/usr/bin/env bash
# Turma: um ambiente completo e ISOLADO por aluno, todos na mesma conta AWS.
#
# Cada aluno (linha do roster) recebe: cluster rw-<id> (VPC própria), tabela rw-<id>-orders, role de Pods
# rw-<id>-orders-api (Pod Identity, só a tabela dele) e role humana rw-<id>-student (só a sessão SSO dele).
# As imagens são construídas UMA vez (ECR compartilhado, somente pull pelos nós).
#
# Uso: scripts/fleet.sh <comando> <roster.csv>      (formato: infrastructure/students.example.csv)
#   quotas   compara as quotas da região com o necessário para a turma
#   up       build único + setup/deploy/acesso/validação de cada aluno em paralelo (PARALLEL=8)
#   access   (re)cria a role de cada aluno + access entry (após infrastructure/identity-center.sh)
#   status   estado do cluster e da última validação de cada aluno
#   down     teardown de todos os ambientes da turma (DELETE_IMAGES=true remove também as imagens)
#   profile  imprime o ~/.aws/config de um aluno: scripts/fleet.sh profile <roster.csv> <student_id>
# Estado/logs por aluno: .workshop/fleet/rw-<id>/ (kubeconfig, overlay, credenciais HyperDX, up.log, down.log)
source "$(dirname "$0")/lib/common.sh"
require aws python3

cmd="${1:-}"; roster="${2:-}"
[[ -n "$cmd" && -f "$roster" ]] || fail "Uso: $0 quotas|up|access|status|down|profile <roster.csv> [student_id]"
PARALLEL="${PARALLEL:-8}"
FLEET_DIR="$REPO_ROOT/.workshop/fleet"
account_id >/dev/null

students() {   # imprime "student_id username" por linha
  while IFS=, read -r sid username _; do
    [[ "$sid" == student_id || -z "$sid" || "$sid" == \#* ]] && continue
    echo "$sid $username"
  done < "$roster"
}
ROWS=()   # bash 3.2 (macOS) não tem mapfile
while IFS= read -r line; do ROWS+=("$line"); done < <(students)
[[ ${#ROWS[@]} -gt 0 ]] || fail "Roster vazio: $roster"

# Ambiente isolado de um aluno: estado, overlay, kubeconfig e portas locais do HyperDX próprios.
student_env() {   # $1 = student_id, $2 = índice
  local cluster="rw-$1"
  export STUDENT_ID="$1" CLUSTER_NAME="$cluster" ASSUME_YES=true
  export STATE_DIR="$FLEET_DIR/$cluster"
  export OVERLAY_DIR="$STATE_DIR/overlay" KUBECONFIG="$STATE_DIR/kubeconfig"
  export HDX_APP_PORT=$((13000 + $2)) HDX_API_PORT=$((18000 + $2))
  unset TABLE_NAME ORDERS_ROLE_NAME ORDERS_POLICY_NAME STUDENT_ROLE_NAME   # derivados do novo CLUSTER_NAME
  mkdir -p "$STATE_DIR"
}

# Executa uma função por aluno, até PARALLEL simultâneas; cada uma loga em $STATE_DIR/<log>.
run_all() {   # $1 = função, $2 = nome do log
  local fn="$1" log="$2" i=0 pids=() names=()
  for row in "${ROWS[@]}"; do
    read -r sid username <<<"$row"
    ( student_env "$sid" "$i"; "$fn" "$sid" "$username" >"$STATE_DIR/$log" 2>&1 ) &
    pids+=($!); names+=("$sid"); i=$((i + 1))
    while [[ $(jobs -rp | wc -l) -ge $PARALLEL ]]; do sleep 5; done
  done
  local failed=0
  for k in "${!pids[@]}"; do
    if wait "${pids[$k]}"; then ok "${names[$k]}"; else warn "${names[$k]} falhou — ver $FLEET_DIR/rw-${names[$k]}/$log"; failed=$((failed + 1)); fi
  done
  [[ $failed -eq 0 ]] || fail "$failed de ${#ROWS[@]} alunos com falha"
}

student_up() {   # $1 = student_id, $2 = username
  "$REPO_ROOT/scripts/setup.sh"
  "$REPO_ROOT/scripts/hyperdx-credentials.sh" push
  "$REPO_ROOT/scripts/deploy.sh" --skip-build
  if STUDENT_USERNAME="$2" "$REPO_ROOT/infrastructure/student-access.sh" create; then :; else
    echo "⚠ role do aluno pendente: rode infrastructure/identity-center.sh e depois scripts/fleet.sh access"; fi
  "$REPO_ROOT/scripts/validate.sh" --quick
}
student_access() { STUDENT_USERNAME="$2" "$REPO_ROOT/infrastructure/student-access.sh" create; }
student_down()   { "$REPO_ROOT/scripts/teardown.sh"; }

case "$cmd" in
  quotas)
    n=${#ROWS[@]}
    q() { aws service-quotas get-service-quota --service-code "$1" --quota-code "$2" --region "$AWS_REGION" \
            --query 'Quota.Value' --output text 2>/dev/null | cut -d. -f1; }
    used_vpc="$(aws ec2 describe-vpcs --region "$AWS_REGION" --query 'length(Vpcs)')"
    used_eip="$(aws ec2 describe-addresses --region "$AWS_REGION" --query 'length(Addresses)')"
    used_igw="$(aws ec2 describe-internet-gateways --region "$AWS_REGION" --query 'length(InternetGateways)')"
    # Por aluno: 1 VPC, 1 IGW, 1 NAT (1 EIP); 2x m6i.large + 1x m6i.xlarge = 8 vCPU (até 14 com o CA no LAB 02).
    printf '%-34s %8s %8s %10s\n' "Quota (${AWS_REGION})" "Atual" "Em uso" "Necessário"
    printf '%-34s %8s %8s %10s\n' "VPCs por região (L-F678F1CE)" "$(q vpc L-F678F1CE)" "$used_vpc" "$((used_vpc + n))"
    printf '%-34s %8s %8s %10s\n' "Internet gateways (L-A4707A72)" "$(q vpc L-A4707A72)" "$used_igw" "$((used_igw + n))"
    printf '%-34s %8s %8s %10s\n' "Elastic IPs (L-0263D0A3)" "$(q ec2 L-0263D0A3)" "$used_eip" "$((used_eip + n))"
    printf '%-34s %8s %8s %10s\n' "vCPU On-Demand std (L-1216C47A)" "$(q ec2 L-1216C47A)" "-" "$((n * 14))"
    printf '%-34s %8s %8s %10s\n' "Clusters EKS (L-1194D53C)" "$(q eks L-1194D53C)" "-" "$n"
    echo
    echo "Pedido de aumento (uma vez por quota; verifique antes de enviar):"
    echo "  aws service-quotas request-service-quota-increase --region ${AWS_REGION} --service-code vpc --quota-code L-F678F1CE --desired-value <n>"
    ;;
  up)
    info "Build único das imagens (${ECR_PREFIX}/*:${IMAGE_TAG})"
    "$REPO_ROOT/scripts/deploy.sh" --build-only
    info "Provisionando ${#ROWS[@]} ambientes (PARALLEL=${PARALLEL}); logs em $FLEET_DIR/rw-<id>/up.log"
    run_all student_up up.log
    ;;
  access) run_all student_access access.log ;;
  status)
    printf '%-14s %-10s %s\n' "Cluster" "EKS" "Validação"
    for row in "${ROWS[@]}"; do
      read -r sid _ <<<"$row"; c="rw-$sid"
      st="$(aws eks describe-cluster --name "$c" --region "$AWS_REGION" --query cluster.status --output text 2>/dev/null || echo -)"
      rep="$FLEET_DIR/$c/validation-report.md"
      val="$( [[ -f "$rep" ]] && echo "$(grep -c '^| ✅' "$rep") ok / $(grep -c '^| ❌' "$rep") falha" || echo -)"
      printf '%-14s %-10s %s\n' "$c" "$st" "$val"
    done
    ;;
  down)
    warn "Isto removerá ${#ROWS[@]} ambientes (rw-*) da conta ${AWS_ACCOUNT_ID}."
    confirm "Confirmar remoção definitiva da turma?" || fail "Cancelado"
    run_all student_down down.log
    ;;
  profile)
    sid="${3:-}"; row="$(printf '%s\n' "${ROWS[@]}" | awk -v s="$sid" '$1 == s')"
    [[ -n "$row" ]] || fail "Aluno '$sid' não está no roster"
    store="$(aws sso-admin list-instances --region "$AWS_REGION" --query 'Instances[0].IdentityStoreId' --output text 2>/dev/null)"
    cat <<CFG
# ~/.aws/config do aluno ${sid} — login: aws sso login --profile workshop-sso
[sso-session workshop]
sso_start_url = ${SSO_START_URL:-https://${store}.awsapps.com/start}
sso_region = ${AWS_REGION}
sso_registration_scopes = sso:account:access

[profile workshop-sso]
sso_session = workshop
sso_account_id = ${AWS_ACCOUNT_ID}
sso_role_name = ${STUDENT_PERMISSION_SET:-ReliabilityWorkshopStudent}
region = ${AWS_REGION}

# Role exclusiva do aluno (o CLI renova a sessão automaticamente a partir do SSO).
[profile workshop]
source_profile = workshop-sso
role_arn = arn:aws:iam::${AWS_ACCOUNT_ID}:role/rw-${sid}-student
region = ${AWS_REGION}

# Depois:  export AWS_PROFILE=workshop STUDENT_ID=${sid}
#          aws eks update-kubeconfig --name rw-${sid} && make hyperdx-credentials-pull
CFG
    ;;
  *) fail "Comando desconhecido: $cmd" ;;
esac
