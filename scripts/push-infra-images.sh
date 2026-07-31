#!/bin/sh
# Pre-pull kubeadm + Calico container images and push them to the local
# Forgejo container registry so cluster builds don't depend on remote pulls.
#
# Usage:
#   scripts/push-infra-images.sh [--k8s-version v1.33.0] [--calico-version v3.29.2]
#
# Versions default to the literals in config/infrastructure.yaml.
# Set FORGEJO_TOKEN to authenticate non-interactively; otherwise docker
# prompts for credentials.
set -eu

REPO="forgejo.afobl.com/warelock"

echo "=== Authenticating to $REPO ==="
if [ -n "${FORGEJO_TOKEN:-}" ]; then
  echo "$FORGEJO_TOKEN" | docker login forgejo.afobl.com --username warelock --password-stdin
else
  docker login forgejo.afobl.com
fi

# Pinned fallback map when kubeadm is not installed on the host.
# Keep in sync with: kubeadm config images list --kubernetes-version v<k8s>
KUBEADM_AUX_v1_33_0="registry.k8s.io/coredns/coredns:v1.12.0 registry.k8s.io/pause:3.10 registry.k8s.io/etcd:3.5.21-0"

K8S_VERSION=""
CALICO_VERSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --k8s-version) K8S_VERSION="$2"; shift 2;;
    --calico-version) CALICO_VERSION="$2"; shift 2;;
    *) echo "Unknown option: $1" >&2; exit 1;;
  esac
done

if [ -z "$K8S_VERSION" ]; then
  K8S_VERSION="v$(yq '.platform.kubernetes.version' config/infrastructure.yaml)"
fi
if [ -z "$CALICO_VERSION" ]; then
  CALICO_VERSION="$(yq '.platform.kubernetes.calico_version' config/infrastructure.yaml)"
  case "$CALICO_VERSION" in
    v*) ;;
    *) CALICO_VERSION="v${CALICO_VERSION}" ;;
  esac
fi

# Derive the kubeadm image list. Prefer the kubeadm binary when available;
# otherwise fall back to the pinned map for known releases.
if command -v kubeadm >/dev/null 2>&1; then
  KUBEADM_IMAGES=$(kubeadm config images list --kubernetes-version "$K8S_VERSION" 2>/dev/null || true)
fi
if [ -z "${KUBEADM_IMAGES:-}" ]; then
  case "$K8S_VERSION" in
    v1.33.0)
      KUBEADM_IMAGES="registry.k8s.io/kube-apiserver:${K8S_VERSION} registry.k8s.io/kube-controller-manager:${K8S_VERSION} registry.k8s.io/kube-scheduler:${K8S_VERSION} registry.k8s.io/kube-proxy:${K8S_VERSION} $KUBEADM_AUX_v1_33_0";;
    *)
      echo "ERROR: kubeadm not installed and no pinned image map for $K8S_VERSION (add it to the script)" >&2
      exit 1;;
  esac
fi

echo "=== Pushing kubeadm images ($K8S_VERSION) to $REPO ==="
for src in $KUBEADM_IMAGES; do
  # name/tag from the last path segment, so nested paths (coredns/coredns)
  # are flattened to a single name in the local registry.
  name="${src##*/}"
  name="${name%%:*}"
  tag="${src##*:}"
  dst="${REPO}/${name}:${tag}"
  echo "--- $src -> $dst"
  docker pull "$src"
  docker tag "$src" "$dst"
  docker push "$dst"
done

echo "=== Pushing Calico images ($CALICO_VERSION) to $REPO ==="
for name in cni node kube-controllers; do
  src="docker.io/calico/${name}:${CALICO_VERSION}"
  dst="${REPO}/calico-${name}:${CALICO_VERSION}"
  echo "--- $src -> $dst"
  docker pull "$src"
  docker tag "$src" "$dst"
  docker push "$dst"
done

echo "=== Pushing runner job container to $REPO ==="
src="node:20-bullseye"
dst="${REPO}/node:20-bullseye"
echo "--- $src -> $dst"
docker pull "$src"
docker tag "$src" "$dst"
docker push "$dst"

echo "=== Pushing Keycloak image to $REPO ==="
src="quay.io/keycloak/keycloak:latest"
dst="${REPO}/keycloak:latest"
echo "--- $src -> $dst"
docker pull "$src"
docker tag "$src" "$dst"
docker push "$dst"

echo "=== Done ==="
