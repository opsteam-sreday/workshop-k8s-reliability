#!/usr/bin/env bash
# Imagens das APIs no ECR: uma tag por app, multi-arch (linux/amd64 + linux/arm64).
#   <ECR_PREFIX>/<app>:<tag>-amd64   imagem amd64
#   <ECR_PREFIX>/<app>:<tag>-arm64   imagem arm64
#   <ECR_PREFIX>/<app>:<tag>         índice multi-arch com as duas — é a tag que os clusters usam
# <tag> = image_tag (scripts/lib/common.sh). Repositórios IMMUTABLE: tag publicada nunca muda; reexecutar
# com o mesmo código não refaz nada. Cada passo é um subcomando, usado igual pelo build local
# (scripts/deploy.sh) e pelo pipeline (.github/workflows/images.yml).
#
# Uso: scripts/images.sh <comando> [app] [arch]
#   tag <app>            imprime a tag
#   check <app>          sem alterações não commitadas + requirements.lock em dia
#   published <app>      sucesso se o índice multi-arch <tag> já existe no ECR
#   login                docker login no ECR
#   repo <app>           cria o repositório (IMMUTABLE, scan on push) ou garante IMMUTABLE no existente
#   build <app> <arch>   build + push de <tag>-<arch> (amd64 | arm64)
#   manifest <app>       publica o índice <tag> a partir de <tag>-amd64 e <tag>-arm64
#   all                  check + repo + build (todas as arquiteturas) + manifest das 3 apps
export WORKSHOP_NO_CLUSTER=true   # não opera um cluster
source "$(dirname "$0")/lib/common.sh"
# tag/check não usam AWS (o pipeline roda os dois antes de ter credenciais).
if [[ "${1:-}" != tag && "${1:-}" != check ]]; then
  require aws
  account_id >/dev/null
  REGISTRY="$(ecr_registry)"
fi

# DOCKER_ISOLATED_CONFIG=true: usa um DOCKER_CONFIG temporário SEM credsStore (Keychain/Desktop helper),
# reaproveitando plugins e contextos do ~/.docker. Útil quando o credential helper trava.
if [[ "${DOCKER_ISOLATED_CONFIG:-false}" == "true" ]]; then
  export DOCKER_CONFIG="$STATE_DIR/docker-config"
  if [[ ! -f "$DOCKER_CONFIG/config.json" ]]; then
    mkdir -p "$DOCKER_CONFIG"
    ctx="$(docker context show 2>/dev/null || echo default)"
    printf '{"auths":{},"currentContext":"%s"}\n' "$ctx" > "$DOCKER_CONFIG/config.json"
  fi
  for d in cli-plugins contexts buildx; do [[ -e "$HOME/.docker/$d" && ! -e "$DOCKER_CONFIG/$d" ]] && ln -s "$HOME/.docker/$d" "$DOCKER_CONFIG/$d"; done
fi

valid_app() { [[ " ${APPS[*]} " == *" ${1:-} "* ]] || fail "app inválida: '${1:-}' (use: ${APPS[*]})"; }
tag_of() { image_tag "$1" || fail "não foi possível calcular a tag de $1 (não é um clone git? defina IMAGE_TAG)"; }
repo_of() { echo "${ECR_PREFIX}/$1"; }
exists() {  # exists <app> <tag>
  aws ecr describe-images --repository-name "$(repo_of "$1")" --image-ids imageTag="$2" --region "$AWS_REGION" >/dev/null 2>&1
}

cmd_check() {
  local app="$1"
  # A tag vem do código commitado: alterações locais gerariam uma imagem diferente sob a mesma tag.
  if [[ -z "${IMAGE_TAG:-}" && -n "$(git -C "$REPO_ROOT" status --porcelain -- "apps/$app" apps/shared apps/.dockerignore)" ]]; then
    fail "${app}: alterações não commitadas em apps/${app} ou apps/shared (faça commit: a tag é o hash delas) ou defina IMAGE_TAG"
  fi
  "$REPO_ROOT/scripts/lock.sh" --check "$app"
}

cmd_login() {
  require docker
  aws ecr get-login-password --region "$AWS_REGION" | with_timeout 60 docker login --username AWS --password-stdin "$REGISTRY" >/dev/null \
    || fail "docker login no ECR falhou/expirou (tente DOCKER_ISOLATED_CONFIG=true)"
  ok "Login no ECR ${REGISTRY}"
}

cmd_repo() {
  local repo; repo="$(repo_of "$1")"
  if aws ecr describe-repositories --repository-names "$repo" --region "$AWS_REGION" >/dev/null 2>&1; then
    aws ecr put-image-tag-mutability --repository-name "$repo" --image-tag-mutability IMMUTABLE --region "$AWS_REGION" >/dev/null
  else
    aws ecr create-repository --repository-name "$repo" --region "$AWS_REGION" --image-tag-mutability IMMUTABLE \
      --image-scanning-configuration scanOnPush=true --tags Key=workshop,Value=kubernetes-reliability >/dev/null
  fi
  ok "Repositório ${repo} (IMMUTABLE)"
}

cmd_build() {
  local app="$1" arch="${2:-}" tag image
  [[ " ${IMAGE_ARCHS[*]} " == *" ${arch} "* ]] || fail "arquitetura inválida: '${arch}' (use: ${IMAGE_ARCHS[*]})"
  require docker
  tag="$(tag_of "$app")"; image="${REGISTRY}/$(repo_of "$app"):${tag}-${arch}"
  if exists "$app" "${tag}-${arch}"; then ok "${image} (já publicada)"; return; fi
  info "Build ${app} linux/${arch}"
  # No CI (CI=true) mostra o log completo do build; localmente fica silencioso.
  local progress=--quiet out=/dev/null
  [[ "${CI:-}" == true ]] && { progress=--progress=plain; out=/dev/stdout; }
  docker buildx build "$progress" --platform "linux/${arch}" -f "$REPO_ROOT/apps/${app}/Dockerfile" \
    -t "$image" --load "$REPO_ROOT/apps" >"$out"
  # Push com watchdog + retry: uploads ocasionalmente travam (Docker Desktop/redes de evento).
  # Tag imutável: se um push "falho" chegou a gravar a tag, repetir seria rejeitado — confira antes.
  local attempt
  for attempt in 1 2 3; do
    if with_timeout 300 docker push --quiet "$image" >/dev/null 2>&1 || exists "$app" "${tag}-${arch}"; then
      ok "$image"; return
    fi
    warn "push de ${app} ${arch} falhou/expirou (tentativa ${attempt}/3)"; sleep 5
  done
  fail "não foi possível enviar ${image}"
}

cmd_manifest() {
  local app="$1" tag base arch sources=()
  tag="$(tag_of "$app")"; base="${REGISTRY}/$(repo_of "$app")"
  if exists "$app" "$tag"; then ok "${base}:${tag} (já publicado)"; return; fi
  for arch in "${IMAGE_ARCHS[@]}"; do
    exists "$app" "${tag}-${arch}" || fail "${base}:${tag}-${arch} não existe (rode: scripts/images.sh build ${app} ${arch})"
    sources+=("${base}:${tag}-${arch}")
  done
  require docker
  # Outro build da mesma tag pode ter publicado o índice no meio do caminho: conta como sucesso.
  docker buildx imagetools create -t "${base}:${tag}" "${sources[@]}" >/dev/null 2>&1 || exists "$app" "$tag" \
    || fail "não foi possível publicar o índice ${base}:${tag}"
  ok "${base}:${tag} (multi-arch: ${IMAGE_ARCHS[*]})"
}

case "${1:-}" in
  tag)       valid_app "${2:-}"; tag_of "$2" ;;
  check)     valid_app "${2:-}"; cmd_check "$2" ;;
  published) valid_app "${2:-}"; tag="$(tag_of "$2")"; exists "$2" "$tag" ;;
  login)     cmd_login ;;
  repo)      valid_app "${2:-}"; cmd_repo "$2" ;;
  build)     valid_app "${2:-}"; cmd_build "$2" "${3:-}" ;;
  manifest)  valid_app "${2:-}"; cmd_manifest "$2" ;;
  all)
    for app in "${APPS[@]}"; do cmd_check "$app"; done
    cmd_login
    for app in "${APPS[@]}"; do
      tag="$(tag_of "$app")"
      if exists "$app" "$tag"; then ok "${REGISTRY}/$(repo_of "$app"):${tag} (já publicado)"; continue; fi
      cmd_repo "$app"
      for arch in "${IMAGE_ARCHS[@]}"; do cmd_build "$app" "$arch"; done
      cmd_manifest "$app"
    done
    ;;
  *) sed -n '2,/^source/p' "$0" | sed '$d'; exit 1 ;;
esac
