#!/bin/sh
# DNS lookup for Terraform external provider.
# Usage: dns-lookup.sh <hostname>
# Output: {"ip":"<address>"}

HOST="$1"
IP=""

if command -v getent >/dev/null 2>&1; then
    IP=$(getent hosts "$HOST" 2>/dev/null | awk '{print $1}' | head -1)
fi

if [ -z "$IP" ] && command -v python3 >/dev/null 2>&1; then
    IP=$(python3 -c "import socket; print(socket.gethostbyname('$HOST'))" 2>/dev/null || echo "")
fi

printf '{"ip":"%s"}' "$IP"
