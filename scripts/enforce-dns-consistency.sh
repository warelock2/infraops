#!/bin/sh
# ===========================================================================
# Pre-Terraform DNS consistency enforcer.
#
# Ensures every managed hostname has exactly one in-pool host override in
# pfSense before Terraform runs. This runs on every master push, outside
# any Terraform changes gate.
#
# Policy:
#   - Managed hostname with one in-pool override → leave untouched
#   - Managed hostname with no override → create via existing add workflow
#   - Managed hostname with multiple entries → keep the in-pool one, delete extras
#   - Managed hostname with only out-of-pool entries → warn, touch nothing
#   - Non-managed entries matching IaC naming pattern → leave alone (conservative)
#
# Any changes trigger a pfSense DNS resolver apply.
# ===========================================================================
set -e

export VAULT_ADDR="${VAULT_ADDR:-https://vault.afobl.com}"
export VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-true}"

# Resolve repo root relative to this script — the CI workspace lives at a
# different absolute path than a dev checkout, so hardcoded paths break.
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
INFRA="$BASE/conf/infrastructure.yaml"

echo "=== Reading pfSense credentials from Vault ==="
PFSENSE_HOST=$(yq -r '[.hosts[] | select(.services? != null) | select(.services[]? == "dns")][0].connection.host' "$INFRA")
PFSENSE_API_KEY=$(vault kv get -format=json secret/infraops/pfsense | jq -r '.data.data.api_key')
DNS_DOMAIN=$(yq -r '.platform.proxmox.dns_domain' "$INFRA")
POOL_START=$(yq -r '[.hosts[] | select(.services? != null) | select(.services[]? == "dns")][0].ip_pool.start' "$INFRA")
POOL_END=$(yq -r '[.hosts[] | select(.services? != null) | select(.services[]? == "dns")][0].ip_pool.end' "$INFRA")

[ -n "$PFSENSE_HOST" ] || { echo "ERROR: pfSense host not found in infrastructure.yaml" >&2; exit 1; }
[ -n "$PFSENSE_API_KEY" ] || { echo "ERROR: pfSense API key not found in Vault" >&2; exit 1; }
[ -n "$DNS_DOMAIN" ] || { echo "ERROR: DNS domain not found in infrastructure.yaml" >&2; exit 1; }
[ -n "$POOL_START" ] || { echo "ERROR: IP pool start not found in infrastructure.yaml" >&2; exit 1; }
[ -n "$POOL_END" ] || { echo "ERROR: IP pool end not found in infrastructure.yaml" >&2; exit 1; }

echo "pfSense: $PFSENSE_HOST"
echo "Domain: $DNS_DOMAIN"
echo "Pool: $POOL_START - $POOL_END"

# Pool bounds as integers for range checks
pool_start_int=$(echo "$POOL_START" | awk -F. '{print $1*16777216 + $2*65536 + $3*256 + $4}')
pool_end_int=$(echo "$POOL_END" | awk -F. '{print $1*16777216 + $2*65536 + $3*256 + $4}')

ip_to_int() {
  echo "$1" | awk -F. '{print $1*16777216 + $2*65536 + $3*256 + $4}'
}

ip_in_pool() {
  local ip="$1"
  local val=$(ip_to_int "$ip")
  [ "$val" -ge "$pool_start_int" ] && [ "$val" -le "$pool_end_int" ]
}

# Build managed hostname list from SSOT (k8s nodes + provisioned standalone hosts)
echo "=== Building managed hostname list from SSOT ==="
MANAGED_HOSTS=""

# K8s clusters
CLUSTER_COUNT=$(yq ".clusters | length" "$INFRA")
for i in $(seq 0 $((CLUSTER_COUNT - 1))); do
  CLUSTER_NAME=$(yq ".clusters[$i].name" "$INFRA")
  CLUSTER_TYPE=$(yq ".clusters[$i].cluster_type // .defaults.cluster_type" "$INFRA")
  CP_NODES=$(yq ".clusters[$i].control_plane.nodes // 0" "$INFRA")
  WORKER_NODES=$(yq ".clusters[$i].workers.nodes // 0" "$INFRA")
  CP_STANDBY=$(yq ".clusters[$i].control_plane.standby // 0" "$INFRA")
  WORKER_STANDBY=$(yq ".clusters[$i].workers.standby // 0" "$INFRA")
  CP_PLANE_NAME=$(yq ".clusters[$i].plane_defaults.control_plane.plane_name // .defaults.planes.control_plane.plane_name" "$INFRA")
  WORKER_PLANE_NAME=$(yq ".clusters[$i].plane_defaults.workers.plane_name // .defaults.planes.workers.plane_name" "$INFRA")
  for n in $(seq 1 $((CP_NODES + CP_STANDBY))); do
    NUM=$(printf "%02d" $n)
    HOSTNAME="${CLUSTER_TYPE}-${CLUSTER_NAME}-${CP_PLANE_NAME}-${NUM}"
    MANAGED_HOSTS="${MANAGED_HOSTS}${HOSTNAME} "
  done
  for n in $(seq 1 $((WORKER_NODES + WORKER_STANDBY))); do
    NUM=$(printf "%02d" $n)
    HOSTNAME="${CLUSTER_TYPE}-${CLUSTER_NAME}-${WORKER_PLANE_NAME}-${NUM}"
    MANAGED_HOSTS="${MANAGED_HOSTS}${HOSTNAME} "
  done
done

# Standalone hosts with infrastructure_provisioning enforcement.
# Single yq pass — piping yq YAML output into jq (the old approach) can't
# parse; the []? optional-chain mirrors the .services[]? filters above.
for HOSTNAME in $(yq -r '.hosts[] | select(.enforcement[]? == "infrastructure_provisioning") | .name' "$INFRA"); do
  MANAGED_HOSTS="${MANAGED_HOSTS}${HOSTNAME} "
done

echo "Managed hosts: $MANAGED_HOSTS"

# Fetch current pfSense host overrides
echo "=== Fetching current host overrides from pfSense ==="
OVERRIDES_JSON=$(curl -k -sS -H "x-api-key: $PFSENSE_API_KEY" "https://$PFSENSE_HOST/api/v2/services/dns_resolver/host_overrides" 2>/dev/null) || { echo "ERROR: failed to fetch host overrides from pfSense" >&2; exit 1; }
echo "$OVERRIDES_JSON" | jq -e '.data' >/dev/null 2>&1 || { echo "ERROR: invalid response from pfSense host overrides API" >&2; exit 1; }

# Helper: check if an override entry is in-pool
is_in_pool() {
  local ip="$1"
  ip_in_pool "$ip"
}

# Analyze overrides per managed hostname using jq over the cached JSON
echo "=== Analyzing current overrides ==="
DIRTY=0
CHANGES=""

for HOSTNAME in $MANAGED_HOSTS; do
  HNAME="${HOSTNAME%%.*}"
  DOMAIN="${HOSTNAME#*.}"
  [ "$HNAME" = "$HOSTNAME" ] && DOMAIN="$DNS_DOMAIN"

  # Find all override IPs matching this hostname. The pfSense v2 API exposes
  # no record ID we can verify against this repo — every in-repo CRUD path
  # (add-host.yaml / delete-host.yaml) addresses records by host+domain query
  # params on the plural endpoint, so we collect IPs only.
  MATCHES=$(echo "$OVERRIDES_JSON" | jq -r --arg h "$HNAME" --arg d "$DOMAIN" '.data[] | select(.host == $h and .domain == $d) | .ip[0]' 2>/dev/null)

  if [ -z "$MATCHES" ]; then
    # No override exists — create via add workflow (short name, the same
    # invocation shape as Terraform's dns_alloc local-exec)
    echo "MISSING: $HNAME.$DOMAIN — will create via add workflow"
    CHANGES="${CHANGES} create:${HNAME}"
    DIRTY=1
    continue
  fi

  KEEP_IP=""
  EXTRAS=0
  for ip in $MATCHES; do
    if ip_in_pool "$ip"; then
      if [ -z "$KEEP_IP" ]; then
        KEEP_IP="$ip"
      else
        echo "DUPLICATE IN-POOL: $HNAME.$DOMAIN has multiple in-pool entries ($ip) — will collapse"
        EXTRAS=$((EXTRAS + 1))
      fi
    else
      echo "OUT-OF-POOL: $HNAME.$DOMAIN has out-of-pool entry ($ip) — will delete"
      EXTRAS=$((EXTRAS + 1))
    fi
  done

  # Keeper alongside junk: with no verified per-record delete we use the
  # proven host+domain query-param DELETE (delete-host.yaml pattern), then
  # recreate the keeper verbatim via the proven singular-endpoint POST
  # (add-host.yaml pattern). The keeper keeps its exact IP; resolver apply
  # happens once at the end. Only-out-of-pool stays warn-only (KEEP_IP empty).
  if [ -n "$KEEP_IP" ] && [ "$EXTRAS" -gt 0 ]; then
    echo "REPAIRING: $HNAME.$DOMAIN — removing all entries, recreating keeper at $KEEP_IP"
    curl -k -sS -X DELETE -H "x-api-key: $PFSENSE_API_KEY" \
      "https://$PFSENSE_HOST/api/v2/services/dns_resolver/host_overrides?host=$HNAME&domain=$DOMAIN" >/dev/null || { echo "ERROR: failed to delete overrides for $HNAME.$DOMAIN" >&2; exit 1; }
    curl -k -sS -X POST -H "x-api-key: $PFSENSE_API_KEY" -H "Content-Type: application/json" \
      -d "{\"host\":\"$HNAME\",\"domain\":\"$DOMAIN\",\"ip\":[\"$KEEP_IP\"]}" \
      "https://$PFSENSE_HOST/api/v2/services/dns_resolver/host_override" >/dev/null || { echo "ERROR: failed to recreate override for $HNAME.$DOMAIN at $KEEP_IP" >&2; exit 1; }
    DIRTY=1
  fi
done

if [ "$DIRTY" -eq 1 ]; then
  echo "=== Changes detected — applying pfSense DNS resolver ==="
  # Create missing entries. Bare ansible-playbook invocation mirrors
  # Terraform's dns_alloc local-exec, which works in this CI image with just
  # the VAULT_* env this step already receives (no ANSIBLE_CONFIG needed).
  for change in $CHANGES; do
    if echo "$change" | grep -q "^create:"; then
      HOST="${change#create:}"
      echo "CREATING: $HOST via add workflow"
      ansible-playbook "$BASE/ansible/playbooks/manage-iac-dns.yaml" -e "workflow=add:${HOST}" || { echo "ERROR: failed to create override for $HOST" >&2; exit 1; }
    fi
  done

  # Apply resolver
  echo "=== Applying pfSense DNS resolver ==="
  curl -k -sS -X POST -H "x-api-key: $PFSENSE_API_KEY" "https://$PFSENSE_HOST/api/v2/services/dns_resolver/apply" >/dev/null 2>&1 || { echo "ERROR: failed to apply DNS resolver" >&2; exit 1; }
  echo "DNS consistency enforced successfully"
else
  echo "=== No changes needed — DNS already consistent ==="
fi