#!/bin/sh
# ===========================================================================
# Clear the "iac" state-drift tag from EXACTLY the hosts that drifted this
# run, once the IaC pipeline has fully succeeded.
#
# The "iac" tag marks "IaC detected state drift on this host and acted on
# it." It is stamped by the process that detected the drift (see
# stamp-iac-tags.sh): Terraform stamps the VMs it changed (create/replace or
# in-place update) and Ansible stamps the hosts its play recap reports as
# changed. The tag stays visible in Proxmox for the rest of the run so the
# drifted-vs-not-drifted set is obvious.
#
# This script is the LAST workflow step and clears the tag from the UNION of
# both drifted sets:
#
#   TERRAFORM_DRIFTED: "hostname:vmid" pairs, output by
#                      terraform-apply-with-readiness.sh (the plan's create/
#                      replace/update actions).
#   ANSIBLE_DRIFTED:   bare hostnames, output by configuration-management.sh
#                      (hosts whose play recap reported changed > 0).
#
# Any OTHER host still carrying the tag (e.g. from an earlier failed run) is
# left alone — it was not touched this run. IaC owns the tag outright: it
# never snapshots a prior tag state to restore later, and any other tags on a
# cleared VM are preserved.
#
# Because this runs as the last step with no gate, a failed run never reaches
# it — the tags stay in place and the drifted hosts remain visible. Errors on
# individual VMs are logged but non-fatal so a cosmetic cleanup problem never
# fails the run. An empty union is a no-op.
#
# Usage:
#   TERRAFORM_DRIFTED="test01:9100" ANSIBLE_DRIFTED="test02" VAULT_TOKEN=... \
#     sh scripts/clear-iac-tags.sh
# ===========================================================================
set -e

export VAULT_ADDR="${VAULT_ADDR:-https://vault.afobl.com}"
export VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-true}"

TERRAFORM_DRIFTED="${TERRAFORM_DRIFTED:-}"
ANSIBLE_DRIFTED="${ANSIBLE_DRIFTED:-}"

echo "=== Reading Proxmox node + API token ==="
PROXMOX_NODE=$(yq -r ".platform.proxmox.node" conf/infrastructure.yaml)
PROXMOX_TOKEN=$(vault kv get -field=api_token secret/infraops/proxmox)
[ -n "$PROXMOX_NODE" ] || { echo "ERROR: empty proxmox node in infrastructure.yaml" >&2; exit 1; }
[ -n "$PROXMOX_TOKEN" ] || { echo "ERROR: empty proxmox API token" >&2; exit 1; }
echo "Proxmox node: $PROXMOX_NODE"

# Build the union vmid set. Terraform entries carry their vmid directly;
# Ansible entries are bare hostnames and must be resolved against the qemu
# list (hosts that no longer exist are skipped).
TERRAFORM_VMIDS=$(echo "$TERRAFORM_DRIFTED" | tr ' ' '\n' | sed '/^$/d' | cut -d: -f2 | sort -u)
if [ -z "$TERRAFORM_VMIDS" ] && [ -z "$ANSIBLE_DRIFTED" ]; then
  echo "=== No hosts drifted this run - nothing to clear ==="
  exit 0
fi

echo "Terraform drifted this run: ${TERRAFORM_DRIFTED:-<none>}"
echo "Ansible drifted this run: ${ANSIBLE_DRIFTED:-<none>}"

echo "=== Listing VMs on node $PROXMOX_NODE ==="
VM_LIST=$(curl -k -sS -f \
  -H "Authorization: PVEAPIToken=$PROXMOX_TOKEN" \
  "https://${PROXMOX_NODE}:8006/api2/json/nodes/${PROXMOX_NODE}/qemu") || {
    echo "FATAL: could not list VMs on node $PROXMOX_NODE" >&2
    exit 1
}

ANSIBLE_VMIDS=$(echo "$ANSIBLE_DRIFTED" | tr ' ' '\n' | sed '/^$/d' | sort -u | while read -r name; do
  echo "$VM_LIST" | jq -r --arg name "$name" '.data[]? | select(.name == $name) | .vmid'
done)

ALL_VMIDS=$(printf '%s\n%s\n' "$TERRAFORM_VMIDS" "$ANSIBLE_VMIDS" | sed '/^$/d' | sort -u)
if [ -z "$ALL_VMIDS" ]; then
  echo "=== Drifted hosts no longer resolve to any VM - nothing to clear ==="
  exit 0
fi

echo "Clearing 'iac' tag from: $(echo "$ALL_VMIDS" | tr '\n' ' ')"
VMID_JSON=$(printf '%s\n' "$ALL_VMIDS" | jq -R . | jq -s -c .)

echo "$VM_LIST" | jq -r --argjson vmids "$VMID_JSON" '
  .data[]
  | select((.vmid | tostring) as $v | ($vmids | index($v)))
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
      -H "Authorization: PVEAPIToken=$PROXMOX_TOKEN" \
      -d "tags=$NEW_TAGS" \
      "https://${PROXMOX_NODE}:8006/api2/json/nodes/${PROXMOX_NODE}/qemu/${VMID}/config" \
      >/dev/null 2>&1 || echo "  WARNING: failed to clear tag on VM $VMID"
  else
    curl -k -sS -f -X PUT \
      -H "Authorization: PVEAPIToken=$PROXMOX_TOKEN" \
      -d "tags=" \
      "https://${PROXMOX_NODE}:8006/api2/json/nodes/${PROXMOX_NODE}/qemu/${VMID}/config" \
      >/dev/null 2>&1 || echo "  WARNING: failed to clear tag on VM $VMID"
  fi
done

echo "=== iac tag clearing complete ==="
