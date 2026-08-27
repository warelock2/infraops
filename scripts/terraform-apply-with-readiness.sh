#!/bin/sh
set -e

export VAULT_ADDR="${VAULT_ADDR:-https://vault.afobl.com}"
export VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-true}"

MAX_RETRIES=3
READINESS_TIMEOUT=1200
PLAN_FILE=/tmp/tfplan
FAILED_VMS_FILE=/tmp/failed_vms.txt
DECLARED_FAILURES_FILE=/tmp/declared_failed_vms.txt

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
     | [((.index // .name)), ((.change.after.vm_id // .change.before.vm_id) | tostring)]
     | join(":")] | .[]'
}

# ---------------------------------------------------------------------------
# Extract every VM Terraform will change for any reason (create, replace, or
# in-place update) - i.e. every VM it detected state drift on. These get the
# "iac" stamp after apply. Pure no-ops and pure destroys are excluded (a
# destroyed VM no longer exists, so there is nothing to tag).
#
# Standby VMs (tagged "standby") are excluded too: they are pre-provisioned
# capacity, not drift, so they must never carry the iac marker.
#
# Output: one "hostname:vmid" pair per line.
# ---------------------------------------------------------------------------
extract_drifted_vms() {
  terraform -chdir=terraform show -json "$PLAN_FILE" | jq -r '
    [.resource_changes[]
     | select(.type == "proxmox_virtual_environment_vm")
     | select((.change.actions | index("create")) or (.change.actions | index("update")))
     | select((((.change.after.tags // .change.before.tags) // []) | index("standby")) | not)
     | [((.index // .name)), ((.change.after.vm_id // .change.before.vm_id) | tostring)]
     | join(":")] | .[]'
}

for RETRY in $(seq 1 "$MAX_RETRIES"); do
  echo "=== Attempt $RETRY/$MAX_RETRIES ==="

  if [ "$RETRY" -gt 1 ]; then
    sh scripts/terraform-init-retry.sh -chdir=terraform init -reconfigure
  fi

  echo "=== PHASE: PLAN ==="
  set +e
  PLAN_OUT=$(terraform -chdir=terraform plan -no-color -input=false -parallelism=1 2>&1)
  PLAN_RC=$?
  set -e
  echo "$PLAN_OUT"

  # Terraform 1.7+ returns exit 1 on "no change found for data.external.dns_alloc"
  # when plan only has destroys. Treat this as "changes detected" (exit 2).
  if echo "$PLAN_OUT" | grep -q 'no change found for data.external.dns_alloc'; then
    PLAN_RC=2
  fi

  case "$PLAN_RC" in
    0)
      echo "Plan: no changes."
      EXPECTED_VMS=""
      DRIFTED_VMS=""
      echo "ready=true" >> "$GITHUB_OUTPUT"
      echo "failed_vms=" >> "$GITHUB_OUTPUT"
      echo "terraform_drifted=" >> "$GITHUB_OUTPUT"
      exit 0
      ;;
    2)
      echo "Plan: changes detected."
      ;;
    1)
      echo "Plan exited 1 (error) — refusing to run destroy-only fallback."
      echo "Terraform plan failed. Check logs above for errors (auth, network, provider issues)."
      echo "Refusing to destroy infrastructure on plan error."
      exit 1
      ;;
    *)
      echo "Plan exited $PLAN_RC — unexpected exit code, treating as error."
      exit 1
      ;;
  esac

  # Check if plan only destroys data.external.dns_alloc (stale state)
  # If so, clean stale state entries and re-plan
  # Extract the planned destroy actions (between "Plan:" summary and next section)
  PLAN_DESTROYS=$(echo "$PLAN_OUT" | sed -n '/^Plan: .* to destroy\.$/,/^$/p' | head -30)
  if echo "$PLAN_OUT" | grep -q '^Plan: 0 to add, 0 to change, [0-9]* to destroy\.$' && \
     echo "$PLAN_OUT" | grep -q 'data.external.dns_alloc' && \
     ! echo "$PLAN_DESTROYS" | grep -q 'proxmox_virtual_environment_vm'; then
    echo "=== Plan only destroys DNS alloc data sources — cleaning stale state ==="
    terraform -chdir=terraform state list | grep 'data.external.dns_alloc' | while read -r res; do
      echo "Removing stale state: $res"
      terraform -chdir=terraform state rm "$res" || true
    done
    echo "=== Re-planning after state cleanup ==="
    set +e
    PLAN_OUT=$(terraform -chdir=terraform plan -no-color -input=false -parallelism=1 2>&1)
    PLAN_RC=$?
    set -e
    echo "Re-plan exit code: $PLAN_RC"
    echo "$PLAN_OUT"
    if [ "$PLAN_RC" -eq 1 ] && echo "$PLAN_OUT" | grep -q 'no change found for data.external.dns_alloc'; then
      PLAN_RC=2
    fi
    case "$PLAN_RC" in
      0)
        echo "Plan after cleanup: no changes."
        EXPECTED_VMS=""
        DRIFTED_VMS=""
        echo "ready=true" >> "$GITHUB_OUTPUT"
        echo "failed_vms=" >> "$GITHUB_OUTPUT"
        echo "terraform_drifted=" >> "$GITHUB_OUTPUT"
        exit 0
        ;;
      2)
        echo "Plan after cleanup: changes detected."
        ;;
      *)
        echo "Plan after cleanup failed with exit $PLAN_RC"
        exit 1
        ;;
    esac
  fi

  echo "=== PHASE: APPLY ==="
  terraform -chdir=terraform apply -parallelism=1 -auto-approve

  if [ -n "$DRIFTED_VMS" ]; then
    echo "=== Stamping iac tag on drifted VMs ==="
    IAC_TARGETS="$DRIFTED_VMS" sh scripts/stamp-iac-tags.sh \
      || echo "WARNING: failed to stamp iac tag on drifted VMs (cosmetic - continuing)"
  fi

  # If nothing was created or replaced, no VM will signal — nothing to wait for
  if [ -z "$EXPECTED_VMS" ]; then
    echo "=== NO NEW VMs - skipping readiness wait ==="
    echo "ready=true" >> "$GITHUB_OUTPUT"
    echo "failed_vms=" >> "$GITHUB_OUTPUT"
    echo "terraform_drifted=$DRIFTED_VMS" >> "$GITHUB_OUTPUT"
    exit 0
  fi

  echo "=== PHASE: ACCEPT/READINESS GATE ==="
  echo "=== Polling for readiness (${READINESS_TIMEOUT}s) ==="
  rm -f "$FAILED_VMS_FILE"
  rm -f "$DECLARED_FAILURES_FILE"
  if EXPECTED_VMS="$EXPECTED_VMS" scripts/wait-for-readiness.sh "$READINESS_TIMEOUT"; then
    echo "=== ALL VMs READY ==="
    echo "ready=true" >> "$GITHUB_OUTPUT"
    echo "failed_vms=" >> "$GITHUB_OUTPUT"
    echo "terraform_drifted=$DRIFTED_VMS" >> "$GITHUB_OUTPUT"
    exit 0
  fi

  echo "=== PHASE: REJECT/DESTROY ==="
  echo "=== Readiness failed - handling botched VMs ==="
  FAILED_VMS=$(cat "$FAILED_VMS_FILE" 2>/dev/null || echo "")
  DECLARED_FAILURES=$(cat "$DECLARED_FAILURES_FILE" 2>/dev/null || echo "")
  FAILURE_POLICY=$(yq '.defaults.on_botched_vm_creation // "destroy"' conf/infrastructure.yaml)
  echo "on_botched_vm_creation: $FAILURE_POLICY"

  ALL_BOTCHED=$(echo "$DECLARED_FAILURES $FAILED_VMS" | tr ' ' '\n' | sed '/^$/d' | tr '\n' ' ')

  if [ "$FAILURE_POLICY" = "preserve" ] && [ -n "$ALL_BOTCHED" ]; then
    echo "=== PRESERVE MODE: halting production line for forensics ==="
    for entry in $ALL_BOTCHED; do
      HOSTNAME="${entry%%:*}"
      VMID="${entry##*:}"
      echo "PRESERVING $HOSTNAME (VMID $VMID) - not destroying, left in place for forensics"
    done
    echo "ready=false" >> "$GITHUB_OUTPUT"
    echo "failed_vms=$ALL_BOTCHED" >> "$GITHUB_OUTPUT"
    exit 1
  fi

  echo "=== Destroying botched VMs ==="
  FAILED_VMS="$DECLARED_FAILURES $FAILED_VMS"
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
      -H "Authorization: PVEAPIToken=$(vault kv get -field=api_token secret/infraops/proxmox)" \
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
