#!/usr/bin/env python3
"""Ambiente LOCAL (sem AWS): DynamoDB Local + Inventory + Orders + BFF em processos reais.

Opcionalmente exporta OTLP para um ClickStack local (all-in-one):
  docker run -d --name clickstack-local -p 18080:8080 -p 18000:8000 -p 14318:4318 \
     -e FRONTEND_URL=http://localhost:18080 docker.clickhouse.com/clickhouse/clickstack-all-in-one:2.39.1

Uso:
  .venv/bin/python scripts/local/stack.py [--otlp http://localhost:14318 --ingestion-key <key>]
Imprime as URLs (BFF/admin) e mantém o ambiente ativo até Ctrl+C.
"""

import argparse
import json
import os
import signal
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests" / "integration"))

parser = argparse.ArgumentParser()
parser.add_argument("--otlp", help="endpoint OTLP/HTTP (ex.: http://localhost:14318)")
parser.add_argument("--ingestion-key", help="ClickStack ingestion key (header authorization)")
parser.add_argument("--state-file", default=str(ROOT / ".workshop" / "local-stack.json"))
args = parser.parse_args()

if args.otlp:
    os.environ["OTEL_EXPORTER_OTLP_ENDPOINT"] = args.otlp
    os.environ["OTEL_METRIC_EXPORT_INTERVAL"] = "5000"
    if args.ingestion_key:
        os.environ["OTEL_EXPORTER_OTLP_HEADERS"] = f"authorization={args.ingestion_key}"

from conftest import Env  # noqa: E402

logdir = Path(tempfile.mkdtemp(prefix="workshop-local-"))
env = Env(logdir)
state = {
    "bff": env.bff.url, "orders": env.orders.url, "inventory": env.inventory.url,
    "admin": {"bff": env.bff.admin, "orders": env.orders.admin, "inventory": env.inventory.admin},
    "dynamodb": env.dynamo.endpoint, "dynamodb_kind": env.dynamo.kind, "logs": str(logdir),
}
Path(args.state_file).parent.mkdir(parents=True, exist_ok=True)
Path(args.state_file).write_text(json.dumps(state, indent=2))
print(json.dumps(state, indent=2), flush=True)


def stop(*_):
    env.stop()
    sys.exit(0)


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
while True:
    time.sleep(3600)
