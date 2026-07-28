#!/bin/sh
set -e

export VAULT_ADDR="${VAULT_ADDR:-https://vault.afobl.com}"
export VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-true}"

echo "=== Reading Proxmox credentials from Vault ==="
PROXMOX_ENDPOINT=$(vault kv get -format=json secret/infraops/proxmox | jq -r '.data.data.endpoint')
PROXMOX_TOKEN=$(vault kv get -format=json secret/infraops/proxmox | jq -r '.data.data.api_token')
PROXMOX_NODE=$(yq .platform.proxmox.node config/infrastructure.yaml)

echo "Endpoint: $PROXMOX_ENDPOINT"
echo "Node: $PROXMOX_NODE"

for entry in $FAILED_VMS; do
  HOSTNAME="${entry%%:*}"
  VMID="${entry##*:}"
  echo "Destroying $HOSTNAME (VMID $VMID)..."
  HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
    -X DELETE \
    -H "Authorization: PVEAPIToken=${PROXMOX_TOKEN}" \
    "${PROXMOX_ENDPOINT}/nodes/${PROXMOX_NODE}/qemu/${VMID}")
  echo "  HTTP $HTTP_CODE"
  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "404" ]; then
    echo "  $HOSTNAME destroyed"
  else
    echo "  WARNING: unexpected HTTP $HTTP_CODE"
  fi
done

echo "=== Re-applying Terraform to recreate destroyed VMs ==="
cd terraform
terraform init -reconfigure
terraform apply -auto-approve -no-color -input=false -parallelism=1
