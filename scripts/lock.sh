#!/usr/bin/env bash
# Gera apps/<serviço>/requirements.lock: todas as dependências (inclusive transitivas) fixadas, com hashes.
# Os Dockerfiles instalam SÓ o lock (pip --require-hashes --no-deps), então o mesmo apps/ gera sempre os mesmos pacotes.
# Uso: scripts/lock.sh [app...]           regenera os locks (precisa de uv e acesso ao PyPI)
#      scripts/lock.sh --check [app...]   só confere se cada pin de requirements.txt está no lock (sem rede;
#                                         usado por scripts/images.sh check). Sem app = as 3.
# Edite requirements.txt / shared/requirements-base.txt e rode scripts/lock.sh; faça commit dos dois.
source "$(dirname "$0")/lib/common.sh"
check=false
[[ "${1:-}" == "--check" ]] && { check=true; shift; }
if [[ $# -gt 0 ]]; then SERVICES=("$@"); else SERVICES=("${APPS[@]}"); fi

if [[ "$check" == true ]]; then
  require python3
  for svc in "${SERVICES[@]}"; do
    python3 -I - "$REPO_ROOT/apps/$svc/requirements.txt" "$REPO_ROOT/apps/$svc/requirements.lock" <<'PY' \
      || fail "apps/${svc}/requirements.lock desatualizado: rode scripts/lock.sh e faça commit"
import os, re, sys
norm = lambda n: re.sub(r"[-_.]+", "-", n).lower()
def pins(path):
    for line in open(path):
        line = line.split("#")[0].strip()
        if line.startswith("-r"):
            yield from pins(os.path.join(os.path.dirname(path), line[2:].strip()))
        elif "==" in line:
            name, ver = line.split("==", 1)
            yield norm(name.split("[")[0]), re.split(r"[\s;\\]", ver.strip())[0]
req, lock = sys.argv[1:]
if not os.path.exists(lock):
    sys.exit(f"{lock} não existe")
locked = dict(pins(lock))
missing = [f"{n}=={v}" for n, v in pins(req) if locked.get(n) != v]
if missing:
    sys.exit("faltando no lock: " + ", ".join(missing))
PY
  done
  ok "Lock em dia com requirements.txt (${SERVICES[*]})"
  exit 0
fi

require uv
for svc in "${SERVICES[@]}"; do
  # --universal: um lock válido para amd64 e arm64 (a arquitetura vai na tag da imagem).
  (cd "$REPO_ROOT/apps/$svc" && uv pip compile requirements.txt --universal --python-version 3.12 \
    --generate-hashes --custom-compile-command "scripts/lock.sh" -q -o requirements.lock)
  ok "apps/${svc}/requirements.lock ($(grep -c '^[a-z0-9].*==' "$REPO_ROOT/apps/$svc/requirements.lock") pacotes)"
done
