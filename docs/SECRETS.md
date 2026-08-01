# SECRETS

Audit of all secrets used by infraops. Last updated: 2026-08-01.

## Forgejo Secrets

| Secret Name | Purpose | Consumer | Regeneration |
|---|---|---|---|
| `ADMIN_SSH_PUBLIC_KEY` | Ansible uses this to enable passwordless admin login to IaC-managed VMs | Terraform `TF_VAR_admin_ssh_public_key` | `ssh-keygen` or copied from existing Ansible admin user account |
| `ANSIBLE_SSH_PRIVATE_KEY` | Forgejo Actions uses this to impersonate the Ansible admin for configuration management | Ansible `ansible_ssh_private_key_file` | `ssh-keygen` or copied from existing Ansible admin user account |
| `ANSIBLE_SSH_PUBLIC_KEY` | Used by `create-proxmox-snippet.sh` to inject the Ansible user's public key into Proxmox cloud-init snippets | Proxmox snippet script | `ssh-keygen` or copied from existing Ansible admin user account |
| `KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD` | Keycloak uses this to set the initial admin password on first boot | Keycloak container | User manually creates with password generator |
| `K8S_ADMIN_KUBECONFIG` | Terraform enforce-iac workflow uses this to drain removed nodes from the k8s cluster | `k8s-drain-removed-nodes.yaml` | Copy kubeconfig from control plane: `scp ansible@k8s-mushroom-control-01:/etc/kubernetes/admin.conf ~/.kube/config` |
| `MINIO_ACCESS_KEY` | Terraform stores state in MinIO, rather than the project repo | Terraform S3 backend | MinIO console → Access Keys → Create |
| `MINIO_SECRET_KEY` | Terraform stores state in MinIO, rather than the project repo | Terraform S3 backend | MinIO console → Access Keys → Create |
| `VAULT_RO_TOKEN` | Terraform and Ansible use this to authenticate to Vault and read secrets (pfSense API key, Proxmox credentials, NATS passwords) | Terraform Vault provider, `local-exec` provisioner, Ansible `vault_kv2_get` | `scripts/create_read_only_vault_token_for_check_ip.sh` |

## Vault Secrets

### `secret/infraops/pfsense` (KV v2)

| Key | Purpose | Consumer | Lifecycle |
|---|---|---|---|
| `api_key` | Terraform uses this to manage static IPs in pfSense unbound DNS resolver for IaC-managed VMs | `manage-iac-dns.yaml` via Vault lookup | Persistent |

### `secret/infraops/proxmox` (KV v2)

| Key | Purpose | Consumer | Lifecycle |
|---|---|---|---|
| `endpoint` | Proxmox VE API URL | Terraform Vault provider → `proxmox` provider | Persistent |
| `api_token` | Proxmox VE API authentication token | Terraform Vault provider → `proxmox` provider | Rotate in Proxmox UI → Datacenter → Permissions → API Tokens |

### `secret/infraops/nats` (KV v2)

| Key | Purpose | Consumer | Lifecycle |
|---|---|---|---|
| `sys_password` | NATS System Admin user (`sys`) | `init-nats-contexts.sh` (system context), `update_service_auth_creds.sh` | Rotate via `update_service_auth_creds.sh --rotate --restart` (midas) |
| `app_password` | NATS Production user (`app`) | `init-nats-contexts.sh` (production context), `update_service_auth_creds.sh` | Rotate via `update_service_auth_creds.sh --rotate --restart` (midas) |
| `vm_password` | NATS VM Bootstrap user (`vm`) | `init-nats-contexts.sh` (vm context), `update_vm_snippet.sh`, `update_service_auth_creds.sh` | Rotate via `update_service_auth_creds.sh --rotate --restart` (midas), then run `update_vm_snippet.sh` |
| `iac_orchestrator_password` | NATS IaC Orchestrator user (`iac-orchestrator`) | `init-nats-contexts.sh` (iac-orchestrator context), `update_service_auth_creds.sh` | Rotate via `update_service_auth_creds.sh --rotate --restart` (midas) |

### Other Vault paths (separate project)

| Path | Project | Notes |
|---|---|---|
| `secrets/k8s_cluster_provisioning` | `~/projects/k8s_cluster_provisioning` | Do not touch — separate project |

## Vault Architecture

- **Engine**: KV v2 mounted at `secret/`
- **Tokens**: Two tokens, both created manually. Never write tokens to disk.
  - **Read-only** (`infraops-check-ip-availability` policy): reads `secret/infraops/pfsense`, `secret/infraops/proxmox`, and `secret/infraops/nats`. Passed as `VAULT_TOKEN` env var. Forgejo secret: `VAULT_RO_TOKEN`.
  - **Read-write** (`infraops-rw` policy): full CRUD on `secret/infraops/*`. Local use only. Not a Forgejo secret.
- **Unsealed manually** — no auto-unseal configured.

## Lifecycle

- **Forgejo secrets**: Managed via Forgejo UI. Rotate on compromise or personnel change.
- **Vault tokens**: Created manually via `vault token create`. Rotate periodically. Do not store on disk.
- **pfSense API key**: Regenerate in pfSense UI → System → KeyAuth, then update `secret/infraops/pfsense`.
- **Proxmox API token**: Stored in Vault at `secret/infraops/proxmox`. Regenerate in Proxmox UI → Datacenter → Permissions → API Tokens, then update Vault.
- **Keycloak**: Bootstrap temporary — change in Keycloak on first admin login.
- **SSH key for snippet script**: Copy `ansible/ansible.pub` and `ansible/create-proxmox-snippet.sh` to the Proxmox server, then run the script as `sudo root` on the Proxmox server.
