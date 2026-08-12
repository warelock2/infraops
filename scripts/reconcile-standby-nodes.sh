#!/bin/sh
# ===========================================================================
# reconcile-standby-nodes.sh — enforce the active/standby partition.
#
# The SSOT's per-plane `standby` integer defines parked spare VMs packed at
# the tail of each plane (nodes+1 .. nodes+standby). Terraform only knows the
# TOTAL (nodes + standby) and manages them as uniform VMs; THIS script is the
# enforcement layer that makes the active/standby split real on the Proxmox
# side via the API.
#
#   --wake  ensure every ACTIVE VM is running and clear the "standby" tag
#           (called before config management, so a promoted ghost is booted
#           before Ansible tries to reach it; also heals a manually-stopped
#           active node)
#   --park  ensure every STANDBY VM is stopped and carries the "standby" tag,
#           and clear the tag from any active VM (called after the ghost
#           build step)
#
# Both modes are idempotent and only touch VMs that exist. Tags other than
# "standby" (e.g. "iac") are always preserved.
#
# Parking uses a clean shutdown (qemu-guest-agent / ACPI), NOT a suspend:
# a parked ghost is a deterministic power-off with a fresh clock on wake, so
# node activation is a plain boot. Suspended VMs wake with a frozen clock and
# stale RAM state — wrong at exactly the moment the k8s join runs.
#
# Requires VAULT_TOKEN (workflow injects it) and reads the Proxmox API token
# from Vault.
# ===========================================================================
set -e

export VAULT_ADDR="${VAULT_ADDR:-https://vault.afobl.com}"
export VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-true}"

MODE="${1:---wake}"
case "$MODE" in
  --wake|--park) ;;
  *) echo "Usage: reconcile-standby-nodes.sh [--wake|--park]" >&2; exit 2 ;;
esac

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

# ---------------------------------------------------------------------------
# Compute active and standby VM sets from the SSOT: "name:vmid" per entry.
# ---------------------------------------------------------------------------
ACTIVE_VMS=""
STANDBY_VMS=""
CLUSTER_COUNT=$(yq ".clusters | length" conf/infrastructure.yaml)
for i in $(seq 0 $((CLUSTER_COUNT - 1))); do
  CLUSTER_TYPE=$(yq -r ".clusters[$i].cluster_type // .defaults.cluster_type" conf/infrastructure.yaml)
  CLUSTER_NAME=$(yq -r ".clusters[$i].name" conf/infrastructure.yaml)
  for plane in control_plane workers; do
    NODES=$(yq ".clusters[$i].${plane}.nodes // 0" conf/infrastructure.yaml)
    STANDBY=$(yq ".clusters[$i].${plane}.standby // 0" conf/infrastructure.yaml)
    [ $((NODES + STANDBY)) -gt 0 ] || continue
    PLANE_NAME=$(yq -r ".clusters[$i].plane_defaults.${plane}.plane_name // .defaults.planes.${plane}.plane_name" conf/infrastructure.yaml)
    VM_ID_START=$(yq -r ".clusters[$i].${plane}.vm_id_start // -1" conf/infrastructure.yaml)
    [ "$VM_ID_START" != "-1" ] || continue
    for n in $(seq 1 $NODES); do
      NUM=$(printf "%02d" "$n")
      VMID=$((VM_ID_START + n - 1))
      ACTIVE_VMS="${ACTIVE_VMS}${CLUSTER_TYPE}-${CLUSTER_NAME}-${PLANE_NAME}-${NUM}:${VMID} "
    done
    for n in $(seq $((NODES + 1)) $((NODES + STANDBY))); do
      NUM=$(printf "%02d" "$n")
      VMID=$((VM_ID_START + n - 1))
      STANDBY_VMS="${STANDBY_VMS}${CLUSTER_TYPE}-${CLUSTER_NAME}-${PLANE_NAME}-${NUM}:${VMID} "
    done
  done
done

echo "Active VMs: ${ACTIVE_VMS:-<none>}"
echo "Standby VMs: ${STANDBY_VMS:-<none>}"

# ---------------------------------------------------------------------------
# Proxmox API helpers
# ---------------------------------------------------------------------------
vm_exists() {
  echo "$VM_LIST" | jq -e --argjson vmid "$1" '.data[]? | select(.vmid == $vmid)' >/dev/null 2>&1
}

vm_running() {
  curl -k -sS -f \
    -H "Authorization: PVEAPIToken=$PROXMOX_TOKEN" \
    "https://${PROXMOX_NODE}:8006/api2/json/nodes/${PROXMOX_NODE}/qemu/${1}/status" \
    | jq -e '.data.status == "running"' >/dev/null 2>&1
}

start_vm() {
  echo "  starting VM $1"
  curl -k -sS -f -X POST \
    -H "Authorization: PVEAPIToken=$PROXMOX_TOKEN" \
    "https://${PROXMOX_NODE}:8006/api2/json/nodes/${PROXMOX_NODE}/qemu/${1}/status/start" >/dev/null 2>&1 \
    || echo "  WARNING: failed to start VM $1"
}

stop_vm() {
  echo "  shutting down VM $1"
  # Graceful shutdown via qemu-guest-agent (or ACPI), falling back to a hard
  # stop only if the guest never cooperates.
  curl -k -sS -f -X POST \
    -H "Authorization: PVEAPIToken=$PROXMOX_TOKEN" \
    "https://${PROXMOX_NODE}:8006/api2/json/nodes/${PROXMOX_NODE}/qemu/${1}/status/shutdown" >/dev/null 2>&1 \
    || curl -k -sS -f -X POST \
         -H "Authorization: PVEAPIToken=$PROXMOX_TOKEN" \
         "https://${PROXMOX_NODE}:8006/api2/json/nodes/${PROXMOX_NODE}/qemu/${1}/status/stop" >/dev/null 2>&1 \
    || echo "  WARNING: failed to stop VM $1"
}

wait_stopped() {
  for _ in $(seq 1 30); do
    vm_running "$1" && sleep 2 || return 0
  done
  echo "  WARNING: VM $1 still running after shutdown timeout"
  return 1
}

current_tags() {
  echo "$VM_LIST" | jq -r --argjson vmid "$1" '.data[]? | select(.vmid == $vmid) | .tags // ""'
}

set_tags() {
  curl -k -sS -f -X PUT \
    -H "Authorization: PVEAPIToken=$PROXMOX_TOKEN" \
    -d "tags=$2" \
    "https://${PROXMOX_NODE}:8006/api2/json/nodes/${PROXMOX_NODE}/qemu/${1}/config" >/dev/null 2>&1 \
    || echo "  WARNING: failed to set tags on VM $1"
}

remove_tag() {
  TAGS=$(current_tags "$1")
  [ -n "$TAGS" ] || return 0
  case ",$TAGS," in
    *",$2,"*)
      NEW_TAGS=$(echo "$TAGS" | tr ',' '\n' | grep -v "^$2$" | paste -sd, -)
      if [ -n "$NEW_TAGS" ]; then
        echo "  removing tag '$2' from VM $1"
        set_tags "$1" "$NEW_TAGS"
      else
        # Only tag being removed — clear the field entirely.
        echo "  clearing tags on VM $1"
        curl -k -sS -f -X PUT \
          -H "Authorization: PVEAPIToken=$PROXMOX_TOKEN" \
          "https://${PROXMOX_NODE}:8006/api2/json/nodes/${PROXMOX_NODE}/qemu/${1}/config" \
          --data-urlencode 'tags=' >/dev/null 2>&1 \
          || echo "  WARNING: failed to clear tags on VM $1"
      fi
      ;;
  esac
}

add_tag() {
  TAGS=$(current_tags "$1")
  case ",$TAGS," in
    *",$2,"*) return 0 ;;
  esac
  [ -n "$TAGS" ] && NEW_TAGS="${TAGS},$2" || NEW_TAGS="$2"
  echo "  adding tag '$2' to VM $1"
  set_tags "$1" "$NEW_TAGS"
}

case "$MODE" in
  --wake)
    echo "=== WAKING active VMs ==="
    for entry in $ACTIVE_VMS; do
      HOSTNAME="${entry%%:*}"
      VMID="${entry##*:}"
      vm_exists "$VMID" || { echo "  $HOSTNAME ($VMID): VM does not exist - skipping"; continue; }
      if vm_running "$VMID"; then
        echo "  $HOSTNAME ($VMID): running - ok"
      else
        echo "  $HOSTNAME ($VMID): stopped - starting"
        start_vm "$VMID"
      fi
      remove_tag "$VMID" standby
    done
    ;;
  --park)
    echo "=== PARKING standby VMs ==="
    for entry in $STANDBY_VMS; do
      HOSTNAME="${entry%%:*}"
      VMID="${entry##*:}"
      vm_exists "$VMID" || { echo "  $HOSTNAME ($VMID): VM does not exist - skipping"; continue; }
      if vm_running "$VMID"; then
        echo "  $HOSTNAME ($VMID): running - shutting down"
        stop_vm "$VMID" && wait_stopped "$VMID" || true
      else
        echo "  $HOSTNAME ($VMID): stopped - ok"
      fi
      add_tag "$VMID" standby
    done
    echo "=== Ensuring no active VM carries the standby tag ==="
    for entry in $ACTIVE_VMS; do
      VMID="${entry##*:}"
      remove_tag "$VMID" standby
    done
    ;;
esac

echo "=== reconcile ($MODE) complete ==="
