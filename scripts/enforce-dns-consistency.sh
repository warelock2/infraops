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

INFRA="/home/warelock/projects/infraops/conf/infrastructure.yaml"

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

# Standalone hosts with infrastructure_provisioning enforcement
STANDALONE_COUNT=$(yq '.hosts | length' "$INFRA")
for i in $(seq 0 $((STANDALONE_COUNT - 1))); do
  ENFORCEMENT=$(yq ".hosts[$i].enforcement // []" "$INFRA" | jq -r '.[]' 2>/dev/null | tr '\n' ' ')
  if echo "$ENFORCEMENT" | grep -q "infrastructure_provisioning"; then
    HOSTNAME=$(yq ".hosts[$i].name" "$INFRA")
    MANAGED_HOSTS="${MANAGED_HOSTS}${HOSTNAME} "
  fi
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

# Build a map: hostname -> list of override UIDs with their IPs
# We'll use jq to process the JSON
echo "=== Analyzing current overrides ==="
DIRTY=0
CHANGES=""

for HOSTNAME in $MANAGED_HOSTS; do
  HNAME="${HOSTNAME%%.*}"
  DOMAIN="${HOSTNAME#*.}"
  [ "$HNAME" = "$HOSTNAME" ] && DOMAIN="$DNS_DOMAIN"

  # Find all overrides matching this hostname
  MATCHES=$(echo "$OVERRIDES_JSON" | jq -r --arg h "$HNAME" --arg d "$DOMAIN" '.data[] | select(.host == $h and .domain == $d) | "\(.uuid) \(.ip[0])"' 2>/dev/null)

  if [ -z "$MATCHES" ]; then
    # No override exists — create one via add workflow
    echo "MISSING: $HOSTNAME.$DOMAIN — will create via add workflow"
    CHANGES="${CHANGES} create:${HOSTNAME}.${DOMAIN}"
    DIRTY=1
    continue
  fi

  IN_POOL_UID=""
  IN_POOL_IP=""
  OUT_OF_POOL_UIDS=""
  OUT_OF_POOL_IPS=""

  while read -r uid ip; do
    [ -z "$uid" ] && continue
    if ip_in_pool "$ip"; then
      if [ -z "$IN_POOL_UID" ]; then
        IN_POOL_UID="$uid"
        IN_POOL_IP="$ip"
      else
        # Second in-pool entry for same hostname — duplicate
        echo "DUPLICATE IN-POOL: $HOSTNAME.$DOMAIN has multiple in-pool entries (uid=$uid, ip=$ip) — will delete extra"
        OUT_OF_POOL_UIDS="${OUT_OF_POOL_UIDS} $uid"
        OUT_OF_POOL_IPS="${OUT_OF_POOL_IPS} $ip"
        DIRTY=1
      fi
    else
      echo "OUT-OF-POOL: $HOSTNAME.$DOMAIN has out-of-pool entry (uid=$uid, ip=$ip) — will delete"
      OUT_OF_POOL_UIDS="${OUT_OF_POOL_UIDS} $uid"
      OUT_OF_POOL_IPS="${OUT_OF_POOL_IPS} $ip"
      DIRTY=1
    fi
  done <<EOF
$MATCHES
EOF

  # Delete extra/out-of-pool entries
  for uid in $OUT_OF_POOL_UIDS; do
    echo "DELETING: override uid=$uid for $HOSTNAME.$DOMAIN"
    curl -k -sS -X DELETE -H "x-api-key: $PFSENSE_API_KEY" "https://$PFSENSE_HOST/api/v2/services/dns_resolver/host_overrides/$uid" >/dev/null 2>&1 || { echo "WARNING: failed to delete override uid=$uid" >&2; }
  done
done

if [ "$DIRTY" -eq 1 ]; then
  echo "=== Changes detected — applying pfSense DNS resolver ==="
  # Create missing entries
  for change in $CHANGES; do
    if echo "$change" | grep -q "^create:"; then
      HOST="${change#create:}"
      echo "CREATING: $HOST via add workflow"
      ansible-playbook /home/warelock/projects/infraops/ansible/playbooks/manage-iac-dns.yaml -e "workflow=add:${HOST}" || { echo "ERROR: failed to create override for $HOST" >&2; exit 1; }
    fi
  done

  # Apply resolver
  echo "=== Applying pfSense DNS resolver ==="
  curl -k -sS -X POST -H "x-api-key: $PFSENSE_API_KEY" "https://$PFSENSE_HOST/api/v2/services/dns_resolver/apply" >/dev/null 2>&1 || { echo "ERROR: failed to apply DNS resolver" >&2; exit 1; }
  echo "DNS consistency enforced successfully"
else
  echo "=== No changes needed — DNS already consistent ==="
fi