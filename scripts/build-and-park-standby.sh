#!/bin/sh
# ===========================================================================
# build-and-park-standby.sh — build and park standby (parked spare) VMs.
#
# Runs AFTER config management on runs that created standby VMs. It:
#
#   1. Lists VMs on the Proxmox node and selects those carrying the "standby"
#      tag that are CURRENTLY RUNNING — i.e. freshly created this run (or
#      self-healed from an earlier failed run) and not yet built. Already
#      parked ghosts are stopped, so they are skipped.
#   2. If any: generates the standby-only inventory and runs common.yaml
#      (accounts + patching baseline) plus k8s-standby-build.yaml (the k8s
#      base toolchain, shared with k8s-cluster.yaml Play 1) against them,
#      restricted to exactly the running ghosts. This builds a standby VM
#      "like any other node".
#   3. Parks the built ghosts with a clean shutdown over SSH — sudo poweroff
#      on the ansible account (passwordless sudo), which is deterministic
#      because ansible just configured the host and proved it healthy. No
#      Proxmox API status round-trip is needed for parking; the "standby" tag
#      is already on the VM from Terraform.
#
# No-op when no standby VMs exist or none are running. The "standby" tag is
# the source of truth for membership (Terraform stamps it at creation, the
# reconcile script maintains it), so this step needs no SSOT parsing.
#
# Requires the same secrets the config-management step uses: VAULT_TOKEN,
# ADMIN_SSH_PUBLIC_KEY, ANSIBLE_SSH_PRIVATE_KEY.
# ===========================================================================
set -e

export VAULT_ADDR="${VAULT_ADDR:-https://vault.afobl.com}"
export VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-true}"

if [ -z "$ADMIN_SSH_PUBLIC_KEY" ]; then
  echo "ERROR: ADMIN_SSH_PUBLIC_KEY not set"
  exit 1
fi
if [ -z "$ANSIBLE_SSH_PRIVATE_KEY" ]; then
  echo "ERROR: ANSIBLE_SSH_PRIVATE_KEY not set"
  exit 1
fi

echo "=== Reading Proxmox node + API token ==="
PROXMOX_NODE=$(yq -r ".platform.proxmox.node" conf/infrastructure.yaml)
PROXMOX_TOKEN=$(vault kv get -field=api_token secret/infraops/proxmox)
[ -n "$PROXMOX_NODE" ] || { echo "ERROR: empty proxmox node in infrastructure.yaml" >&2; exit 1; }
[ -n "$PROXMOX_TOKEN" ] || { echo "ERROR: empty proxmox API token" >&2; exit 1; }

echo "=== Listing VMs on node $PROXMOX_NODE ==="
VM_LIST=$(curl -k -sS -f \
  -H "Authorization: PVEAPIToken=$PROXMOX_TOKEN" \
  "https://${PROXMOX_NODE}:8006/api2/json/nodes/${PROXMOX_NODE}/qemu") || {
    echo "FATAL: could not list VMs on node $PROXMOX_NODE" >&2
    exit 1
  }

# Running VMs tagged "standby" — freshly created ghosts that need building.
RUNNING_STANDBY=$(echo "$VM_LIST" | jq -r \
  '[.data[]? | select((.tags // "") | split(",") | index("standby")) | select(.status == "running") | "\(.name):\(.vmid)"] | .[]')

if [ -z "$RUNNING_STANDBY" ]; then
  echo "=== No running standby VMs - nothing to build ==="
  exit 0
fi
echo "Standby VMs to build:"
echo "$RUNNING_STANDBY" | tr ' ' '\n'

RUNNING_NAMES=$(echo "$RUNNING_STANDBY" | cut -d: -f1 | tr '\n' ',' | sed 's/,$//')

echo "=== Staging SSH keys ==="
echo "$ADMIN_SSH_PUBLIC_KEY" > /tmp/ssh_key.pub
echo "$ANSIBLE_SSH_PRIVATE_KEY" > /tmp/ansible_key
chmod 600 /tmp/ansible_key

echo "=== Generating standby inventory ==="
python3 scripts/generate-inventory.py --standby --output ansible/inventory-standby.json

export ANSIBLE_CONFIG="$PWD/ansible/ansible.cfg"
SERVICE_HOST=$(yq .defaults.service_host conf/infrastructure.yaml)
DNS_DOMAIN=$(yq .platform.proxmox.dns_domain conf/infrastructure.yaml)
SERVICE_DOMAIN="${SERVICE_HOST}.${DNS_DOMAIN}"
GIT_COMMIT=$(printf '%s' "$GITHUB_SHA" | cut -c1-8)
GIT_TAG="${GITHUB_REF_NAME}"
echo "=== Reading NTfy channel from Vault ==="
NTFY_CHANNEL=$(vault kv get -field=message_channel_phone secret/infraops/ntfy)

KUBERNETES_VERSION=$(yq .tools.kubernetes conf/infrastructure.yaml)
POD_NETWORK_CIDR=$(yq .platform.kubernetes.pod_network_cidr conf/infrastructure.yaml)
CALICO_VERSION=$(yq .tools.calico conf/infrastructure.yaml)
ADMIN_USER=$(yq .platform.admin.user conf/infrastructure.yaml)
ADMIN_GROUP=$(yq .platform.admin.group conf/infrastructure.yaml)

echo "=== Building standby VMs (common baseline + k8s base) ==="
ANSIBLE_LOG=/tmp/standby-build-output.log
ansible-playbook -i ansible/inventory-standby.json ansible/playbooks/common.yaml \
  --limit "$RUNNING_NAMES" --private-key /tmp/ansible_key \
  -e "infra_platform_kubernetes_version=$KUBERNETES_VERSION" \
  -e "infra_platform_kubernetes_pod_network_cidr=$POD_NETWORK_CIDR" \
  -e "infra_platform_kubernetes_calico_version=$CALICO_VERSION" \
  -e "infra_service_domain=$SERVICE_DOMAIN" \
  -e "infra_admin_user=$ADMIN_USER" \
  -e "infra_admin_group=$ADMIN_GROUP" \
  -e infra_ssh_key_file=/tmp/ssh_key.pub \
  -e "git_commit=$GIT_COMMIT" \
  -e "git_tag=$GIT_TAG" \
  -e "ntfy_message_channel=$NTFY_CHANNEL" >"$ANSIBLE_LOG" 2>&1
STATUS=$?
cat "$ANSIBLE_LOG"
if [ "$STATUS" -ne 0 ]; then
  echo "ERROR: common baseline playbook failed on standby VMs (exit $STATUS)" >&2
  exit "$STATUS"
fi

ansible-playbook -i ansible/inventory-standby.json ansible/playbooks/k8s-standby-build.yaml \
  --limit "$RUNNING_NAMES" --private-key /tmp/ansible_key \
  -e "infra_platform_kubernetes_version=$KUBERNETES_VERSION" \
  -e "infra_platform_kubernetes_pod_network_cidr=$POD_NETWORK_CIDR" \
  -e "infra_platform_kubernetes_calico_version=$CALICO_VERSION" \
  -e "infra_service_domain=$SERVICE_DOMAIN" \
  -e "infra_admin_user=$ADMIN_USER" \
  -e "infra_admin_group=$ADMIN_GROUP" \
  -e infra_ssh_key_file=/tmp/ssh_key.pub \
  -e "git_commit=$GIT_COMMIT" \
  -e "git_tag=$GIT_TAG" \
  -e "ntfy_message_channel=$NTFY_CHANNEL" >"$ANSIBLE_LOG" 2>&1
STATUS=$?
cat "$ANSIBLE_LOG"
if [ "$STATUS" -ne 0 ]; then
  echo "ERROR: k8s-standby-build playbook failed (exit $STATUS)" >&2
  exit "$STATUS"
fi

echo "=== Parking standby VMs (SSH poweroff) ==="
for name in $(echo "$RUNNING_NAMES" | tr ',' ' '); do
  echo "  powering off $name"
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
    -i /tmp/ansible_key "ansible@${name}.${DNS_DOMAIN}" "sudo systemctl poweroff" \
    || echo "  WARNING: poweroff failed for $name"
done

echo "=== Standby build and park complete ==="
