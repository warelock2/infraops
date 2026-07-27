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
: "${VAULT_ADDR:=https://docker.localdomain:8200}"
: "${VAULT_SKIP_VERIFY:=true}"
export VAULT_ADDR VAULT_SKIP_VERIFY

# Get vm_password from Vault
NATS_VM_PASSWORD=$(vault kv get -field=vm_password secret/infraops/nats)

# Fill template and deploy with sudo
sed "s|__NATS_VM_PASSWORD__|${NATS_VM_PASSWORD}|g" cloud-init-reboot.yaml.template \
  | sudo tee /var/lib/vz/snippets/cloud-init-reboot.yaml >/dev/null

echo "Deployed filled snippet to /var/lib/vz/snippets/cloud-init-reboot.yaml"