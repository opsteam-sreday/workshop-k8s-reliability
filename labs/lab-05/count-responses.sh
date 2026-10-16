#!/usr/bin/env bash
# Conta as respostas de POST/GET /orders da BFF por status HTTP desde um instante (logs "HTTP request completed").
# Uso: T0=$(date -u +%FT%TZ) ... ; labs/lab-05/count-responses.sh "$T0"
source "$(dirname "$0")/../../scripts/lib/common.sh"
require kubectl python3
since="${1:?uso: count-responses.sh <RFC3339, ex.: \$(date -u +%FT%TZ)>}"
for p in $(kubectl -n ecommerce get pod -l app.kubernetes.io/name=bff-api -o name); do
  kubectl -n ecommerce logs "$p" -c app --since-time="$since"
done | python3 -c '
import collections, json, sys
c = collections.Counter()
for line in sys.stdin:
    try:
        r = json.loads(line)
    except ValueError:
        continue
    if r.get("message") == "HTTP request completed" and str(r.get("http.route", "")).startswith("/orders"):
        c[r.get("http.response.status_code")] += 1
total = sum(c.values())
errors = sum(v for k, v in c.items() if str(k).startswith("5"))
print("respostas da BFF:", ", ".join(f"{k}={v}" for k, v in sorted(c.items(), key=lambda kv: str(kv[0]))) or "nenhuma",
      f"(total {total}, erros 5xx {errors})")
'
