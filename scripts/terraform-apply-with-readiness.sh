#!/bin/sh
set -e

export VAULT_ADDR="${VAULT_ADDR:-https://vault.afobl.com}"
export VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-true}"

MAX_RETRIES=3
READINESS_TIMEOUT=1200
PLAN_FILE=/tmp/tfplan
FAILED_VMS_FILE=/tmp/failed_vms.txt

# ---------------------------------------------------------------------------
# Extract VMs that Terraform will create or replace from the plan.
#
# Terraform is the authority on what it will create: a "create" or
# "delete,create" (replacement) action means the VM boots fresh from a clone,
# runs cloud-init, and signals readiness via NATS. In-place "update" and
# "no-op" VMs never signal (their helloworld service already self-destructed).
#
# Output: one "hostname:vmid" pair per line.
# ---------------------------------------------------------------------------
extract_created_vms() {
  terraform -chdir=terraform show -json "$PLAN_FILE" | jq -r '
    [.resource_changes[]
     | select(.type == "proxmox_virtual_environment_vm")
     | select(.change.actions | index("create"))
     | [((.index.key // .name)), ((.change.after.vm_id // .change.before.vm_id) | tostring)]
     | join(":")] | .[]'
}

for RETRY in $(seq 1 "$MAX_RETRIES"); do
  echo "=== Attempt $RETRY/$MAX_RETRIES ==="

  if [ "$RETRY" -gt 1 ]; then
    sh scripts/terraform-init-retry.sh -chdir=terraform init -reconfigure
  fi

  # Plan to a file so we can inspect exactly what will be created
  terraform -chdir=terraform plan -out="$PLAN_FILE" -no-color -input=false -parallelism=1

  # The VMs Terraform creates/replaces are the ones that will signal readiness
  EXPECTED_VMS=$(extract_created_vms | tr '\n' ' ')
  echo "VMs to create/replace: $EXPECTED_VMS"

  # Apply the exact plan we inspected
  terraform -chdir=terraform apply "$PLAN_FILE" -parallelism=1

  # If nothing was created or replaced, no VM will signal — nothing to wait for
  if [ -z "$EXPECTED_VMS" ]; then
    echo "=== NO NEW VMs - skipping readiness wait ==="
    echo "ready=true" >> "$GITHUB_OUTPUT"
    echo "failed_vms=" >> "$GITHUB_OUTPUT"
    exit 0
  fi

  echo "=== Polling for readiness (${READINESS_TIMEOUT}s) ==="
  rm -f "$FAILED_VMS_FILE"
  if EXPECTED_VMS="$EXPECTED_VMS" scripts/wait-for-readiness.sh "$READINESS_TIMEOUT"; then
    echo "=== ALL VMs READY ==="
    echo "ready=true" >> "$GITHUB_OUTPUT"
    echo "failed_vms=" >> "$GITHUB_OUTPUT"
    exit 0
  fi

  echo "=== Readiness timeout - destroying failed VMs ==="
  FAILED_VMS=$(cat "$FAILED_VMS_FILE" 2>/dev/null || echo "")

  for entry in $FAILED_VMS; do
    HOSTNAME="${entry%%:*}"
    VMID="${entry##*:}"
    echo "Destroying failed VM: $HOSTNAME (VMID $VMID)"

    # Remove from state (try cluster and standalone resource addresses)
    terraform -chdir=terraform state rm "proxmox_virtual_environment_vm.vm[\"$HOSTNAME\"]" 2>/dev/null || true
    terraform -chdir=terraform state rm "proxmox_virtual_environment_vm.standalone[\"$HOSTNAME\"]" 2>/dev/null || true

    echo "Deleting VM $HOSTNAME via Proxmox API..."
    PROXMOX_NODE=$(yq ".platform.proxmox.node" conf/infrastructure.yaml)
    curl -k -sS -f -X DELETE \
      -H "Authorization: Bearer $(vault kv get -field=api_token secret/infraops/proxmox)" \
      -w "\n  -> HTTP %{http_code}\n" \
      "https://${PROXMOX_NODE}:8006/api2/json/nodes/${PROXMOX_NODE}/qemu/${VMID}" \
      && echo "  -> Destroyed" \
      || echo "  -> Delete failed"
  done

  echo "Retrying..."
done

echo "=== MAX RETRIES REACHED ==="
echo "ready=false" >> "$GITHUB_OUTPUT"
echo "failed_vms=$FAILED_VMS" >> "$GITHUB_OUTPUT"
exit 1
