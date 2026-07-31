#!/bin/sh
set -e

export VAULT_ADDR="${VAULT_ADDR:-https://vault.afobl.com}"
export VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-true}"

if [ -z "${FAILED_VMS:-}" ]; then
  echo "FAILED_VMS not set, reading from wait-for-readiness output..."
  FAILED_VMS=$(cat /tmp/failed_vms.txt 2>/dev/null || grep '^failed_vms=' /tmp/wait-output.txt 2>/dev/null | cut -d= -f2- || echo "")
fi

if [ -z "$FAILED_VMS" ]; then
  echo "No failed VMs to destroy"
  exit 0
fi

PROXMOX_NODE=$(yq ".platform.proxmox.node" config/infrastructure.yaml)
PROXMOX_TOKEN=$(vault kv get -field=api_token secret/infraops/proxmox)

echo "Destroying failed VMs: $FAILED_VMS"

for entry in $FAILED_VMS; do
  HOSTNAME="${entry%%:*}"
  VMID="${entry##*:}"
  echo "Destroying failed VM: $HOSTNAME (VMID $VMID)"

  # Stop VM first (required before destroy)
  echo "Stopping VM $HOSTNAME (VMID $VMID)..."
  curl -k -sS -f -X POST \
    -H "Authorization: Bearer $PROXMOX_TOKEN" \
    -w "\n  -> HTTP %{http_code}\n" \
    "https://${PROXMOX_NODE}:8006/api2/json/nodes/${PROXMOX_NODE}/qemu/${VMID}/status/stop" \
    && echo "  -> Stopped" \
    || echo "  -> Stop failed"

  # Wait for stop to complete
  sleep 5

  terraform -chdir=terraform state rm "proxmox_virtual_environment_vm.vm[\"$HOSTNAME\"]" 2>/dev/null || true

  echo "Deleting VM $HOSTNAME (VMID $VMID) via Proxmox API..."
  curl -k -sS -f -X DELETE \
    -H "Authorization: Bearer $PROXMOX_TOKEN" \
    -w "\n  -> HTTP %{http_code}\n" \
    "https://${PROXMOX_NODE}:8006/api2/json/nodes/${PROXMOX_NODE}/qemu/${VMID}" \
    && echo "  -> Destroyed" \
    || echo "  -> Delete failed"
done