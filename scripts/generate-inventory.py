#!/usr/bin/env python3
"""
Generate Ansible inventory from infrastructure.yaml.

Reads the single source of truth (conf/infrastructure.yaml) and outputs
a JSON inventory that Ansible can consume directly. This replaces the
Terraform output-based inventory generation.

Usage:
    python scripts/generate-inventory.py [--output ansible/inventory.json]
"""

import json
import re
import sys
import yaml
from pathlib import Path


def load_infrastructure(config_path: str = "conf/infrastructure.yaml") -> dict:
    """Load and parse infrastructure.yaml."""
    with open(config_path, "r") as f:
        return yaml.safe_load(f)


def build_vm_name(cluster_type: str, cluster_name: str, plane_name: str, node_num: int) -> str:
    """Build the VM name using the naming convention: {type}-{cluster}-{plane}-{nn}"""
    return f"{cluster_type}-{cluster_name}-{plane_name}-{node_num:02d}"


def generate_inventory(infra: dict, dns_domain: str) -> dict:
    """Generate Ansible inventory from infrastructure config."""
    # Ansible inventory is a dict of GROUPS. The implicit "all" group holds
    # every host; k8s_control / k8s_worker / docker_services are the groups
    # the playbooks target. A host can be in "all" plus one or more groups.
    inventory = {
        "all": {"hosts": {}},
        "k8s_control": {"hosts": {}},
        "k8s_worker": {"hosts": {}},
        "docker_services": {"hosts": {}},
    }

    # Process clusters
    # Only clusters with infrastructure_provisioning in enforcement are real
    # VMs Terraform builds (others are skipped — no inventory entries).
    clusters = infra.get("clusters", [])
    for cluster in clusters:
        cluster_name = cluster["name"]
        cluster_type = cluster.get("cluster_type", infra.get("defaults", {}).get("cluster_type", "k8s"))
        enforcement = cluster.get("enforcement", [])

        if "infrastructure_provisioning" not in enforcement:
            continue

        # Process control plane nodes
        cp_config = cluster.get("control_plane", {})
        cp_nodes = cp_config.get("nodes", 0)
        cp_plane_name = infra.get("defaults", {}).get("planes", {}).get("control_plane", {}).get("plane_name", "control")

        for i in range(1, cp_nodes + 1):
            name = build_vm_name(cluster_type, cluster_name, cp_plane_name, i)
            inventory["all"]["hosts"][name] = {"ansible_host": f"{name}.{dns_domain}"}
            inventory["k8s_control"]["hosts"][name] = {}

        # Process worker nodes
        worker_config = cluster.get("workers", {})
        worker_nodes = worker_config.get("nodes", 0)
        worker_plane_name = infra.get("defaults", {}).get("planes", {}).get("workers", {}).get("plane_name", "worker")

        for i in range(1, worker_nodes + 1):
            name = build_vm_name(cluster_type, cluster_name, worker_plane_name, i)
            inventory["all"]["hosts"][name] = {"ansible_host": f"{name}.{dns_domain}"}
            inventory["k8s_worker"]["hosts"][name] = {}

        # Create per-cluster group with vars
        # Ansible group vars (group_vars/k8s_<cluster>.*) could hold these,
        # but putting them here as group vars keeps cluster-specific values
        # (VIP, OIDC, API endpoint) glued to the hosts that use them.
        cluster_group_name = f"k8s_{cluster_name}"
        oidc_issuer_url = cluster.get("oidc_issuer_url", infra.get("platform", {}).get("kubernetes", {}).get("oidc_issuer_url"))
        cp_vip = cp_config.get("vip")
        cp_api_host = f"k8s-{cluster_name}-api.{dns_domain}"
        cp_endpoint = f"{cp_api_host}:6443"

        cluster_hosts = {}
        for i in range(1, cp_nodes + 1):
            name = build_vm_name(cluster_type, cluster_name, cp_plane_name, i)
            cluster_hosts[name] = {}
        for i in range(1, worker_nodes + 1):
            name = build_vm_name(cluster_type, cluster_name, worker_plane_name, i)
            cluster_hosts[name] = {}

        inventory[cluster_group_name] = {
            "hosts": cluster_hosts,
            "vars": {
                "oidc_issuer_url": oidc_issuer_url,
                "cp_vip": cp_vip,
                "cp_api_host": cp_api_host,
                "cp_endpoint": cp_endpoint,
            },
        }

    # Process standalone hosts
    # Non-cluster hosts (docker, firewall) get an ansible_host/ansible_user
    # for SSH; only those opted into configuration_management join the
    # docker_services group the plays target.
    hosts = infra.get("hosts", [])
    for host in hosts:
        name = host["name"]
        connection = host.get("connection", {})
        host_vars = {
            "ansible_host": connection.get("host", name),
            "ansible_user": connection.get("user", "ansible"),
        }
        inventory["all"]["hosts"][name] = host_vars

        enforcement = host.get("enforcement", [])
        if "configuration_management" in enforcement:
            inventory["docker_services"]["hosts"][name] = host_vars

    return inventory


def main():
    """Main entry point."""
    import argparse

    parser = argparse.ArgumentParser(description="Generate Ansible inventory from infrastructure.yaml")
    parser.add_argument(
        "--config",
        default="conf/infrastructure.yaml",
        help="Path to infrastructure.yaml (default: conf/infrastructure.yaml)",
    )
    parser.add_argument(
        "--output",
        default=None,
        help="Output file path (default: stdout)",
    )
    args = parser.parse_args()

    # Load infrastructure
    infra = load_infrastructure(args.config)

    # Get DNS domain
    dns_domain = infra.get("platform", {}).get("proxmox", {}).get("dns_domain", "localdomain")

    # Generate inventory
    inventory = generate_inventory(infra, dns_domain)

    # Output
    output = json.dumps(inventory, indent=2)
    if args.output:
        Path(args.output).parent.mkdir(parents=True, exist_ok=True)
        with open(args.output, "w") as f:
            f.write(output)
        print(f"Inventory written to {args.output}")
    else:
        print(output)


if __name__ == "__main__":
    main()
