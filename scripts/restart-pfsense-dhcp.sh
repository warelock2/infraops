#!/bin/sh
# ===========================================================================
# Restart the pfSense DHCP service after deleting any ghost DHCP leases, so
# DNS ends up clean (the restart regenerates Unbound from dhcpd.leases).
#
# Why: a freshly cloned VM holds a short DHCP lease during its boot window
# (before cloud-init applies the static netplan). The VM now releases that
# lease itself during the DHCP->static switch (see
# cloud-init-reboot.yaml.template), so the lease is gone on the pfSense side
# — BUT the stale DNS registration made by dhcpleases survives until the DHCP
# service restarts and rewrites the Unbound entries. This script runs right
# after the Terraform apply loop and BEFORE Ansible config management, so
# Ansible only ever sees unpolluted DNS.
#
# Remediate in stages:
#   Stage 1: delete ghost DHCP leases -> restart DHCP (triggers dhcpleases
#            resync of Unbound local-data) -> re-verify.
#   Stage 2: restart DNS resolver (dns_resolver/apply) so Unbound fully
#            reloads its config and clears its message cache -> re-verify.
# After all remediation, gate with compare_dns(): authoritative query vs
# chain query. If the chain returns any IP not present in the authoritative
# answer, fail with an explicit diagnostic — something upstream is serving
# stale data and must be rooted out before the pipeline proceeds.
# ===========================================================================
set -ex

export VAULT_ADDR="${VAULT_ADDR:-https://vault.afobl.com}"
export VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-true}"

echo "=== Reading pfSense API key from Vault ==="
PFSENSE_API_KEY=$(vault kv get -format=json secret/infraops/pfsense | jq -r '.data.data.api_key')
[ -n "$PFSENSE_API_KEY" ] || { echo "ERROR: empty pfSense API key" >&2; exit 1; }

echo "=== Reading infrastructure.yaml ==="
INFRA=/tmp/infraops-infra.yaml
cp conf/infrastructure.yaml "$INFRA"

PFSENSE_HOST=$(yq -r '[.hosts[] | select(.services? != null) | select(.services[]? == "dhcp")][0].connection.host' "$INFRA")
POOL_START=$(yq -r '[.hosts[] | select(.ip_pool? != null)][0].ip_pool.start' "$INFRA")
POOL_END=$(yq -r '[.hosts[] | select(.ip_pool? != null)][0].ip_pool.end' "$INFRA")
if [ -z "$PFSENSE_HOST" ] || [ -z "$POOL_START" ] || [ -z "$POOL_END" ]; then
  echo "ERROR: could not find pfSense host or IaC pool in infrastructure.yaml" >&2
  exit 1
fi
echo "pfSense host: $PFSENSE_HOST  pool: $POOL_START-$POOL_END"

echo "=== Collecting provisioned VM FQDNs ==="
PROVISIONED_FQDNS=$(python3 - "$INFRA" <<'PYEOF'
import json, sys, yaml
from pathlib import Path

infra = yaml.safe_load(Path(sys.argv[1]).read_text())
domain = infra.get("platform", {}).get("proxmox", {}).get("dns_domain", "localdomain")
defaults = infra.get("defaults", {})

fqdns = []

for host in infra.get("hosts", []):
    enforcement = host.get("enforcement") or []
    if "infrastructure_provisioning" in enforcement:
        fqdns.append(f"{host['name']}.{domain}")

for cluster in infra.get("clusters", []):
    enforcement = cluster.get("enforcement") or []
    if "infrastructure_provisioning" not in enforcement:
        continue
    ctype = defaults.get("cluster_type", "k8s")
    cname = cluster["name"]
    cp = cluster.get("control_plane", {})
    cp_nodes = cp.get("nodes", 0)
    cp_plane = defaults.get("planes", {}).get("control_plane", {}).get("plane_name", "control")
    for i in range(1, cp_nodes + 1):
        fqdns.append(f"{ctype}-{cname}-{cp_plane}-{i:02d}.{domain}")
    wk = cluster.get("workers", {})
    wk_nodes = wk.get("nodes", 0)
    wk_plane = defaults.get("planes", {}).get("workers", {}).get("plane_name", "worker")
    for i in range(1, wk_nodes + 1):
        fqdns.append(f"{ctype}-{cname}-{wk_plane}-{i:02d}.{domain}")

print("\n".join(fqdns))
PYEOF
)
echo "Provisioned FQDNs: $PROVISIONED_FQDNS"
[ -n "$PROVISIONED_FQDNS" ] || {
  echo "WARNING: no provisioned VMs to verify — nothing to check after DHCP restart"
  exit 0
}

# resolve_fqdn via nslookup against a given DNS server.
# Usage: resolve_fqdn <fqdn> [<server>]
# If server is provided, query that server directly; otherwise use system resolver.
resolve_fqdn() {
  fqdn="$1"
  server="$2"
  if [ -n "$server" ]; then
    nslookup "$fqdn" "$server" 2>/dev/null | awk '/^Name:/{seen=1;next} seen && /^Address: [0-9]/{print $2}'
  else
    nslookup "$fqdn" 2>/dev/null | awk '/^Name:/{seen=1;next} seen && /^Address: [0-9]/{print $2}'
  fi
}

# ip_in_pool returns 0 if ip is within the IaC pool, 1 otherwise.
ip_in_pool() {
  python3 - "$1" "$POOL_START" "$POOL_END" <<'PYEOF'
import ipaddress, sys
ip = ipaddress.ip_address(sys.argv[1])
start = ipaddress.ip_address(sys.argv[2])
end = ipaddress.ip_address(sys.argv[3])
sys.exit(0 if start <= ip <= end else 1)
PYEOF
}

# command_prompt runs a command on pfSense via the diagnostics endpoint and
# prints the API's text output. Mirrors delete-lease.yaml's API usage.
command_prompt() {
  curl -k -sS \
    -X POST \
    -H "x-api-key: $PFSENSE_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(python3 -c 'import json, sys; print(json.dumps({"command": sys.argv[1]}))' "$1")" \
    "https://$PFSENSE_HOST/api/v2/diagnostics/command_prompt" |
    python3 -c 'import json, sys; print(json.load(sys.stdin).get("data", {}).get("output", ""))'
}

# delete_ghost_lease removes one lease declaration from dhcpd.leases, using the
# exact sequence from ansible/playbooks/tasks/delete-lease.yaml: stop dhcpd and
# wait until it is truly dead (so it cannot rewrite the file from memory), then
# sed the lease block out. The caller restarts dhcpd once after all deletions.
delete_ghost_lease() {
  target_item="$1"
  echo "  Deleting ghost lease $target_item"

  kill_out=$(command_prompt "killall dhcpd 2>/dev/null; for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x dhcpd >/dev/null 2>&1 || break; sleep 1; done; if pgrep -x dhcpd >/dev/null 2>&1; then echo STILL-RUNNING; else echo DEAD; fi")
  case "$kill_out" in
    *DEAD*) ;;
    *) echo "ERROR: dhcpd did not stop before deleting lease $target_item (output: $kill_out)" >&2; exit 1 ;;
  esac

  remove_out=$(command_prompt "sed -i '' '/^lease $target_item {\$/,/^}\$/d' /var/dhcpd/var/db/dhcpd.leases; grep -c 'lease $target_item {' /var/dhcpd/var/db/dhcpd.leases; echo DONE")
  remaining=$(printf '%s\n' "$remove_out" | head -n1)
  if [ "$remaining" != "0" ]; then
    echo "ERROR: lease $target_item still present in dhcpd.leases (output: $remove_out)" >&2
    exit 1
  fi
  echo "  Ghost lease $target_item removed from dhcpd.leases"
}

# verify_dns resolves every provisioned FQDN against pfSense directly,
# prints OK/GHOST per answer, and sets GHOST_IPS to the out-of-pool answers
# found (space separated). Returns 0 when DNS is clean, 1 when at least one
# ghost survived.
verify_dns() {
  GHOST_IPS=""
  GHOSTS=0
  for fqdn in $PROVISIONED_FQDNS; do
    # Retry resolution so a just-restarted resolver doesn't trip a stale cache.
    IP_LIST=""
    for attempt in 1 2 3; do
      IP_LIST=$(resolve_fqdn "$fqdn" "$PFSENSE_HOST")
      [ -n "$IP_LIST" ] && break
      echo "  $fqdn not resolvable yet (attempt $attempt/3) — retrying"
      sleep 3
    done
    [ -n "$IP_LIST" ] || { echo "ERROR: $fqdn does not resolve at all" >&2; GHOSTS=1; continue; }

    for ip in $IP_LIST; do
      if ip_in_pool "$ip"; then
        echo "  OK: $fqdn -> $ip (in pool)"
      else
        echo "  GHOST: $fqdn -> $ip (outside pool)" >&2
        GHOST_IPS="$GHOST_IPS $ip"
        GHOSTS=1
      fi
    done
  done
  [ "$GHOSTS" -eq 0 ]
}

# compare_dns checks if normal chain resolution matches authoritative query.
# Returns 0 if they match, 1 if chain has extras not in authoritative.
# On mismatch, prints explicit diagnostic.
compare_dns() {
  MISMATCH=0
  for fqdn in $PROVISIONED_FQDNS; do
    AUTH_IPS=$(resolve_fqdn "$fqdn" "$PFSENSE_HOST")
    CHAIN_IPS=$(resolve_fqdn "$fqdn")

    # If authoritative returns nothing, we can't validate — treat as error
    [ -n "$AUTH_IPS" ] || {
      echo "ERROR: authoritative DNS ($PFSENSE_HOST) returned no answer for $fqdn" >&2
      MISMATCH=1
      continue
    }

    # Check for chain extras (IPs in chain not in authoritative)
    CHAIN_EXTRAS=""
    for cip in $CHAIN_IPS; do
      FOUND=0
      for aip in $AUTH_IPS; do
        [ "$cip" = "$aip" ] && { FOUND=1; break; }
      done
      [ $FOUND -eq 0 ] && CHAIN_EXTRAS="$CHAIN_EXTRAS $cip"
    done

    if [ -n "$CHAIN_EXTRAS" ]; then
      echo "DNS CACHE POLLUTION: $fqdn chain returned extra IPs:$CHAIN_EXTRAS not present on authoritative $PFSENSE_HOST (authoritative: $AUTH_IPS)" >&2
      MISMATCH=1
    fi
  done
  [ $MISMATCH -eq 0 ]
}

echo "=== Stage 0: Initial DNS verification ==="
if verify_dns; then
  echo "=== DNS clean on initial check ==="
  if compare_dns; then
    echo "=== Authoritative and chain DNS agree — proceeding ==="
    exit 0
  fi
  echo "=== Initial DNS clean but chain differs — entering remediation ==="
fi

echo "=== Stage 1: Delete ghost leases + restart DHCP ==="
for ghost_ip in $GHOST_IPS; do
  delete_ghost_lease "$ghost_ip"
done

echo "=== Restarting pfSense DHCP service (apply) ==="
HTTP_CODE=$(curl -k -sS -o /tmp/dhcp_apply.json -w '%{http_code}' \
  -X POST \
  -H "x-api-key: $PFSENSE_API_KEY" \
  "https://$PFSENSE_HOST/api/v2/services/dhcp_server/apply")
echo "apply HTTP $HTTP_CODE"
[ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "202" ] || {
  echo "ERROR: DHCP apply failed (HTTP $HTTP_CODE)" >&2
  cat /tmp/dhcp_apply.json >&2 || true
  exit 1
}

echo "=== Waiting for DHCP/DNS to settle ==="
sleep 15

echo "=== Stage 1 re-verification ==="
if verify_dns; then
  echo "=== DNS clean after Stage 1 ==="
  if compare_dns; then
    echo "=== Authoritative and chain DNS agree after Stage 1 — proceeding ==="
    exit 0
  fi
  echo "=== Stage 1 DNS clean but chain differs — escalating to Stage 2 ==="
fi

echo "=== Stage 2: Restart DNS resolver (dns_resolver/apply) ==="
HTTP_CODE=$(curl -k -sS -o /tmp/dns_apply.json -w '%{http_code}' \
  -X POST \
  -H "x-api-key: $PFSENSE_API_KEY" \
  "https://$PFSENSE_HOST/api/v2/services/dns_resolver/apply")
echo "dns_resolver/apply HTTP $HTTP_CODE"
[ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "202" ] || {
  echo "ERROR: DNS resolver apply failed (HTTP $HTTP_CODE)" >&2
  cat /tmp/dns_apply.json >&2 || true
  exit 1
}

echo "=== Waiting for DNS resolver to settle ==="
sleep 15

echo "=== Stage 2 re-verification ==="
if verify_dns; then
  echo "=== DNS clean after Stage 2 ==="
else
  echo "FATAL: out-of-pool DNS answers survived Stage 2 remediation" >&2
  exit 1
fi

echo "=== Final gate: Authoritative vs Chain comparison ==="
if compare_dns; then
  echo "=== Authoritative and chain DNS agree — proceeding ==="
  exit 0
else
  echo "FATAL: chain DNS differs from authoritative after all remediation — pipeline stopped" >&2
  exit 1
fi