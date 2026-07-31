#!/bin/sh
set -e

export VAULT_ADDR="${VAULT_ADDR:-https://vault.afobl.com}"
export VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-true}"

MAX_RETRIES=3
READINESS_TIMEOUT=1200

echo "=== Computing expected VMs ==="
EXPECTED_VMS=""
CLUSTER_COUNT=$(yq ".clusters | length" config/infrastructure.yaml)
for i in $(seq 0 $((CLUSTER_COUNT - 1))); do
  CLUSTER_NAME=$(yq ".clusters[$i].name" config/infrastructure.yaml)
  CLUSTER_TYPE=$(yq ".clusters[$i].cluster_type // .defaults.cluster_type" config/infrastructure.yaml)
  CP_NODES=$(yq ".clusters[$i].control_plane.nodes // 0" config/infrastructure.yaml)
  WORKER_NODES=$(yq ".clusters[$i].workers.nodes // 0" config/infrastructure.yaml)
  CP_PLANE_NAME=$(yq ".clusters[$i].plane_defaults.control_plane.plane_name // .defaults.planes.control_plane.plane_name" config/infrastructure.yaml)
  WORKER_PLANE_NAME=$(yq ".clusters[$i].plane_defaults.workers.plane_name // .defaults.planes.workers.plane_name" config/infrastructure.yaml)
  CP_VM_ID_START=$(yq ".clusters[$i].control_plane.vm_id_start" config/infrastructure.yaml)
  WORKER_VM_ID_START=$(yq ".clusters[$i].workers.vm_id_start" config/infrastructure.yaml)
  for n in $(seq 1 $CP_NODES); do
    NUM=$(printf "%02d" $n)
    HOSTNAME="${CLUSTER_TYPE}-${CLUSTER_NAME}-${CP_PLANE_NAME}-${NUM}"
    VMID=$((CP_VM_ID_START + n - 1))
    EXPECTED_VMS="${EXPECTED_VMS}${HOSTNAME}:${VMID} "
  done
  for n in $(seq 1 $WORKER_NODES); do
    NUM=$(printf "%02d" $n)
    HOSTNAME="${CLUSTER_TYPE}-${CLUSTER_NAME}-${WORKER_PLANE_NAME}-${NUM}"
    VMID=$((WORKER_VM_ID_START + n - 1))
    EXPECTED_VMS="${EXPECTED_VMS}${HOSTNAME}:${VMID} "
  done
done

echo "Expected VMs: $EXPECTED_VMS"

for RETRY in $(seq 1 $MAX_RETRIES); do
  echo "=== Readiness attempt $RETRY/$MAX_RETRIES ==="

  if [ $RETRY -eq 1 ]; then
    terraform -chdir=terraform apply -auto-approve -no-color -input=false -parallelism=1
  else
    terraform -chdir=terraform init -reconfigure
    terraform -chdir=terraform apply -auto-approve -no-color -input=false -parallelism=1
  fi

  echo "=== Polling for readiness (1200s) ==="
  if scripts/wait-for-readiness.sh 1200; then
    echo "=== ALL VMs READY ==="
    echo "ready=true" >> "$GITHUB_OUTPUT"
    echo "failed_vms=" >> "$GITHUB_OUTPUT"
    exit 0
  fi

  echo "=== Readiness timeout - destroying failed VMs ==="
  FAILED_VMS=$(cat /tmp/failed_vms.txt 2>/dev/null || echo "")
  if [ -z "$FAILED_VMS" ]; then
    FAILED_VMS=$(grep '^failed_vms=' /tmp/wait-output.txt 2>/dev/null | cut -d= -f2- || echo "")
  fi

  for entry in $FAILED_VMS; do
    HOSTNAME="${entry%%:*}"
    VMID="${entry##*:}"
    echo "Destroying failed VM: $HOSTNAME (VMID $VMID)"
    
    terraform -chdir=terraform state rm "proxmox_virtual_environment_vm.vm[\"$HOSTNAME\"]" 2>/dev/null || true
    
    echo "Deleting VM $HOSTNAME via Proxmox API..."
    PROXMOX_NODE=$(yq ".platform.proxmox.node" config/infrastructure.yaml)
    curl -k -s -X DELETE \
      -H "Authorization: Bearer $(vault kv get -field=api_token secret/infraops/proxmox)" \
      "https://${PROXMOX_NODE}:8006/api2/json/nodes/${PROXMOX_NODE}/qemu/${VMID}" \
      || echo "Proxmox delete failed for VMID $VMID (may already be gone)"
  done

  echo "Retrying..."
done

echo "=== MAX RETRIES REACHED ==="
echo "ready=false" >> "$GITHUB_OUTPUT"
echo "failed_vms=$FAILED_VMS" >> "$GITHUB_OUTPUT"
exit 1