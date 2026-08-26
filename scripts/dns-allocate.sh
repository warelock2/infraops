#!/bin/sh
set -eu

HOST="$1"
POOL_START="$2"
POOL_END="$3"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BASE=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
INFRA="$BASE/conf/infrastructure.yaml"

DOMAIN=$(yq -r '.platform.proxmox.dns_domain' "$INFRA")
FQDN="$HOST"
case "$HOST" in
  *.*) ;;
  *) FQDN="$HOST.$DOMAIN" ;;
esac

ansible-playbook "$BASE/ansible/playbooks/manage-iac-dns.yaml" \
  -e "workflow=add:$FQDN" \
  > /tmp/terraform-dns-alloc.log 2>&1

export VAULT_ADDR="${VAULT_ADDR:-https://vault.afobl.com}"
export VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-true}"
PFSENSE_HOST=$(yq -r '[.hosts[] | select(.services? != null) | select(.services[]? == "dns")][0].connection.host' "$INFRA")
PFSENSE_API_KEY=$(vault kv get -format=json secret/infraops/pfsense | jq -r '.data.data.api_key')
NAME="${FQDN%%.*}"
FQDN_DOMAIN="${FQDN#*.}"

IP=$(curl -k -sS -f -H "x-api-key: $PFSENSE_API_KEY" \
  "https://$PFSENSE_HOST/api/v2/services/dns_resolver/host_overrides" |
  jq -r --arg h "$NAME" --arg d "$FQDN_DOMAIN" \
    '.data[] | select(.host == $h and .domain == $d) | .ip[0]' | head -1)

if [ -z "$IP" ] || [ "$IP" = "null" ]; then
  printf '%s\n' "DNS allocation for $FQDN was not found in pfSense overrides" >&2
  exit 1
fi

START=$(echo "$POOL_START" | awk -F. '{print $1*16777216 + $2*65536 + $3*256 + $4}')
END=$(echo "$POOL_END" | awk -F. '{print $1*16777216 + $2*65536 + $3*256 + $4}')
VALUE=$(echo "$IP" | awk -F. '{print $1*16777216 + $2*65536 + $3*256 + $4}')
if [ -z "$IP" ] || [ "$VALUE" -lt "$START" ] || [ "$VALUE" -gt "$END" ]; then
  printf '%s\n' "DNS allocation for $HOST did not produce an in-pool address" >&2
  exit 1
fi

printf '{"ip":"%s"}\n' "$IP"
