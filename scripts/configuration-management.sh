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
K8S_VERSION=$(yq .platform.kubernetes.version conf/infrastructure.yaml)
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

ansible-playbook -i ansible/inventory.json ansible/playbooks/site.yaml \
  --private-key /tmp/ansible_key \
  -e infra_platform_kubernetes_version=$(yq .platform.kubernetes.version conf/infrastructure.yaml) \
  -e infra_platform_kubernetes_pod_network_cidr=$(yq .platform.kubernetes.pod_network_cidr conf/infrastructure.yaml) \
  -e infra_platform_kubernetes_calico_version=$(yq .platform.kubernetes.calico_version conf/infrastructure.yaml) \
  -e infra_service_domain=$SERVICE_DOMAIN \
  -e infra_admin_user=$(yq .platform.admin.user conf/infrastructure.yaml) \
  -e infra_admin_group=$(yq .platform.admin.group conf/infrastructure.yaml) \
  -e infra_ssh_key_file=/tmp/ssh_key.pub \
  -e git_commit=$GIT_COMMIT \
  -e git_tag=$GIT_TAG \
  -e ntfy_message_channel=$NTFY_CHANNEL
