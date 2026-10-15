#!/usr/bin/env bash
# Role IAM EXCLUSIVA do aluno (${CLUSTER_NAME}-student) + acesso admin ao cluster DELE (EKS access entry).
#
# O aluno entra pelo IAM Identity Center no permission set ${STUDENT_PERMISSION_SET}. Todos os alunos desse
# permission set compartilham a mesma role AWSReservedSSO_* nesta conta, então ela sozinha não isola ninguém:
# a trust policy desta role exige aws:userid = <role-id SSO>:<username do aluno>, ou seja, SÓ a sessão SSO
# daquele usuário consegue assumi-la. A permission policy (infrastructure/student/student-policy.json)
# limita o acesso AWS ao cluster, à tabela e ao secret do HyperDX do próprio aluno.
#
# Uso: STUDENT_ID=aluno01 STUDENT_USERNAME=<username no Identity Center> infrastructure/student-access.sh create
#      STUDENT_ID=aluno01 infrastructure/student-access.sh delete|status
source "$(dirname "$0")/../scripts/lib/common.sh"
require aws python3
account_id >/dev/null

STUDENT_PERMISSION_SET="${STUDENT_PERMISSION_SET:-ReliabilityWorkshopStudent}"
role_arn="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${STUDENT_ROLE_NAME}"

sso_role() {   # imprime "<arn> <role-id>" da role SSO do permission set nesta conta
  aws iam list-roles --path-prefix /aws-reserved/sso.amazonaws.com/ \
    --query "Roles[?starts_with(RoleName, 'AWSReservedSSO_${STUDENT_PERMISSION_SET}_')].[Arn,RoleId] | [0]" --output text
}

cmd="${1:-status}"
case "$cmd" in
  create)
    [[ "$CLUSTER_NAME" != "reliability-workshop" ]] || fail "Role de aluno exige STUDENT_ID (cluster rw-<aluno>)"
    [[ -n "${STUDENT_USERNAME:-}" ]] || fail "Defina STUDENT_USERNAME (username do aluno no Identity Center)"
    read -r sso_arn sso_id <<<"$(sso_role)"
    [[ "$sso_arn" == arn:* ]] || fail "Role SSO do permission set ${STUDENT_PERMISSION_SET} não existe nesta conta (atribua-o à conta: infrastructure/identity-center.sh)"
    tmp="$(mktemp -d)"
    python3 - "$sso_arn" "${sso_id}:${STUDENT_USERNAME}" > "$tmp/trust.json" <<'PY'
import json, sys
print(json.dumps({"Version": "2012-10-17", "Statement": [{
    "Effect": "Allow", "Principal": {"AWS": sys.argv[1]}, "Action": "sts:AssumeRole",
    "Condition": {"StringEquals": {"aws:userid": sys.argv[2]}}}]}))
PY
    render "$REPO_ROOT/infrastructure/student/student-policy.json" > "$tmp/policy.json"
    if aws iam get-role --role-name "$STUDENT_ROLE_NAME" >/dev/null 2>&1; then
      aws iam update-assume-role-policy --role-name "$STUDENT_ROLE_NAME" --policy-document "file://$tmp/trust.json"
      ok "Trust policy atualizada: $STUDENT_ROLE_NAME"
    else
      aws iam create-role --role-name "$STUDENT_ROLE_NAME" --assume-role-policy-document "file://$tmp/trust.json" \
        --max-session-duration 43200 --description "Aluno ${STUDENT_USERNAME} - cluster ${CLUSTER_NAME}" \
        --tags Key=workshop,Value=kubernetes-reliability Key=cluster,Value="$CLUSTER_NAME" >/dev/null
      ok "Role criada: $STUDENT_ROLE_NAME (somente a sessão SSO de ${STUDENT_USERNAME})"
    fi
    aws iam put-role-policy --role-name "$STUDENT_ROLE_NAME" --policy-name student-scope \
      --policy-document "file://$tmp/policy.json"
    rm -rf "$tmp"
    ok "Permissões limitadas a ${CLUSTER_NAME} / ${TABLE_NAME}"
    "$REPO_ROOT/infrastructure/access-entry.sh" grant "$role_arn"
    ;;
  delete)
    if aws eks describe-access-entry --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
        --principal-arn "$role_arn" >/dev/null 2>&1; then
      aws eks delete-access-entry --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" --principal-arn "$role_arn"
      ok "Access entry removida"
    fi
    if aws iam get-role --role-name "$STUDENT_ROLE_NAME" >/dev/null 2>&1; then
      aws iam delete-role-policy --role-name "$STUDENT_ROLE_NAME" --policy-name student-scope 2>/dev/null || true
      aws iam delete-role --role-name "$STUDENT_ROLE_NAME"
      ok "Role $STUDENT_ROLE_NAME removida"
    else
      ok "Role $STUDENT_ROLE_NAME não existe"
    fi
    ;;
  status)
    aws iam get-role --role-name "$STUDENT_ROLE_NAME" \
      --query 'Role.{Role:RoleName,Trust:AssumeRolePolicyDocument.Statement[0].Condition}' --output json
    ;;
  *) fail "Uso: $0 create|delete|status" ;;
esac
