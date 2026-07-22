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

### Deploy a Cluster

Trigger the `enforce-iac` workflow via Forgejo or:

```bash
~/bin/trigger_workflow infraops enforce-iac.yaml
```

## What you can do with this

By editing the `config/infrastructure.yaml` file, then committing and doing a git push, you can:

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

## Currently supported infrastructure components

- **Ubuntu 26.04 LTS VMs** via Proxmox VE with cloud-init
- **Kubernetes clusters** (kubeadm, keepalived VIP, haproxy load balancing)
- **Docker Compose services**
- **Keycloak** identity provider
- **MinIO** object storage (S3-compatible)
- **HashiCorp Vault** secrets management
- **pfSense Unbound DNS** service static IP management
