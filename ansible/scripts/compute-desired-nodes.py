#!/usr/bin/env python3
"""Compute desired k8s node names from infrastructure.yaml"""
import sys
import yaml
import os

playbook_dir = sys.argv[1] if len(sys.argv) > 1 else '.'
# infrastructure.yaml is at project root (../../conf/infrastructure.yaml from playbook_dir)
infra_path = os.path.join(playbook_dir, '..', '..', 'conf', 'infrastructure.yaml')
with open(infra_path) as f:
    infra = yaml.safe_load(f)

nodes = []
defaults = infra.get('defaults', {})
cluster_type = defaults.get('cluster_type', 'k8s')
planes = defaults.get('planes', {})

for cluster in infra.get('clusters', []):
    enforcement = cluster.get('enforcement', [])
    if 'infrastructure_provisioning' not in enforcement:
        continue
    ctype = cluster.get('cluster_type', cluster_type)
    name = cluster['name']
    for plane_key in ['control_plane', 'workers']:
        plane_cfg = cluster.get(plane_key, {})
        count = plane_cfg.get('nodes', 0)
        plane_name = planes.get(plane_key, {}).get('plane_name', plane_key.replace('_', '-'))
        for i in range(1, count + 1):
            nodes.append(f'{ctype}-{name}-{plane_name}-{i:02d}')

print(' '.join(nodes))