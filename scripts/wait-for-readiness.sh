#!/bin/sh
set -e

export VAULT_ADDR="${VAULT_ADDR:-https://vault.afobl.com}"
export VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-true}"

# Accept timeout as first argument, default 1200s (20 min)
READINESS_TIMEOUT="${1:-1200}"

echo "=== Reading NATS password from Vault ==="
NATS_IAC_PASSWORD=$(vault kv get -format=json secret/infraops/nats | jq -r '.data.data.iac_orchestrator_password')

echo "=== Setting up nats context ==="
nats context add iac-orchestrator \
  --server tls://midas.afobl.com:4222 \
  --user iac-orchestrator --password "$NATS_IAC_PASSWORD"

echo "=== Computing expected VMs ==="
EXPECTED_VMS=""
CLUSTER_COUNT=$(yq ".clusters | length" conf/infrastructure.yaml)
for i in $(seq 0 $((CLUSTER_COUNT - 1))); do
  CLUSTER_NAME=$(yq ".clusters[$i].name" conf/infrastructure.yaml)
  CLUSTER_TYPE=$(yq ".clusters[$i].cluster_type // .defaults.cluster_type" conf/infrastructure.yaml)
  CP_NODES=$(yq ".clusters[$i].control_plane.nodes // 0" conf/infrastructure.yaml)
  WORKER_NODES=$(yq ".clusters[$i].workers.nodes // 0" conf/infrastructure.yaml)
  CP_PLANE_NAME=$(yq ".clusters[$i].plane_defaults.control_plane.plane_name // .defaults.planes.control_plane.plane_name" conf/infrastructure.yaml)
  WORKER_PLANE_NAME=$(yq ".clusters[$i].plane_defaults.workers.plane_name // .defaults.planes.workers.plane_name" conf/infrastructure.yaml)
  CP_VM_ID_START=$(yq ".clusters[$i].control_plane.vm_id_start" conf/infrastructure.yaml)
  WORKER_VM_ID_START=$(yq ".clusters[$i].workers.vm_id_start" conf/infrastructure.yaml)
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
TOTAL=$(echo "$EXPECTED_VMS" | wc -w)
echo "Total VMs: $TOTAL"

echo "=== Polling for readiness signals (${READINESS_TIMEOUT}s timeout) ==="
READY_VMS=""
START_TIME=$(date +%s)
TIMEOUT=$READINESS_TIMEOUT

echo "=== Consumer info before polling ==="
nats consumer info infraops readiness-poller --context=iac-orchestrator 2>&1 || true

while true; do
  ELAPSED=$(( $(date +%s) - START_TIME ))
  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    echo "TIMEOUT after ${TIMEOUT}s"
    break
  fi

  REMAINING=$((TIMEOUT - ELAPSED))
  echo "--- Poll cycle (${ELAPSED}s elapsed, ${REMAINING}s remaining) ---"

  while MSG=$(nats consumer next infraops readiness-poller --context=iac-orchestrator --raw --wait=2s 2>/dev/null); do
    echo "RAW MSG: $MSG"
    HOSTNAME=$(echo "$MSG" | jq -r '.hostname // empty' 2>/dev/null || true)
    echo "PARSED HOSTNAME: '$HOSTNAME'"
    if [ -n "$HOSTNAME" ] && echo "$READY_VMS" | grep -q "$HOSTNAME"; then
      continue
    fi
    if [ -n "$HOSTNAME" ]; then
      echo "READY: $HOSTNAME"
      READY_VMS="$READY_VMS $HOSTNAME"
      nats pub "infraops.helloworld.ack.$HOSTNAME" '{"ack":true}' --context=iac-orchestrator
    fi
  done || true

  ALL_READY=true
  for entry in $EXPECTED_VMS; do
    HOSTNAME="${entry%%:*}"
    if ! echo "$READY_VMS" | grep -qw "$HOSTNAME"; then
      ALL_READY=false
      break
    fi
  done

  if [ "$ALL_READY" = "true" ]; then
    echo "ALL VMs READY"
    echo "ready=true" >> "$GITHUB_OUTPUT"
    exit 0
  fi

  NOT_READY=""
  for entry in $EXPECTED_VMS; do
    HOSTNAME="${entry%%:*}"
    if ! echo "$READY_VMS" | grep -qw "$HOSTNAME"; then
      NOT_READY="$NOT_READY $HOSTNAME"
    fi
  done
  echo "Not ready yet:$NOT_READY"
  sleep 10
done

echo "TIMEOUT: some VMs did not declare readiness"
echo "ready=false" >> "$GITHUB_OUTPUT"

FAILED_VMS=""
for entry in $EXPECTED_VMS; do
  HOSTNAME="${entry%%:*}"
  VMID="${entry##*:}"
  if ! echo "$READY_VMS" | grep -qw "$HOSTNAME"; then
    echo "FAILED: $HOSTNAME (VMID $VMID)"
    FAILED_VMS="$FAILED_VMS $HOSTNAME:$VMID"
  fi
done
echo "failed_vms=$FAILED_VMS" >> "$GITHUB_OUTPUT"
exit 1
