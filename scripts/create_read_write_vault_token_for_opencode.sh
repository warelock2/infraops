#!/usr/bin/env bash
# create_read_write_vault_token_for_opencode.sh
# Creates an infraops-rw policy and a reusable token restricted to secret/infraops/*

set -euo pipefail

POLICY_NAME="infraops-rw"
DISPLAY_NAME="ansible-infraops"

# 1. Write the policy
vault policy write "$POLICY_NAME" - <<'EOF'
path "secret/data/infraops/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "secret/metadata/infraops/*" {
  capabilities = ["list", "read", "delete"]
}
EOF

echo "Policy '$POLICY_NAME' written."

# 2. Create a reusable token (no expiry)
vault token create \
  -policy="$POLICY_NAME" \
  -display-name="$DISPLAY_NAME" \
  -period=0 \
  -format=json | jq -r '.auth.client_token'
