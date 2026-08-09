#!/usr/bin/env bash
# ===========================================================================
# Create a scoped read/write Vault token for opencode automation.
#
# Same pattern as the read-only variant, but grants create/read/update/delete
# on everything under secret/infraops/* — the level the automation agent
# needs to manage infra secrets. The policy is still scoped to the infraops
# prefix so a leaked token can't reach other Vault paths.
#
# PREREQUISITE: run the following once so this token is truly non-expiring
# (a plain -period=0 token is NOT non-expiring — it just inherits the ~32-day
# server default TTL):
#   vault auth tune -default-lease-ttl=0 -max-lease-ttl=0 token/
# With that in place, -ttl=0 means "no expiration". A leaked non-expiring token
# is worse than a TTL'd one, so keep it in Vault/Forgejo secrets, never on disk.
#
# The emitted token goes to stdout — capture it, don't log it.
# ===========================================================================
# create_read_write_vault_token_for_opencode.sh

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

# 2. Create a reusable token (non-expiring: relies on the token auth method
#    being tuned to -max-lease-ttl=0, see the header).
vault token create \
  -policy="$POLICY_NAME" \
  -display-name="$DISPLAY_NAME" \
  -ttl=0 \
  -format=json | jq -r '.auth.client_token'
