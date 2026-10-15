#!/usr/bin/env bash
# Build + push das 3 imagens para o Amazon ECR e deploy no namespace ecommerce.
# Uso: scripts/deploy.sh [--skip-build]
source "$(dirname "$0")/lib/common.sh"
require aws kubectl docker
account_id >/dev/null
REGISTRY="$(ecr_registry)"
SERVICES=(bff-api orders-api inventory-api)
PLATFORM="${PLATFORM:-linux/amd64}"   # m6i = x86_64

# DOCKER_ISOLATED_CONFIG=true: usa um DOCKER_CONFIG temporário SEM credsStore (Keychain/Desktop helper),
# reaproveitando plugins e contextos do ~/.docker. Útil quando o credential helper trava.
if [[ "${DOCKER_ISOLATED_CONFIG:-false}" == "true" ]]; then
  export DOCKER_CONFIG="$STATE_DIR/docker-config"
  mkdir -p "$DOCKER_CONFIG"
  ctx="$(docker context show 2>/dev/null || echo default)"
  printf '{"auths":{},"currentContext":"%s"}\n' "$ctx" > "$DOCKER_CONFIG/config.json"
  for d in cli-plugins contexts buildx; do [[ -e "$HOME/.docker/$d" && ! -e "$DOCKER_CONFIG/$d" ]] && ln -s "$HOME/.docker/$d" "$DOCKER_CONFIG/$d"; done
fi

if [[ "${1:-}" != "--skip-build" ]]; then
  info "Login no ECR ${REGISTRY}"
  aws ecr get-login-password --region "$AWS_REGION" | with_timeout 60 docker login --username AWS --password-stdin "$REGISTRY" >/dev/null \
    || fail "docker login no ECR falhou/expirou (tente DOCKER_ISOLATED_CONFIG=true scripts/deploy.sh)"
  for svc in "${SERVICES[@]}"; do
    repo="reliability-workshop/${svc}"
    aws ecr describe-repositories --repository-names "$repo" --region "$AWS_REGION" >/dev/null 2>&1 || \
      aws ecr create-repository --repository-name "$repo" --region "$AWS_REGION" \
        --image-scanning-configuration scanOnPush=true --tags Key=workshop,Value=kubernetes-reliability >/dev/null
    image="${REGISTRY}/${repo}:${IMAGE_TAG}"
    info "Build ${svc} (${PLATFORM})"
    docker buildx build --quiet --platform "$PLATFORM" -f "$REPO_ROOT/apps/${svc}/Dockerfile" \
      -t "$image" --load "$REPO_ROOT/apps" >/dev/null
    # Push com watchdog + retry: uploads ocasionalmente travam (Docker Desktop/redes de evento).
    pushed=false
    for attempt in 1 2 3; do
      if with_timeout 300 docker push --quiet "$image" >/dev/null 2>&1; then pushed=true; break; fi
      warn "push de ${svc} falhou/expirou (tentativa ${attempt}/3)"; sleep 5
    done
    [[ "$pushed" == true ]] || fail "não foi possível enviar ${image}"
    ok "$image"
  done
fi

# Overlay gerado com valores da conta (imagens ECR, região e tabela).
OVERLAY="$REPO_ROOT/kubernetes/overlays/generated"
mkdir -p "$OVERLAY"
cat > "$OVERLAY/kustomization.yaml" <<YAML
# GERADO por scripts/deploy.sh — não editar.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
images:
$(for svc in "${SERVICES[@]}"; do printf '  - name: %s\n    newName: %s/reliability-workshop/%s\n    newTag: "%s"\n' "$svc" "$REGISTRY" "$svc" "$IMAGE_TAG"; done)
patches:
  - target: {kind: ConfigMap, name: orders-config}
    patch: |-
      - op: replace
        path: /data/ORDERS_TABLE_NAME
        value: "${TABLE_NAME}"
      - op: replace
        path: /data/AWS_REGION
        value: "${AWS_REGION}"
YAML

info "Aplicando manifests"
kubectl apply -f "$REPO_ROOT/kubernetes/priority/priorityclasses.yaml" >/dev/null
kubectl apply -k "$OVERLAY"
kubectl apply -f "$REPO_ROOT/kubernetes/hpa/orders-api-hpa.yaml"
for svc in "${SERVICES[@]}"; do
  kubectl -n ecommerce rollout status "deploy/${svc}" --timeout=5m
done
ok "Deploy concluído. Valide com: scripts/validate.sh"
