# SECRETS

Audit of all secrets used by infraops. Last updated: <date>.

## Forgejo Secrets

| Secret Name | Purpose | Consumer | Regeneration |
|---|---|---|---|
| `ADMIN_SSH_PUBLIC_KEY` | Ansible uses this to enable passwordless admin login to IaC-managed VMs | Terraform `TF_VAR_admin_ssh_public_key` | `ssh-keygen` or copied from existing Ansible admin user account |
| `ANSIBLE_SSH_PRIVATE_KEY` | Forgejo Actions uses this to impersonate the Ansible admin for configuration management | Ansible `ansible_ssh_private_key_file` | `ssh-keygen` or copied from existing Ansible admin user account |
| `KEYCLOAK_ADMIN_PASSWORD` | Keycloak uses this to set the initial admin password on first boot | Keycloak container | User manually creates with password generator |
| `KEYCLOAK_DB_PASSWORD` | Keycloak uses this to initialize its database on first boot | Keycloak container | User manually creates with password generator |
| `MINIO_ACCESS_KEY` | Terraform stores state in MinIO, rather than the project repo | Terraform S3 backend | MinIO console → Access Keys → Create |
| `MINIO_SECRET_KEY` | Terraform stores state in MinIO, rather than the project repo | Terraform S3 backend | MinIO console → Access Keys → Create |
| `PROXMOX_API_ENDPOINT` | Terraform uses this to target which Proxmox host to manage | Terraform `TF_VAR_proxmox_endpoint` | User configures (not a secret) |
| `PROXMOX_API_TOKEN` | Terraform uses this to authenticate with Proxmox to create/destroy VMs | Terraform `TF_VAR_proxmox_api_token` | Proxmox UI → Datacenter → Permissions → API Tokens → Add |
| `VAULT_RO_TOKEN` | Terraform local-exec and Ansible use this to read pfSense API key for DNS management | Terraform `local-exec` provisioner, Ansible `vault_kv2_get` | `scripts/create_read_only_vault_token_for_check_ip.sh` |

## Vault Secrets

### `secret/infraops/pfsense` (KV v2)

| Key | Purpose | Consumer | Lifecycle |
|---|---|---|---|
| `api_key` | Terraform uses this to manage static IPs in pfSense unbound DNS resolver for IaC-managed VMs | `manage-iac-dns.yaml` via Vault lookup | Persistent |

### Other Vault paths (separate project)

| Path | Project | Notes |
|---|---|---|
| `secrets/k8s_cluster_provisioning` | `~/projects/k8s_cluster_provisioning` | Do not touch — separate project |

## Vault Architecture

- **Engine**: KV v2 mounted at `secret/`
- **Tokens**: Two tokens, both created manually. Never write tokens to disk.
  - **Read-only** (`infraops-check-ip-availability` policy): reads `secret/infraops/pfsense`. Passed as `VAULT_TOKEN` env var. Forgejo secret: `VAULT_RO_TOKEN`.
  - **Read-write** (`infraops-rw` policy): full CRUD on `secret/infraops/*`. Local use only. Not a Forgejo secret.
- **Unsealed manually** — no auto-unseal configured.

## Lifecycle

- **Forgejo secrets**: Managed via Forgejo UI. Rotate on compromise or personnel change.
- **Vault tokens**: Created manually via `vault token create`. Rotate periodically. Do not store on disk.
- **pfSense API key**: Regenerate in pfSense UI → System → KeyAuth, then update `secret/infraops/pfsense`.
- **Keycloak**: Bootstrap temporary — change in Keycloak on first admin login.
- **SSH key for snippet script**: Copy `ansible/ansible.pub` and `ansible/create-proxmox-snippet.sh` to the Proxmox server, then run the script as `sudo root` on the Proxmox server.
