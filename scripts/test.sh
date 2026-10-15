#!/usr/bin/env bash
# Testes locais (sem AWS): unitários das 3 APIs + integração com processos reais e DynamoDB Local.
# Requer Python 3.12 (uv recomendado) e Docker (para DynamoDB Local; sem Docker usa moto server).
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -x .venv/bin/python ]]; then
  if command -v uv >/dev/null; then uv venv -q -p 3.12 .venv && uv pip install -q -p .venv/bin/python -r apps/requirements-dev.txt
  else python3.12 -m venv .venv && .venv/bin/pip install -q -r apps/requirements-dev.txt; fi
fi
status=0
for svc in orders-api inventory-api bff-api; do
  echo "==> unit: $svc"; .venv/bin/python -m pytest -q "apps/$svc/tests" 2>&1 | grep -v '^{"timestamp' || status=1
done
echo "==> integração (BFF -> Orders -> Inventory + DynamoDB Local)"
.venv/bin/python -m pytest -q tests/integration 2>&1 | grep -v '^{"timestamp' || status=1
exit $status
