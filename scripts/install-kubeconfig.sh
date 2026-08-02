#!/usr/bin/env bash
# ===========================================================================
# Fetch a kubeconfig from a cluster node and merge it into the local config.
#
# scp's ~/.kube/config off a node (usually the control-plane leader) and
# either adopts it (no local config yet) or flattens it into the existing
# local config. Derives a context name from the remote config by default,
# renames the context if a different name was requested, then activates it.
#
# Usage: install-kubeconfig.sh <user@host> [context-name]
# ===========================================================================
set -euo pipefail

CLUSTER_NODE="${1:?Usage: $0 <user@host> [context-name]}"
CONTEXT_NAME="${2}"

if ! command -v kubectl &>/dev/null; then
  echo "Error: kubectl not found" >&2
  exit 1
fi

KUBEDIR="${HOME}/.kube"
mkdir -p "${KUBEDIR}"
LOCAL_CONFIG="${KUBEDIR}/config"
REMOTE_CONFIG=$(mktemp)
MERGED_CONFIG=$(mktemp)
trap 'rm -f "${REMOTE_CONFIG}" "${MERGED_CONFIG}"' EXIT

echo "Fetching kubeconfig from ${CLUSTER_NODE}..."
scp "${CLUSTER_NODE}:.kube/config" "${REMOTE_CONFIG}"

# Derive context name from the remote config
REMOTE_CONTEXT=$(kubectl --kubeconfig "${REMOTE_CONFIG}" config current-context 2>/dev/null || echo "default")
if [ -z "${CONTEXT_NAME}" ]; then
  CONTEXT_NAME="${REMOTE_CONTEXT}"
fi

if [ ! -f "${LOCAL_CONFIG}" ] || [ ! -s "${LOCAL_CONFIG}" ]; then
  # No existing config — just use the remote config as-is
  cp "${REMOTE_CONFIG}" "${LOCAL_CONFIG}"
  chmod 600 "${LOCAL_CONFIG}"
else
  # Merge remote into existing config
  KUBECONFIG="${LOCAL_CONFIG}:${REMOTE_CONFIG}" kubectl config view --flatten > "${MERGED_CONFIG}"
  mv "${MERGED_CONFIG}" "${LOCAL_CONFIG}"
  chmod 600 "${LOCAL_CONFIG}"
fi

# Rename context if it differs from requested name
if [ "${REMOTE_CONTEXT}" != "${CONTEXT_NAME}" ]; then
  kubectl config rename-context "${REMOTE_CONTEXT}" "${CONTEXT_NAME}" 2>/dev/null || true
fi

kubectl config use-context "${CONTEXT_NAME}"

echo
echo "Context '${CONTEXT_NAME}' is now active."
echo "Available contexts:"
kubectl config get-contexts -o name
