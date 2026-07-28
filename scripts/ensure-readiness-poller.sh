#!/bin/sh
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
