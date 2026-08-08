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
# Resolution order: getent (glibc) first, then Python's socket (fallback for
# hosts without getent). Empty string if unresolvable.
#
# The IaC DNS pool (start/end) is the AUTHORITATIVE range for VM static
# addresses. When supplied, ONLY an answer inside the pool is acceptable —
# an out-of-pool record (a stale DHCP "ghost" or any foreign registration)
# must NEVER become a VM's static IP. If the resolver yields no in-pool
# answer, the script asks pfSense's host-override API directly (the source
# of truth the IaC allocation writes to, immune to resolver caches and
# DHCP-lease ghosts) and accepts the override's IP only if it is in-pool.
#
# Usage: dns-lookup.sh <hostname> [pool_start] [pool_end]
# ===========================================================================

HOST="$1"
POOL_START="$2"
POOL_END="$3"
IP=""

if command -v getent >/dev/null 2>&1; then
    IP_LIST=$(getent hosts "$HOST" 2>/dev/null | awk '{print $1}')
elif command -v python3 >/dev/null 2>&1; then
    IP_LIST=$(python3 -c "import socket; print(socket.gethostbyname('$HOST'))" 2>/dev/null || echo "")
fi

[ -z "$IP_LIST" ] && IP_LIST=""

# Normalize pool bounds to integers for comparison (IPv4 only; anything else
# leaves the pool filters inert and the lookup falls back to plain getent).
if [ -n "$POOL_START" ] && [ -n "$POOL_END" ]; then
    _start=$(echo "$POOL_START" | awk -F. '{print $1*16777216 + $2*65536 + $3*256 + $4}')
    _end=$(echo "$POOL_END" | awk -F. '{print $1*16777216 + $2*65536 + $3*256 + $4}')
fi

for candidate in $IP_LIST; do
    if [ -n "$_start" ] && [ -n "$_end" ]; then
        _val=$(echo "$candidate" | awk -F. '{print $1*16777216 + $2*65536 + $3*256 + $4}')
        if [ "$_val" -ge "$_start" ] && [ "$_val" -le "$_end" ] 2>/dev/null; then
            IP="$candidate"
            break
        fi
    elif [ -z "$IP" ]; then
        IP="$candidate"
    fi
done

# No pool given: fall back to the first resolver answer (historical behavior).
if [ -z "$IP" ] && [ -z "$_start" ] && [ -z "$_end" ]; then
    IP=$(echo "$IP_LIST" | head -1)
fi

# Authoritative fallback for the pool case: the resolver returned no in-pool
# answer (stale resolver cache serving a ghost, or the override simply not yet
# visible). The host-override record dns_alloc just created is the truth, so
# read it straight from pfSense instead of trusting a foreign record.
if [ -z "$IP" ] && [ -n "$_start" ] && [ -n "$_end" ]; then
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
            API_IP=$(curl -k -sS -H "x-api-key: $PFSENSE_API_KEY" \
                "https://$PFSENSE_HOST/api/v2/services/dns_resolver/host_overrides" 2>/dev/null |
                jq -r --arg h "$_name" --arg d "$_domain" '.data[] | select(.host == $h and .domain == $d) | .ip[0]' 2>/dev/null | head -1)
            if [ -n "$API_IP" ]; then
                _val=$(echo "$API_IP" | awk -F. '{print $1*16777216 + $2*65536 + $3*256 + $4}')
                if [ "$_val" -ge "$_start" ] && [ "$_val" -le "$_end" ] 2>/dev/null; then
                    IP="$API_IP"
                fi
            fi
        fi
    fi
fi

printf '{"ip":"%s"}' "$IP"
