#!/usr/bin/env bash
# ===========================================================================
# Build and push the ci-base Docker image to the Forgejo registry.
#
# ci-base (forgejo.afobl.com/warelock/ci-base:latest) is what every Forgejo
# Actions workflow step runs in. It bundles the toolchain CI needs: terraform
# (version pinned in conf/infrastructure.yaml), vault, nats CLI, kubectl, yq,
# ansible-core + collections, python libs. This script rebuilds it and pushes
# it, so CI stays in sync with the config.
#
# The Dockerfile is split into cached layers (base, pip, galaxy, binaries,
# provider mirror) so rebuilds reuse unchanged layers; versions are pinned via
# ARGs + the lock file, so caching does not hurt reproducibility.
#
# Docker credentials are handled via docker login; the config file is
# shredded afterwards so tokens never persist on the build host.
# ===========================================================================
set -euo pipefail

IMAGE="forgejo.afobl.com/warelock/ci-base:latest"
DOCKERFILE="docker/ci-base/Dockerfile"
FORGEJO_RAW_URL="https://forgejo.afobl.com/warelock/infraops/raw/branch/master/conf/infrastructure.yaml"

cd "$(dirname "$0")/.."

NATS_CLI_VERSION=$(curl -sf "$FORGEJO_RAW_URL" | yq -p yaml '.platform.nats.cli_version' -)
if [ -z "$NATS_CLI_VERSION" ]; then
  echo "ERROR: Could not fetch nats CLI version from infrastructure.yaml" >&2
  exit 1
fi
echo "NATS CLI version: $NATS_CLI_VERSION"

docker login forgejo.afobl.com

echo "Building $IMAGE from $DOCKERFILE..."
# Build context is the repo root so the Dockerfile can COPY terraform/ (the
# provider mirror is baked from terraform/.terraform.lock.hcl). .dockerignore
# keeps the context to docker/ci-base/ + terraform/ only. No --no-cache: the
# Dockerfile is split into cached layers so rebuilds reuse unchanged steps.
docker build --build-arg NATS_CLI_VERSION="$NATS_CLI_VERSION" -t "$IMAGE" -f "$DOCKERFILE" .

echo "Pushing $IMAGE..."
docker push "$IMAGE"

shred -u ~/.docker/config.json
cp ~/.docker/config.json.empty ~/.docker/config.json

echo "Done: $IMAGE"
