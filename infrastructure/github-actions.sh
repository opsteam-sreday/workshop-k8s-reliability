#!/usr/bin/env bash
# Cria/remove o OIDC provider do GitHub e a role IAM assumida pelos workflows de .github/workflows.
# Uso: infrastructure/github-actions.sh create|delete|status
#   GITHUB_REPOSITORY          owner/repo autorizado (padrão: derivado do remote origin)
#   GITHUB_REPOSITORY_IDS      "<owner_id>/<repo_id>": org/repo com IDs imutáveis no subject OIDC (o erro
#                              "Not authorized to perform sts:AssumeRoleWithWebIdentity" + no CloudTrail um sub
#                              repo:<owner>@<id>/<repo>@<id>:...). Padrão: obtido da API do GitHub (gh ou repo público)
#   GITHUB_ENVIRONMENT         environment do GitHub exigido na trust policy (padrão: workshop)
#   GITHUB_ACTIONS_POLICY_ARN  policy anexada à role. Padrão: a policy gerenciada do workshop, gerada a partir de
#                              infrastructure/github-actions/pipeline-policy.json e limitada a CLUSTER_NAME/região
source "$(dirname "$0")/../scripts/lib/common.sh"
require aws git

STACK_NAME="${GITHUB_ACTIONS_STACK_NAME:-reliability-workshop-github-actions}"
export GITHUB_ACTIONS_ROLE_NAME="${GITHUB_ACTIONS_ROLE_NAME:-reliability-workshop-github-actions}"
TEMPLATE="$REPO_ROOT/infrastructure/github-actions/oidc-role.yaml"
GITHUB_ENVIRONMENT="${GITHUB_ENVIRONMENT:-workshop}"
if [[ -z "${GITHUB_REPOSITORY:-}" ]]; then
  GITHUB_REPOSITORY="$(git -C "$REPO_ROOT" remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
fi
if [[ -z "${GITHUB_REPOSITORY_IDS:-}" ]]; then
  if command -v gh >/dev/null 2>&1; then
    GITHUB_REPOSITORY_IDS="$(gh api "repos/${GITHUB_REPOSITORY}" --jq '"\(.owner.id)/\(.id)"' 2>/dev/null || true)"
  else
    GITHUB_REPOSITORY_IDS="$(curl -fsS "https://api.github.com/repos/${GITHUB_REPOSITORY}" 2>/dev/null \
      | python3 -c 'import json,sys; r=json.load(sys.stdin); print(f"{r[\"owner\"][\"id\"]}/{r[\"id\"]}")' 2>/dev/null || true)"
  fi
fi
account_id >/dev/null
WORKSHOP_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${GITHUB_ACTIONS_ROLE_NAME}"

role_arn() {
  aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='RoleArn'].OutputValue" --output text
}

# Cria ou atualiza a policy gerenciada do workshop (IAM guarda no máximo 5 versões).
apply_workshop_policy() {
  local doc; doc="$(mktemp)"
  render "$REPO_ROOT/infrastructure/github-actions/pipeline-policy.json" > "$doc"
  if aws iam get-policy --policy-arn "$WORKSHOP_POLICY_ARN" >/dev/null 2>&1; then
    for v in $(aws iam list-policy-versions --policy-arn "$WORKSHOP_POLICY_ARN" \
        --query 'Versions[?!IsDefaultVersion].VersionId' --output text); do
      aws iam delete-policy-version --policy-arn "$WORKSHOP_POLICY_ARN" --version-id "$v"
    done
    aws iam create-policy-version --policy-arn "$WORKSHOP_POLICY_ARN" --policy-document "file://$doc" --set-as-default >/dev/null
    ok "Policy atualizada: $WORKSHOP_POLICY_ARN"
  else
    aws iam create-policy --policy-name "$GITHUB_ACTIONS_ROLE_NAME" --policy-document "file://$doc" \
      --description "Pipeline do workshop (cluster ${CLUSTER_NAME}, ${AWS_REGION})" \
      --tags Key=workshop,Value=kubernetes-reliability >/dev/null
    ok "Policy criada: $WORKSHOP_POLICY_ARN"
  fi
  rm -f "$doc"
}

cmd="${1:-status}"
case "$cmd" in
  create)
    if [[ -z "${GITHUB_ACTIONS_POLICY_ARN:-}" ]]; then
      apply_workshop_policy
      GITHUB_ACTIONS_POLICY_ARN="$WORKSHOP_POLICY_ARN"
    fi
    create_provider=true
    if aws iam get-open-id-connect-provider --open-id-connect-provider-arn \
        "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com" >/dev/null 2>&1; then
      # Provider já existe (criado fora desta stack): reutiliza em vez de duplicar.
      aws cloudformation describe-stack-resource --stack-name "$STACK_NAME" --region "$AWS_REGION" \
        --logical-resource-id GitHubOidcProvider >/dev/null 2>&1 || create_provider=false
    fi
    info "Implantando stack $STACK_NAME (repo ${GITHUB_REPOSITORY}${GITHUB_REPOSITORY_IDS:+ ids ${GITHUB_REPOSITORY_IDS}}, environment ${GITHUB_ENVIRONMENT})"
    aws cloudformation deploy --stack-name "$STACK_NAME" --region "$AWS_REGION" \
      --template-file "$TEMPLATE" --capabilities CAPABILITY_NAMED_IAM --no-fail-on-empty-changeset \
      --tags workshop=kubernetes-reliability \
      --parameter-overrides GitHubRepository="$GITHUB_REPOSITORY" GitHubRepositoryIds="${GITHUB_REPOSITORY_IDS:-}" \
        GitHubEnvironment="$GITHUB_ENVIRONMENT" \
        RoleName="$GITHUB_ACTIONS_ROLE_NAME" PermissionsPolicyArn="$GITHUB_ACTIONS_POLICY_ARN" \
        CreateOidcProvider="$create_provider"
    ok "Role: $(role_arn) (policy ${GITHUB_ACTIONS_POLICY_ARN})"
    echo "Configure no GitHub: Settings › Environments › ${GITHUB_ENVIRONMENT} › variável AWS_ROLE_ARN=$(role_arn)"
    ;;
  delete)
    info "Removendo stack $STACK_NAME"
    aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$AWS_REGION"
    aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$AWS_REGION"
    ok "Stack removida"
    if aws iam get-policy --policy-arn "$WORKSHOP_POLICY_ARN" >/dev/null 2>&1; then
      for v in $(aws iam list-policy-versions --policy-arn "$WORKSHOP_POLICY_ARN" \
          --query 'Versions[?!IsDefaultVersion].VersionId' --output text); do
        aws iam delete-policy-version --policy-arn "$WORKSHOP_POLICY_ARN" --version-id "$v"
      done
      aws iam delete-policy --policy-arn "$WORKSHOP_POLICY_ARN"
      ok "Policy $WORKSHOP_POLICY_ARN removida"
    fi
    ;;
  status)
    aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" \
      --query 'Stacks[0].{Status:StackStatus,Outputs:Outputs}'
    ;;
  *) fail "Uso: $0 create|delete|status" ;;
esac
