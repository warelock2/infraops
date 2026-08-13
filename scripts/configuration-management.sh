#!/bin/sh
# ===========================================================================
# Configuration Management: provision a Kubernetes cluster's control-plane
# kubeconfig for the orchestrator, then run the full ansible site playbook
# against the freshly-created inventory.
#
# Runs inside the ci-base container with secrets injected via env (step env:
# ADMIN_SSH_PUBLIC_KEY, ANSIBLE_SSH_PRIVATE_KEY) and Vault (NATS channel etc).
# Expects to be invoked from the repository root with the workspace checked out.
#
# NOTE: this must stay a real script file rather than an inline `sh -c '...'`
# workflow arg. The runner tokenizes with.args with a quote-stripping parser,
# so an inline yq expression containing a pipe (e.g. `yq '.clusters | length'`)
# loses its quotes and the pipe becomes real shell syntax, breaking the step.
# ===========================================================================
set -e

if [ -z "$ADMIN_SSH_PUBLIC_KEY" ]; then
  echo "ERROR: ADMIN_SSH_PUBLIC_KEY not set"
  exit 1
fi
if [ -z "$ANSIBLE_SSH_PRIVATE_KEY" ]; then
  echo "ERROR: ANSIBLE_SSH_PRIVATE_KEY not set"
  exit 1
fi

export VAULT_ADDR="${VAULT_ADDR:-https://vault.afobl.com}"
export VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-true}"

echo "=== Reading NTfy channel from Vault ==="
NTFY_CHANNEL=$(vault kv get -field=message_channel_phone secret/infraops/ntfy)

echo "=== Verifying kubectl version matches config ==="
K8S_VERSION=$(yq .tools.kubernetes conf/infrastructure.yaml)
BAKED_KUBECTL=$(kubectl version --client -o yaml | yq .clientVersion.gitVersion)
case "$BAKED_KUBECTL" in
  *"$K8S_VERSION"*) ;;
  *)
    echo "ERROR: config k8s version $K8S_VERSION != baked kubectl $BAKED_KUBECTL; rebuild ci-base (KUBECTL_VERSION ARG)"
    exit 1
    ;;
esac

echo "=== Staging SSH keys ==="
echo "$ADMIN_SSH_PUBLIC_KEY" > /tmp/ssh_key.pub
echo "$ANSIBLE_SSH_PRIVATE_KEY" > /tmp/ansible_key
chmod 600 /tmp/ansible_key
mkdir -p ~/.kube

echo "=== Fetching control-plane kubeconfig (if an existing cluster is already bootstrapped) ==="
DNS_DOMAIN=$(yq .platform.proxmox.dns_domain conf/infrastructure.yaml)
if [ "$(yq '.clusters | length' conf/infrastructure.yaml)" -gt 0 ]; then
  CP01=$(yq -r '.clusters[0].name' conf/infrastructure.yaml)
  CP_FQDN=k8s-${CP01}-control-01.${DNS_DOMAIN}
  if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -i /tmp/ansible_key ansible@${CP_FQDN} \
      'test -f /etc/kubernetes/admin.conf' 2>/dev/null; then
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -i /tmp/ansible_key ansible@${CP_FQDN} \
      sudo cat /etc/kubernetes/admin.conf > ~/.kube/config
    chmod 600 ~/.kube/config
  else
    echo "WARNING: /etc/kubernetes/admin.conf absent on ${CP_FQDN} (fresh cluster not yet bootstrapped) - skipping kubeconfig fetch"
  fi
else
  echo "No clusters in infrastructure.yaml - skipping kubeconfig fetch"
fi

echo "=== Running ansible site playbook ==="
export ANSIBLE_CONFIG=$PWD/ansible/ansible.cfg
SERVICE_HOST=$(yq .defaults.service_host conf/infrastructure.yaml)
DNS_DOMAIN=$(yq .platform.proxmox.dns_domain conf/infrastructure.yaml)
SERVICE_DOMAIN="${SERVICE_HOST}.${DNS_DOMAIN}"
GIT_COMMIT="${GITHUB_SHA::8}"
GIT_TAG="${GITHUB_REF_NAME}"

ANSIBLE_LOG=/tmp/ansible-output.log
: > "$ANSIBLE_LOG"
ansible-playbook -i ansible/inventory.json ansible/playbooks/site.yaml \
  --private-key /tmp/ansible_key \
  -e infra_platform_kubernetes_version=$(yq .tools.kubernetes conf/infrastructure.yaml) \
  -e infra_platform_kubernetes_pod_network_cidr=$(yq .platform.kubernetes.pod_network_cidr conf/infrastructure.yaml) \
  -e infra_platform_kubernetes_calico_version=$(yq .tools.calico conf/infrastructure.yaml) \
  -e infra_service_domain=$SERVICE_DOMAIN \
  -e infra_admin_user=$(yq .platform.admin.user conf/infrastructure.yaml) \
  -e infra_admin_group=$(yq .platform.admin.group conf/infrastructure.yaml) \
  -e infra_ssh_key_file=/tmp/ssh_key.pub \
  -e git_commit=$GIT_COMMIT \
  -e git_tag=$GIT_TAG \
  -e ntfy_message_channel=$NTFY_CHANNEL >"$ANSIBLE_LOG" 2>&1 &
ANSIBLE_PID=$!
RUN_START=$(date +%s)
LAST_HEARTBEAT=$RUN_START
LAST_LINE=0
while kill -0 "$ANSIBLE_PID" 2>/dev/null; do
  tail -n "+$((LAST_LINE + 1))" "$ANSIBLE_LOG" 2>/dev/null
  LAST_LINE=$(wc -l < "$ANSIBLE_LOG" 2>/dev/null || echo "$LAST_LINE")
  NOW=$(date +%s)
  if [ $((NOW - LAST_HEARTBEAT)) -ge 60 ]; then
    echo "[watchdog] ansible site playbook still running (elapsed $((NOW - RUN_START))s) - last task above"
    LAST_HEARTBEAT=$NOW
  fi
  sleep 3
done
if wait "$ANSIBLE_PID"; then
  ANSIBLE_STATUS=0
else
  ANSIBLE_STATUS=$?
fi
tail -n "+$((LAST_LINE + 1))" "$ANSIBLE_LOG" 2>/dev/null
if [ "$ANSIBLE_STATUS" -ne 0 ]; then
  echo "=== ANSIBLE FAILURE DIAGNOSTICS (exit $ANSIBLE_STATUS) ==="
  echo "--- PLAY RECAP ---"
  awk '/PLAY RECAP/{recap=1} recap' "$ANSIBLE_LOG" || true
  echo "--- failures / unreachable ---"
  grep -nE 'fatal:|FAILED!|unreachable=|ERROR' "$ANSIBLE_LOG" || true
  echo "--- last 40 lines of ansible output ---"
  tail -n 40 "$ANSIBLE_LOG" || true
  if [ -s ~/.kube/config ]; then
    echo "--- cluster state (nodes) ---"
    kubectl --kubeconfig ~/.kube/config get nodes -o wide 2>&1 || true
    echo "--- cluster state (pods) ---"
    kubectl --kubeconfig ~/.kube/config get pods -A -o wide 2>&1 | head -50 || true
    echo "--- recent cluster events ---"
    kubectl --kubeconfig ~/.kube/config get events -A --sort-by=.lastTimestamp 2>&1 | tail -30 || true
  else
    echo "--- no kubeconfig available (cluster likely not bootstrapped) ---"
  fi
  echo "ERROR: ansible site playbook failed (exit $ANSIBLE_STATUS)" >&2
  exit "$ANSIBLE_STATUS"
fi

echo "=== Detecting hosts whose state drifted (changed > 0) ==="
ANSIBLE_DRIFTED=$(awk '/PLAY RECAP/{recap=1} recap && $2 == ":" && $0 ~ /changed=[1-9][0-9]*/ {print $1}' "$ANSIBLE_LOG" | sort -u | grep -v '^localhost$' | tr '\n' ' ')
ANSIBLE_DRIFTED=$(echo "$ANSIBLE_DRIFTED" | sed 's/ *$//')
echo "Hosts changed by config management: ${ANSIBLE_DRIFTED:-<none>}"
if [ -n "$ANSIBLE_DRIFTED" ]; then
  echo "=== Stamping iac tag on drifted hosts ==="
  IAC_TARGETS="$ANSIBLE_DRIFTED" sh scripts/stamp-iac-tags.sh \
    || echo "WARNING: failed to stamp iac tag on drifted hosts (cosmetic - continuing)"
fi
if [ -n "$GITHUB_OUTPUT" ]; then
  echo "ansible_drifted=$ANSIBLE_DRIFTED" >> "$GITHUB_OUTPUT"
fi
