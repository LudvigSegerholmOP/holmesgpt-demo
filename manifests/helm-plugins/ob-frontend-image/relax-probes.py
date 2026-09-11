#!/usr/bin/env python3
"""Loosen container probes on every Deployment in a manifest stream.

Under QEMU user-mode emulation (arm64 node, amd64 images) the Python services
take well over a second to answer their first gRPC health check, and the
chart's probes (timeoutSeconds: 1, periodSeconds: 5, failureThreshold: 3) get
them killed in a loop before they ever become ready. Raise each probe to the
floors below; probes already above a floor are left alone.

Reads YAML documents on stdin, writes them on stdout.
"""
import sys
import yaml

FLOORS = {
    "initialDelaySeconds": 20,
    "timeoutSeconds": 10,
    "periodSeconds": 10,
    "failureThreshold": 10,
}
PROBES = ("startupProbe", "readinessProbe", "livenessProbe")


def relax(container):
    for name in PROBES:
        probe = container.get(name)
        if not isinstance(probe, dict):
            continue
        for key, floor in FLOORS.items():
            probe[key] = max(int(probe.get(key, 0)), floor)


docs = []
for doc in yaml.safe_load_all(sys.stdin):
    if isinstance(doc, dict) and doc.get("kind") == "Deployment":
        spec = doc.get("spec", {}).get("template", {}).get("spec", {})
        for c in spec.get("containers", []) + spec.get("initContainers", []):
            relax(c)
    docs.append(doc)

yaml.safe_dump_all(docs, sys.stdout, default_flow_style=False, sort_keys=False)
