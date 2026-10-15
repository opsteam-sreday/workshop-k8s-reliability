#!/usr/bin/env bash
# Deploy das 3 APIs no namespace ecommerce, com as imagens multi-arch do ECR (build: scripts/images.sh).
# Uso: scripts/deploy.sh [--skip-build | --build-only]
#   (padrão)      publica as imagens que ainda não estão no ECR + deploy
#   --build-only  só build/push (a frota faz isso uma vez; o pipeline usa .github/workflows/images.yml)
#   --skip-build  só deploy: as imagens da tag atual de cada app já precisam estar publicadas
source "$(dirname "$0")/lib/common.sh"
require aws kubectl python3
account_id >/dev/null
REGISTRY="$(ecr_registry)"

if [[ "${1:-}" != "--skip-build" ]]; then
  "$REPO_ROOT/scripts/images.sh" all
  [[ "${1:-}" == "--build-only" ]] && { ok "Imagens publicadas (${ECR_PREFIX}/*, ${IMAGE_ARCHS[*]})"; exit 0; }
fi

# Tag de cada app (índice multi-arch: cada nó puxa a sua arquitetura).
TAGS=()
for app in "${APPS[@]}"; do
  tag="$(image_tag "$app")" || fail "não foi possível calcular a tag de ${app} (não é um clone git? defina IMAGE_TAG)"
  "$REPO_ROOT/scripts/images.sh" published "$app" \
    || fail "Imagem ${ECR_PREFIX}/${app}:${tag} não existe no ECR (rode scripts/images.sh all ou o workflow images)"
  TAGS+=("$tag")
done

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
$(for i in "${!APPS[@]}"; do printf '  - name: %s\n    newName: %s/%s/%s\n    newTag: "%s"\n' "${APPS[$i]}" "$REGISTRY" "$ECR_PREFIX" "${APPS[$i]}" "${TAGS[$i]}"; done)
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
for app in "${APPS[@]}"; do
  kubectl -n ecommerce rollout status "deploy/${app}" --timeout=5m
done
# O NLB recebe o hostname em ~1 min; o DNS dele leva mais alguns minutos para responder.
lb=""
for _ in $(seq 1 18); do
  lb="$(kubectl -n ecommerce get svc bff-api-public -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
  [[ -n "$lb" ]] && break; sleep 10
done
if [[ -n "$lb" ]]; then ok "BFF pública: http://${lb}/docs (DNS do NLB leva ~2-3 min na primeira vez)"
else warn "NLB da BFF ainda sem hostname: kubectl -n ecommerce describe svc bff-api-public"; fi
ok "Deploy concluído. Valide com: scripts/validate.sh"
