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
#
# Each received message is externally validated before acking:
#   - announced ip matches the live pfSense host override for that hostname
#   - announced vmid matches the SSOT plane math (vm_id_start + n)
#   - TCP :22 connects at the override IP and returns SSH-2.0 banner
# Only messages passing all checks are acked and counted as READY.
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
  WORKER_STANDBY=$(yq ".clusters[$i].workers.standby // 0" conf.infrastructure.yaml)
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

echo "=== Fetching pfSense API credentials for override lookup ==="
PFSENSE_HOST=$(yq -r '[.hosts[] | select(.services? != null) | select(.services[]? == "dns")][0].connection.host' conf/infrastructure.yaml)
PFSENSE_API_KEY=$(vault kv get -format=json secret/infraops/pfsense | jq -r '.data.data.api_key')
[ -n "$PFSENSE_HOST" ] || { echo "ERROR: could not determine pfSense host from infrastructure.yaml" >&2; exit 1; }
[ -n "$PFSENSE_API_KEY" ] || { echo "ERROR: could not fetch pfSense API key from Vault" >&2; exit 1; }
echo "pfSense host: $PFSENSE_HOST"

# Fetch current pfSense host overrides once at start (authoritative source for expected IPs)
echo "=== Fetching current host overrides from pfSense ==="
OVERRIDES_JSON=$(curl -k -sS -H "x-api-key: $PFSENSE_API_KEY" "https://$PFSENSE_HOST/api/v2/services/dns_resolver/host_overrides" 2>/dev/null) || { echo "ERROR: failed to fetch host overrides from pfSense" >&2; exit 1; }
echo "$OVERRIDES_JSON" | jq -e '.data' >/dev/null 2>&1 || { echo "ERROR: invalid response from pfSense host overrides API" >&2; exit 1; }

# Helper: get expected override IP for a hostname from the cached pfSense data
get_override_ip() {
  local hname="$1"
  local dname="$2"
  echo "$OVERRIDES_JSON" | jq -r --arg h "$hname" --arg d "$dname" '.data[] | select(.host == $h and .domain == $d) | .ip[0]' | head -1
}

# Helper: get expected VMID for a hostname from EXPECTED_VMS
get_expected_vmid() {
  local hname="$1"
  echo "$EXPECTED_VMS" | tr ' ' '\n' | grep "^$hname:" | cut -d: -f2 | head -1
}

# Helper: validate announced tuple against SSOT + reachability
# Returns 0 on pass, 1 on fail (with evidence printed)
validate_announcement() {
  local hostname="$1"
  local announced_ip="$2"
  local announced_vmid="$3"

  # Extract short hostname and domain
  local hname="${hostname%%.*}"
  local dname="${hostname#*.}"
  [ "$hname" = "$hostname" ] && dname="$(yq -r '.platform.proxmox.dns_domain' conf/infrastructure.yaml)"

  # 1. Expected override IP from pfSense
  local override_ip=$(get_override_ip "$hname" "$dname")
  if [ -z "$override_ip" ] || [ "$override_ip" = "null" ]; then
    echo "VALIDATION FAIL: $hostname — no host override found in pfSense for $hname.$dname" >&2
    return 1
  fi
  if [ "$announced_ip" != "$override_ip" ]; then
    echo "VALIDATION FAIL: $hostname — announced ip=$announced_ip does not match pfSense override=$override_ip" >&2
    return 1
  fi

  # 2. Expected VMID from plane math
  local expected_vmid=$(get_expected_vmid "$hostname")
  if [ -z "$expected_vmid" ]; then
    echo "VALIDATION FAIL: $hostname — not in EXPECTED_VMS (unknown hostname)" >&2
    return 1
  fi
  if [ "$announced_vmid" != "$expected_vmid" ]; then
    echo "VALIDATION FAIL: $hostname — announced vmid=$announced_vmid does not match expected=$expected_vmid" >&2
    return 1
  fi

  # 3. TCP :22 reachability + SSH banner at the override IP
  echo "VALIDATION: $hostname — probing SSH at $override_ip:22..." >&2
  local ssh_ok=0
  for attempt in 1 2 3; do
    if timeout 5 bash -c "exec 3<>/dev/tcp/$override_ip/22; cat <&3" 2>/dev/null | grep -q '^SSH-2.0-'; then
      ssh_ok=1
      break
    fi
    echo "VALIDATION: $hostname — attempt $attempt/3 failed, retrying in 20s..." >&2
    sleep 20
  done
  if [ $ssh_ok -eq 0 ]; then
    echo "VALIDATION FAIL: $hostname — SSH banner not received at $override_ip:22 after 3 attempts" >&2
    return 1
  fi

  echo "VALIDATION PASS: $hostname (ip=$override_ip, vmid=$expected_vmid)" >&2
  return 0
}

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
    ANNOUNCED_IP=$(echo "$MSG" | jq -r '.ip // empty' 2>/dev/null || true)
    ANNOUNCED_VMID=$(echo "$MSG" | jq -r '.vmid // empty' 2>/dev/null || true)
    echo "PARSED: hostname='$HOSTNAME' ip='$ANNOUNCED_IP' vmid='$ANNOUNCED_VMID'"
    if [ -n "$HOSTNAME" ] && [ -n "$ANNOUNCED_IP" ] && [ -n "$ANNOUNCED_VMID" ]; then
      if validate_announcement "$HOSTNAME" "$ANNOUNCED_IP" "$ANNOUNCED_VMID"; then
        nats pub "infraops.helloworld.ack.$HOSTNAME" '{"ack":true}' --context=iac-orchestrator
        if ! echo "$READY_VMS" | grep -qw "$HOSTNAME"; then
          echo "READY: $HOSTNAME"
          READY_VMS="$READY_VMS $HOSTNAME"
        fi
      else
        echo "VALIDATION REJECTED: $HOSTNAME — message not acked, will be retried by VM" >&2
      fi
    elif [ -n "$HOSTNAME" ]; then
      # Legacy or malformed message — ack to let VM self-destruct, but don't credit
      echo "LEGACY/MALFORMED MESSAGE: $HOSTNAME (missing ip/vmid) — acking without credit" >&2
      nats pub "infraops.helloworld.ack.$HOSTNAME" '{"ack":true}' --context=iac-orchestrator
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