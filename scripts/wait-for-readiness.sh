#!/bin/sh
# ===========================================================================
# Block until the readiness handshake for expected VMs completes.
#
# Called by the workflow AFTER terraform apply. It waits on the NATS stream:
# each freshly-created VM publishes infraops.helloworld once it has booted,
# run cloud-init, and validated hostname/IP/route/sshd. We consume one
# message per expected VM; any VM that fails to signal within the timeout is
# reported via FAILED_VMS (consumed by destroy-failed-vms.sh). A VM that
# declares failure (infraops.helloworld.fail.<host>) halts the wait
# immediately and is reported via DECLARED_FAILED_VMS so the caller can
# choose to preserve it for forensics instead of destroying it.
#
# EXPECTED_VMS may be provided by the caller (terraform-apply-with-readiness.sh
# derives it from the Terraform plan — exactly the VMs being created/replaced).
# Otherwise fall back to computing it from infrastructure.yaml.
# ===========================================================================
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

# EXPECTED_VMS was described in the header above; here it's read into the
# script's own variable (set -u safety) if the caller passed it.
if [ -n "${EXPECTED_VMS:-}" ]; then
  echo "=== Using EXPECTED_VMS from caller ==="
else
  echo "=== Computing expected VMs ==="
  EXPECTED_VMS=""
  CLUSTER_COUNT=$(yq ".clusters | length" conf/infrastructure.yaml)
for i in $(seq 0 $((CLUSTER_COUNT - 1))); do
  CLUSTER_NAME=$(yq ".clusters[$i].name" conf/infrastructure.yaml)
  CLUSTER_TYPE=$(yq ".clusters[$i].cluster_type // .defaults.cluster_type" conf/infrastructure.yaml)
  CP_NODES=$(yq ".clusters[$i].control_plane.nodes // 0" conf/infrastructure.yaml)
  WORKER_NODES=$(yq ".clusters[$i].workers.nodes // 0" conf/infrastructure.yaml)
  CP_STANDBY=$(yq ".clusters[$i].control_plane.standby // 0" conf/infrastructure.yaml)
  WORKER_STANDBY=$(yq ".clusters[$i].workers.standby // 0" conf/infrastructure.yaml)
  CP_PLANE_NAME=$(yq ".clusters[$i].plane_defaults.control_plane.plane_name // .defaults.planes.control_plane.plane_name" conf/infrastructure.yaml)
  WORKER_PLANE_NAME=$(yq ".clusters[$i].plane_defaults.workers.plane_name // .defaults.planes.workers.plane_name" conf/infrastructure.yaml)
  CP_VM_ID_START=$(yq ".clusters[$i].control_plane.vm_id_start" conf/infrastructure.yaml)
  WORKER_VM_ID_START=$(yq ".clusters[$i].workers.vm_id_start" conf/infrastructure.yaml)
  for n in $(seq 1 $((CP_NODES + CP_STANDBY))); do
    NUM=$(printf "%02d" $n)
    HOSTNAME="${CLUSTER_TYPE}-${CLUSTER_NAME}-${CP_PLANE_NAME}-${NUM}"
    VMID=$((CP_VM_ID_START + n - 1))
    EXPECTED_VMS="${EXPECTED_VMS}${HOSTNAME}:${VMID} "
  done
  for n in $(seq 1 $((WORKER_NODES + WORKER_STANDBY))); do
    NUM=$(printf "%02d" $n)
    HOSTNAME="${CLUSTER_TYPE}-${CLUSTER_NAME}-${WORKER_PLANE_NAME}-${NUM}"
    VMID=$((WORKER_VM_ID_START + n - 1))
    EXPECTED_VMS="${EXPECTED_VMS}${HOSTNAME}:${VMID} "
  done
done
fi

echo "Expected VMs: $EXPECTED_VMS"
TOTAL=$(echo "$EXPECTED_VMS" | wc -w)
echo "Total VMs: $TOTAL"

echo "=== Polling for readiness signals (${READINESS_TIMEOUT}s timeout) ==="
READY_VMS=""
START_TIME=$(date +%s)
TIMEOUT=$READINESS_TIMEOUT

echo "=== Pre-flight: readiness-poller consumer must exist ==="
if ! nats consumer info infraops readiness-poller --context=iac-orchestrator >/dev/null 2>&1; then
  echo "ERROR: readiness-poller consumer does not exist in stream 'infraops'."
  echo "The orchestrator cannot receive VM readiness signals without it."
  echo "Ensure ensure-readiness-poller.sh ran successfully before this step."
  exit 1
fi
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
    if [ -n "$HOSTNAME" ]; then
      # Always ack so the VM's helloworld.service can self-destruct — even if
      # this VM isn't in our wait set (e.g. a modified-but-rebooted existing VM).
      nats pub "infraops.helloworld.ack.$HOSTNAME" '{"ack":true}' --context=iac-orchestrator
      if ! echo "$READY_VMS" | grep -qw "$HOSTNAME"; then
        echo "READY: $HOSTNAME"
        READY_VMS="$READY_VMS $HOSTNAME"
      fi
    fi
  done || true

  # A VM that could not be made healthy declares failure via
  # infraops.helloworld.fail.<host>. That is a stop-the-line event: halt
  # immediately instead of waiting out the timeout, and record the VM so the
  # caller can decide (destroy+retry or preserve for forensics).
  while FAILMSG=$(nats consumer next infraops failure-poller --context=iac-orchestrator --raw --wait=2s 2>/dev/null); do
    echo "RAW FAIL MSG: $FAILMSG"
    FHOSTNAME=$(echo "$FAILMSG" | jq -r '.hostname // empty' 2>/dev/null || true)
    echo "PARSED FAILURE HOSTNAME: '$FHOSTNAME'"
    if [ -n "$FHOSTNAME" ] && echo "$EXPECTED_VMS" | grep -qw "$FHOSTNAME"; then
      ENTRY=$(echo "$EXPECTED_VMS" | tr ' ' '\n' | grep "^$FHOSTNAME:" || true)
      VMID=$(echo "$ENTRY" | cut -d: -f2)
      echo "DECLARED FAILURE: $FHOSTNAME (VMID $VMID) — halting production line, leaving VM in place"
      echo "$FHOSTNAME:$VMID" >> /tmp/declared_failed_vms.txt
      echo "declared_failed_vms=$FHOSTNAME:$VMID" >> "$GITHUB_OUTPUT"
      echo "ready=false" >> "$GITHUB_OUTPUT"
      exit 1
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
echo "$FAILED_VMS" > /tmp/failed_vms.txt
exit 1
