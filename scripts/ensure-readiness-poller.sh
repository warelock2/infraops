#!/bin/sh
# ===========================================================================
# Ensure the NATS readiness and failure consumers exist and are wired up.
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
# A VM that cannot be made healthy publishes a failure message to
# infraops.helloworld.fail.<host>; a second durable consumer, failure-poller,
# filters on that subject so wait-for-readiness.sh can detect a declared
# failure and halt the production line for forensics.
#
# Idempotent: the consumer is deleted (if present) and recreated fresh with
# --deliver=new so it only sees readiness signals published AFTER this run
# started. A stale position inherited from a prior/cancelled run would make
# wait-for-readiness.sh miss a freshly-created VM's signal and falsely reject
# it, causing the apply/gate loop to cycle. The || true keeps missing or
# already-existing consumers from failing the run.
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

echo "=== Resetting readiness-poller consumer (delete + recreate fresh) ==="
nats consumer rm infraops readiness-poller --context=iac-orchestrator 2>/dev/null || true
nats consumer add infraops readiness-poller \
  --pull --ack=explicit --deliver=new \
  --filter="infraops.helloworld" \
  --replay=instant --max-deliver=-1 --max-pending=-1 \
  --context=iac-orchestrator || true

echo "=== Resetting failure-poller consumer (delete + recreate fresh) ==="
nats consumer rm infraops failure-poller --context=iac-orchestrator 2>/dev/null || true
nats consumer add infraops failure-poller \
  --pull --ack=explicit --deliver=new \
  --filter="infraops.helloworld.fail.>" \
  --replay=instant --max-deliver=-1 --max-pending=-1 \
  --context=iac-orchestrator || true

echo "=== Consumer info ==="
nats consumer info infraops readiness-poller --context=iac-orchestrator || true
echo "=== Stream info ==="
nats stream info infraops --context=iac-orchestrator || true
