#!/usr/bin/env bash
# ===========================================================================
# Create a scoped read-only Vault token for the IP-availability checker.
#
# Principle of least privilege: instead of a broad root/token, this writes a
# narrow policy that only allows READING the pfSense/proxmox/nats/ntfy paths
# under secret/infraops/* (enough to check whether an IP is already allocated,
# and for CI to read the ntfy channel) and mints a reusable token bound to that
# policy.
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
# create_read_only_vault_token_for_check_ip.sh

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
path "secret/data/infraops/proxmox" {
  capabilities = ["read"]
}
path "secret/metadata/infraops/proxmox" {
  capabilities = ["read"]
}
path "secret/data/infraops/nats" {
  capabilities = ["read"]
}
path "secret/metadata/infraops/nats" {
  capabilities = ["read"]
}
path "secret/data/infraops/ntfy" {
  capabilities = ["read"]
}
path "secret/metadata/infraops/ntfy" {
  capabilities = ["read"]
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
