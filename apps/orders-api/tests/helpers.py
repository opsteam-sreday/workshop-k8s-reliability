"""Monta Orders (service) + Inventory (app ASGI real) em processo, com DynamoDB mockado (moto)."""

import importlib.util
import sys
from dataclasses import replace
from pathlib import Path

import httpx

ROOT = Path(__file__).resolve().parents[3]


def load_inventory():
    if "inventory_app.main" in sys.modules:
        return sys.modules["inventory_app.main"]
    pkg_dir = ROOT / "apps" / "inventory-api" / "app"
    spec = importlib.util.spec_from_file_location("inventory_app", pkg_dir / "__init__.py",
                                                  submodule_search_locations=[str(pkg_dir)])
    module = importlib.util.module_from_spec(spec)
    sys.modules["inventory_app"] = module
    spec.loader.exec_module(module)
    import importlib as il
    return il.import_module("inventory_app.main")


def build(dynamodb, clock, table="test-orders", **overrides):
    from app.config import Settings
    from app.inventory_client import InventoryClient
    from app.repository import OrdersRepository
    from app.service import OrderService

    inv = load_inventory()
    inv.store.reset()
    settings = replace(Settings.from_env(), table_name=table, inventory_url="http://inventory", inventory_retry_base_ms=1,
                       inventory_retry_max_backoff_ms=2, **overrides)
    client = InventoryClient(settings, transport=httpx.ASGITransport(app=inv.app))
    repo = OrdersRepository(dynamodb, table, clock=clock)
    return OrderService(settings, repo, client), repo, inv
