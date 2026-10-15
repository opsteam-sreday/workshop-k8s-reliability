#!/usr/bin/env bash
# Modo didático: explica um passo, mostra o comando exato e o executa.
#
# Uso: scripts/lib/explain.sh "Título" "Explicação (o quê / por quê)" -- comando [args...]
#
# Variáveis:
#   EXPLAIN=false       desliga as explicações (só executa)
#   EXPLAIN_PAUSE=true  pausa antes de cada comando (ideal para apresentar ao vivo)
#
# As mensagens didáticas vão para o stderr: o stdout é só do comando, então VAR="$(run ...)" captura
# apenas a saída dele (ex.: a ingestion key do HyperDX no setup.sh).
set -uo pipefail
title="$1"; why="$2"; shift 2
[[ "${1:-}" == "--" ]] && shift

if [[ "${EXPLAIN:-true}" != "false" ]]; then
  exec 3>&1 1>&2
  printf '\n\033[1;34m▶ %s\033[0m\n' "$title"
  printf '%s\n' "$why" | fold -s -w 100 | sed 's/^/  /'
  printf '  \033[1;33m$'
  for arg in "$@"; do
    if [[ "$arg" =~ ^[A-Za-z0-9_./:=@%+,-]+$ ]]; then printf ' %s' "$arg"
    else printf " '%s'" "${arg//\'/\'\\\'\'}"; fi
  done
  printf '\033[0m\n'
  if [[ "${EXPLAIN_PAUSE:-false}" == "true" ]]; then
    read -r -p "  [Enter para executar, Ctrl+C para sair] " _ </dev/tty
  fi
  exec 1>&3 3>&-
fi
start=$(date +%s)
"$@"
status=$?
if [[ "${EXPLAIN:-true}" != "false" ]]; then
  exec 1>&2
  if [[ $status -eq 0 ]]; then
    printf '  \033[1;32m✔ concluído em %ss\033[0m\n' "$(( $(date +%s) - start ))"
  else
    printf '  \033[1;31m✘ falhou (exit %s)\033[0m\n' "$status"
  fi
fi
exit $status
