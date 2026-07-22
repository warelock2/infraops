#!/usr/bin/env bash
set -euo pipefail

IMAGE="forgejo.afobl.com/warelock/ci-base:latest"
DOCKERFILE="docker/ci-base/Dockerfile"

cd "$(dirname "$0")/.."

docker login forgejo.afobl.com

echo "Building $IMAGE from $DOCKERFILE..."
docker build -t "$IMAGE" -f "$DOCKERFILE" docker/ci-base/

echo "Pushing $IMAGE..."
docker push "$IMAGE"

cp ~/.docker/config.json.empty ~/.docker/config.json

echo "Done: $IMAGE"
