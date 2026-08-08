# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-08-07

### Added
- **DHCP ghost-lease elimination** — a three-part fix for DNS pollution caused by short-lived leases VMs hold during their boot window:
  - Guest side: `scripts/cloud-init-reboot.yaml.template` runcmd releases the VM's lease during the DHCP→static switch (`networkctl down eth0 && dhclient eth0 && dhclient -r eth0`, guarded by a marker file)
  - Pipeline gate: `scripts/restart-pfsense-dhcp.sh` restarts pfSense DHCP via `/api/v2/services/dhcp_server/apply`, verifies every provisioned VM FQDN resolves only to in-pool IPs (192.168.0.40-.49), and **auto-deletes** any out-of-pool "ghost" lease that survived (stop dhcpd → sed `dhcpd.leases` → apply → re-verify)
  - Manual fallback: `ansible/playbooks/manage-iac-dhcp.yaml` + `tasks/delete-lease.yaml` for DNS-driven ghost lease deletion
- **NATS readiness handshake** — VM provisioning is now gated on a real readiness signal instead of sleep-based polling:
  - `scripts/terraform-apply-with-readiness.sh`: derives the expected VM set from the Terraform plan (create/replace only), applies, and blocks until every expected VM signals; retries with failed-VM destruction
  - `scripts/wait-for-readiness.sh`: consumes the `infraops.helloworld` stream; a declared VM failure (`.fail.<host>`) halts the wait for forensics
  - `scripts/ensure-readiness-poller.sh`: creates/refreshes durable NATS consumers (`readiness-poller`, `failure-poller`) per run
  - `scripts/destroy-failed-vms.sh`: tears down VMs that never signaled so the apply can retry
  - Cloud-init `helloworld.sh`: validates hostname/IP/route/sshd/cloud-init, heals what it can, reboots up to `MAX_REBOOTS`, and only then publishes readiness; new `on_botched_vm_creation` (`destroy`/`preserve`) policy
- **Orderly rolling k8s reboots** (`ansible/playbooks/tasks/final-act-reboot-node.yaml`): drain → reboot → rejoin wait → uncordon, one control node at a time for clusters with 3+ control planes
- **Universal final-act playbook** (`ansible/playbooks/final-act.yaml`): post-patch reboot handling for every managed host + ntfy admin notification when a host needs manual attention
- **Common baseline playbook** (`ansible/playbooks/common.yaml`): admin account + patching for all `configuration_management` hosts
- **Standalone VM ID auto-allocation** (`scripts/standalone-vm-ids.py`): first-free ID from the pool via the Terraform external data source
- **`scripts/terraform-init-retry.sh`**: retries flaky provider registry downloads with backoff
- **`scripts/configuration-management.sh`**: config-management step moved to a script file (avoids quote-stripping of inline workflow args)
- **Schema**: `on_botched_vm_creation` (`destroy`/`preserve`) added to `conf/infrastructure.schema.yaml`
- **ci-base**: Dockerfile split into cached layers (base/pip/galaxy/binaries/provider mirror) for fast rebuilds; terraform provider mirror baked in for offline init
- **Docs**: educational annotations across scripts, playbooks, tasks, templates, workflows, and the cloud-init readiness template; Architecture Highlights added to README

### Changed
- IaC DNS pool narrowed to `192.168.0.40-.49`
- `scripts/dns-lookup.sh` now prefers IaC pool answers over any out-of-pool record
- VMs cloned directly onto the RAIDZ datastore
- kubeconfig for node draining fetched live from `control-01` instead of a stale secret
- `ansible/requirements.txt` → `ansible/requirements.yaml` (galaxy collections)
- deploy-k8s workflow now runs in the ci-base image instead of ad-hoc toolchain installs
- Cloud-init snippet moved from `snippets/` to `scripts/`; `scripts/update_vm_snippet.sh` supersedes `ansible/create-proxmox-snippet.sh`
- k8s node sizing reduced to 2GB RAM (defaults)
- `scripts/vischema` renamed to `scripts/viinfra`

### Fixed
- Readiness wait now polls `cloud-init status` instead of the persisted boot-finished marker (which survives reboots and can pass mid-run)
- helloworld exits after issuing a reboot and no longer auto-restarts in a loop
- `StartLimit` keys moved from `[Service]` to `[Unit]`
- `nats sub --timeout` now requires a duration suffix
- Readiness extractor `jq` expression + apply flag position; `-parallelism=1` restored on apply
- `--apiserver-bind-port 6444` passed to control-plane joins
- Read-only Vault token can now read the ntfy channel secret
- Durable `ens18` → `eth0` netplan fix; NIC naming standardized on `eth0`
- Stray `---` document separator in `tasks/delete-lease.yaml` (broke YAML parsing and DNS-driven ghost lease deletion)
- enforce-iac `K8s Drain Removed Nodes` step skips when the cluster's control plane does not resolve (a brand-new/destroyed cluster has nothing to drain and no kubeconfig to fetch)
- Readiness `hostinfo.txt` IP is now parsed from the static netplan cloud-init rendered from Terraform's `ip_config` instead of the VM's runtime `ip -4 addr show` — the VM's self-capture raced the netplan switch and could record the boot-window DHCP address, making helloworld reject the VM's correct static IP
- `scripts/dns-lookup.sh` no longer falls back to an out-of-pool answer when the IaC pool is authoritative — a stale DHCP ghost (e.g. from a failed earlier run) could become a VM's static netplan IP, disagreeing with the in-pool DNS override. When the resolver yields no in-pool answer it now queries the pfSense host-override API directly (the source of truth `dns_alloc` writes), accepting the override IP only if it is in-pool
- `scripts/configuration-management.sh` skips the control-plane kubeconfig fetch when `/etc/kubernetes/admin.conf` doesn't exist yet (fresh cluster not yet bootstrapped by the site playbook) instead of failing the whole config-management step

### Removed
- `ansible/create-proxmox-snippet.sh` (superseded by `scripts/update_vm_snippet.sh`)
- `snippets/cloud-init-reboot.yaml.template` (moved to `scripts/`)
- `ansible/requirements.txt` (replaced by `ansible/requirements.yaml`)
- mushroom cluster from `conf/infrastructure.yaml` (testing churn; `clusters: []`)

---

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