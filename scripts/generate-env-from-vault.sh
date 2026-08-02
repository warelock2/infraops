#!/bin/bash -e
# ===========================================================================
# Render env-example.txt template with values from Vault.
#
# The repo stores env TEMPLATES, not secrets. This script substitutes every
# {{VAULT:path:key}} token in the template with the live value from Vault
# and writes the result to a 0600 output file. The output is meant to be
# consumed once (e.g. rendered into a cloud-init snippet) and then shredded,
# so it never persists with real secrets in the repo.
#
# Auth: $VAULT_TOKEN, or fall back to `pass tokens/vault-prod`.
# Usage: generate-env-from-vault.sh [template] [output]
# ===========================================================================

set -euo pipefail

TEMPLATE="${1:-/home/warelock/projects/infraops/scripts/env-example.txt}"
OUTPUT="${2:-/home/warelock/projects/infraops/scripts/.env}"

if [[ ! -f "$TEMPLATE" ]]; then
  echo "Template not found: $TEMPLATE" >&2
  exit 1
fi

# Check for Vault token
if [[ -z "${VAULT_TOKEN:-}" ]]; then
  if command -v pass >/dev/null 2>&1 && pass tokens/vault-prod >/dev/null 2>&1; then
    export VAULT_TOKEN=$(pass tokens/vault-prod)
    export GPG_TTY=$(tty)
    gpg-connect-agent updatestartuptty /bye >/dev/null 2>&1 || true
  else
    echo "VAULT_TOKEN not set and pass tokens/vault-prod not available" >&2
    exit 1
  fi
fi

if [[ -z "${VAULT_ADDR:-}" ]]; then
  export VAULT_ADDR="https://vault.afobl.com"
fi

export VAULT_SKIP_VERIFY=true

# Render template
sed \
  -e "s|{{VAULT:secret/infraops/nats:vm_password}}|$(vault kv get -field=vm_password secret/infraops/nats)|g" \
  -e "s|{{VAULT:secret/infraops/nats:iac_orchestrator_password}}|$(vault kv get -field=iac_orchestrator_password secret/infraops/nats)|g" \
  -e "s|{{VAULT:secret/infraops/nats:app_password}}|$(vault kv get -field=app_password secret/infraops/nats)|g" \
  -e "s|{{VAULT:secret/infraops/nats:sys_password}}|$(vault kv get -field=sys_password secret/infraops/nats)|g" \
  "$TEMPLATE" > "$OUTPUT"

chmod 600 "$OUTPUT"
echo "Generated $OUTPUT"
echo "Run: shred -u $OUTPUT after template creation"