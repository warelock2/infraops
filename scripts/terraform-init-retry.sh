#!/bin/sh
# ===========================================================================
# Retry wrapper around `terraform init`.
#
# WHY THIS EXISTS
#   terraform init downloads providers from the public registry
#   (registry.terraform.io via CloudFront). From the CI runner that path is
#   flaky — the connection gets reset mid-download, which fails the whole
#   init and thus the pipeline. init is idempotent and re-runs safely, so
#   we simply retry with a backoff until providers are cached locally.
#
# USAGE
#   terraform-init-retry.sh <full terraform command...>
#   # -chdir must come FIRST (global flag), e.g.:
#   #   terraform-init-retry.sh -chdir=terraform init -reconfigure
#   #   terraform-init-retry.sh init -reconfigure
#
# Tuning: TF_INIT_RETRIES (default 5) attempts, TF_INIT_BACKOFF (default 10s).
# ===========================================================================
set -e

MAX_ATTEMPTS="${TF_INIT_RETRIES:-5}"
BACKOFF="${TF_INIT_BACKOFF:-10}"

attempt=0
while true; do
  attempt=$((attempt + 1))
  if terraform "$@"; then
    exit 0
  fi
  if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    echo "ERROR: terraform failed after $MAX_ATTEMPTS attempts" >&2
    exit 1
  fi
  echo "WARN: terraform failed (attempt $attempt/$MAX_ATTEMPTS); retrying in ${BACKOFF}s..." >&2
  sleep "$BACKOFF"
done
