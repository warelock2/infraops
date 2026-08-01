#!/usr/bin/env bash
# Flush the forgejo-runner's dind image cache.
# Run on the host that runs the docker daemon (spacedock).
set -euo pipefail

echo "Pruning unused images from docker_dind..."
docker exec docker_dind sh -c 'DOCKER_HOST=tcp://localhost:2375 docker system prune -af'

echo "Done. Runner will re-pull fresh images on next job."
