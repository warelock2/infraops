#!/usr/bin/env python3
"""Reconcile apiServer.extraArgs in the cluster's kubeadm-config ConfigMap.

The API server's OIDC flags are pinned in the kubeadm-config ConfigMap
(data.ClusterConfiguration.apiServer.extraArgs), which kubeadm writes once at
init and never rewrites afterwards. If the IaC template that rendered those
flags changes later (e.g. commit 406ab6b dropped a stale oidc-ca-file pin in
favour of the system CA store), the ConfigMap silently keeps the old flags --
and every *new* control-plane node that joins generates its apiserver manifest
from that stale ConfigMap. That is exactly how a promoted standby ghost's
apiserver ended up referencing /etc/kubernetes/pki/oidc-ca.pem, a file no node
has, and crash-looped forever.

This reconciles only the extraArgs list to the desired name=value flags given
on the command line, leaving every other field of the ConfigMap untouched.
Idempotent: prints "unchanged" and exits 0 when the list already matches.

Usage:
  reconcile-kubeadm-config.py [--kubeconfig PATH] name=value [name=value ...]

Run as root on a control-plane node (admin.conf) after `kubeadm init` and
before any additional control node joins.
"""
import argparse
import json
import subprocess
import sys

import yaml


def kubectl(args, kubeconfig):
    cmd = ["kubectl"]
    if kubeconfig:
        cmd += ["--kubeconfig", kubeconfig]
    return subprocess.run(cmd + args, capture_output=True, text=True, check=True)


def as_list(extra_args):
    # kubeadm v1beta4 stores extraArgs as a list of {name, value}; older
    # configs used a dict. Normalize to the list form for comparison.
    if isinstance(extra_args, dict):
        return [{"name": k, "value": v} for k, v in extra_args.items()]
    return [dict(e) for e in (extra_args or [])]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kubeconfig", default=None)
    parser.add_argument("flags", nargs="+", help="desired flags as name=value pairs")
    args = parser.parse_args()

    desired = [{"name": n, "value": v} for n, v in (f.split("=", 1) for f in args.flags)]
    desired_set = {(d["name"], d["value"]) for d in desired}

    raw = kubectl(["get", "cm", "kubeadm-config", "-n", "kube-system", "-o", "json"], args.kubeconfig).stdout
    data = json.loads(raw).get("data", {})
    if "ClusterConfiguration" not in data:
        print("ERROR: kubeadm-config ConfigMap has no ClusterConfiguration", file=sys.stderr)
        sys.exit(1)

    cfg = yaml.safe_load(data["ClusterConfiguration"]) or {}
    current_set = {(d["name"], d["value"]) for d in as_list(cfg.get("apiServer", {}).get("extraArgs"))}

    if current_set == desired_set:
        print("unchanged")
        return

    cfg.setdefault("apiServer", {})["extraArgs"] = desired
    new_raw = yaml.safe_dump(cfg, default_flow_style=False)
    patch = json.dumps({"data": {"ClusterConfiguration": new_raw}})
    kubectl(["patch", "cm", "kubeadm-config", "-n", "kube-system", "--type", "merge", "-p", patch], args.kubeconfig)
    print("updated apiServer.extraArgs to: " + ", ".join(f"{d['name']}={d['value']}" for d in desired))


if __name__ == "__main__":
    main()
