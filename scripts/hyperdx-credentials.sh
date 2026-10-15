#!/usr/bin/env bash
# Sincroniza .workshop/hyperdx-credentials.json com o SSM Parameter Store (SecureString).
# Necessário quando o ambiente é criado por um runner descartável (GitHub Actions): o setup só registra o
# usuário instrutor na primeira execução; nas seguintes ele precisa das MESMAS credenciais para o login.
# Uso: scripts/hyperdx-credentials.sh pull|push|delete
source "$(dirname "$0")/lib/common.sh"
require aws

PARAM="${HYPERDX_CREDS_PARAM:-/reliability-workshop/${CLUSTER_NAME}/hyperdx-credentials}"
FILE="$STATE_DIR/hyperdx-credentials.json"

cmd="${1:-pull}"
case "$cmd" in
  pull)
    if value="$(aws ssm get-parameter --name "$PARAM" --with-decryption --region "$AWS_REGION" \
        --query Parameter.Value --output text 2>/dev/null)"; then
      (umask 077; printf '%s\n' "$value" > "$FILE")
      ok "Credenciais do HyperDX restauradas de $PARAM"
    else
      warn "Parâmetro $PARAM não existe (primeiro setup deste cluster?)"
    fi
    ;;
  push)
    [[ -s "$FILE" ]] || fail "$FILE não existe — execute o setup primeiro"
    aws ssm put-parameter --name "$PARAM" --type SecureString --overwrite --region "$AWS_REGION" \
      --value "file://$FILE" >/dev/null
    ok "Credenciais do HyperDX gravadas em $PARAM"
    ;;
  delete)
    aws ssm delete-parameter --name "$PARAM" --region "$AWS_REGION" >/dev/null 2>&1 \
      && ok "Parâmetro $PARAM removido" || ok "Parâmetro $PARAM não existe"
    ;;
  *) fail "Uso: $0 pull|push|delete" ;;
esac
