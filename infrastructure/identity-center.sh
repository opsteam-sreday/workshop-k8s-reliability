#!/usr/bin/env bash
# IAM Identity Center: permission set dos alunos + usuários da turma + atribuição à conta do workshop.
# Executar com credenciais da CONTA DE GERENCIAMENTO (ou admin delegado do Identity Center) — a conta do
# workshop é membro da organização e não pode criar permission sets.
#
# O permission set só permite sts:AssumeRole em rw-*-student da conta do workshop; quem decide QUAL role cada
# aluno assume é a trust policy de cada role (infrastructure/student-access.sh, condição aws:userid).
#
# Uso: WORKSHOP_ACCOUNT_ID=<conta> infrastructure/identity-center.sh apply|remove <roster.csv>
#   roster.csv: cluster_id,username,email,given_name,family_name  (ver infrastructure/students.example.csv)
#   CREATE_USERS=false  não cria usuários (diretório externo/SCIM: os usuários já devem existir)
export WORKSHOP_NO_CLUSTER=true   # não opera um cluster
source "$(dirname "$0")/../scripts/lib/common.sh"
require aws python3

cmd="${1:-}"; roster="${2:-}"
[[ "$cmd" =~ ^(apply|remove)$ && -f "$roster" ]] || fail "Uso: WORKSHOP_ACCOUNT_ID=<conta> $0 apply|remove <roster.csv>"
[[ "${WORKSHOP_ACCOUNT_ID:-}" =~ ^[0-9]{12}$ ]] || fail "Defina WORKSHOP_ACCOUNT_ID (conta onde ficam os clusters)"
STUDENT_PERMISSION_SET="${STUDENT_PERMISSION_SET:-ReliabilityWorkshopStudent}"
CREATE_USERS="${CREATE_USERS:-true}"

read -r INSTANCE_ARN STORE_ID <<<"$(aws sso-admin list-instances --region "$AWS_REGION" \
  --query 'Instances[0].[InstanceArn,IdentityStoreId]' --output text)"
[[ "$INSTANCE_ARN" == arn:* ]] || fail "Identity Center não encontrado em ${AWS_REGION}"

permission_set_arn() {
  for ps in $(aws sso-admin list-permission-sets --instance-arn "$INSTANCE_ARN" --region "$AWS_REGION" \
      --query 'PermissionSets[]' --output text); do
    name="$(aws sso-admin describe-permission-set --instance-arn "$INSTANCE_ARN" --permission-set-arn "$ps" \
      --region "$AWS_REGION" --query 'PermissionSet.Name' --output text)"
    [[ "$name" == "$STUDENT_PERMISSION_SET" ]] && { echo "$ps"; return 0; }
  done
  return 0   # não encontrado: saída vazia (sem isso, o set -e encerraria o script em silêncio)
}

user_id() {
  aws identitystore get-user-id --identity-store-id "$STORE_ID" --region "$AWS_REGION" \
    --alternate-identifier "{\"UniqueAttribute\":{\"AttributePath\":\"userName\",\"AttributeValue\":\"$1\"}}" \
    --query UserId --output text 2>/dev/null || true
}

wait_assignment() {   # $1 = request id; $2 = creation|deletion
  local status
  for _ in $(seq 1 60); do
    if [[ "$2" == creation ]]; then
      status="$(aws sso-admin describe-account-assignment-creation-status --instance-arn "$INSTANCE_ARN" \
        --account-assignment-creation-request-id "$1" --region "$AWS_REGION" \
        --query 'AccountAssignmentCreationStatus.[Status,FailureReason]' --output text)"
    else
      status="$(aws sso-admin describe-account-assignment-deletion-status --instance-arn "$INSTANCE_ARN" \
        --account-assignment-deletion-request-id "$1" --region "$AWS_REGION" \
        --query 'AccountAssignmentDeletionStatus.[Status,FailureReason]' --output text)"
    fi
    [[ "$status" == SUCCEEDED* ]] && return 0
    [[ "$status" == FAILED* ]] && { warn "$status"; return 1; }
    sleep 3
  done
  warn "atribuição ainda em andamento ($1)"
}

PS_ARN="$(permission_set_arn)"
case "$cmd" in
  apply)
    if [[ -z "$PS_ARN" ]]; then
      PS_ARN="$(aws sso-admin create-permission-set --instance-arn "$INSTANCE_ARN" --region "$AWS_REGION" \
        --name "$STUDENT_PERMISSION_SET" --session-duration PT8H \
        --description "Aluno do Kubernetes Reliability Workshop: só assume a role rw-<aluno>-student" \
        --tags Key=workshop,Value=kubernetes-reliability \
        --query 'PermissionSet.PermissionSetArn' --output text)"
      ok "Permission set criado: $STUDENT_PERMISSION_SET"
    fi
    policy="$(python3 -c 'import json,sys; print(json.dumps({"Version":"2012-10-17","Statement":[{"Sid":"AssumeOwnStudentRole","Effect":"Allow","Action":"sts:AssumeRole","Resource":f"arn:aws:iam::{sys.argv[1]}:role/rw-*-student"}]}))' "$WORKSHOP_ACCOUNT_ID")"
    aws sso-admin put-inline-policy-to-permission-set --instance-arn "$INSTANCE_ARN" --region "$AWS_REGION" \
      --permission-set-arn "$PS_ARN" --inline-policy "$policy"
    ok "Inline policy: sts:AssumeRole em arn:aws:iam::${WORKSHOP_ACCOUNT_ID}:role/rw-*-student"

    while IFS=, read -r sid username email given family; do
      [[ "$sid" == cluster_id || "$sid" == student_id || -z "$sid" || "$sid" == \#* ]] && continue
      uid="$(user_id "$username")"
      if [[ -z "$uid" || "$uid" == None ]]; then
        [[ "$CREATE_USERS" == true ]] || { warn "$sid: usuário $username não existe (CREATE_USERS=false) — ignorado"; continue; }
        uid="$(aws identitystore create-user --identity-store-id "$STORE_ID" --region "$AWS_REGION" \
          --user-name "$username" --display-name "$given $family" \
          --name "GivenName=$given,FamilyName=$family" \
          --emails "Value=$email,Type=work,Primary=true" --query UserId --output text)"
        ok "$sid: usuário $username criado"
      fi
      req="$(aws sso-admin create-account-assignment --instance-arn "$INSTANCE_ARN" --region "$AWS_REGION" \
        --permission-set-arn "$PS_ARN" --target-type AWS_ACCOUNT --target-id "$WORKSHOP_ACCOUNT_ID" \
        --principal-type USER --principal-id "$uid" \
        --query 'AccountAssignmentCreationStatus.RequestId' --output text)"
      wait_assignment "$req" creation && ok "$sid: $username atribuído à conta $WORKSHOP_ACCOUNT_ID"
    done < "$roster"

    # Propaga a inline policy para a role AWSReservedSSO_* já existente na conta.
    aws sso-admin provision-permission-set --instance-arn "$INSTANCE_ARN" --region "$AWS_REGION" \
      --permission-set-arn "$PS_ARN" --target-type AWS_ACCOUNT --target-id "$WORKSHOP_ACCOUNT_ID" >/dev/null
    ok "Permission set provisionado. Próximo passo (na conta do workshop): scripts/fleet.sh access $roster"
    ;;
  remove)
    [[ -n "$PS_ARN" ]] || { ok "Permission set $STUDENT_PERMISSION_SET não existe"; exit 0; }
    while IFS=, read -r sid username _; do
      [[ "$sid" == cluster_id || "$sid" == student_id || -z "$sid" || "$sid" == \#* ]] && continue
      uid="$(user_id "$username")"; [[ -n "$uid" && "$uid" != None ]] || continue
      req="$(aws sso-admin delete-account-assignment --instance-arn "$INSTANCE_ARN" --region "$AWS_REGION" \
        --permission-set-arn "$PS_ARN" --target-type AWS_ACCOUNT --target-id "$WORKSHOP_ACCOUNT_ID" \
        --principal-type USER --principal-id "$uid" \
        --query 'AccountAssignmentDeletionStatus.RequestId' --output text 2>/dev/null)" || continue
      wait_assignment "$req" deletion && ok "$sid: atribuição de $username removida"
    done < "$roster"
    warn "Usuários NÃO são removidos do Identity Center (podem existir fora do workshop)."
    ;;
esac
