#!/bin/sh
set -eu

INPUT=$(cat)
HOST=$(printf '%s' "$INPUT" | jq -r '.name')
POOL_START=$(printf '%s' "$INPUT" | jq -r '.pool_start')
POOL_END=$(printf '%s' "$INPUT" | jq -r '.pool_end')
exec 9>/tmp/terraform-dns-alloc.lock
flock -x 9
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
POOL_PREFIX=$(printf '%s' "$POOL_START" | cut -d. -f1-3)
START_OCTET=$(printf '%s' "$POOL_START" | cut -d. -f4)
END_OCTET=$(printf '%s' "$POOL_END" | cut -d. -f4)

IP=""
for CANDIDATE in $(curl -k -sS -f -H "x-api-key: $PFSENSE_API_KEY" \
  "https://$PFSENSE_HOST/api/v2/services/dns_resolver/host_overrides" |
  jq -r --arg h "$NAME" --arg d "$FQDN_DOMAIN" \
    '.data[] | select(.host == $h and .domain == $d) | .ip[0]'); do
  CANDIDATE_PREFIX=$(printf '%s' "$CANDIDATE" | cut -d. -f1-3)
  CANDIDATE_OCTET=$(printf '%s' "$CANDIDATE" | cut -d. -f4)
  case "$CANDIDATE_PREFIX" in
    "$POOL_PREFIX") ;;
    *) continue ;;
  esac
  case "$CANDIDATE_OCTET" in
    ''|*[!0-9]*) continue ;;
  esac
  if [ "$CANDIDATE_OCTET" -ge "$START_OCTET" ] && [ "$CANDIDATE_OCTET" -le "$END_OCTET" ]; then
    IP="$CANDIDATE"
    break
  fi
done

if [ -z "$IP" ]; then
  printf '%s\n' "DNS allocation for $HOST did not produce an in-pool address" >&2
  exit 1
fi

printf '{"ip":"%s"}\n' "$IP"
