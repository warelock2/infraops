#!/bin/sh
# ===========================================================================
# Stamp the "iac" state-drift tag on the hosts that drifted this run.
#
# Called by the apply and config-management scripts AFTER they have acted on
# a host: Terraform stamps the VMs it detected drift on (create/replace or
# in-place update), Ansible stamps the hosts its play recap reports as
# changed. The tag stays visible in Proxmox for the rest of the run so the
# drifted-vs-not-drifted set is obvious, then the LAST workflow step
# (clear-iac-tags.sh) removes it from exactly the combined set.
#
# Input: space-separated host entries, either "name:vmid" (from Terraform)
# or a bare hostname (from Ansible). Bare names are resolved to a vmid via
# the node's qemu list.
#
# Idempotent: a host already carrying the iac tag is left untouched. Other
# tags are preserved. VMs that no longer exist are skipped with a warning.
#
# Usage:
#   VAULT_TOKEN=... sh scripts/stamp-iac-tags.sh "test01:9100 test02"
# ===========================================================================
set -e

export VAULT_ADDR="${VAULT_ADDR:-https://vault.afobl.com}"
export VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-true}"

# Hosts to stamp, as "name:vmid" and/or bare-hostname entries
IAC_TARGETS="${IAC_TARGETS:-}"

echo "=== Reading Proxmox node + API token ==="
PROXMOX_NODE=$(yq -r ".platform.proxmox.node" conf/infrastructure.yaml)
PROXMOX_TOKEN=$(vault kv get -field=api_token secret/infraops/proxmox)
[ -n "$PROXMOX_NODE" ] || { echo "ERROR: empty proxmox node in infrastructure.yaml" >&2; exit 1; }
[ -n "$PROXMOX_TOKEN" ] || { echo "ERROR: empty proxmox API token" >&2; exit 1; }
echo "Proxmox node: $PROXMOX_NODE"

if [ -z "$IAC_TARGETS" ]; then
  echo "=== No hosts drifted this run - nothing to stamp ==="
  exit 0
fi

echo "Hosts to stamp: $IAC_TARGETS"

echo "=== Listing VMs on node $PROXMOX_NODE ==="
VM_LIST=$(curl -k -sS -f \
  -H "Authorization: PVEAPIToken=$PROXMOX_TOKEN" \
  "https://${PROXMOX_NODE}:8006/api2/json/nodes/${PROXMOX_NODE}/qemu") || {
    echo "FATAL: could not list VMs on node $PROXMOX_NODE" >&2
    exit 1
  }

for entry in $IAC_TARGETS; do
  case "$entry" in
    *:*)
      HOSTNAME="${entry%%:*}"
      VMID="${entry##*:}"
      ;;
    *)
      HOSTNAME="$entry"
      VMID=$(echo "$VM_LIST" | jq -r --arg name "$entry" '.data[]? | select(.name == $name) | .vmid' | head -1)
      ;;
  esac

  [ -n "$VMID" ] || { echo "  WARNING: no VM found for '$entry' - skipping"; continue; }

  TAGS=$(echo "$VM_LIST" | jq -r --argjson vmid "$VMID" '.data[]? | select(.vmid == $vmid) | .tags // ""')
  [ -n "$TAGS" ] || TAGS=""
  case ",$TAGS," in
    *",iac,"*) echo "  VM $HOSTNAME ($VMID): already tagged iac - ok"; continue ;;
  esac

  [ -n "$TAGS" ] && NEW_TAGS="${TAGS},iac" || NEW_TAGS="iac"
  echo "  Stamping iac tag on $HOSTNAME ($VMID) (tags: '$TAGS' -> '$NEW_TAGS')"

  curl -k -sS -f -X PUT \
    -H "Authorization: PVEAPIToken=$PROXMOX_TOKEN" \
    -d "tags=$NEW_TAGS" \
    "https://${PROXMOX_NODE}:8006/api2/json/nodes/${PROXMOX_NODE}/qemu/${VMID}/config" \
    >/dev/null 2>&1 || echo "  WARNING: failed to stamp tag on $HOSTNAME ($VMID)"
done

echo "=== iac tag stamping complete ==="
