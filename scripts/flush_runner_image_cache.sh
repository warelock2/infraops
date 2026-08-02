#!/usr/bin/env bash
# ===========================================================================
# Flush the forgejo-runner's dind image cache.
#
# Forgejo Actions runners build in a Docker-in-Docker daemon (container
# docker_dind). Cached images can go stale between runs, so this prunes them
# and lets the next job re-pull fresh ones. Run ON THE HOST that owns the
# docker_dind container (spacedock), not inside a workflow.
# ===========================================================================
set -euo pipefail

echo "Pruning unused images from docker_dind..."
docker exec docker_dind sh -c 'DOCKER_HOST=tcp://localhost:2375 docker system prune -af'

echo "Done. Runner will re-pull fresh images on next job."
