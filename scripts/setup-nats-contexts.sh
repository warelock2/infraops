#!/bin/sh
# Configure the 4 NATS client contexts (system, production, vm, iac-orchestrator)
# using passwords fetched from Vault at secret/infraops/nats.
#
# No secrets are stored in this file - they come from Vault at runtime.
#
# Usage:
#   VAULT_ADDR=... VAULT_TOKEN=... scripts/setup-nats-contexts.sh
set -eu

export VAULT_ADDR="${VAULT_ADDR:-https://vault.afobl.com}"
export VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-true}"

SERVER="tls://midas.afobl.com:4222"

echo "=== Reading NATS passwords from Vault ==="
VAULT_SECRET=$(vault kv get -format=json secret/infraops/nats)

nats_context_add() {
  context_name="$1"
  description="$2"
  nats_user="$3"
  vault_key="$4"
  password=$(echo "$VAULT_SECRET" | jq -r ".data.data.${vault_key}")
  nats context add "$context_name" --server "$SERVER" \
    --description "$description" --user "$nats_user" --password "$password"
}

echo "=== Setting up nats contexts ==="
nats_context_add system "NATS System Admin" sys sys_password
nats_context_add production "NATS Production" app app_password
nats_context_add vm "VM Bootstrap" vm vm_password
nats_context_add iac-orchestrator "IaC Orchestrator" iac-orchestrator iac_orchestrator_password

echo "=== Contexts configured ==="
nats context ls
