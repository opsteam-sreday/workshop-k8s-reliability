#!/usr/bin/env bash
# VPC do cluster (stack CloudFormation ${CLUSTER_NAME}-vpc) segundo o plano de endereçamento (README.md):
#   rw-<prefixo>NN (ex.: rw-aluno07) -> 10.(200+NN).0.0/16, NN = 1..40 (10.200 fica livre: VPC_SECOND_OCTET=200)
#   VPC_SECOND_OCTET=<200..240> sobrescreve o cálculo (IDs de aluno sem número no final).
# As 2 AZs giram por cluster (NAT na AZ A): os NATs da turma se distribuem entre as AZs elegíveis.
#
# Uso: infrastructure/vpc/vpc.sh plan|create|delete|status
#      eval "$(infrastructure/vpc/vpc.sh env)"   # exporta VPC_ID, PUBLIC_SUBNET_A/B, PRIVATE_SUBNET_A/B
source "$(dirname "$0")/../../scripts/lib/common.sh"
require aws

STACK_NAME="${CLUSTER_NAME}-vpc"
# use1-az3 (us-east-1e na maioria das contas) não aceita control plane do EKS nem tem m6i.
EXCLUDED_AZ_IDS="${EXCLUDED_AZ_IDS:-use1-az3}"

second_octet() {
  if [[ -n "${VPC_SECOND_OCTET:-}" ]]; then echo "$VPC_SECOND_OCTET"
  elif [[ "$CLUSTER_NAME" =~ ^rw-[a-z]*0*([0-9]+)$ ]] && (( BASH_REMATCH[1] >= 1 && BASH_REMATCH[1] <= 40 )); then
    echo $((200 + BASH_REMATCH[1]))
  else
    fail "Sem CIDR no plano para ${CLUSTER_NAME}: use IDs aluno01..aluno40 ou defina VPC_SECOND_OCTET (200-240)"
  fi
}

az_pair() {   # $1 = segundo octeto; imprime "<az A> <az B>" (nomes), girando pela lista de AZs elegíveis
  local zones=() z id name
  while read -r name id; do
    [[ " $EXCLUDED_AZ_IDS " == *" $id "* ]] || zones+=("$name")
  done < <(aws ec2 describe-availability-zones --region "$AWS_REGION" \
             --filters Name=state,Values=available Name=zone-type,Values=availability-zone \
             --query 'sort_by(AvailabilityZones, &ZoneId)[].[ZoneName,ZoneId]' --output text)
  local n=${#zones[@]} i=$(( $1 - 200 ))
  (( n >= 2 )) || fail "Menos de 2 AZs elegíveis em ${AWS_REGION}"
  echo "${zones[$(( i % n ))]} ${zones[$(( (i + 1) % n ))]}"
}

output() {
  aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

cmd="${1:-status}"
case "$cmd" in
  plan)
    octet="$(second_octet)"; read -r az_a az_b <<<"$(az_pair "$octet")"
    cat <<PLAN
Cluster ........ ${CLUSTER_NAME}  (stack ${STACK_NAME})
VPC ............ 10.${octet}.0.0/16
Públicas ....... 10.${octet}.0.0/20 (${az_a}, NAT) · 10.${octet}.16.0/20 (${az_b})   -> control plane do EKS
Privadas ....... 10.${octet}.64.0/18 (${az_a}) · 10.${octet}.128.0/18 (${az_b})      -> node groups
PLAN
    ;;
  create)
    octet="$(second_octet)"; read -r az_a az_b <<<"$(az_pair "$octet")"
    # Duas VPCs com o mesmo CIDR impediriam peering/VPN futuros e indicam erro no plano: recusa.
    other="$(aws ec2 describe-vpcs --region "$AWS_REGION" --filters "Name=cidr,Values=10.${octet}.0.0/16" \
      --query "Vpcs[?!(Tags[?Key=='cluster' && Value=='${CLUSTER_NAME}'])].VpcId" --output text)"
    [[ -z "$other" ]] || fail "10.${octet}.0.0/16 já está em uso pela VPC ${other} (outro cluster?)"
    info "VPC 10.${octet}.0.0/16 em ${az_a}/${az_b} (stack ${STACK_NAME})"
    aws cloudformation deploy --stack-name "$STACK_NAME" --region "$AWS_REGION" \
      --template-file "$REPO_ROOT/infrastructure/vpc/vpc.yaml" --no-fail-on-empty-changeset \
      --tags workshop=kubernetes-reliability cluster="$CLUSTER_NAME" \
      --parameter-overrides ClusterName="$CLUSTER_NAME" SecondOctet="$octet" AzA="$az_a" AzB="$az_b"
    ok "VPC $(output VpcId) ($(output VpcCidr))"
    ;;
  env)
    echo "export VPC_ID=$(output VpcId)"
    for k in PublicSubnetA PublicSubnetB PrivateSubnetA PrivateSubnetB; do
      var="$(sed -E 's/([a-z])([A-Z])/\1_\2/g' <<<"$k" | tr '[:lower:]' '[:upper:]')"   # PublicSubnetA -> PUBLIC_SUBNET_A
      echo "export ${var}=$(output "$k")"
    done
    ;;
  delete)
    if aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
      info "Removendo VPC (stack $STACK_NAME)"
      aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$AWS_REGION"
      aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$AWS_REGION"
      ok "VPC removida"
    else
      ok "Stack $STACK_NAME não existe"
    fi
    ;;
  status)
    aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" \
      --query 'Stacks[0].{Status:StackStatus,Outputs:Outputs}'
    ;;
  *) fail "Uso: $0 plan|create|env|delete|status" ;;
esac
