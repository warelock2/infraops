#!/usr/bin/env bash
# ===========================================================================
# Build and push the ci-base Docker image to the Forgejo registry.
#
# ci-base (forgejo.afobl.com/warelock/ci-base:latest) is what every Forgejo
# Actions workflow step runs in. It bundles the toolchain CI needs: terraform
# (version pinned in conf/infrastructure.yaml), vault, nats CLI, kubectl, yq,
# ansible-core + collections, python libs. This script rebuilds it (--no-cache
# for reproducibility) and pushes it, so CI stays in sync with the config.
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
docker build --no-cache --build-arg NATS_CLI_VERSION="$NATS_CLI_VERSION" -t "$IMAGE" -f "$DOCKERFILE" docker/ci-base/

echo "Pushing $IMAGE..."
docker push "$IMAGE"

shred -u ~/.docker/config.json
cp ~/.docker/config.json.empty ~/.docker/config.json

echo "Done: $IMAGE"
