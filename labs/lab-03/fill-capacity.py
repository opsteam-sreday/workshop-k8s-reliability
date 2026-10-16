#!/usr/bin/env python3
"""Ocupa a CPU livre dos nós `apps` com Pods "ballast" (pause) de PRIORIDADE ALTA.

Deixa apenas SLACK_M (padrão 100m) livres por nó. Como os ballasts têm prioridade
critical-services (igual à Orders), eles não podem ser preemptados pela Orders API: o
ÚNICO candidato a vítima passa a ser a Inventory API (low-priority-services).
Uso: fill-capacity.py [--slack 100] [--node <nó>]   |   remover: kubectl -n loadtest delete pod -l app.kubernetes.io/name=capacity-ballast
"""

from __future__ import annotations

import argparse
import json
import subprocess


def kubectl(*args: str, stdin: str | None = None) -> str:
    return subprocess.run(["kubectl", *args], input=stdin, check=True, capture_output=True, text=True).stdout


def cpu_m(value: str) -> int:
    if value.endswith("m"):
        return int(value[:-1])
    return int(float(value) * 1000)


parser = argparse.ArgumentParser()
parser.add_argument("--slack", type=int, default=100, help="millicores livres deixados em cada nó")
parser.add_argument("--node", help="ocupa só este nó apps (LAB 07: topology spread); padrão: todos")
args = parser.parse_args()

nodes = json.loads(kubectl("get", "nodes", "-l", "workload=apps", "-o", "json"))["items"]
pods = json.loads(kubectl("get", "pods", "-A", "-o", "json", "--field-selector=status.phase!=Succeeded,status.phase!=Failed"))["items"]
if args.node:
    nodes = [n for n in nodes if n["metadata"]["name"] == args.node]
    if not nodes:
        raise SystemExit(f"{args.node} não é um nó workload=apps")
for node in nodes:
    name = node["metadata"]["name"]
    allocatable = cpu_m(node["status"]["allocatable"]["cpu"])
    requested = 0
    for pod in pods:
        if pod["spec"].get("nodeName") != name:
            continue
        for c in pod["spec"]["containers"]:
            requested += cpu_m(c.get("resources", {}).get("requests", {}).get("cpu", "0"))
    ballast = allocatable - requested - args.slack
    print(f"{name}: allocatable={allocatable}m requested={requested}m -> ballast={max(ballast, 0)}m")
    if ballast <= 0:
        continue
    manifest = {
        "apiVersion": "v1", "kind": "Pod",
        "metadata": {"generateName": "capacity-ballast-", "namespace": "loadtest",
                     "labels": {"app.kubernetes.io/name": "capacity-ballast", "app.kubernetes.io/part-of": "reliability-workshop"}},
        "spec": {
            "priorityClassName": "critical-services",
            "automountServiceAccountToken": False,
            "affinity": {"nodeAffinity": {"requiredDuringSchedulingIgnoredDuringExecution": {"nodeSelectorTerms": [
                {"matchExpressions": [{"key": "kubernetes.io/hostname", "operator": "In", "values": [node["metadata"]["labels"]["kubernetes.io/hostname"]]}]}]}}},
            "securityContext": {"runAsNonRoot": True, "runAsUser": 65535, "seccompProfile": {"type": "RuntimeDefault"}},
            "containers": [{
                "name": "pause", "image": "registry.k8s.io/pause:3.10",
                "resources": {"requests": {"cpu": f"{ballast}m", "memory": "16Mi"}, "limits": {"memory": "16Mi"}},
                "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}},
            }],
        },
    }
    print(kubectl("create", "-f", "-", stdin=json.dumps(manifest)).strip())
