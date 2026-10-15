#!/usr/bin/env bash
# Testes positivos e NEGATIVOS de EKS Pod Identity e isolamento IAM.
#   1. Orders API (orders-api-sa) acessa o DynamoDB — e SOMENTE o necessário (Scan/DescribeTable negados),
#      SÓ na tabela do próprio cluster (PutItem/GetItem em outra tabela da conta negados — isolamento da turma).
#   2. bff-api-sa e inventory-api-sa NÃO obtêm credenciais AWS (sem associação; IMDS bloqueado).
#   3. Ninguém consegue criar um Pod "avulso" com orders-api-sa (ValidatingAdmissionPolicy).
#   4. kubectl debug (container efêmero) em Pods da Orders API é negado.
source "$(dirname "$0")/lib/common.sh"
require kubectl
AWSCLI_IMAGE="${AWSCLI_IMAGE:-public.ecr.aws/aws-cli/aws-cli:latest}"
pass=0; failn=0
result() { if [[ "$1" == "PASS" ]]; then ok "PASS — $2"; pass=$((pass+1)); else warn "FAIL — $2"; failn=$((failn+1)); fi; }

# ---------------------------------------------------------------- 1. positivo (Orders)
pod="$(kubectl -n ecommerce get pod -l app.kubernetes.io/name=orders-api --field-selector=status.phase=Running -o go-template='{{range .items}}{{if not .metadata.deletionTimestamp}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | head -1)"
out="$(kubectl -n ecommerce exec -i "$pod" -c app -- python - <<'PY' 2>&1 || true
import os, boto3, botocore
table, region = os.environ["ORDERS_TABLE_NAME"], os.environ["AWS_REGION"]
sts = boto3.client("sts", region_name=region)
print("IDENTITY", sts.get_caller_identity()["Arn"])
ddb = boto3.client("dynamodb", region_name=region)
ddb.get_item(TableName=table, Key={"PK": {"S": "ORDER#__iam_check__"}, "SK": {"S": "META"}})
print("GETITEM_OK")
ddb.query(TableName=table, IndexName="GSI1", KeyConditionExpression="GSI1PK = :p", ExpressionAttributeValues={":p": {"S": "CUSTOMER#__iam_check__"}}, Limit=1)
print("QUERY_OK")
for name, call in [("SCAN", lambda: ddb.scan(TableName=table, Limit=1)),
                   ("DESCRIBE", lambda: ddb.describe_table(TableName=table)),
                   ("DELETEITEM", lambda: ddb.delete_item(TableName=table, Key={"PK": {"S": "x"}, "SK": {"S": "y"}})),
                   ("LISTTABLES", lambda: ddb.list_tables()),
                   # Outra tabela da conta (ex.: de outro aluno): a policy só cobre a tabela deste cluster.
                   ("OTHERTABLE", lambda: ddb.get_item(TableName=table + "-other-tenant", Key={"PK": {"S": "x"}, "SK": {"S": "y"}}))]:
    try:
        call(); print(name + "_ALLOWED")
    except botocore.exceptions.ClientError as e:
        print(name + "_DENIED", e.response["Error"]["Code"])
PY
)"
echo "$out" | sed 's/^/    /'
grep -q "assumed-role/${ORDERS_ROLE_NAME}/" <<<"$out" && result PASS "Orders API assume ${ORDERS_ROLE_NAME} via Pod Identity" || result FAIL "Orders API não assumiu ${ORDERS_ROLE_NAME}"
grep -q GETITEM_OK <<<"$out" && grep -q QUERY_OK <<<"$out" && result PASS "Orders API: GetItem/Query permitidos" || result FAIL "Orders API sem GetItem/Query"
for op in SCAN DESCRIBE DELETEITEM LISTTABLES OTHERTABLE; do
  grep -q "${op}_DENIED AccessDenied" <<<"$out" && result PASS "Orders API: ${op} negado (least privilege)" || result FAIL "Orders API: ${op} deveria ser negado"
done

# ---------------------------------------------------------------- 2. negativos (BFF e Inventory)
probe_sa() {
  local sa="$1" name="iam-probe-${1%-sa}-$RANDOM"
  kubectl -n ecommerce run "$name" --rm -i --quiet --restart=Never --image="$AWSCLI_IMAGE" --pod-running-timeout=3m \
    --overrides="{\"spec\":{\"serviceAccountName\":\"$sa\",\"automountServiceAccountToken\":false,\"nodeSelector\":{\"workload\":\"apps\"},
      \"securityContext\":{\"runAsNonRoot\":true,\"runAsUser\":1000,\"seccompProfile\":{\"type\":\"RuntimeDefault\"}},
      \"containers\":[{\"name\":\"probe\",\"image\":\"$AWSCLI_IMAGE\",\"env\":[{\"name\":\"HOME\",\"value\":\"/tmp\"},{\"name\":\"AWS_REGION\",\"value\":\"$AWS_REGION\"},{\"name\":\"AWS_EC2_METADATA_SERVICE_ENDPOINT_MODE\",\"value\":\"IPv4\"}],
      \"command\":[\"sh\",\"-c\",\"env | grep -c AWS_CONTAINER_CREDENTIALS_FULL_URI || true; timeout 20 aws sts get-caller-identity 2>&1 | tail -1; timeout 20 aws dynamodb get-item --table-name $TABLE_NAME --key '{\\\"PK\\\":{\\\"S\\\":\\\"x\\\"},\\\"SK\\\":{\\\"S\\\":\\\"y\\\"}}' 2>&1 | tail -1; if command -v curl >/dev/null; then (curl -s -m 3 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' >/dev/null && echo IMDS_REACHABLE) || echo IMDS_BLOCKED; else (timeout 3 bash -c 'echo > /dev/tcp/169.254.169.254/80' && echo IMDS_REACHABLE) || echo IMDS_BLOCKED; fi\"],
      \"securityContext\":{\"allowPrivilegeEscalation\":false,\"capabilities\":{\"drop\":[\"ALL\"]}}}]}}" 2>&1 || true
}
for sa in bff-api-sa inventory-api-sa; do
  out="$(probe_sa "$sa")"
  echo "$out" | sed 's/^/    /'
  if grep -qiE "Unable to locate credentials|NoCredentials" <<<"$out" && ! grep -q '"Arn"' <<<"$out"; then
    result PASS "${sa}: sem credenciais AWS (DynamoDB inacessível)"
  else
    result FAIL "${sa}: obteve credenciais ou resultado inesperado"
  fi
  grep -q IMDS_BLOCKED <<<"$out" && result PASS "${sa}: IMDS do nó inacessível" || result FAIL "${sa}: IMDS acessível"
done

# ---------------------------------------------------------------- 3. Pod avulso com orders-api-sa
out="$(kubectl -n ecommerce run rogue-orders-sa --restart=Never --image="$AWSCLI_IMAGE" --dry-run=server \
  --overrides='{"spec":{"serviceAccountName":"orders-api-sa","securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"rogue","image":"'"$AWSCLI_IMAGE"'","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' -o name 2>&1 || true)"
echo "    $out"
grep -q "restrict-orders-api-sa" <<<"$out" && result PASS "Pod avulso com orders-api-sa negado pela ValidatingAdmissionPolicy" \
  || result FAIL "Pod avulso com orders-api-sa NÃO foi negado"

# ---------------------------------------------------------------- 4. kubectl debug na Orders API
out="$(kubectl -n ecommerce debug "$pod" --image=busybox:1.37 --profile=restricted -c iam-debug -- true 2>&1 || true)"
echo "    $out"
grep -qiE "restrict-orders-api-sa|denied" <<<"$out" && result PASS "Container efêmero em Pod da Orders API negado" \
  || result FAIL "kubectl debug não foi negado"

echo; info "Pod Identity/IAM: ${pass} PASS, ${failn} FAIL"
[[ "$failn" -eq 0 ]]
