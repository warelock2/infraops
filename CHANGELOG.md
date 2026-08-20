# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.0] - 2026-08-20

### Added
- **Standby node pools** — per-plane `standby` integer on clusters (default `0`). Terraform provisions `nodes + standby` uniform VMs; the partition is enforced by `scripts/reconcile-standby-nodes.sh` (wakes actives, clears the `standby` tag on promotion) and `scripts/build-and-park-standby.sh`: ghosts are pre-built with the k8s base toolchain (shared `tasks/k8s-base.yaml` used by both `k8s-cluster.yaml` Play 1 and the new `k8s-standby-build.yaml`) then parked with a clean `sudo poweroff` over SSH. Expanding the cluster (increase `nodes`, decrease `standby` — total flat) boots and joins the promoted ghost without rebuilding, ~3x faster than a cold build. Standby VMs are deliberately `iac`-invisible: Terraform stamps no `iac` tag on them and `extract_drifted_vms` filters them out. New CI steps: Wake Active Nodes (pre config-mgmt), Build and Park Standby Nodes (post config-mgmt), plus per-stage run timings via `scripts/record-timing.sh`/`report-timings.sh`
- **Agent/skill framework** — 4 agents (`config-manager`, `k8s`, `provisioner`, `release-manager`) + 4 skills (`ssot-change`, `validate-infra`, `k8s-cluster`, `release`) with maintenance guide in AGENTS.md
- **DNS ghost fix** — removed destroy provisioner from `dns_alloc`; added `replace_triggered_by` on VMs so config changes trigger full VM recreation with fresh cloud-init IPs instead of in-place updates
- **Ghost control-plane join fix** — `scripts/reconcile-kubeadm-config.py` reconciles kubeadm-config ConfigMap `apiServer.extraArgs` on leader after init; joining control nodes fail-fast waiting for local apiserver
- **Odd control-plane quorum rule** — `clusters[].control_plane.nodes` must be odd (e.g. 1, 3, or 5) so etcd voting can't deadlock; even counts fail schema validation. Doc generator renders `not:` constraints into `SCHEMA_REFERENCE.md`

### Changed
- Schema: added `standby` fields to `control_plane` and `workers` planes with defaults
- pfSense DNS creation: use `pfrest.pfsense` collection module (raw POST returned 405)
- Stream ansible output live with forensics dump on config-mgmt failure

### Fixed
- DNS IP shuffle on `dns_alloc` recreate: destroy provisioner deleted entries before create re-allocated in random order
- pfSense API 405 on host override creation (plural endpoint doesn't support POST)
- `add-host.yaml` now cleans up ghost entries (IP outside pool) and preserves valid in-pool entries

## [Unreleased]

### Added
- **Standby node pools** — per-plane `standby` integer on clusters (default `0`). Terraform provisions `nodes + standby` uniform VMs; the partition is enforced by `scripts/reconcile-standby-nodes.sh` (wakes actives, clears the `standby` tag on promotion) and `scripts/build-and-park-standby.sh`: ghosts are pre-built with the k8s base toolchain (shared `tasks/k8s-base.yaml` used by both `k8s-cluster.yaml` Play 1 and the new `k8s-standby-build.yaml`) then parked with a clean `sudo poweroff` over SSH. Expanding the cluster (increase `nodes`, decrease `standby` — total flat) boots and joins the promoted ghost without rebuilding, ~3x faster than a cold build. Standby VMs are deliberately `iac`-invisible: Terraform stamps no `iac` tag on them and `extract_drifted_vms` filters them out. New CI steps: Wake Active Nodes (pre config-mgmt), Build and Park Standby Nodes (post config-mgmt), plus per-stage run timings via `scripts/record-timing.sh`/`report-timings.sh`
- **Admin SSH keys via IaC** — `warelock@spacedock` public key tracked in `ansible/files/` and provisioned to every warelock account by a repo-tracked `authorized_key` task (no more secret-only or manual key distribution)
- **Odd control-plane quorum rule** — `clusters[].control_plane.nodes` must be odd (e.g. 1, 3, or 5) so etcd voting can't deadlock; even counts fail schema validation. The doc generator renders `not:` constraints into `SCHEMA_REFERENCE.md`
- **`iac` state-drift tag lifecycle** — the `iac` tag marks "IaC detected state drift on this host and acted on it." The actor that detects the drift stamps it: Terraform after changing a VM (create/replace or in-place update, via `scripts/stamp-iac-tags.sh` from `terraform-apply-with-readiness.sh`), and Ansible after its play recap reports a host with `changed > 0` (from `configuration-management.sh`). The tag stays visible for the rest of the run; the last workflow step (`scripts/clear-iac-tags.sh`) then removes it from the **union** of the Terraform-drifted and Ansible-drifted sets and only those — a host tagged by an earlier failed run but not touched this run keeps its tag. IaC owns the tag outright (no snapshot/restore of prior tag state); other tags are preserved. `tags` is in `lifecycle.ignore_changes` so Terraform never fights the stamp/clear

### Changed
- **`iac` state-drift tag documented** — `docs/ARCHITECTURE.md` gains a State Drift Tag section (semantics, who stamps, who clears) and the Data Flow + CI/CD Pipeline mermaid diagrams now show the stamp/clear steps
- **Derived host FQDNs** — `connection.host` in `conf/infrastructure.yaml` is now an optional override; FQDNs default to `<name>.<dns_domain>` and are derived consistently in `generate-inventory.py`, `terraform/outputs.tf`, and vault-URL playbook lookups (kills the stale-`test01.localdomain` class of bug)
- **Worker plane**: mushroom workers back to 2 (`worker-03` removed)
- `scripts/viinfra`: prompts to commit+push after successful validation (default message "Updated SSOT"), prints validation errors immediately on failure, blank-line separation between output sections

### Fixed
- **Standby park shut down nothing** — `reconcile-standby-nodes.sh` checked VM state with `GET .../qemu/{vmid}/status`, which returns the *subdirectory list* (current/start/stop/...), so `vm_running()` always errored and read the VM as stopped; `--park` skipped every shutdown and `--wake` spuriously "started" running actives. `vm_running()` now uses `/status/current`, and `build-and-park-standby.sh` parks ghosts deterministically with `sudo systemctl poweroff` over SSH (the build just proved the host healthy) instead of relying on the Proxmox status check
- **DHCP ghost-lease cleanup order** — `restart-pfsense-dhcp.sh` and the workflow step now verify DNS, DELETE surviving ghost leases first (stop dhcpd → sed `dhcpd.leases`), and only THEN restart dhcpd so Unbound is rebuilt against a clean leases file. Restarting first re-registered the ghosts still in the file. Step renamed to "Delete Ghost DHCP Leases and Restart pfSense DHCP"

## [0.4.0] - 2026-08-09

### Added
- **mushroom Kubernetes cluster** — new multi-node k8s workload (control-01 + workers, kubeadm/Calico/kube-vip) managed end-to-end by the enforce-iac pipeline; overlapping VMID ranges fixed so the cluster's VMs allocate cleanly
- **Worker-plane lifecycle**: `conf/infrastructure.yaml` now drives worker count; expanded by one (`worker-03`), shrunk by one, then re-expanded — full apply + join + drain + orderly reboot cycle proven in CI
- **SSOT version pinning** — all tool/build versions grouped under a new top-level `tools` block in `conf/infrastructure.yaml`; ci-base image and CI toolchain are now reproducible (schema updated, version patterns enforced with `latest` keyword support)
- **Keycloak OIDC auth for k8s** — `kubernetes-mushroom` client with audience + group mappers (`mushroom-admins`/`mushroom-viewers`), token-only kubeconfig flow, RBAC bindings for cluster-admin and read-only access
- **Docs**: Keycloak OIDC user management guide rewritten with a Basic Usage Workflow; README quick-start added

### Changed
- Keycloak admin user is now `warelock` (bootstrap `admin` removed)
- `timeout = 28` and `pipelining = True` moved from `[ssh_connection]` to `[defaults]` in `ansible/ansible.cfg` — `[ssh_connection]` placement was silently ignored in ansible-core 2.17
- K8s OIDC trust uses the system CA store (Let's Encrypt `*.afobl.com` wildcard) instead of a pinned self-signed CA
- `scripts/k8s-oidc-client-setup.sh`: OIDC issuer built port-free on 443 (no `:8443`)

### Fixed
- CI become probe failed worker-02's post-join check by ~0.5s — `become_timeout` raised 12s → 30s
- K8s drain step skipped whenever the control plane is unresolvable, unreachable, or not yet bootstrapped (no `admin.conf`) instead of failing a brand-new/destroyed cluster
- Out-of-pool DHCP ghost lease could become a VM's static netplan IP — allocator now refuses out-of-pool answers
- Readiness gate derived the expected VM IP from the IaC-injected netplan instead of the VM's runtime self-capture (which raced the DHCP→static switch)
- Keycloak audience mapper key corrected to `included.custom.audience` (the prior camelCase key was silently ignored)
- CI fails loudly when a pinned SSOT version key is missing

### Removed
- `test01` test host from `conf/infrastructure.yaml`
- `ansible/files/oidc-ca.pem` (superseded by system CA trust)

---

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