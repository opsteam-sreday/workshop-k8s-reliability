#!/usr/bin/env bash
# Sincroniza .workshop/hyperdx-credentials.json com o AWS Secrets Manager.
# Necessário quando o ambiente é criado por um runner descartável (GitHub Actions): o setup só registra o
# usuário instrutor na primeira execução; nas seguintes ele precisa das MESMAS credenciais para o login.
# Uso: scripts/hyperdx-credentials.sh pull|push|delete
source "$(dirname "$0")/lib/common.sh"
require aws

SECRET_ID="${HYPERDX_CREDS_SECRET:-reliability-workshop/${CLUSTER_NAME}/hyperdx-credentials}"
FILE="$STATE_DIR/hyperdx-credentials.json"

cmd="${1:-pull}"
case "$cmd" in
  pull)
    if value="$(aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --region "$AWS_REGION" \
        --query SecretString --output text 2>/dev/null)"; then
      (umask 077; printf '%s\n' "$value" > "$FILE")
      ok "Credenciais do HyperDX restauradas de $SECRET_ID"
    else
      warn "Secret $SECRET_ID não existe (primeiro setup deste cluster?)"
    fi
    ;;
  push)
    [[ -s "$FILE" ]] || fail "$FILE não existe — execute o setup primeiro"
    if aws secretsmanager describe-secret --secret-id "$SECRET_ID" --region "$AWS_REGION" >/dev/null 2>&1; then
      aws secretsmanager put-secret-value --secret-id "$SECRET_ID" --region "$AWS_REGION" \
        --secret-string "file://$FILE" >/dev/null
    else
      aws secretsmanager create-secret --name "$SECRET_ID" --region "$AWS_REGION" \
        --description "HyperDX (instrutor) do cluster ${CLUSTER_NAME}" \
        --tags Key=workshop,Value=kubernetes-reliability Key=cluster,Value="$CLUSTER_NAME" \
        --secret-string "file://$FILE" >/dev/null
    fi
    ok "Credenciais do HyperDX gravadas em $SECRET_ID"
    ;;
  delete)
    # Sem janela de recuperação: o mesmo nome é reutilizado quando o cluster for recriado.
    aws secretsmanager delete-secret --secret-id "$SECRET_ID" --region "$AWS_REGION" \
      --force-delete-without-recovery >/dev/null 2>&1 \
      && ok "Secret $SECRET_ID removido" || ok "Secret $SECRET_ID não existe"
    ;;
  *) fail "Uso: $0 pull|push|delete" ;;
esac
