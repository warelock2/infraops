#!/bin/sh
# ===========================================================================
# DNS lookup helper for the Terraform external provider.
#
# Terraform cannot resolve DNS directly, so main.tf calls this via the
# `external` provider to look up an FQDN's current IP (used to detect
# pre-registered DNS entries during allocation). It returns JSON in the
# exact shape Terraform's external data source expects:
#   {"ip":"<address>"}
#
# With a pool supplied, read the exact pfSense host override created by the
# allocation step. Resolver answers are deliberately not used because they may
# contain stale DHCP leases or cached records.
#
# Without a pool, retain the historical resolver lookup behavior.
#
# Usage: dns-lookup.sh <hostname> [pool_start] [pool_end]
# ===========================================================================

HOST="$1"
POOL_START="$2"
POOL_END="$3"
IP=""

if [ -n "$POOL_START" ] && [ -n "$POOL_END" ]; then
    SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
    INFRA="$SCRIPT_DIR/../conf/infrastructure.yaml"
    if [ -f "$INFRA" ] \
        && command -v yq >/dev/null 2>&1 \
        && command -v vault >/dev/null 2>&1 \
        && command -v curl >/dev/null 2>&1 \
        && command -v jq >/dev/null 2>&1; then
        export VAULT_ADDR="${VAULT_ADDR:-https://vault.afobl.com}"
        export VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-true}"
        PFSENSE_HOST=$(yq -r '[.hosts[] | select(.services? != null) | select(.services[]? == "dns")][0].connection.host' "$INFRA" 2>/dev/null)
        PFSENSE_API_KEY=$(vault kv get -format=json secret/infraops/pfsense 2>/dev/null | jq -r '.data.data.api_key')
        if [ -n "$PFSENSE_HOST" ] && [ -n "$PFSENSE_API_KEY" ]; then
            _name="${HOST%%.*}"
            _domain="${HOST#*.}"
            IP=$(curl -k -sS -H "x-api-key: $PFSENSE_API_KEY" \
                "https://$PFSENSE_HOST/api/v2/services/dns_resolver/host_overrides" 2>/dev/null |
                jq -r --arg h "$_name" --arg d "$_domain" '.data[] | select(.host == $h and .domain == $d) | .ip[0]' 2>/dev/null | head -1)
            _start=$(echo "$POOL_START" | awk -F. '{print $1*16777216 + $2*65536 + $3*256 + $4}')
            _end=$(echo "$POOL_END" | awk -F. '{print $1*16777216 + $2*65536 + $3*256 + $4}')
            _val=$(echo "$IP" | awk -F. '{print $1*16777216 + $2*65536 + $3*256 + $4}')
            if [ -z "$IP" ] || [ "$_val" -lt "$_start" ] || [ "$_val" -gt "$_end" ] 2>/dev/null; then
                IP=""
            fi
        fi
    fi
else
    if command -v getent >/dev/null 2>&1; then
        IP=$(getent hosts "$HOST" 2>/dev/null | awk 'NR == 1 {print $1}')
    elif command -v python3 >/dev/null 2>&1; then
        IP=$(python3 -c "import socket; print(socket.gethostbyname('$HOST'))" 2>/dev/null || echo "")
    fi
fi

printf '{"ip":"%s"}' "$IP"
