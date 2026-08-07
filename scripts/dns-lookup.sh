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
# addresses. When supplied, any answer inside the pool wins over answers
# outside it — so a DHCP lease registration or other foreign record can
# never outrank the IaC host override, even if the resolver returns it
# first. Falls back to the first answer if no pool is given or nothing
# resolves inside it.
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

# No pool match (or no pool given): use the first answer as a fallback.
[ -z "$IP" ] && IP=$(echo "$IP_LIST" | head -1)

printf '{"ip":"%s"}' "$IP"
