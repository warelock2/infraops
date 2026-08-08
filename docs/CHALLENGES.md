# Challenges

Major problems we hit building this infrastructure and how we solved them.

## DHCP doesn't register hostnames in DNS

Proxmox assigns IPs via DHCP but the router's DHCP doesn't create DNS records. We need DNS resolution for IP allocation (`scripts/dns-lookup.sh` picks the next free in-pool address) and Ansible inventory. **Solution:** Manage static IPs directly in pfSense Unbound DNS via REST API. Terraform allocates IPs from a defined pool, creates DNS records, and VMs get static IPs via cloud-init.

## Terraform creates VMs before Ansible can connect

VMs boot and cloud-init runs, but SSH isn't ready when Terraform's `wait_for_connection` returns. Ansible fails with connection refused. **Solution:** The NATS readiness handshake. Each VM runs `helloworld.sh` after cloud-init: it validates hostname/IP/route/sshd/cloud-init status, heals what it can, reboots up to `MAX_REBOOTS`, and publishes a readiness signal to the `infraops` JetStream stream. `scripts/terraform-apply-with-readiness.sh` derives the exact VM set from the Terraform plan (create/replace only), applies, and blocks until each one signals — destroying failed VMs and retrying — so Ansible never touches a half-booted VM. (This replaced an earlier 5-minute fixed sleep plus `wait_for_connection` 600-second retry approach.)

## Netplan apply fails during early boot

Cloud-init writes netplan config but the interface rename (`ens18` → `eth0`) fails with `[busy]` error during the DHCP race window. **Solution:** Added `netplan apply` to cloud-init's `runcmd` section, after qemu-guest-agent starts. By runcmd time the busy condition has cleared.

## Cloud-init `power_state` causes problems

Putting `power_state` in cloud-init to reboot after setup causes reboot loops and timing issues. **Solution:** Removed `power_state` from the cloud-init snippet entirely. Reboot is handled separately by Ansible when needed.

## pfREST Ansible collection has bugs

`lookup_object()` throws "matched multiple existing objects" because query params don't filter. `delete_object()` sends ID in JSON body but the API expects it in the URL path. **Solution:** Use `ansible.builtin.uri` with DELETE to the plural endpoint plus query parameters. Proven to work reliably.

## Golden image approach was fragile

Initially built custom VM images with `virt-customize`. Templates broke across Proxmox versions and were hard to maintain. **Solution:** Use stock Ubuntu 26.04 cloud images with Proxmox-native cloud-init. Simpler, more portable, easier to update.

## VIP as IP breaks TLS and kubectl

Using the VIP IP directly in Terraform's `cp_endpoint` works but `kubectl` can't verify TLS certificates. **Solution:** Changed `cp_endpoint` to use DNS hostname (`k8s-{name}-api.{domain}:6443`). Keepalived handles VIP failover, DNS resolves to the active node.

## Ansible collection version conflicts

System-wide `ansible` and project venv `ansible` had different collection versions. `pfsensible.core` conflicted with `pfrest.pfsense`. **Solution:** All project Python dependencies go into `.venv/` within the project directory. Never install system-wide or user-level packages.

## Vault tokens in files are a liability

Writing Vault tokens to `~/.vault-token` means secrets on disk. CI needs tokens but can't store files. **Solution:** Pass tokens via `VAULT_TOKEN` environment variable only. Read-only token for CI, read-write token for local use. No file-based tokens anywhere.

## Cloud-init status --wait returns rc=2

`cloud-init status --wait` returns exit code 2 when done with warnings (status: done). Ansible treats this as failure. **Solution:** Added `failed_when: false` to the task. Cloud-init completed successfully, the warnings are non-critical.

## DNS resolver changes need explicit apply

Creating or deleting host overrides via pfSense REST API stages changes but doesn't commit them. Unbound continues serving old records. **Solution:** Must call `pfrest.pfsense.services_dns_resolver_apply` after every create/delete operation to commit changes.

## Ubuntu phased updates look like a patching failure

Right after a fresh patch run, `apt list --upgradable` can show 10-20+ "available" packages (`apparmor`, `bind9`, `systemd`, `udev`, `grub-pc`, `cloud-init`, ...) even though `apt-get upgrade` reported nothing to do. This is not a failed patch and not a stale cache — Canonical publishes SRUs as **phased updates** (e.g. `(phased 10%)`), rolling them out to a small cohort first. `apt-get upgrade` correctly defers them (`The following upgrades have been deferred due to phasing: ...`) until the phase window opens for the machine, which is keyed off the apt cache `update-success-stamp` age. Running `apt update` re-stamps the cache and can make them show up as upgradable, and a later run installs them. **Solution:** Verify with `apt-get upgrade --dry-run` (prints `deferred due to phasing`) rather than `apt list --upgradable`. The packages converge on their own as phasing ramps, or on the next scheduled patch run.

## Ghost DHCP leases pollute DNS after VM creation

A freshly cloned VM boots with the golden template's DHCP netplan for a short window before cloud-init applies its static netplan. systemd-networkd tears that DHCP client down **without** sending DHCPRELEASE, so pfSense keeps a "ghost" lease for the VM's MAC. The stale registration even outlives the lease itself: pfSense's resolver keeps answering the hostname with the pool-adjacent ghost IP until the DHCP service is restarted and dhcpleases rewrites Unbound from the leases file. Deleting the lease on the pfSense side was not enough — the DNS entry survived until a full DHCP service restart, so Ansible could start against polluted DNS. **Solution:** Two halves. (1) In the cloud-init `runcmd` (scripts/cloud-init-reboot.yaml.template), after hostinfo.txt captures the static IP, run the dhclient release procedure `networkctl down eth0 && dhclient eth0 && dhclient -r eth0` once per instance (guarded by `command -v dhclient` and an `/etc/helloworld/dhcp-released` marker). The interface is **not** brought back up with `networkctl up eth0` — that asks networkd to request a fresh lease and undoes the release; the existing reboot dance re-applies the persisted static netplan instead. (2) The CI pipeline (enforce-iac.yaml) inserts a "Restart pfSense DHCP and Verify Clean DNS" step right after the apply loop and before Ansible: it reads the pfSense API key from Vault, POSTs `/api/v2/services/dhcp_server/apply`, then verifies every provisioned VM FQDN resolves only to IPs inside the IaC pool — **auto-deleting** any out-of-pool ghost lease that survived the restart (stop dhcpd → sed `dhcpd.leases` → apply → re-verify) and failing the run only if a ghost persists after deletion. Existing VMs created before the template had `isc-dhcp-client` baked in still need it installed manually; old clones skip the release silently.

## VM self-captured IP breaks the readiness contract

`hostinfo.txt` — the VM's identity file written by cloud-init `runcmd` — used to capture the IP from the VM's own `ip -4 addr show` at boot. That is transient runtime state, and it races the netplan switch: on a freshly cloned VM the runcmd can record the boot-window DHCP address (e.g. `192.168.0.222`) just before the static netplan lands. `helloworld.sh` then treats that captured address as the *expected* IP and reboots the VM for not matching it — even though the VM is sitting on the correct static IP — declaring the provision a failure after `MAX_REBOOTS`. Two of three mushroom nodes hit this race and failed the readiness gate despite being healthy. **Solution:** The VM is only authoritative about its own health; its expected IP must come from the IaC process. That address is already delivered to the VM by Terraform — `terraform/main.tf` sets `initialization.ip_config.ipv4.address` from the same DNS allocation that becomes the static netplan — so `scripts/cloud-init-reboot.yaml.template` now parses `hostinfo.txt`'s `ip` from `/etc/netplan/50-cloud-init.yaml` (the netplan cloud-init rendered from that `ip_config`) instead of `ip -4 addr show`. If no static address is present the runcmd fails loudly rather than letting the VM self-report. `helloworld.sh` is unchanged: it still compares the runtime IP against the (now IaC-injected) expected IP and verifies route/sshd/NATS.
