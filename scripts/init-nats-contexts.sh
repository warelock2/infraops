#!/bin/sh
# Configure NATS client contexts with passwords fetched from Vault.
#
# No secrets are stored in this file - they come from Vault at runtime.
# Safe to run via curl | bash (no relative path dependencies).
set -eu

SERVER="tls://midas.afobl.com:4222"
VAULT_PATH="secret/infraops/nats"
ALL_CONTEXTS="system production vm iac-orchestrator"

usage() {
  cat <<EOF
Usage: init-nats-contexts.sh [OPTIONS]

Configure NATS client contexts with passwords from Vault ($VAULT_PATH).

Options:
  --contexts=LIST    Comma-separated list of contexts to configure
                     (default: all)
                     Valid: $ALL_CONTEXTS
  --help             Show this help message

Examples:
  # Configure all contexts
  init-nats-contexts.sh

  # Configure specific contexts
  init-nats-contexts.sh --contexts=system,production

  # Configure a single context
  init-nats-contexts.sh --contexts=production

  # Remote execution (new machine, no repo clone)
  curl -sfL https://forgejo.afobl.com/warelock/infraops/raw/branch/master/scripts/init-nats-contexts.sh | bash

  # Remote with specific contexts
  curl -sfL ... | bash -s -- --contexts=system,production

  # Remote with a single context
  curl -sfL ... | bash -s -- --contexts=production

To delete a context in the future:
  nats context rm <context-name>

Prerequisites:
  - vault CLI with valid token (VAULT_TOKEN, pass tokens/vault-prod, or ~/.vault-token)
  - jq
  - nats CLI
  - Network access to Vault and NATS ($SERVER)

To rotate passwords, see docs/NATS.md (server-side: update_service_auth_creds.sh --rotate --restart).
EOF
}

# --- Dependency checks ---
for cmd in vault jq nats; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: $cmd is required but not installed." >&2
    exit 1
  fi
done

# --- Parse arguments ---
REQUESTED=""
for arg in "$@"; do
  case "$arg" in
    --contexts=*)
      REQUESTED="${arg#*=}"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ -z "$REQUESTED" ] || [ "$REQUESTED" = "all" ]; then
  REQUESTED="$ALL_CONTEXTS"
else
  REQUESTED=$(echo "$REQUESTED" | tr ',' ' ')
fi

for ctx in $REQUESTED; do
  case " $ALL_CONTEXTS " in
    *" $ctx "*)
      ;;
    *)
      echo "ERROR: Unknown context '$ctx'" >&2
      echo "Valid contexts: $ALL_CONTEXTS" >&2
      exit 4
      ;;
  esac
done

# --- Vault setup ---
export VAULT_ADDR="${VAULT_ADDR:-https://vault.afobl.com}"
export VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-true}"

if [ -z "${VAULT_TOKEN:-}" ]; then
  if command -v pass >/dev/null 2>&1 && pass tokens/vault-prod >/dev/null 2>&1; then
    VAULT_TOKEN=$(pass tokens/vault-prod)
    export GPG_TTY=$(tty)
    gpg-connect-agent updatestartuptty /bye >/dev/null 2>&1 || true
  elif [ -f "${HOME}/.vault-token" ]; then
    VAULT_TOKEN=$(cat "${HOME}/.vault-token")
  else
    echo "ERROR: No Vault token available (VAULT_TOKEN, pass tokens/vault-prod, or ~/.vault-token)" >&2
    exit 2
  fi
fi
export VAULT_TOKEN

# --- Fetch passwords from Vault ---
echo "=== Reading NATS passwords from Vault ==="
VAULT_SECRET=$(vault kv get -format=json "$VAULT_PATH")

nats_context_add() {
  context_name="$1"
  description="$2"
  nats_user="$3"
  vault_key="$4"
  password=$(echo "$VAULT_SECRET" | jq -er ".data.data.${vault_key}")
  nats context add "$context_name" --server "$SERVER" \
    --description "$description" --user "$nats_user" --password "$password"
}

# --- Configure requested contexts ---
echo "=== Configuring NATS contexts ==="
for ctx in $REQUESTED; do
  case "$ctx" in
    system)
      nats_context_add system "NATS System Admin" sys sys_password
      ;;
    production)
      nats_context_add production "NATS Production" app app_password
      ;;
    vm)
      nats_context_add vm "VM Bootstrap" vm vm_password
      ;;
    iac-orchestrator)
      nats_context_add iac-orchestrator "IaC Orchestrator" iac-orchestrator iac_orchestrator_password
      ;;
  esac
  echo "  ok: $ctx"
done

echo "=== Contexts configured ==="
nats context ls
