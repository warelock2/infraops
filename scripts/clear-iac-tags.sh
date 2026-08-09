#!/bin/sh
# ===========================================================================
# Clear the "iac" tag from the VMs this run created/replaced, once the IaC
# pipeline has fully succeeded.
#
# Every VM Terraform creates is stamped with the tag "iac" at creation (see
# terraform/main.tf: tags is in ignore_changes so Terraform never fights this
# script). The tag is the "is IaC still working on this VM?" flag:
#
#   - present  -> IaC is touching this VM; the workflow has not finished with
#                 it yet
#   - cleared  -> the workflow (provision + readiness + config management)
#                 completed successfully, so IaC is done with the VM
#
# IaC owns the tag outright — it never snapshots a VM's prior tag state to
# restore it later. It stamps "iac" when it touches the VM and removes it when
# it is done and satisfied. Only the VMs listed in CREATED_VMS (the ones this
# run created/replaced, published by terraform-apply-with-readiness.sh) are
# cleared; VMs the run did not touch keep whatever tags they have.
#
# This script runs as the LAST step of enforce-iac.yaml. Because workflow
# steps fail fast, it only executes when every prior step succeeded — so a
# failed run leaves the tag in place and the affected VMs are instantly
# visible in the Proxmox UI. Any future post-Ansible tools run before it.
#
# For each created VM carrying the tag, it PUTs the VM config with the
# remaining tags (the "iac" tag is removed, any other tags are preserved).
# Idempotent: VMs without the tag are left alone. Errors on individual VMs are
# logged but non-fatal so a cosmetic cleanup problem never fails the run.
#
# Usage:
#   CREATED_VMS="host1:vmid1 host2:vmid2" VAULT_TOKEN=... sh scripts/clear-iac-tags.sh
# ===========================================================================
set -e

export VAULT_ADDR="${VAULT_ADDR:-https://vault.afobl.com}"
export VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-true}"

# The VMs this run created/replaced, as space-separated "hostname:vmid" pairs
# (the output of extract_created_vms in terraform-apply-with-readiness.sh).
CREATED_VMS="${CREATED_VMS:-}"

echo "=== Reading Proxmox node + API token ==="
PROXMOX_NODE=$(yq -r ".platform.proxmox.node" conf/infrastructure.yaml)
PROXMOX_TOKEN=$(vault kv get -field=api_token secret/infraops/proxmox)
[ -n "$PROXMOX_NODE" ] || { echo "ERROR: empty proxmox node in infrastructure.yaml" >&2; exit 1; }
[ -n "$PROXMOX_TOKEN" ] || { echo "ERROR: empty proxmox API token" >&2; exit 1; }
echo "Proxmox node: $PROXMOX_NODE"

# Nothing created or replaced this run -> nothing to clear
CREATED_VMIDS=$(echo "$CREATED_VMS" | tr ' ' '\n' | sed '/^$/d' | cut -d: -f2)
if [ -z "$CREATED_VMIDS" ]; then
  echo "=== No VMs created/replaced this run - nothing to clear ==="
  exit 0
fi

echo "Created/replaced this run: $CREATED_VMS"

echo "=== Listing VMs on node $PROXMOX_NODE ==="
VM_LIST=$(curl -k -sS -f \
  -H "Authorization: Bearer $PROXMOX_TOKEN" \
  "https://${PROXMOX_NODE}:8006/api2/json/nodes/${PROXMOX_NODE}/qemu") || {
    echo "FATAL: could not list VMs on node $PROXMOX_NODE" >&2
    exit 1
}

# Only clear the "iac" tag on the created/replaced VMs of THIS run. The vmid
# set is built as a jq array so the list is filtered in one pass; a vmid that
# no longer exists (e.g. destroyed by botched-VM handling) is skipped.
CREATED_JSON=$(printf '%s\n' "$CREATED_VMIDS" | jq -R . | jq -s -c .)

echo "$VM_LIST" | jq -r --argjson created "$CREATED_JSON" '
  .data[]
  | select(.vmid as $v | ($created | index($v)))
  | [.vmid, (.tags // "")] | @tsv' | while IFS="$(printf '\t')" read -r VMID TAGS; do
  [ -n "$TAGS" ] || continue
  case ",$TAGS," in
    *",iac,"*) ;;
    *) continue ;;
  esac

  NEW_TAGS=$(echo "$TAGS" | tr ',' '\n' | grep -v '^iac$' | paste -sd, -)
  echo "Clearing 'iac' tag from VM $VMID (tags: '$TAGS' -> '${NEW_TAGS:-}')"

  if [ -n "$NEW_TAGS" ]; then
    curl -k -sS -f -X PUT \
      -H "Authorization: Bearer $PROXMOX_TOKEN" \
      -d "tags=$NEW_TAGS" \
      "https://${PROXMOX_NODE}:8006/api2/json/nodes/${PROXMOX_NODE}/qemu/${VMID}/config" \
      >/dev/null 2>&1 || echo "  WARNING: failed to clear tag on VM $VMID"
  else
    curl -k -sS -f -X PUT \
      -H "Authorization: Bearer $PROXMOX_TOKEN" \
      -d "tags=" \
      "https://${PROXMOX_NODE}:8006/api2/json/nodes/${PROXMOX_NODE}/qemu/${VMID}/config" \
      >/dev/null 2>&1 || echo "  WARNING: failed to clear tag on VM $VMID"
  fi
done

echo "=== iac tag clearing complete ==="
