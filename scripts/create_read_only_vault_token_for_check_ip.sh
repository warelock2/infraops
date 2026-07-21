#!/usr/bin/env bash
# create_read_only_vault_token_for_check_ip.sh
# Creates a read-only policy scoped to secret/infraops/pfsense and a reusable token

set -euo pipefail

POLICY_NAME="infraops-check-ip-availability"
DISPLAY_NAME="check-ip-availability"

# 1. Write the policy
vault policy write "$POLICY_NAME" - <<'EOF'
path "secret/data/infraops/pfsense" {
  capabilities = ["read"]
}
path "secret/metadata/infraops/pfsense" {
  capabilities = ["read"]
}
EOF

echo "Policy '$POLICY_NAME' written."

# 2. Create a reusable token (no expiry)
vault token create \
  -policy="$POLICY_NAME" \
  -display-name="$DISPLAY_NAME" \
  -period=0 \
  -format=json | jq -r '.auth.client_token'
