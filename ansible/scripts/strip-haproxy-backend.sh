#!/bin/sh
# Strip departing backends from haproxy config
ITEM="$1"
if grep -Eq '^[[:space:]]*server '"$ITEM"'([[:space:]]|$)' /etc/haproxy/haproxy.cfg; then
    sudo sed -i -E '/^[[:space:]]*server '"$ITEM"'([[:space:]]|$)/d' /etc/haproxy/haproxy.cfg
    echo changed
fi