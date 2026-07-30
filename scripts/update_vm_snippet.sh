#!/bin/bash -e
# Deploys filled snippet to Proxmox snippets directory

# Get Vault token from pass
if [[ -z "${VAULT_TOKEN:-}" ]]; then
  if command -v pass >/dev/null 2>&1 && pass tokens/vault-prod >/dev/null 2>&1; then
    export VAULT_TOKEN=$(pass tokens/vault-prod)
    export GPG_TTY=$(tty)
    gpg-connect-agent updatestartuptty /bye >/dev/null 2>&1 || true
  else
    echo "ERROR: Cannot retrieve VAULT_TOKEN from pass" >&2
    exit 1
  fi
fi

# Vault config
: "${VAULT_ADDR:=https://vault.afobl.com}"
: "${VAULT_SKIP_VERIFY:=true}"
export VAULT_ADDR VAULT_SKIP_VERIFY

# Get vm_password from Vault
NATS_VM_PASSWORD=$(vault kv get -field=vm_password secret/infraops/nats)

# Fetch cloud-init template from git and deploy filled snippet
RAW_URL="https://forgejo.afobl.com/warelock/infraops/raw/branch/master/scripts/cloud-init-reboot.yaml.template"
curl -sfL "$RAW_URL" | sed "s|__NATS_VM_PASSWORD__|${NATS_VM_PASSWORD__}|g" | sudo tee /var/lib/vz/snippets/cloud-init-reboot.yaml >/dev/null

echo "Deployed filled snippet to /var/lib/vz/snippets/cloud-init-reboot.yaml"