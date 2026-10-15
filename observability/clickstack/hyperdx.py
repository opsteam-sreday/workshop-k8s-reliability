"""Cliente mínimo (somente stdlib) para o HyperDX do ClickStack.

- API interna (UI, cookie de sessão) via porta 3000: registro, login, /api/team (ingestion key), /api/me.
- External API v2 via porta 8000 com Personal API Access Key (Bearer): sources, webhooks,
  saved searches, alerts.
"""

from __future__ import annotations

import json
import os
import secrets
import string
import time
import urllib.error
import urllib.request
from pathlib import Path


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):  # noqa: D401 - captura o 303 do login
        return None


_opener = urllib.request.build_opener(_NoRedirect)


class HyperDXError(RuntimeError):
    pass


class HyperDX:
    def __init__(self, app_url: str, api_url: str) -> None:
        self.app_url = app_url.rstrip("/")
        self.api_url = api_url.rstrip("/")
        self.cookie: str | None = None
        self.access_key: str | None = None

    # ------------------------------------------------------------------ transporte
    def _request(self, method: str, url: str, body: object | None = None, headers: dict | None = None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method,
                                     headers={"Content-Type": "application/json", "Accept": "application/json", **(headers or {})})
        try:
            resp = _opener.open(req, timeout=30)
            status, resp_headers, raw = resp.status, resp.headers, resp.read()
        except urllib.error.HTTPError as exc:
            status, resp_headers, raw = exc.code, exc.headers, exc.read()
        set_cookie = resp_headers.get_all("Set-Cookie") or []
        for c in set_cookie:
            if c.startswith("connect.sid="):
                self.cookie = c.split(";", 1)[0]
        try:
            payload = json.loads(raw) if raw else None
        except ValueError:
            payload = raw.decode(errors="replace")
        return status, payload

    def internal(self, method: str, path: str, body: object | None = None):
        headers = {"Cookie": self.cookie} if self.cookie else {}
        return self._request(method, f"{self.app_url}/api{path}", body, headers)

    def v2(self, method: str, path: str, body: object | None = None):
        if not self.access_key:
            raise HyperDXError("access key ausente: execute login() antes")
        status, payload = self._request(method, f"{self.api_url}/api/v2{path}", body,
                                        {"Authorization": f"Bearer {self.access_key}"})
        if status >= 400:
            raise HyperDXError(f"{method} /api/v2{path} -> {status}: {payload}")
        return payload.get("data", payload) if isinstance(payload, dict) else payload

    # ------------------------------------------------------------------ fluxo
    def wait_ready(self, timeout: float = 300) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                status, _ = self.internal("GET", "/installation")
                if status == 200:
                    return
            except OSError:
                pass
            time.sleep(3)
        raise HyperDXError(f"HyperDX não respondeu em {self.app_url}")

    def team_exists(self) -> bool:
        status, payload = self.internal("GET", "/installation")
        return bool(status == 200 and payload and payload.get("isTeamExisting"))

    def register(self, email: str, password: str) -> None:
        status, payload = self.internal("POST", "/register/password",
                                        {"email": email, "password": password, "confirmPassword": password})
        if status != 200:
            raise HyperDXError(f"registro falhou ({status}): {payload}")

    def login(self, email: str, password: str) -> None:
        status, payload = self.internal("POST", "/login/password", {"email": email, "password": password})
        if status not in (200, 302, 303) or not self.cookie:
            raise HyperDXError(f"login falhou ({status}): {payload}")
        status, me = self.internal("GET", "/me")
        if status != 200 or not isinstance(me, dict):
            raise HyperDXError(f"/api/me falhou ({status}): {me}")
        self.access_key = me.get("accessKey")

    def ingestion_key(self) -> str:
        status, team = self.internal("GET", "/team")
        if status != 200 or not team.get("apiKey"):
            raise HyperDXError(f"/api/team falhou ({status}): {team}")
        return team["apiKey"]


def _password() -> str:
    alphabet = string.ascii_letters + string.digits
    core = "".join(secrets.choice(alphabet) for _ in range(16))
    return f"Ws-{core}9a!Z"


def load_or_create_credentials(path: Path) -> dict:
    if path.exists():
        return json.loads(path.read_text())
    creds = {"email": os.getenv("HYPERDX_EMAIL", "instrutor@workshop.local"),
             "password": os.getenv("HYPERDX_PASSWORD") or _password()}
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(creds, indent=2))
    path.chmod(0o600)
    return creds


def connect(app_url: str, api_url: str, creds_path: Path) -> HyperDX:
    """Registra o primeiro usuário (se ainda não existir equipe) e autentica."""
    client = HyperDX(app_url, api_url)
    client.wait_ready()
    creds = load_or_create_credentials(creds_path)
    if not client.team_exists():
        client.register(creds["email"], creds["password"])
    client.login(creds["email"], creds["password"])
    return client
