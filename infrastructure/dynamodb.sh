#!/usr/bin/env bash
# Cria/remove a tabela DynamoDB do workshop (pedidos + registros de idempotência).
# Uso: infrastructure/dynamodb.sh create|delete|status
source "$(dirname "$0")/../scripts/lib/common.sh"
require aws

cmd="${1:-status}"
case "$cmd" in
  create)
    if aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
      ok "Tabela $TABLE_NAME já existe"
    else
      info "Criando tabela $TABLE_NAME (PAY_PER_REQUEST, GSI1 para listagem por cliente)"
      aws dynamodb create-table --region "$AWS_REGION" --table-name "$TABLE_NAME" \
        --cli-input-json "file://$REPO_ROOT/infrastructure/dynamodb-table.json" \
        --tags Key=workshop,Value=kubernetes-reliability Key=cluster,Value="$CLUSTER_NAME" >/dev/null
      aws dynamodb wait table-exists --table-name "$TABLE_NAME" --region "$AWS_REGION"
      ok "Tabela criada"
    fi
    # TTL é ASSÍNCRONO: itens expirados podem permanecer por até alguns dias antes da remoção.
    # Por isso a aplicação também verifica `expires_at` logicamente.
    ttl_status="$(aws dynamodb describe-time-to-live --table-name "$TABLE_NAME" --region "$AWS_REGION" \
      --query 'TimeToLiveDescription.TimeToLiveStatus' --output text)"
    if [[ "$ttl_status" != "ENABLED" && "$ttl_status" != "ENABLING" ]]; then
      aws dynamodb update-time-to-live --table-name "$TABLE_NAME" --region "$AWS_REGION" \
        --time-to-live-specification "Enabled=true,AttributeName=expires_at" >/dev/null
      ok "TTL habilitado em expires_at"
    else
      ok "TTL: $ttl_status"
    fi
    ;;
  delete)
    if aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
      info "Removendo tabela $TABLE_NAME"
      aws dynamodb delete-table --table-name "$TABLE_NAME" --region "$AWS_REGION" >/dev/null
      aws dynamodb wait table-not-exists --table-name "$TABLE_NAME" --region "$AWS_REGION"
      ok "Tabela removida"
    else
      ok "Tabela $TABLE_NAME não existe"
    fi
    ;;
  status)
    aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$AWS_REGION" \
      --query 'Table.{Name:TableName,Status:TableStatus,Billing:BillingModeSummary.BillingMode,Items:ItemCount,GSIs:GlobalSecondaryIndexes[].IndexName}'
    ;;
  *) fail "Uso: $0 create|delete|status" ;;
esac
