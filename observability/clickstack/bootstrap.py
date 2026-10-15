#!/usr/bin/env python3
"""Registra o usuário instrutor no HyperDX e imprime a Ingestion API Key da equipe.

Uso: bootstrap.py --app-url http://localhost:3000 --api-url http://localhost:8000 --creds .workshop/hyperdx-credentials.json
A chave é impressa em stdout (para o setup.sh criar o Secret clickstack-ingestion).
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from hyperdx import connect  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app-url", default="http://localhost:3000")
parser.add_argument("--api-url", default="http://localhost:8000")
parser.add_argument("--creds", default=".workshop/hyperdx-credentials.json")
args = parser.parse_args()

client = connect(args.app_url, args.api_url, Path(args.creds))
print(client.ingestion_key())
