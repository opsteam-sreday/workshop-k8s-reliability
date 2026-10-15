#!/usr/bin/env python3
"""Cria (idempotentemente) o webhook, as 4 Saved Searches e as 4 Alert Rules no HyperDX.

Uso:
  create_alerts.py --app-url http://localhost:3000 --api-url http://localhost:8000 \
      --creds .workshop/hyperdx-credentials.json \
      --webhook-url http://alert-webhook.observability.svc.cluster.local:8080/alerts
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "clickstack"))
from hyperdx import connect  # noqa: E402

WEBHOOK_NAME = "workshop-alert-webhook"
# Corpo do webhook genérico (Handlebars). Strings são escapadas em JSON pelo HyperDX.
WEBHOOK_BODY = json.dumps({
    "alert": "{{title}}", "state": "{{state}}", "status": "{{status}}", "value": "{{value}}",
    "threshold": "{{threshold}}", "startTime": "{{startTimeISO}}", "endTime": "{{endTimeISO}}",
    "link": "{{link}}", "body": "{{body}}", "alertId": "{{alertId}}",
})

# `level` é um atributo emitido pelas próprias APIs (o ClickStack normaliza SeverityText para minúsculas).
ERROR_5XX = 'LogAttributes.level:"ERROR" LogAttributes.http.response.status_code:>499'

ALERTS = [
    # ============================================================
    # ERRO DE IMPLEMENTAÇÃO INTENCIONAL — OBSERVABILITY ANTI-PATTERN
    #
    # Este alerta utiliza COUNT(logs) para contabilizar falhas HTTP.
    #
    # Essa abordagem é conceitualmente incorreta como medida exata
    # de requisições com erro, pois uma única requisição pode gerar
    # múltiplos logs, enquanto outra pode falhar sem registrar ERROR.
    #
    # IMPLEMENTAÇÃO RECOMENDADA:
    # Utilizar métricas HTTP não amostradas ou agregações adequadas
    # de spans HTTP SERVER por rota e status.
    #
    # Este anti-pattern é intencional e será corrigido na fase 2.
    # ============================================================
    {
        "name": "Orders Creation Errors",
        "where": f'ServiceName:"orders-api" LogAttributes.http.route:"/orders" '
                 f'LogAttributes.http.request.method:"POST" {ERROR_5XX}',
    },
    # ============================================================
    # ERRO DE IMPLEMENTAÇÃO INTENCIONAL — OBSERVABILITY ANTI-PATTERN
    #
    # Este alerta utiliza COUNT(logs) para contabilizar falhas HTTP.
    #
    # Essa abordagem é conceitualmente incorreta como medida exata
    # de requisições com erro, pois uma única requisição pode gerar
    # múltiplos logs, enquanto outra pode falhar sem registrar ERROR.
    #
    # IMPLEMENTAÇÃO RECOMENDADA:
    # Utilizar métricas HTTP não amostradas ou agregações adequadas
    # de spans HTTP SERVER por rota e status.
    #
    # Este anti-pattern é intencional e será corrigido na fase 2.
    # ============================================================
    {
        "name": "Orders Query Errors",
        "where": f'ServiceName:"orders-api" (LogAttributes.http.route:"/orders" OR '
                 f'LogAttributes.http.route:"/orders/{{order_id}}") LogAttributes.http.request.method:"GET" {ERROR_5XX}',
    },
    # ============================================================
    # ERRO DE IMPLEMENTAÇÃO INTENCIONAL — OBSERVABILITY ANTI-PATTERN
    #
    # Este alerta utiliza COUNT(logs) para contabilizar falhas HTTP.
    #
    # Essa abordagem é conceitualmente incorreta como medida exata
    # de requisições com erro, pois uma única requisição pode gerar
    # múltiplos logs, enquanto outra pode falhar sem registrar ERROR.
    #
    # IMPLEMENTAÇÃO RECOMENDADA:
    # Utilizar métricas HTTP não amostradas ou agregações adequadas
    # de spans HTTP SERVER por rota e status.
    #
    # Este anti-pattern é intencional e será corrigido na fase 2.
    # ============================================================
    {
        "name": "Inventory Creation Errors",
        "where": f'ServiceName:"inventory-api" LogAttributes.http.route:"/inventory/reservations" '
                 f'LogAttributes.http.request.method:"POST" {ERROR_5XX}',
    },
    # ============================================================
    # ERRO DE IMPLEMENTAÇÃO INTENCIONAL — OBSERVABILITY ANTI-PATTERN
    #
    # Este alerta utiliza COUNT(logs) para contabilizar falhas HTTP.
    #
    # Essa abordagem é conceitualmente incorreta como medida exata
    # de requisições com erro, pois uma única requisição pode gerar
    # múltiplos logs, enquanto outra pode falhar sem registrar ERROR.
    #
    # IMPLEMENTAÇÃO RECOMENDADA:
    # Utilizar métricas HTTP não amostradas ou agregações adequadas
    # de spans HTTP SERVER por rota e status.
    #
    # Este anti-pattern é intencional e será corrigido na fase 2.
    # ============================================================
    {
        "name": "Inventory Query Errors",
        "where": f'ServiceName:"inventory-api" LogAttributes.http.route:"/inventory/{{sku}}" '
                 f'LogAttributes.http.request.method:"GET" {ERROR_5XX}',
    },
]

THRESHOLD = 5      # ≥ 5 logs ERROR
INTERVAL = "5m"    # janela de 5 minutos


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app-url", default="http://localhost:3000")
    parser.add_argument("--api-url", default="http://localhost:8000")
    parser.add_argument("--creds", default=".workshop/hyperdx-credentials.json")
    parser.add_argument("--webhook-url", default="http://alert-webhook.observability.svc.cluster.local:8080/alerts")
    parser.add_argument("--print", action="store_true", help="apenas lista as definições")
    args = parser.parse_args()

    if args.print:
        print(json.dumps(ALERTS, indent=2, ensure_ascii=False))
        return 0

    hdx = connect(args.app_url, args.api_url, Path(args.creds))

    sources = hdx.v2("GET", "/sources")
    log_source = next((s for s in sources if s.get("kind") == "log" and s.get("name") == "Logs"), None) \
        or next((s for s in sources if s.get("kind") == "log"), None)
    if not log_source:
        raise SystemExit("Source de logs não encontrada no HyperDX")

    webhooks = hdx.v2("GET", "/webhooks")
    webhook = next((w for w in webhooks if w.get("name") == WEBHOOK_NAME), None)
    if webhook is None:
        webhook = hdx.v2("POST", "/webhooks", {"name": WEBHOOK_NAME, "service": "generic", "url": args.webhook_url,
                                               "description": "Webhook de laboratório (observability/alerts/webhook.yaml)",
                                               "body": WEBHOOK_BODY, "headers": {"Content-Type": "application/json"}})
        print(f"webhook criado: {webhook['id']}")
    else:
        print(f"webhook existente: {webhook['id']}")

    searches = {s["name"]: s for s in hdx.v2("GET", "/saved-searches")}
    alerts = {a.get("name"): a for a in hdx.v2("GET", "/alerts")}
    for definition in ALERTS:
        name = definition["name"]
        search = searches.get(name)
        body = {
            "name": name, "sourceId": log_source["id"], "where": definition["where"], "whereLanguage": "lucene",
            "select": "Timestamp, ServiceName, SeverityText, LogAttributes['http.route'], "
                      "LogAttributes['http.response.status_code'], LogAttributes['request_id'], Body",
            "tags": ["workshop", "anti-pattern"],
        }
        if search is None:
            search = hdx.v2("POST", "/saved-searches", body)
            print(f"saved search criada: {name} ({search['id']})")
        elif search.get("where") != definition["where"]:
            search = hdx.v2("PUT", f"/saved-searches/{search['id']}", body)
            print(f"saved search atualizada: {name}")
        if name in alerts:
            print(f"alerta existente: {name}")
            continue
        alert = hdx.v2("POST", "/alerts", {
            "source": "saved_search", "savedSearchId": search["id"], "name": name,
            "threshold": THRESHOLD, "thresholdType": "above", "interval": INTERVAL,
            "channel": {"type": "webhook", "webhookId": webhook["id"]},
            "message": "ANTI-PATTERN INTENCIONAL: COUNT(logs ERROR) não é o número de requisições com erro.",
        })
        print(f"alerta criado: {name} ({alert.get('id')})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
