#!/usr/bin/env bash
set -euo pipefail

# k8s-oidc-client-setup.sh
# Sets up kubectl OIDC authentication against a Keycloak-protected Kubernetes cluster.
# Installs kubectl, kubelogin, kubectx if missing. Configures kubeconfig with OIDC context.

# --- Defaults ---
OIDC_SERVER_NAME="keycloak.afobl.com"
OIDC_SERVER_PORT="443"
OIDC_REALM="infraops"
OIDC_CA_FILE=""
CLUSTER_SERVER=""
CLUSTER_CA_FILE=""
CLUSTER=""

# --- Color output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { error "$@"; exit 1; }

# --- Usage ---
usage() {
  cat <<EOF
Usage: $0 --cluster=<name> [options]

Required:
  --cluster=<name>              Kubernetes cluster name (e.g., mushroom, banana)

Optional:
  --oidc-server-name=<host>     Keycloak hostname          (default: keycloak.afobl.com)
  --oidc-server-port=<port>     Keycloak port              (default: 8443)
  --oidc-realm=<realm>          Keycloak realm             (default: infraops)
  --oidc-ca-file=<path>         OIDC CA cert path          (auto-detected if omitted)
  --server=<url>                K8s API server URL         (auto-resolved via DNS if omitted)
  --ca-file=<path>              Cluster CA cert path       (auto-detected from kubeconfig)
  -h, --help                    Show this help

Examples:
  $0 --cluster=mushroom
  $0 --cluster=banana --oidc-server-name=kc.prod --oidc-server-port=443
  $0 --cluster=banana --server=https://10.0.0.5:6443 --ca-file=./banana-ca.pem
EOF
  exit 0
}

# --- Parse arguments ---
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cluster=*)         CLUSTER="${1#*=}" ;;
      --oidc-server-name=*) OIDC_SERVER_NAME="${1#*=}" ;;
      --oidc-server-port=*) OIDC_SERVER_PORT="${1#*=}" ;;
      --oidc-realm=*)      OIDC_REALM="${1#*=}" ;;
      --oidc-ca-file=*)    OIDC_CA_FILE="${1#*=}" ;;
      --server=*)          CLUSTER_SERVER="${1#*=}" ;;
      --ca-file=*)         CLUSTER_CA_FILE="${1#*=}" ;;
      -h|--help)           usage ;;
      *)                   die "Unknown option: $1" ;;
    esac
    shift
  done

  [[ -z "$CLUSTER" ]] && die "Missing required flag: --cluster=<name>"
}

# --- Install kubectl ---
install_kubectl() {
  if command -v kubectl &>/dev/null; then
    local ver
    ver=$(kubectl version --client -o json 2>/dev/null | grep gitVersion | head -1 | tr -d '",' | awk '{print $2}')
    info "kubectl already installed (${ver:-unknown version})"
    return
  fi

  info "kubectl not found, installing..."
  local os arch
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m)
  [[ "$arch" == "x86_64" ]] && arch="amd64"
  [[ "$arch" == "aarch64" ]] && arch="arm64"

  local version
  version=$(curl -sL https://dl.k8s.io/release/stable.txt)
  curl -LO "https://dl.k8s.io/release/${version}/bin/${os}/${arch}/kubectl" || die "Failed to download kubectl"
  chmod +x kubectl
  sudo mv kubectl /usr/local/bin/ || die "Failed to install kubectl (sudo failed?)"
  info "kubectl installed: ${version}"
}

# --- Install kubelogin ---
install_kubelogin() {
  if command -v kubectl-oidc_login &>/dev/null || kubectl oidc-login --help &>/dev/null 2>&1; then
    info "kubelogin already installed"
    return
  fi

  info "kubelogin not found, installing..."
  local os arch
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m)
  [[ "$arch" == "x86_64" ]] && arch="amd64"
  [[ "$arch" == "aarch64" ]] && arch="arm64"

  curl -sL "https://github.com/int128/kubelogin/releases/latest/download/kubelogin_${os}_${arch}.zip" \
    -o /tmp/kubelogin.zip || die "Failed to download kubelogin"
  unzip -o /tmp/kubelogin.zip -d /tmp/kubelogin >/dev/null 2>&1 || die "Failed to unzip kubelogin"
  chmod +x /tmp/kubelogin/kubelogin
  sudo mv /tmp/kubelogin/kubelogin /usr/local/bin/kubectl-oidc_login || die "Failed to install kubelogin"
  rm -rf /tmp/kubelogin /tmp/kubelogin.zip
  info "kubelogin installed"
}

# --- Install kubectx ---
install_kubectx() {
  if command -v kubectx &>/dev/null; then
    info "kubectx already installed"
    return
  fi

  info "kubectx not found, installing..."
  local os arch
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m)
  [[ "$arch" == "x86_64" ]] && arch="x86_64"
  [[ "$arch" == "aarch64" ]] && arch="arm64"

  local url="https://github.com/ahmetb/kubectx/releases/latest/download/kubectx_${os}_${arch}.tar.gz"
  curl -sL "$url" | tar xz -C /tmp kubectx || die "Failed to download kubectx"
  chmod +x /tmp/kubectx
  sudo mv /tmp/kubectx /usr/local/bin/kubectx || die "Failed to install kubectx"
  info "kubectx installed"
}

# --- Resolve OIDC CA cert ---
resolve_oidc_ca() {
  local candidates=()

  [[ -n "$OIDC_CA_FILE" ]] && candidates+=("$OIDC_CA_FILE")
  candidates+=("./oidc-ca.pem")
  candidates+=("./ansible/files/oidc-ca.pem")
  candidates+=("${HOME}/.kube/oidc-ca.pem")

  for f in "${candidates[@]}"; do
    if [[ -f "$f" ]]; then
      info "OIDC CA cert found: ${f}"
      OIDC_CA_RESOLVED="$f"
      return
    fi
  done

  # Fetch from Keycloak server
  info "OIDC CA cert not found locally, fetching from Keycloak..."
  local issuer_url="https://${OIDC_SERVER_NAME}:${OIDC_SERVER_PORT}"
  OIDC_CA_RESOLVED=$(mktemp)
  openssl s_client -connect "${OIDC_SERVER_NAME}:${OIDC_SERVER_PORT}" -showcerts </dev/null 2>/dev/null \
    | openssl x509 -outform PEM > "$OIDC_CA_RESOLVED" 2>/dev/null

  if [[ ! -s "$OIDC_CA_RESOLVED" ]]; then
    rm -f "$OIDC_CA_RESOLVED"
    die "Could not fetch OIDC CA cert from ${issuer_url}. Provide --oidc-ca-file=<path>."
  fi

  info "OIDC CA cert fetched from ${issuer_url}"
}

# --- Resolve K8s API server ---
resolve_cluster_server() {
  if [[ -n "$CLUSTER_SERVER" ]]; then
    info "K8s API server: ${CLUSTER_SERVER} (from --server flag)"
    return
  fi

  local hostname="k8s-${CLUSTER}-control-01"
  local fqdn="${hostname}.localdomain"

  # Try FQDN first, then short name
  local ip
  for host in "$fqdn" "$hostname"; do
    if ip=$(getent hosts "$host" 2>/dev/null | awk '{print $1}' | head -1); then
      CLUSTER_SERVER="https://${ip}:6443"
      info "K8s API server resolved: ${CLUSTER_SERVER} (from ${host})"
      return
    fi
  done

  die "Could not resolve ${fqdn} or ${hostname}. Provide --server=<url>."
}

# --- Resolve cluster CA cert ---
resolve_cluster_ca() {
  if [[ -n "$CLUSTER_CA_FILE" ]]; then
    if [[ -f "$CLUSTER_CA_FILE" ]]; then
      info "Cluster CA cert: ${CLUSTER_CA_FILE} (from --ca-file flag)"
      return
    fi
    die "Cluster CA file not found: ${CLUSTER_CA_FILE}"
  fi

  # Try to extract from existing kubeconfig
  local kubeconfig="${HOME}/.kube/config"
  if [[ -f "$kubeconfig" ]]; then
    local ca_data
    ca_data=$(kubectl config view --minify -o jsonpath='{.clusters[?(@.cluster.server=="'"${CLUSTER_SERVER}"'")].cluster.certificate-authority-data}' 2>/dev/null || true)

    if [[ -n "$ca_data" ]]; then
      CLUSTER_CA_FILE=$(mktemp)
      echo "$ca_data" | base64 -d > "$CLUSTER_CA_FILE" 2>/dev/null || {
        # base64 might need different flag on some systems
        echo "$ca_data" | base64 --decode > "$CLUSTER_CA_FILE" 2>/dev/null || true
      }
      if [[ -s "$CLUSTER_CA_FILE" ]]; then
        info "Cluster CA cert extracted from kubeconfig"
        return
      fi
      rm -f "$CLUSTER_CA_FILE"
    fi
  fi

  die "Cluster CA cert not found. Provide --ca-file=<path>."
}

# --- Copy OIDC CA cert ---
install_oidc_ca() {
  local target="${HOME}/.kube/oidc-ca.pem"
  mkdir -p "${HOME}/.kube"

  if [[ "$OIDC_CA_RESOLVED" == "$target" ]]; then
    info "OIDC CA cert already at ${target}"
    return
  fi

  cp "$OIDC_CA_RESOLVED" "$target"
  chmod 600 "$target"
  info "OIDC CA cert installed to ${target}"
}

# --- Configure kubeconfig ---
configure_kubeconfig() {
  local ctx_oidc="${CLUSTER}"
  local ctx_cert="${CLUSTER}-admin-cert"
  local user_oidc="warelock@keycloak"

  # Add cluster entry if it doesn't exist
  if ! kubectl config get-clusters 2>/dev/null | grep -q "^${CLUSTER}$"; then
    kubectl config set-cluster "$CLUSTER" \
      --server="$CLUSTER_SERVER" \
      --certificate-authority="${CLUSTER_CA_FILE}" \
      --embed-certs=false
    info "Cluster '${CLUSTER}' added to kubeconfig"
  else
    # Update server/CA if cluster already exists
    kubectl config set-cluster "$CLUSTER" \
      --server="$CLUSTER_SERVER" \
      --certificate-authority="${CLUSTER_CA_FILE}" \
      --embed-certs=false 2>/dev/null
    info "Cluster '${CLUSTER}' already in kubeconfig, updated"
  fi

  # Rename existing OIDC context to cert-based fallback if needed
  if kubectl config get-contexts "$ctx_oidc" -o name 2>/dev/null | grep -q "^${ctx_oidc}$"; then
    local current_user
    current_user=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"${ctx_oidc}\")].context.user}" 2>/dev/null || true)
    # Only rename if the existing context is NOT the OIDC user we're about to set
    if [[ "$current_user" != "$user_oidc" ]]; then
      kubectl config rename-context "$ctx_oidc" "$ctx_cert" 2>/dev/null || true
      info "Existing context '${ctx_oidc}' renamed to '${ctx_cert}' (cert-based fallback)"
    else
      # Remove the old OIDC context so we can recreate it cleanly
      kubectl config delete-context "$ctx_oidc" 2>/dev/null || true
    fi
  fi

  # Add OIDC user
  kubectl config set-credentials "$user_oidc" \
    --exec-api-version=client.authentication.k8s.io/v1beta1 \
    --exec-command=kubectl \
    --exec-arg=oidc-login \
    --exec-arg=get-token \
    --exec-arg=--oidc-issuer-url="https://${OIDC_SERVER_NAME}:${OIDC_SERVER_PORT}/realms/${OIDC_REALM}" \
    --exec-arg=--oidc-client-id="kubernetes-${CLUSTER}" \
    --exec-arg=--oidc-client-secret="" \
    --exec-arg=--certificate-authority="${HOME}/.kube/oidc-ca.pem" \
    --exec-arg=--oidc-extra-scope=groups
  info "OIDC user '${user_oidc}' configured"

  # Add OIDC context
  kubectl config set-context "$ctx_oidc" \
    --cluster="$CLUSTER" \
    --user="$user_oidc"
  info "OIDC context '${ctx_oidc}' created"

  # Add cert-based fallback context if it doesn't exist yet
  if ! kubectl config get-contexts "$ctx_cert" -o name 2>/dev/null | grep -q "^${ctx_cert}$"; then
    kubectl config set-context "$ctx_cert" \
      --cluster="$CLUSTER" \
      --user="kubernetes-admin" 2>/dev/null || true
    info "Cert-based fallback context '${ctx_cert}' created"
  fi
}

# --- Switch context ---
switch_context() {
  kubectx "${CLUSTER}" 2>/dev/null || kubectl config use-context "${CLUSTER}"
  info "Switched to context '${CLUSTER}'"
}

# --- Cleanup temp files ---
cleanup() {
  [[ -f "${OIDC_CA_RESOLVED:-}" && "${OIDC_CA_RESOLVED}" != "${HOME}/.kube/oidc-ca.pem" ]] && rm -f "$OIDC_CA_RESOLVED"
  [[ -f "${CLUSTER_CA_FILE:-}" && ! -f "${CLUSTER_CA_FILE}" ]] && rm -f "$CLUSTER_CA_FILE" 2>/dev/null
  # Don't clean up CLUSTER_CA_FILE if it was a temp file we created from kubeconfig
}
trap cleanup EXIT

# --- Main ---
main() {
  parse_args "$@"

  echo ""
  info "=== K8s OIDC Client Setup ==="
  info "Cluster:       ${CLUSTER}"
  info "Keycloak:      ${OIDC_SERVER_NAME}:${OIDC_SERVER_PORT}"
  info "Realm:         ${OIDC_REALM}"
  echo ""

  # Install prerequisites
  install_kubectl
  install_kubelogin
  install_kubectx
  echo ""

  # Resolve endpoints
  resolve_cluster_server
  resolve_cluster_ca
  resolve_oidc_ca
  echo ""

  # Configure
  install_oidc_ca
  configure_kubeconfig
  echo ""

  # Switch
  switch_context

  echo ""
  info "=== Setup Complete ==="
  info "OIDC context:  ${CLUSTER}"
  info "Cert context:  ${CLUSTER}-admin-cert"
  info "Run 'kubectx ${CLUSTER}' to switch to OIDC"
  info "Run 'kubectx ${CLUSTER}-admin-cert' for cert-based access"
  echo ""
  info "First kubectl command will open browser for Keycloak login."
  info "After that, tokens are cached for ~24 hours."
  echo ""
}

main "$@"
