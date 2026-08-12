#!/usr/bin/env python3
"""
Allocate VM IDs for standalone hosts — Terraform external data source.

Terraform's HCL cannot "find the first free integer in a range" on its own,
so main.tf calls this script via the `external` provider. Each provisioned
standalone host (infrastructure_provisioning in enforcement) gets a VM ID:

  * an explicit `vm.vm_id` on the host always wins, or
  * the first free ID in `vm.vm_id_start..vm.vm_id_end`, falling back to
    `defaults.vm.vm_id_start..defaults.vm.vm_id_end` (the shared pool that
    standalone VMs auto-roll 9100, 9101, ... from).

The "used" set excludes the Proxmox template ID, every cluster node ID, and
every explicit standalone VM ID, so allocation never collides. Hosts are
processed in YAML order; the caller's own ID is returned on stdout in the
exact shape the external provider expects: {"vm_id":"<number>"}.

Usage: standalone-vm-ids.py <hostname>
"""

import json
import sys
from pathlib import Path

import yaml

BASE = Path(__file__).resolve().parent.parent
INFRA_PATH = BASE / "conf" / "infrastructure.yaml"


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def cluster_node_ids(infra: dict) -> set:
    """All VM IDs claimed by managed cluster nodes (vm_id_start + n)."""
    ids = set()
    for cluster in infra.get("clusters", []):
        for plane_key in ("control_plane", "workers"):
            plane = cluster.get(plane_key, {})
            start = plane.get("vm_id_start")
            count = plane.get("nodes", 0) + plane.get("standby", 0)
            if start is not None:
                ids.update(range(start, start + count))
    return ids


def first_free(start: int, end: int, used: set) -> int:
    """First unused ID in [start, end], or None when the range is exhausted."""
    for vm_id in range(start, end + 1):
        if vm_id not in used:
            return vm_id
    return None


def allocate(infra: dict) -> dict:
    """Return {host_name: vm_id} for every provisioned standalone host."""
    defaults = infra.get("defaults", {}).get("vm", {})
    template_id = infra.get("platform", {}).get("proxmox", {}).get("template_id")

    hosts = [
        h for h in infra.get("hosts", [])
        if "infrastructure_provisioning" in h.get("enforcement", [])
    ]

    used = set()
    if template_id is not None:
        used.add(template_id)
    used |= cluster_node_ids(infra)
    for h in hosts:
        explicit = (h.get("vm", {}) or {}).get("vm_id")
        if explicit is not None:
            used.add(explicit)

    allocated = {}
    for h in hosts:
        name = h.get("name")
        vm = h.get("vm", {}) or {}
        if vm.get("vm_id") is not None:
            allocated[name] = vm["vm_id"]
            continue

        start = vm.get("vm_id_start", defaults.get("vm_id_start"))
        end = vm.get("vm_id_end", defaults.get("vm_id_end"))
        if start is None:
            fail(f"host '{name}' has no explicit vm.vm_id and no vm_id_start configured (checked defaults.vm.vm_id_start)")
        if end is None or end < start:
            fail(f"host '{name}' has an invalid VM ID range ({start}..{end})")

        vm_id = first_free(start, end, used)
        if vm_id is None:
            fail(f"VM ID range {start}..{end} for host '{name}' is exhausted")
        used.add(vm_id)
        allocated[name] = vm_id

    return allocated


def main() -> None:
    if len(sys.argv) != 2:
        fail("expected exactly one argument: the standalone host name")

    hostname = sys.argv[1]
    with open(INFRA_PATH) as f:
        infra = yaml.safe_load(f)

    allocated = allocate(infra)
    if hostname not in allocated:
        fail(f"host '{hostname}' is not a provisioned standalone host")

    print(json.dumps({"vm_id": str(allocated[hostname])}))


if __name__ == "__main__":
    main()
