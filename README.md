# InfraOps

Infrastructure as Code, flowing from a single, multi-tool source of truth.

**License:** GPLv3 — see [LICENSE.md](LICENSE.md) for full terms.

## Quick Start

### Pull Credentials from an IaC-Managed Cluster

```bash
curl -skSL https://YOUR_FORGEJO_URL/warelock/infraops/raw/branch/master/scripts/k8s_import_context.sh | bash -s -- <cluster_name>
```

Example for the "mushroom" cluster:

```bash
curl -skSL https://YOUR_FORGEJO_URL/warelock/infraops/raw/branch/master/scripts/k8s_import_context.sh | bash -s -- mushroom
```

This merges the cluster's admin kubeconfig into your local `~/.kube/config` as a new context. Requirements:

- SSH access to the control plane node (key-based auth)
- `kubectl`, `ssh`, and `sed` (kubectl is auto-installed if missing)

Then switch to the context:

```bash
kubectl config use-context kubernetes-admin@kubernetes
```

### Configure a NATS Client

Configure NATS client contexts (passwords fetched from Vault, no secrets in this repo):

```bash
curl -sfL https://YOUR_FORGEJO_URL/warelock/infraops/raw/branch/master/scripts/init-nats-contexts.sh | bash
```

Select a subset:

```bash
curl -sfL https://YOUR_FORGEJO_URL/warelock/infraops/raw/branch/master/scripts/init-nats-contexts.sh | bash -s -- --contexts=system,production
```

Requirements: `vault` (with token), `jq`, `nats`. See [docs/NATS.md](docs/NATS.md) for full setup, rotation, and troubleshooting.

### Configure kubectl with OIDC (Keycloak)

For SSO access to a cluster instead of admin certs, run the Keycloak client setup (installs `kubelogin` if missing and wires the OIDC device-flow exec plugin into your kubeconfig):

```bash
./scripts/k8s-oidc-client-setup.sh --cluster=mushroom
```

Requires a Keycloak account in the `infraops` realm with membership in the cluster's `<cluster>-admins` or `<cluster>-viewers` group. Full workflow — user onboarding, first login, revoking access — is in [docs/k8s-keycloak-user-management-guide.md](docs/k8s-keycloak-user-management-guide.md).

### Deploy a Cluster

Trigger the `enforce-iac` workflow via Forgejo or:

```bash
~/bin/trigger_workflow infraops enforce-iac.yaml
```

## What you can do with this

By editing the `conf/infrastructure.yaml` file, then committing and doing a git push, you can:

- Create a new Kubernetes cluster (e.g., add a `banana` cluster with 1 control plane + 2 workers)
- Scale an existing cluster's worker nodes (e.g., from 2 to 3)
- Add a new VM host to the infrastructure
- Change the VIP endpoint for a cluster's API server
- Update the Kubernetes version (e.g., from `1.33.0` to `1.33.1`)
- Resize VM resources (CPU, RAM, disk)
- Import a cluster's kubeconfig into your local `~/.kube/config` (one-liner)

## Prerequisites

This infrastructure requires the following components in your environment:

- **Proxmox VE** — hypervisor for VM provisioning
- **pfSense** — firewall/router with REST API and Unbound DNS
- **HashiCorp Vault** — secrets management (running on Docker host)
- **Terraform** (~1.7) — infrastructure provisioning
- **Ansible** (~10.x) — configuration management
- **Docker / Docker Compose** — containerized services (Keycloak, MinIO, etc.)
- **Keycloak** — identity provider with OIDC
- **MinIO** — S3-compatible object storage (Terraform state backend)
- **Forgejo** or GitHub — Git hosting with CI/CD runners
- **pfSense REST API package** (`pfSense-pkg-RESTAPI`) — required for DNS automation via Ansible

## Architecture Highlights

| Feature | Description |
|---------|-------------|
| **Single Source of Truth** | `conf/infrastructure.yaml` drives Terraform, Ansible, inventory generation, and CI validation |
| **Schema-Validated Config** | JSON Schema (`infrastructure.schema.yaml`) enforced in CI — typos fail fast |
| **Multi-Tool Orchestration** | Clean handoff: Terraform (provision) → NATS stream (readiness) → Ansible (configure) |
| **Message Queue Readiness Handshake** | VMs boot → cloud-init publishes to NATS → ack → self-destructs → Ansible gate passes |
| **Self-Correcting VMs** | Hellworld/ack/self-destruct pattern guarantees every created VM signals readiness |
| **Hard Readiness Gate** | Ansible never runs until every expected VM acknowledges |
| **Drift Detection** | k8s drain playbook compares actual nodes to desired config; removes orphans automatically |
| **Immutable-by-Default** | Config changes → Terraform recreates VMs (fresh cloud-init → new handshake) |
| **Fully Offline CI Runtime** | Provider mirror baked into `ci-base` image; `terraform init` never hits registry during runs |
| **Layered Docker Caching** | Split Dockerfile layers → 40min cold build, 10s warm rebuild; 11min → 2min pipeline |
| **Flaky-Network Resilience** | Retry wrappers on all external downloads (build-time + CI init) |
| **Multi-Stage Gate Pipeline** | Validate → Plan (exit code gates) → Apply+Wait → Inventory → Config Mgmt |
| **Educational Inline Comments** | 6-tier comment system explaining *why* not just *what* across Terraform, Ansible, Config, Bash, Python, CI |

## Currently supported infrastructure components

- **Ubuntu 26.04 LTS VMs** via Proxmox VE with cloud-init
- **Kubernetes clusters** (kubeadm, keepalived VIP, haproxy load balancing)
- **Docker Compose services**
- **Keycloak** identity provider
- **MinIO** object storage (S3-compatible)
- **HashiCorp Vault** secrets management
- **pfSense Unbound DNS** service static IP management
- **Locally cached Docker images** — CI base image bakes all Terraform providers, binaries, and collections; `terraform init` runs fully offline in CI
