#!/bin/bash
# ===========================================================================
# Import a k8s cluster's admin context into the local kubeconfig.
#
# One-shot convenience: ssh to the cluster's first control-plane node
# (k8s-<cluster>-control-01), pull /etc/kubernetes/admin.conf, rewrite the
# server URL to the stable API DNS name (k8s-<cluster>-api.localdomain), and
# merge it into ~/.kube/config. Installs kubectl on the fly if missing.
#
# Usage: k8s_import_context.sh <cluster_name>   (e.g. mushroom)
# ===========================================================================
set -e

CLUSTER="${1}"
DNS_DOMAIN="localdomain"

if [ -z "${CLUSTER}" ]; then
  echo "Usage: $0 <cluster_name>" >&2
  echo "Example: $0 mushroom" >&2
  exit 1
fi

CP_HOST="k8s-${CLUSTER}-control-01"
API_HOST="k8s-${CLUSTER}-api.${DNS_DOMAIN}"
KUBECONFIG_PATH="${HOME}/.kube/config"

# Dependency checks
for cmd in ssh sed; do
  if ! command -v "${cmd}" &>/dev/null; then
    echo "Error: ${cmd} is required but not installed." >&2
    exit 1
  fi
done

if ! command -v kubectl &>/dev/null; then
  echo "kubectl not found. Installing..."
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)
  case "${ARCH}" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
  esac
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/${OS}/${ARCH}/kubectl"
  chmod +x kubectl
  sudo mv kubectl /usr/local/bin/
  echo "kubectl installed: $(kubectl version --client --short 2>/dev/null)"
fi

# Ensure ~/.kube exists
mkdir -p "${HOME}/.kube"

# Pull admin.conf from control plane, merge into local kubeconfig, fix server URL
ssh "${CP_HOST}" sudo cat /etc/kubernetes/admin.conf \
  | KUBECONFIG="${KUBECONFIG_PATH}:/dev/stdin" kubectl config view --flatten \
  | sed "s|server: https://.*|server: https://${API_HOST}:6443|" \
  > /tmp/merged.yaml && mv /tmp/merged.yaml "${KUBECONFIG_PATH}"

echo "Context for ${CLUSTER} merged."
echo "Switch with: kubectl config use-context kubernetes-admin@kubernetes"
