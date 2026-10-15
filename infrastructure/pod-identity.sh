#!/usr/bin/env bash
# EKS Pod Identity: IAM Role exclusiva da Orders API (ecommerce/orders-api-sa).
#
# - TransactWriteItems NÃO é uma action IAM separada: a autorização é feita por item,
#   com as actions PutItem/UpdateItem. Por isso a policy lista apenas
#   GetItem, PutItem, UpdateItem e Query (as operações efetivamente usadas).
# - Sem Scan, DeleteItem, BatchWrite, DescribeTable etc.
# - A trust policy restringe a conta e o cluster de origem (aws:SourceAccount/SourceArn);
#   a permission policy exige as session tags do Pod Identity (ABAC: namespace + SA + cluster).
#
# Uso: infrastructure/pod-identity.sh create|delete|status
source "$(dirname "$0")/../scripts/lib/common.sh"
require aws
account_id >/dev/null

policy_arn="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${ORDERS_POLICY_NAME}"
cmd="${1:-status}"

association_id() {
  aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --namespace ecommerce --service-account orders-api-sa \
    --query 'associations[0].associationId' --output text 2>/dev/null | grep -v None || true
}

case "$cmd" in
  create)
    tmp="$(mktemp -d)"
    render "$REPO_ROOT/infrastructure/orders-dynamodb-policy.json" > "$tmp/policy.json"
    render "$REPO_ROOT/infrastructure/pod-identity-trust.json" > "$tmp/trust.json"

    if aws iam get-policy --policy-arn "$policy_arn" >/dev/null 2>&1; then
      info "Atualizando policy $ORDERS_POLICY_NAME (nova versão default)"
      versions="$(aws iam list-policy-versions --policy-arn "$policy_arn" --query 'Versions[?!IsDefaultVersion].VersionId' --output text)"
      for v in $versions; do aws iam delete-policy-version --policy-arn "$policy_arn" --version-id "$v"; done
      aws iam create-policy-version --policy-arn "$policy_arn" --policy-document "file://$tmp/policy.json" --set-as-default >/dev/null
    else
      info "Criando policy $ORDERS_POLICY_NAME"
      aws iam create-policy --policy-name "$ORDERS_POLICY_NAME" --policy-document "file://$tmp/policy.json" \
        --tags Key=workshop,Value=kubernetes-reliability >/dev/null
    fi

    if aws iam get-role --role-name "$ORDERS_ROLE_NAME" >/dev/null 2>&1; then
      info "Atualizando trust policy da role $ORDERS_ROLE_NAME"
      aws iam update-assume-role-policy --role-name "$ORDERS_ROLE_NAME" --policy-document "file://$tmp/trust.json"
    else
      info "Criando role $ORDERS_ROLE_NAME (trust: pods.eks.amazonaws.com)"
      aws iam create-role --role-name "$ORDERS_ROLE_NAME" --assume-role-policy-document "file://$tmp/trust.json" \
        --description "EKS Pod Identity - Orders API (workshop)" --tags Key=workshop,Value=kubernetes-reliability >/dev/null
    fi
    aws iam attach-role-policy --role-name "$ORDERS_ROLE_NAME" --policy-arn "$policy_arn"

    if [[ -n "$(association_id)" ]]; then
      ok "Pod Identity Association já existe: $(association_id)"
    else
      info "Associando role à ServiceAccount ecommerce/orders-api-sa"
      aws eks create-pod-identity-association --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
        --namespace ecommerce --service-account orders-api-sa \
        --role-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ORDERS_ROLE_NAME}" >/dev/null
      ok "Associação criada: $(association_id)"
    fi
    rm -rf "$tmp"
    ;;
  delete)
    id="$(association_id)"
    if [[ -n "$id" ]]; then
      aws eks delete-pod-identity-association --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" --association-id "$id" >/dev/null
      ok "Pod Identity Association removida"
    fi
    if aws iam get-role --role-name "$ORDERS_ROLE_NAME" >/dev/null 2>&1; then
      aws iam detach-role-policy --role-name "$ORDERS_ROLE_NAME" --policy-arn "$policy_arn" 2>/dev/null || true
      aws iam delete-role --role-name "$ORDERS_ROLE_NAME"
      ok "Role $ORDERS_ROLE_NAME removida"
    fi
    if aws iam get-policy --policy-arn "$policy_arn" >/dev/null 2>&1; then
      for v in $(aws iam list-policy-versions --policy-arn "$policy_arn" --query 'Versions[?!IsDefaultVersion].VersionId' --output text); do
        aws iam delete-policy-version --policy-arn "$policy_arn" --version-id "$v"
      done
      aws iam delete-policy --policy-arn "$policy_arn"
      ok "Policy $ORDERS_POLICY_NAME removida"
    fi
    ;;
  status)
    aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" --output table
    ;;
  *) fail "Uso: $0 create|delete|status" ;;
esac
