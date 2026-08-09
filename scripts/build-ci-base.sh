#!/usr/bin/env bash
# ===========================================================================
# Build and push the ci-base Docker image to the Forgejo registry.
#
# ci-base (forgejo.afobl.com/warelock/ci-base) is what every Forgejo Actions
# workflow step runs in. It bundles the toolchain CI needs: terraform (version
# pinned in conf/infrastructure.yaml), vault, nats CLI, kubectl, yq, ansible-core
# + collections, python libs. This script rebuilds it and pushes it, so CI stays
# in sync with the config.
#
# Tags pushed:
#   :latest          — rolling tag used by the workflows
#   :<git-describe>  — e.g. v0.3.0-7-g9c3aee6 (version tag + commit distance +
#                      short SHA) = the last commit before this rebuild
#   :<short-sha>     — bare commit SHA for exact immutability
#
# The Dockerfile is split into cached layers (base, pip, galaxy, binaries,
# provider mirror) so rebuilds reuse unchanged layers; versions are pinned via
# ARGs + the lock file, so caching does not hurt reproducibility.
#
# Docker credentials are handled via docker login; the config file is
# shredded afterwards so tokens never persist on the build host.
# ===========================================================================
set -euo pipefail

IMAGE_BASE="forgejo.afobl.com/warelock/ci-base"
DOCKERFILE="docker/ci-base/Dockerfile"
FORGEJO_RAW_URL="https://forgejo.afobl.com/warelock/infraops/raw/branch/master/conf/infrastructure.yaml"

cd "$(dirname "$0")/.."

# Versioned tags: stamp the image with the repo state it was built from. The
# build-time HEAD is the last commit before the rebuild, so GIT_DESCRIBE and
# GIT_SHA are exact references to what produced this image.
GIT_DESCRIBE=$(git describe --tags --always)
GIT_SHA=$(git rev-parse --short HEAD)

# Fetch the SSOT once and source every binary version from it, so a controlled
# version upgrade is a single edit in conf/infrastructure.yaml.
INFRA_YAML=$(curl -sf "$FORGEJO_RAW_URL")
if [ -z "$INFRA_YAML" ]; then
  echo "ERROR: Could not fetch conf/infrastructure.yaml from $FORGEJO_RAW_URL" >&2
  exit 1
fi

NATS_CLI_VERSION=$(printf '%s' "$INFRA_YAML" | yq -p yaml '.platform.nats.cli_version' -)
TF_VERSION=$(printf '%s' "$INFRA_YAML" | yq -p yaml '.platform.terraform.version' -)
VAULT_VERSION=$(printf '%s' "$INFRA_YAML" | yq -p yaml '.platform.vault.cli_version' -)
KUBECTL_VERSION=$(printf '%s' "$INFRA_YAML" | yq -p yaml '.platform.kubernetes.kubectl_version' -)

for V in NATS_CLI_VERSION TF_VERSION VAULT_VERSION KUBECTL_VERSION; do
  if [ -z "${!V}" ]; then
    echo "ERROR: Could not read $V from conf/infrastructure.yaml" >&2
    exit 1
  fi
done
echo "NATS CLI version: $NATS_CLI_VERSION"
echo "Terraform version: $TF_VERSION"
echo "Vault CLI version: $VAULT_VERSION"
echo "kubectl version: $KUBECTL_VERSION"

docker login forgejo.afobl.com

echo "Building $IMAGE_BASE:latest from $DOCKERFILE..."
# Build context is the repo root so the Dockerfile can COPY terraform/ (the
# provider mirror is baked from terraform/.terraform.lock.hcl). .dockerignore
# keeps the context to docker/ci-base/ + terraform/ only. No --no-cache: the
# Dockerfile is split into cached layers so rebuilds reuse unchanged steps.
docker build \
  --build-arg NATS_CLI_VERSION="$NATS_CLI_VERSION" \
  --build-arg TF_VERSION="$TF_VERSION" \
  --build-arg VAULT_VERSION="$VAULT_VERSION" \
  --build-arg KUBECTL_VERSION="$KUBECTL_VERSION" \
  -t "$IMAGE_BASE:latest" -f "$DOCKERFILE" .

echo "Tagging $IMAGE_BASE:$GIT_DESCRIBE and $IMAGE_BASE:$GIT_SHA..."
docker tag "$IMAGE_BASE:latest" "$IMAGE_BASE:$GIT_DESCRIBE"
docker tag "$IMAGE_BASE:latest" "$IMAGE_BASE:$GIT_SHA"

echo "Pushing tags..."
docker push "$IMAGE_BASE:latest"
docker push "$IMAGE_BASE:$GIT_DESCRIBE"
docker push "$IMAGE_BASE:$GIT_SHA"

shred -u ~/.docker/config.json
cp ~/.docker/config.json.empty ~/.docker/config.json

echo "Done: $IMAGE_BASE:latest / :$GIT_DESCRIBE / :$GIT_SHA"
