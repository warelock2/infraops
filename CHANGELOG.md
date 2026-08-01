# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2025-08-02

### Added
- **NATS client context initialization tool** (`scripts/init-nats-contexts.sh`)
  - Interactive/non-interactive context configuration from Vault
  - Supports `--contexts=<list>` (default: all 4 contexts)
  - `--help` with usage examples and `nats context rm` reference
  - Safe for `curl | bash` remote execution (no relative paths)
  - Validates context names, exits with descriptive codes

- **Server-side NATS password rotation** (`scripts/update_service_auth_creds.sh` in midas project)
  - `--rotate`: Generates 4×24-char base62 passwords → writes to `secret/infraops/nats` (Vault)
  - `--restart`: Renders `conf/nats-server.conf` from template → `docker compose restart nats`
  - Single Vault fetch, guards against empty passwords, chmod 600 output

- **Comprehensive NATS documentation** (`docs/NATS.md`)
  - Client setup with copy-paste one-liners (local + `curl | bash`)
  - Rotating passwords: server-side rotation + client refresh + Proxmox snippet update
  - Server admin commands (health checks, stream management)
  - Vault path/keys reference
  - Troubleshooting guide (common errors + resolutions)

- **NATS secrets documentation** (`docs/SECRETS.md`)
  - Added `secret/infraops/nats` entry with all 4 keys (`sys`, `app`, `vm`, `iac_orchestrator`)
  - Updated Vault architecture section (RO token now includes nats read)
  - Documented rotation lifecycle

- **README quick-start** for NATS client configuration

### Changed
- **Config directory renamed**: `config/` → `conf/` (all 22+ references updated)
- **ci-base image**: Added `openssh-client` for Ansible SSH connections
- **check-jsonschema**: Installed with dependencies (fixed missing `click` in slim image)
- **Build script**: `scripts/build-ci-base.sh` now uses `--no-cache` flag

### Fixed
- **NATS password rotation workflow** — moved rotation to server-side script (`update_service_auth_creds.sh --rotate --restart`), client tool is read-only
- **NATS context command** — corrected `nats context delete` → `nats context rm` in docs and scripts
- **Stale `--rotate` references** removed from client tool docs
- **Orphaned `scripts/setup-nats-contexts.sh`** removed (superseded by `init-nats-contexts.sh`)
- **Stale redirect artifact** `{changed:` removed + added to `.gitignore`
- **ci-base build** now uses `--no-cache` to prevent stale layers
- **check-jsonschema** installed with dependencies (previously missing `click`)

### Security
- **Scrubbed 4 leaked NATS passwords** from git history via `git-filter-repo` (92 commits parsed, 0 matches remaining)
- **Pre-push hooks** (`githooks/pre-push`) block direct pushes to `github`/`dmz` mirrors
- **Mirror sanitization** via `~/bin/push_public` strips `conf/infrastructure.yaml` from history
- **NAT rotation completed**: Vault v6 with new passwords, NATS server restarted, all 4 client contexts refreshed

### Removed
- `scripts/setup-nats-contexts.sh` (orphaned, superseded by `init-nats-contexts.sh`)
- Stale redirect artifact `{changed:` (empty file from botched redirect)

---

## [0.1.0] - 2025-07-21

### Added
- Initial infrastructure-as-code setup
- Terraform configuration for Proxmox VM provisioning
- Ansible playbooks for Kubernetes cluster deployment (kubeadm, Calico, kube-vip)
- HashiCorp Vault integration for secrets management
- pfSense DNS management via REST API
- Keycloak identity provider with OIDC integration
- MinIO S3 backend for Terraform state
- Forgejo CI/CD workflows (`enforce-iac.yaml`, `deploy-k8s.yaml`)
- ci-base Docker image with Terraform, Ansible, kubectl, vault CLI
- Golden image creation script (`scripts/create_golden_image_vm.sh`)
- Cloud-init snippets for VM bootstrap (NAT, reboot coordination)
- pfSense DNS automation via Ansible
- k8s cluster bootstrap with readiness polling via NATS

### Changed
- Migrated from manual SSH to Ansible for configuration management
- Migrated Terraform state to MinIO S3 backend
- Standardized on `forgejo.afobl.com/warelock/*` Docker images

### Fixed
- Cloud-init netplan race condition (interface rename `ens18` → `eth0`)
- Terraform plan exit code handling in CI
- Vault read-only token policy for CI/CD
- pfSense REST API collection bugs (lookup/delete object)
- k8s VIP/HAProxy configuration for control plane HA

### Security
- Vault unsealed manually (no auto-unseal)
- Read-only Vault token for CI (`infraops-check-ip-availability` policy)
- Read-write Vault token for local use only (`infraops-rw` policy)
- SSH keys injected via cloud-init (no secrets in repo)

---

## Upcoming

### [0.3.0] - Planned
- NATS metrics/monitoring documentation
- Automated Proxmox snippet update via CI/CD
- Consider `--tlsca` support for NATS client tool

### [1.0.0] - Future
- Stable API contract for Terraform modules / Ansible roles / script CLIs
- Full production hardening checklist
- Migration guide from 0.x

---

## Migration Notes

### From 0.1.0 → 0.2.0
**No breaking changes** — all existing workflows, Terraform modules, Ansible roles, and script interfaces remain compatible.

**Actions required after upgrade:**
1. Run NATS rotation on docker host:
   ```bash
   cd ~/projects/midas
   scripts/update_service_auth_creds.sh --rotate --restart
   ```
2. Refresh NATS contexts on client machines:
   ```bash
   scripts/init-nats-contexts.sh
   ```
3. Update Proxmox cloud-init snippet:
   ```bash
   scripts/update_vm_snippet.sh
   ```
4. Commit midas project changes (template + rotation script)

---

## Links
- [NATS Documentation](docs/NATS.md)
- [Secrets Audit](docs/SECRETS.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Challenges & Solutions](docs/CHALLENGES.md)