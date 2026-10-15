"""Ambiente de integração: DynamoDB Local (Docker) ou moto server + 3 APIs em processos reais."""

from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

import boto3
import httpx
import pytest

ROOT = Path(__file__).resolve().parents[2]
PY = sys.executable
TABLE = "it-orders"


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_http(url: str, timeout: float = 30) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if httpx.get(url, timeout=1).status_code < 500:
                return
        except httpx.HTTPError:
            pass
        time.sleep(0.2)
    raise RuntimeError(f"timeout aguardando {url}")


class Dynamo:
    def __init__(self) -> None:
        self.port = free_port()
        self.container = None
        self.moto = None
        if shutil.which("docker") and subprocess.run(["docker", "info"], capture_output=True).returncode == 0:
            self.container = subprocess.check_output([
                "docker", "run", "-d", "--rm", "-p", f"127.0.0.1:{self.port}:8000", "amazon/dynamodb-local:latest",
                "-jar", "DynamoDBLocal.jar", "-inMemory", "-sharedDb"]).decode().strip()
            self.kind = "dynamodb-local"
        else:  # fallback: moto server (atomicidade sob concorrência não é garantida pelo moto)
            from moto.server import ThreadedMotoServer
            self.moto = ThreadedMotoServer(port=self.port)
            self.moto.start()
            self.kind = "moto"
        self.endpoint = f"http://127.0.0.1:{self.port}"
        self.client = boto3.client("dynamodb", endpoint_url=self.endpoint, region_name="us-east-1",
                                   aws_access_key_id="local", aws_secret_access_key="local")
        deadline = time.time() + 30
        while True:
            try:
                self.client.list_tables()
                break
            except Exception:
                if time.time() > deadline:
                    raise
                time.sleep(0.3)
        spec = json.loads((ROOT / "infrastructure" / "dynamodb-table.json").read_text())
        self.client.create_table(TableName=TABLE, **spec)
        self.client.update_time_to_live(TableName=TABLE, TimeToLiveSpecification={"Enabled": True, "AttributeName": "expires_at"})

    def stop(self) -> None:
        if self.container:
            subprocess.run(["docker", "rm", "-f", self.container], capture_output=True)
        if self.moto:
            self.moto.stop()

    def orders_for(self, customer: str) -> list[dict]:
        resp = self.client.query(TableName=TABLE, IndexName="GSI1", KeyConditionExpression="GSI1PK = :pk",
                                 ExpressionAttributeValues={":pk": {"S": f"CUSTOMER#{customer}"}})
        return resp["Items"]


class Service:
    def __init__(self, name: str, env: dict[str, str], logdir: Path) -> None:
        self.name = name
        self.port = free_port()
        self.admin_port = free_port()
        self.env = {**os.environ, **env, "PORT": str(self.port), "ADMIN_PORT": str(self.admin_port),
                    "WORKSHOP_MODE": "true", "PYTHONPATH": str(ROOT / "apps" / "shared"), "OTEL_SDK_DISABLED": "false",
                    "SHUTDOWN_DELAY_SECONDS": "0"}
        self.logfile = logdir / f"{name}.log"
        self.proc: subprocess.Popen | None = None

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    @property
    def admin(self) -> str:
        return f"http://127.0.0.1:{self.admin_port}"

    def start(self) -> None:
        log = open(self.logfile, "a")
        self.proc = subprocess.Popen([PY, "-m", "app"], cwd=ROOT / "apps" / self.name, env=self.env, stdout=log, stderr=log)
        wait_http(f"{self.url}/health/ready")

    def stop(self) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(10)
            except subprocess.TimeoutExpired:
                self.proc.kill()

    def wait_exit(self, timeout: float = 10) -> int:
        return self.proc.wait(timeout)

    def logs(self) -> list[dict]:
        out = []
        for line in self.logfile.read_text().splitlines():
            if line.startswith("{"):
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
        return out


class Env:
    def __init__(self, tmp: Path) -> None:
        self.dynamo = Dynamo()
        self.inventory = Service("inventory-api", {"INVENTORY_MAX_CONCURRENT_REQUESTS": "200"}, tmp)
        self.inventory.start()
        self.orders = Service("orders-api", {
            "ORDERS_TABLE_NAME": TABLE, "DYNAMODB_ENDPOINT": self.dynamo.endpoint, "AWS_REGION": "us-east-1",
            "AWS_ACCESS_KEY_ID": "local", "AWS_SECRET_ACCESS_KEY": "local", "INVENTORY_URL": self.inventory.url,
            "IDEMPOTENCY_LEASE_SECONDS": "3", "CB_RECOVERY_TIMEOUT_SECONDS": "3", "INVENTORY_MAX_CONCURRENT_REQUESTS": "50",
        }, tmp)
        self.orders.start()
        self.bff = Service("bff-api", {"ORDERS_URL": self.orders.url, "BFF_ORDERS_TIMEOUT_MS": "5000"}, tmp)
        self.bff.start()

    def stop(self) -> None:
        for s in (self.bff, self.orders, self.inventory):
            s.stop()
        self.dynamo.stop()

    # helpers ------------------------------------------------------------------------
    def admin(self, svc: Service, method: str, path: str, body: dict | None = None) -> dict:
        r = httpx.request(method, f"{svc.admin}{path}", json=body, timeout=10)
        r.raise_for_status()
        return r.json()

    def reset(self) -> None:
        for svc in (self.inventory, self.orders, self.bff):
            self.admin(svc, "POST", "/admin/faults/reset")
        self.admin(self.orders, "POST", "/admin/circuit-breaker/reset")

    def stock(self, sku: str = "product-001") -> int:
        return self.admin(self.inventory, "GET", "/admin/state")["products"][sku]["available"]

    def reservations(self) -> dict:
        return self.admin(self.inventory, "GET", "/admin/state")


@pytest.fixture(scope="session")
def env(tmp_path_factory):
    e = Env(tmp_path_factory.mktemp("logs"))
    yield e
    e.stop()


@pytest.fixture(autouse=True)
def _reset(env):
    env.reset()
    yield
    env.reset()
