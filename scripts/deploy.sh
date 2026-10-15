#!/usr/bin/env bash
# Build + push das 3 imagens para o Amazon ECR e deploy no namespace ecommerce.
# Uso: scripts/deploy.sh [--skip-build | --build-only]
#   --build-only  só build/push (a frota faz isso uma vez; os clusters usam --skip-build)
source "$(dirname "$0")/lib/common.sh"
require aws kubectl python3
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
  require docker
  info "Login no ECR ${REGISTRY}"
  aws ecr get-login-password --region "$AWS_REGION" | with_timeout 60 docker login --username AWS --password-stdin "$REGISTRY" >/dev/null \
    || fail "docker login no ECR falhou/expirou (tente DOCKER_ISOLATED_CONFIG=true scripts/deploy.sh)"
  for svc in "${SERVICES[@]}"; do
    repo="${ECR_PREFIX}/${svc}"
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

[[ "${1:-}" == "--build-only" ]] && { ok "Imagens publicadas (${ECR_PREFIX}/*:${IMAGE_TAG})"; exit 0; }

# Overlay gerado com valores do cluster (imagens ECR, região e tabela).
OVERLAY="$OVERLAY_DIR"
mkdir -p "$OVERLAY"
BASE_REL="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$REPO_ROOT/kubernetes/base" "$OVERLAY")"
cat > "$OVERLAY/kustomization.yaml" <<YAML
# GERADO por scripts/deploy.sh — não editar.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ${BASE_REL}
images:
$(for svc in "${SERVICES[@]}"; do printf '  - name: %s\n    newName: %s/%s/%s\n    newTag: "%s"\n' "$svc" "$REGISTRY" "$ECR_PREFIX" "$svc" "$IMAGE_TAG"; done)
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
kubectl apply -k "$OVERLAY"   # plataforma (namespaces, PriorityClasses, NetworkPolicies) + apps (inclui o HPA)
for svc in "${SERVICES[@]}"; do
  kubectl -n ecommerce rollout status "deploy/${svc}" --timeout=5m
done
ok "Deploy concluído. Valide com: scripts/validate.sh"
