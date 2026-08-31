#!/bin/sh
# ===========================================================================
# Cluster Health Gate — verify the live Kubernetes cluster matches the
# declared intent in infrastructure.yaml.
#
# Runs inside the ci-base runner container AFTER config management
# (site.yaml / k8s-cluster plays) has bootstrapped/configured the cluster.
#
# `kubectl wait --for=condition=Ready nodes --all` (inside site.yaml) only
# ensures the nodes that EXIST are Ready. It does NOT check the node set
# matches the SSOT. A partial/aborted bootstrap (e.g. run #848 where only
# some control nodes came up) passes that wait and leaves a broken half
# cluster silently in place. This gate recomputes the DESIRED node set from
# infrastructure.yaml (same formula Terraform uses) and compares it to what
# the API server actually has; any missing/unexpected node FAILS the run
# loudly, so a broken cluster is never reported as healthy.
#
# Requires: ANSIBLE_SSH_PRIVATE_KEY secret (via env); yq, python3, kubectl,
# ssh in the container. Exits 0 when healthy (or when no config-management
# cluster exists to gate), non-zero when the cluster diverges from intent.
# ===========================================================================
set -e

if [ "$(yq '.clusters | length' conf/infrastructure.yaml)" -eq 0 ]; then
  echo "No clusters in infrastructure.yaml - cluster health gate skipped"
  exit 0
fi

if [ -z "$ANSIBLE_SSH_PRIVATE_KEY" ]; then
  echo "ERROR: ANSIBLE_SSH_PRIVATE_KEY not set" >&2
  exit 1
fi

echo "=== Cluster health gate: resolving control plane ==="
DNS_DOMAIN=$(yq .platform.proxmox.dns_domain conf/infrastructure.yaml)
CP01=$(yq -r '.clusters[0].name' conf/infrastructure.yaml)
CP_FQDN=k8s-${CP01}-control-01.${DNS_DOMAIN}

mkdir -p ~/.kube
echo "$ANSIBLE_SSH_PRIVATE_KEY" > /tmp/ansible_key
chmod 600 /tmp/ansible_key

SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"

if ! ssh $SSH_OPTS -i /tmp/ansible_key "ansible@${CP_FQDN}" \
    'test -f /etc/kubernetes/admin.conf' 2>/dev/null; then
  echo "ERROR: ${CP_FQDN} reachable but no /etc/kubernetes/admin.conf (cluster not bootstrapped?) - cannot verify cluster health" >&2
  exit 1
fi

ssh $SSH_OPTS -i /tmp/ansible_key "ansible@${CP_FQDN}" \
  sudo cat /etc/kubernetes/admin.conf > ~/.kube/config
chmod 600 ~/.kube/config

echo "=== Cluster health gate: computing desired node set from infrastructure.yaml ==="
DESIRED=$(python3 ansible/scripts/compute-desired-nodes.py ansible/playbooks)
echo "Desired nodes: ${DESIRED}"

echo "=== Cluster health gate: reading actual node set from API server ==="
ACTUAL=$(kubectl --kubeconfig ~/.kube/config get nodes -o jsonpath='{.items[*].metadata.name}')
echo "Actual nodes: ${ACTUAL}"

MISSING=""
for n in $DESIRED; do
  case " $ACTUAL " in
    *" $n "*) ;;
    *) MISSING="$MISSING $n" ;;
  esac
done

UNEXPECTED=""
for n in $ACTUAL; do
  case " $DESIRED " in
    *" $n "*) ;;
    *) UNEXPECTED="$UNEXPECTED $n" ;;
  esac
done

if [ -n "$MISSING" ] || [ -n "$UNEXPECTED" ]; then
  echo "ERROR: CLUSTER HEALTH GATE FAILED" >&2
  echo "  Desired nodes :${DESIRED}" >&2
  echo "  Actual nodes  :${ACTUAL}" >&2
  [ -n "$MISSING" ] && echo "  Missing (declared but not present):${MISSING}" >&2
  [ -n "$UNEXPECTED" ] && echo "  Unexpected (present but not declared):${UNEXPECTED}" >&2
  echo "  This indicates an incomplete/failed bootstrap or shrink. Refusing to proceed with a broken cluster." >&2
  exit 1
fi

echo "OK: cluster health gate passed (${DESIRED})"
