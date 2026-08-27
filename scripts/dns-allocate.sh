#!/bin/sh
set -eu

INPUT=$(cat)
HOST=$(printf '%s' "$INPUT" | jq -r '.name')
POOL_START=$(printf '%s' "$INPUT" | jq -r '.pool_start // empty')
POOL_END=$(printf '%s' "$INPUT" | jq -r '.pool_end // empty')

if [ -z "$POOL_START" ] || [ -z "$POOL_END" ]; then
  printf '%s\n' '{"ip":"0.0.0.0"}'
  exit 0
fi

exec 9>/tmp/terraform-dns-alloc.lock
flock -x 9
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BASE=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
INFRA="$BASE/conf/infrastructure.yaml"
if [ -x "$BASE/.venv/bin/python" ]; then
  export ANSIBLE_PYTHON_INTERPRETER="$BASE/.venv/bin/python"
fi
export ANSIBLE_CONFIG="$BASE/ansible/ansible.cfg"

DOMAIN=$(yq -r '.platform.proxmox.dns_domain' "$INFRA")
FQDN="$HOST"
case "$HOST" in
  *.*) ;;
  *) FQDN="$HOST.$DOMAIN" ;;
esac

export VAULT_ADDR="${VAULT_ADDR:-https://vault.afobl.com}"
export VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-true}"
PFSENSE_HOST=$(yq -r '[.hosts[] | select(.services? != null) | select(.services[]? == "dns")][0].connection.host' "$INFRA")
PFSENSE_API_KEY=$(vault kv get -format=json secret/infraops/pfsense | jq -r '.data.data.api_key')
NAME="${FQDN%%.*}"
FQDN_DOMAIN="${FQDN#*.}"
POOL_PREFIX=$(printf '%s' "$POOL_START" | cut -d. -f1-3)
START_OCTET=$(printf '%s' "$POOL_START" | cut -d. -f4)
END_OCTET=$(printf '%s' "$POOL_END" | cut -d. -f4)

find_pool_ip() {
  ATTEMPT=1
  while [ "$ATTEMPT" -le 3 ]; do
    RESPONSE=$(curl -k -sS -f --retry 5 --retry-all-errors --retry-delay 2 \
      -H "x-api-key: $PFSENSE_API_KEY" \
      "https://$PFSENSE_HOST/api/v2/services/dns_resolver/host_overrides" 2>/dev/null || true)
    for CANDIDATE in $(printf '%s' "$RESPONSE" |
      jq -r --arg h "$NAME" --arg d "$FQDN_DOMAIN" \
        '.data[]? | select(.host == $h and .domain == $d) | .ip[0]' 2>/dev/null); do
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
        printf '%s\n' "$CANDIDATE"
        return 0
      fi
    done
    sleep 2
    ATTEMPT=$((ATTEMPT + 1))
  done
}

is_pool_ip() {
  CANDIDATE="$1"
  CANDIDATE_PREFIX=$(printf '%s' "$CANDIDATE" | cut -d. -f1-3)
  CANDIDATE_OCTET=$(printf '%s' "$CANDIDATE" | cut -d. -f4)
  [ "$CANDIDATE_PREFIX" = "$POOL_PREFIX" ] || return 1
  case "$CANDIDATE_OCTET" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$CANDIDATE_OCTET" -ge "$START_OCTET" ] && [ "$CANDIDATE_OCTET" -le "$END_OCTET" ]
}

IP=$(find_pool_ip || true)
if [ -z "$IP" ]; then
  ANSIBLE_OUTPUT=$(ansible-playbook "$BASE/ansible/playbooks/manage-iac-dns.yaml" \
    -e "workflow=add:$FQDN" 2>&1 | tee /tmp/terraform-dns-alloc.log)
  IP=$(printf '%s\n' "$ANSIBLE_OUTPUT" | awk '/DNS_ALLOCATED_IP=/ {line=$0; sub(/^.*DNS_ALLOCATED_IP=/, "", line); match(line, /[0-9][0-9.]*/); ip=substr(line, RSTART, RLENGTH)} END {print ip}')
  if [ -z "$IP" ]; then
    printf '%s\n' "DNS allocation for $HOST did not report an address" >&2
    exit 1
  fi
  if ! is_pool_ip "$IP"; then
    printf '%s\n' "DNS allocation for $HOST returned an invalid pool address" >&2
    exit 1
  fi
  AUTHORITATIVE_IP=$(find_pool_ip || true)
  if [ "$AUTHORITATIVE_IP" != "$IP" ]; then
    printf '%s\n' "DNS allocation for $HOST was not confirmed by pfSense" >&2
    exit 1
  fi
fi

if [ -z "$IP" ] || ! is_pool_ip "$IP"; then
  printf '%s\n' "DNS allocation for $HOST did not produce an in-pool address" >&2
  exit 1
fi

printf '{"ip":"%s"}\n' "$IP"
