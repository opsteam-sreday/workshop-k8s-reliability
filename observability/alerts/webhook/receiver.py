#!/usr/bin/env python3
"""Receptor de webhooks de laboratório (somente stdlib).

POST /alerts  -> registra o payload (log JSON em stdout) e guarda os últimos 200 em memória.
GET  /alerts  -> lista os alertas recebidos (usado por scripts/validate.sh e LAB 05).
GET  /healthz -> health check.
"""

import json
import os
import sys
import threading
from collections import deque
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RECEIVED: deque = deque(maxlen=200)
LOCK = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def _send(self, status: int, body: object) -> None:
        data = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):  # noqa: N802
        if self.path.startswith("/healthz"):
            return self._send(200, {"status": "ok"})
        if self.path.startswith("/alerts"):
            with LOCK:
                return self._send(200, {"count": len(RECEIVED), "alerts": list(RECEIVED)})
        return self._send(404, {"error": "not found"})

    def do_POST(self):  # noqa: N802
        if not self.path.startswith("/alerts"):
            return self._send(404, {"error": "not found"})
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(min(length, 1_000_000)).decode(errors="replace")
        try:
            payload = json.loads(raw)
        except ValueError:
            payload = {"raw": raw}
        entry = {"received_at": datetime.now(timezone.utc).isoformat(), "idempotency_key": self.headers.get("Idempotency-Key"),
                 "payload": payload}
        with LOCK:
            RECEIVED.append(entry)
        print(json.dumps({"level": "WARN", "message": "ALERTA RECEBIDO", **entry}, ensure_ascii=False), flush=True)
        return self._send(200, {"status": "received"})

    def log_message(self, *_):  # silencia o access log padrão
        pass


if __name__ == "__main__":
    port = int(os.getenv("PORT", "8080"))
    print(json.dumps({"level": "INFO", "message": f"alert-webhook ouvindo em :{port}"}), flush=True)
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
    sys.exit(0)
