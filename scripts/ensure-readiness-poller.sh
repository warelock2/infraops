#!/bin/sh
# ===========================================================================
# Ensure the NATS readiness consumer exists and is wired up.
#
# The readiness handshake works like this: a freshly cloned VM runs
# helloworld.sh, which validates its own boot and publishes a message to the
# infraops.helloworld stream. The CI orchestrator must be able to consume
# that stream, so this script creates an iac-orchestrator NATS context (the
# CI identity, password from Vault) and a durable pull consumer named
# readiness-poller that filters on infraops.helloworld. wait-for-readiness.sh
# then does `nats consumer next infraops readiness-poller` to block until a
# signal arrives (or times out).
#
# Idempotent: consumer add and the info calls use || true so a missing or
# already-existing consumer doesn't fail the run.
# ===========================================================================
set -ex

export VAULT_ADDR="${VAULT_ADDR:-https://vault.afobl.com}"
export VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-true}"

echo "=== Reading NATS password from Vault ==="
NATS_IAC_PASSWORD=$(vault kv get -format=json secret/infraops/nats | jq -r '.data.data.iac_orchestrator_password')
echo "NATS_IAC_PASSWORD length: ${#NATS_IAC_PASSWORD}"

echo "=== Setting up nats context ==="
nats context add iac-orchestrator \
  --server tls://midas.afobl.com:4222 \
  --user iac-orchestrator --password "$NATS_IAC_PASSWORD"

echo "=== Ensuring readiness-poller consumer exists ==="
nats consumer add infraops readiness-poller \
  --pull --ack=explicit --deliver=all \
  --filter="infraops.helloworld" \
  --replay=instant --max-deliver=-1 --max-pending=-1 \
  --defaults --context=iac-orchestrator || true

echo "=== Consumer info ==="
nats consumer info infraops readiness-poller --context=iac-orchestrator || true
echo "=== Stream info ==="
nats stream info infraops --context=iac-orchestrator || true
