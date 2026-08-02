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
# Usage: dns-lookup.sh <hostname>
# ===========================================================================

HOST="$1"
IP=""

if command -v getent >/dev/null 2>&1; then
    IP=$(getent hosts "$HOST" 2>/dev/null | awk '{print $1}' | head -1)
fi

if [ -z "$IP" ] && command -v python3 >/dev/null 2>&1; then
    IP=$(python3 -c "import socket; print(socket.gethostbyname('$HOST'))" 2>/dev/null || echo "")
fi

printf '{"ip":"%s"}' "$IP"
