#!/usr/bin/env bash
# Concede acesso de administrador do cluster a principals IAM via EKS access entries (API do EKS, sem kubectl).
# O criador do cluster já é admin; isto dá acesso a outros (ex.: pipeline ↔ instrutor).
# Uso: infrastructure/access-entry.sh grant [<arn> ...]   (sem ARN: o principal atual)
#      infrastructure/access-entry.sh list
source "$(dirname "$0")/../scripts/lib/common.sh"
require aws

ADMIN_POLICY="arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

# arn:aws:sts::<conta>:assumed-role/<role>/<sessão> -> arn:aws:iam::<conta>:role/<role>
# (roles com path, ex. aws-reserved/sso.amazonaws.com/, precisam ser informadas pelo ARN IAM completo)
to_principal_arn() {
  sed -E 's#^arn:aws:sts::([0-9]+):assumed-role/([^/]+)/.*#arn:aws:iam::\1:role/\2#' <<<"$1"
}

cmd="${1:-list}"; shift || true
case "$cmd" in
  grant)
    principals=("$@")
    [[ ${#principals[@]} -gt 0 ]] || principals=("$(aws sts get-caller-identity --query Arn --output text)")
    for raw in "${principals[@]}"; do
      arn="$(to_principal_arn "$raw")"
      if aws eks describe-access-entry --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
          --principal-arn "$arn" >/dev/null 2>&1; then
        ok "Access entry já existe: $arn"
      else
        # Role recém-criada (ex.: student-access.sh): o IAM leva alguns segundos para propagar e, até lá,
        # o EKS responde "invalid principal". Repete por até ~2 min antes de desistir.
        for attempt in $(seq 1 24); do
          if err="$(aws eks create-access-entry --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
              --principal-arn "$arn" --tags workshop=kubernetes-reliability 2>&1 >/dev/null)"; then
            break
          fi
          [[ "$err" == *"invalid principal"* && $attempt -lt 24 ]] || fail "create-access-entry falhou para $arn: $err"
          info "Aguardando a propagação de $arn no IAM (tentativa ${attempt}/24)"; sleep 5
        done
        ok "Access entry criada: $arn"
      fi
      aws eks associate-access-policy --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
        --principal-arn "$arn" --policy-arn "$ADMIN_POLICY" --access-scope type=cluster >/dev/null
      ok "AmazonEKSClusterAdminPolicy associada: $arn"
    done
    ;;
  list)
    aws eks list-access-entries --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" --output table
    ;;
  *) fail "Uso: $0 grant [<arn> ...] | list" ;;
esac
