# ===========================================================================
# Terraform configuration for provisioning Proxmox VMs.
#
# WHAT THIS DOES
#   Reads the single source of truth (conf/infrastructure.yaml) and turns it
#   into actual VMs on a Proxmox node. Each VM is cloned from a golden
#   template, given a static IP (via DNS lookup), and booted with a
#   cloud-init snippet that signals readiness back over NATS.
#
# KEY IDEA
#   The .yaml file declares WHAT we want. This file declares HOW to get it.
#   Terraform's job is to make the live infrastructure match the declared
#   intent ("infrastructure as code" / drift correction).
# ===========================================================================

terraform {
  # Pin both the Terraform CLI version and every provider. Providers are the
  # plugins that speak to external systems (Proxmox API, Vault API, shell).
  # Without version pins, a provider upgrade could silently change behavior.
  required_version = ">= 1.7"

  required_providers {
    proxmox = {
      # bpg/proxmox is the community-maintained provider for the Proxmox API.
      source  = "bpg/proxmox"
      version = "~> 0.70"
    }
    external = {
      # The "external" provider runs an arbitrary program and reads JSON back.
      # We use it to resolve DNS names to IPs before a VM boots.
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
    vault = {
      # Lets Terraform read secrets from HashiCorp Vault at plan/apply time.
      # This is how API credentials reach Terraform without being hardcoded.
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }

  # State is stored in MinIO (S3-compatible object storage) instead of a local
  # file. Remote state lets the CI pipeline share one state file, and the
  # MinIO buckets are the same ones used for the golden VM images.
  backend "s3" {
    bucket                      = "tf-state"
    key                         = "proxmox-vms/terraform.tfstate"
    region                      = "us-east-1"
    skip_region_validation      = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_requesting_account_id  = true
    use_path_style              = true

    endpoints = {
      # MinIO is S3-compatible but served from its own host/port.
      s3 = "http://minio.afobl.com:9000"
    }
  }
}

# ---------------------------------------------------------------------------
# Vault provider + secret lookup.
#
# The Proxmox endpoint and API token live in Vault. This "data source" reads
# them at plan time; the provider block below consumes the result. Note the
# order: the data block must come before the provider that references it.
# ---------------------------------------------------------------------------
provider "vault" {
  address          = var.vault_address
  skip_child_token = true
}

data "vault_generic_secret" "proxmox" {
  path = "secret/infraops/proxmox"
}

# ---------------------------------------------------------------------------
# Proxmox provider.
#
# Credentials come from Vault (see data block above). "insecure" is derived
# from the same infrastructure.yaml that drives everything else — one switch
# in the YAML controls TLS verification across the whole provider.
# ---------------------------------------------------------------------------
provider "proxmox" {
  endpoint  = data.vault_generic_secret.proxmox.data["endpoint"]
  api_token = data.vault_generic_secret.proxmox.data["api_token"]
  insecure  = try(yamldecode(file("${path.root}/../conf/infrastructure.yaml")).platform.proxmox.tls_self_signed, false)
}

# ===========================================================================
# locals — "derived values" computed once from the YAML.
#
# Think of locals as variables you compute from other inputs. Terraform
# evaluates them lazily and only recomputes when the inputs change. All the
# real logic of "which VMs to build, with what names/IDs" lives here.
# ===========================================================================
locals {
  # Load the single source of truth as a native Terraform object. The
  # "${path.root}/../conf" path reaches the YAML relative to this .tf file.
  infra = yamldecode(file("${path.root}/../conf/infrastructure.yaml"))

  # "Enforcement" is the permission/ownership switch in the YAML. A cluster
  # is only managed by Terraform if it opts in to "infrastructure_provisioning".
  # This filter keeps Terraform from touching clusters that are managed by
  # another system (or not managed at all).
  managed_clusters = [
    for c in try(local.infra.clusters, []) : c
    if contains(try(c.enforcement, []), "infrastructure_provisioning")
  ]

  # Expand every managed cluster into a flat list of VM definitions.
  # Comprehension order: clusters -> planes (control_plane, workers) -> nodes.
  # The VM name encodes its identity:
  #   <cluster_type>-<cluster_name>-<plane_name>-<NN>
  # e.g. k8s-mushroom-control-01. The %02d pads the node number to two digits
  # so names sort lexically the same way they sort numerically.
  # try() supplies defaults at each level (cluster > plane > global defaults),
  # so sparse YAML still yields a complete VM definition.
  node_list = flatten([
    for c in local.managed_clusters : flatten([
      for plane in ["control_plane", "workers"] : [
        for n in range(try(c[plane].nodes, 0)) : {
          name = format(
            "%s-%s-%s-%02d",
            try(c.cluster_type, local.infra.defaults.cluster_type),
            c.name,
            try(c.plane_defaults[plane].plane_name, local.infra.defaults.planes[plane].plane_name),
            n + 1,
          )
          vm_id     = try(c[plane].vm_id_start + n, -1)
          cores     = try(c[plane].cores, try(c.plane_defaults[plane].cores, local.infra.defaults.vm.cores))
          memory_gb = try(c[plane].memory_gb, try(c.plane_defaults[plane].memory_gb, local.infra.defaults.vm.memory_gb))
          disk_gb   = try(c[plane].disk_gb, try(c.plane_defaults[plane].disk_gb, local.infra.defaults.vm.disk_gb))
          datastore = try(c[plane].datastore, local.infra.defaults.vm.datastore)
        }
      ]
    ])
  ])

  # Keyed map of VM name -> resource attributes. "for ... in ... : key =>
  # value" builds a map, and each key must be unique — which doubles as a
  # safety check that we never generate two VMs with the same name.
  vms = { for n in local.node_list : n.name => {
    vm_id     = n.vm_id
    cores     = n.cores
    memory    = n.memory_gb * 1024
    disk      = n.disk_gb
    datastore = n.datastore
  } }

  # Standalone hosts (non-cluster, e.g. docker, firewall) keyed by name.
  standalone_hosts = {
    for h in try(local.infra.hosts, []) : h.name => h
  }

  # Standalone hosts that Terraform should provision — same enforcement
  # filter as clusters. A host listed here but without vm.vm_id will fail a
  # precondition on the resource (see the standalone resource below).
  standalone_hosts_provision = {
    for h in try(local.infra.hosts, []) : h.name => h
    if contains(try(h.enforcement, []), "infrastructure_provisioning")
  }

  # Per-cluster groups with OIDC issuer URL override.
  # Produces an Ansible inventory group per cluster (k8s_<name>) carrying the
  # cluster's API endpoint and OIDC issuer. The regex matches the VM names we
  # generated above so each cluster only claims its own nodes.
  cluster_groups = {
    for c in local.managed_clusters : "k8s_${c.name}" => {
      vars = {
        oidc_issuer_url = try(c.oidc_issuer_url, local.infra.platform.kubernetes.oidc_issuer_url)
        cp_vip          = try(c.control_plane.vip, null)
        cp_api_host     = "k8s-${c.name}-api.${local.dns_domain}"
        cp_endpoint     = "k8s-${c.name}-api.${local.dns_domain}:6443"
      }
      hosts = {
        for name, vm in proxmox_virtual_environment_vm.vm :
        name => {}
        if can(regex("^k8s-${c.name}-", name))
      }
    }
  }

  # Resolved values: TF_VAR overrides from infrastructure.yaml.
  # coalesce picks the first non-null value. Each variable defaults to null,
  # so passing a variable (e.g. TF_VAR_dns_domain=...) overrides the YAML;
  # otherwise we fall through to the YAML value. YAML is the default source
  # of truth, but an explicit variable always wins.
  proxmox_target_node = coalesce(var.proxmox_target_node, local.infra.platform.proxmox.node)
  dns_servers         = coalesce(var.dns_servers, local.infra.platform.proxmox.dns_servers)
  dns_domain          = coalesce(var.dns_domain, local.infra.platform.proxmox.dns_domain)
  template_id         = coalesce(var.template_id, local.infra.platform.proxmox.template_id)
  linked_clone        = try(local.infra.platform.proxmox.linked_clone, false)
  gateway             = local.infra.defaults.gateway

  # VM ID validation — collected before any resource is created.
  all_vm_ids = concat(
    [for n in local.node_list : n.vm_id if n.vm_id > 0],
    [for h in local.standalone_hosts_provision : try(h.vm.vm_id, -1) if try(h.vm.vm_id, -1) > 0]
  )

  # Check 1: no plane may exceed its declared vm_id_end range. The condition
  # only applies when vm_id_end is actually set (try() with null check), so
  # clusters without an upper bound aren't falsely flagged.
  vm_id_end_violations = flatten([
    for c in local.managed_clusters : [
      for plane in ["control_plane", "workers"] : {
        cluster = c.name
        plane   = plane
        message = "VM IDs exceed vm_id_end range for ${plane} in cluster ${c.name}"
      }
      if try(c[plane].vm_id_end, null) != null && try(c[plane].vm_id_start, 0) + try(c[plane].nodes, 0) - 1 > c[plane].vm_id_end
    ]
  ])

  # Check 2: no VM ID may be reused by two different VMs. O(n^2) but n is
  # small; clarity beats micro-optimization here.
  vm_id_overlap_violations = [
    for i in range(length(local.all_vm_ids)) : {
      id      = local.all_vm_ids[i]
      message = "VM ID ${local.all_vm_ids[i]} is used multiple times"
    }
    if length([for j in range(length(local.all_vm_ids)) : local.all_vm_ids[j] if local.all_vm_ids[j] == local.all_vm_ids[i]]) > 1
  ]
}

# ---------------------------------------------------------------------------
# DNS pre-registration for cluster VMs.
#
# Before a VM boots it needs a static IP. We ask pfSense (via an Ansible
# playbook) to reserve a DNS A record for the VM's hostname. The subsequent
# data.external.dns_lookup then resolves that name to the IP we hand to
# cloud-init. Without the reservation, the lookup would come back empty.
#
# local-exec runs a shell command on the Terraform machine. It is the
# "escape hatch" when the provider can't do something natively. The destroy
# variant (when = destroy) removes the record when the VM goes away.
# ---------------------------------------------------------------------------
resource "terraform_data" "dns_alloc" {
  for_each = local.vms

  input = {
    name = each.key
  }

  provisioner "local-exec" {
    command = "ansible-playbook ${path.root}/../ansible/playbooks/manage-iac-dns.yaml -e 'workflow=add:${each.key}'"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "ansible-playbook ${path.root}/../ansible/playbooks/manage-iac-dns.yaml -e 'workflow=delete:${each.key}'"
  }
}

# ---------------------------------------------------------------------------
# Resolve the DNS record to an IP.
#
# The external provider runs scripts/dns-lookup.sh <hostname> and parses its
# JSON output. depends_on forces the DNS allocation above to finish first.
# each.value.result.ip is consumed by the VM's cloud-init ip_config.
# ---------------------------------------------------------------------------
data "external" "dns_lookup" {
  for_each   = local.vms
  depends_on = [terraform_data.dns_alloc]
  program    = ["sh", "${path.root}/../scripts/dns-lookup.sh", "${each.key}.${local.dns_domain}"]
}

# ===========================================================================
# The main VM resource.
#
# for_each = local.vms means ONE VM per entry in the map — a "resource
# instance" per node. each.key is the VM name, each.value the attributes.
#
# lifecycle:
#   - preconditions are soft assertions that fail the plan if untrue
#     (bad VM ID, overlapping IDs) BEFORE anything is created.
#   - ignore_changes = [initialization] stops Terraform from diffing the
#     cloud-init config on every run. Once a VM exists, its cloud-init data
#     is "baked in" and must not trigger perpetual diffs.
#
# initialization is the cloud-init block: static IP + DNS + SSH user/key +
# a vendor data file (the readiness snippet). This is what makes each cloned
# VM a unique, addressable member of the infrastructure.
# ===========================================================================
resource "proxmox_virtual_environment_vm" "vm" {
  for_each  = local.vms
  name      = each.key
  node_name = local.proxmox_target_node
  vm_id     = each.value.vm_id

  lifecycle {
    precondition {
      condition     = each.value.vm_id > 0
      error_message = "VM ${each.key} has invalid VM ID: ${each.value.vm_id}"
    }

    precondition {
      condition     = length(local.vm_id_overlap_violations) == 0
      error_message = "VM ID overlap detected: ${join(", ", [for v in local.vm_id_overlap_violations : v.message])}"
    }

    ignore_changes = [initialization]
  }

  # QEMU guest agent gives Proxmox clean shutdown + guest info. wait_for_ip is
  # disabled because we set a static IP ourselves from DNS.
  agent {
    enabled = true
    wait_for_ip {
      disabled = true
    }
  }

  # Cloning from the golden template takes time; give it a generous budget.
  timeout_clone = 600

  clone {
    vm_id   = local.template_id
    full    = !local.linked_clone
    retries = 2
  }

  cpu {
    cores = each.value.cores
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = each.value.datastore
    interface    = "scsi0"
    size         = each.value.disk
  }

  network_device {
    bridge = "vmbr0"
  }

  # smbios serial is stamped with the VM ID. The readiness snippet on the VM
  # reads /sys/class/dmi/id/product_serial to learn which VM it is, so the
  # VM can identify itself (hostname + vm_id) when it reports readiness.
  smbios {
    serial = tostring(each.value.vm_id)
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${data.external.dns_lookup[each.key].result.ip}/24"
        gateway = local.gateway
      }
    }

    dns {
      domain  = local.dns_domain
      servers = local.dns_servers
    }

    user_account {
      username = "ansible"
      keys     = ["ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCuRwmKwRFe5YMo1AXZMUBlz2rXWboVpOChnKqY2zm1K/RVhAW98wZNilcvAshvNM3SkywHTMJA2M+CJtVdfpFijARPfY1Hq91dIo1BhG71WtwfmRnG1zz45CouOLmriPV5kh8TkOv4iPJyKY7juA9cVyekgniyynC99nlPMeaJmZ1xGgoEOCBWA3aSOG0TrmLI1AKYx+hVGb1lbMHiLVBrlwuv7UtCNWaPNILRbYLrWeqr2Tr8vf9lXj7aJq/xzTMrfGWRuIvmR+h5zymZFDctRmwfb6cYf4OJP6ztYYrg0VvK/bLkMRTgHx3Pxgobs0giOElAz4SVd+ZjcrM2P1uXYuIWKBzB7rO0sxZp/L0+X7pikDU4mAX5DGOBWECZa8/iajv9hk8GW5sFQDNmeS7evbOhi+rtW50+JZP4UUbXgT/cx0ADdbC2+vJqqIoIOvxuucCl4k5eNznhIqM9RRcS1GabIOtosoojZ9xoYhwu0vsX+FwX3SFp5NXXzl2HV0M= ansible@spacedock"]
    }

    vendor_data_file_id = "local:snippets/cloud-init-reboot.yaml"
  }
}

# Standalone host DNS allocation
# Same pattern as the cluster DNS alloc above, but for standalone hosts
# (docker, firewall, ...) rather than cluster nodes.
resource "terraform_data" "standalone_dns_alloc" {
  for_each = local.standalone_hosts_provision

  input = {
    name = each.key
  }

  provisioner "local-exec" {
    command = "ansible-playbook ${path.root}/../ansible/playbooks/manage-iac-dns.yaml -e 'workflow=add:${each.key}'"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "ansible-playbook ${path.root}/../ansible/playbooks/manage-iac-dns.yaml -e 'workflow=delete:${each.key}'"
  }
}

# Standalone host DNS lookup
# Same DNS round-trip as the cluster nodes, for standalone hosts.
data "external" "standalone_dns_lookup" {
  for_each   = local.standalone_hosts_provision
  depends_on = [terraform_data.standalone_dns_alloc]
  program    = ["sh", "${path.root}/../scripts/dns-lookup.sh", "${each.key}.${local.dns_domain}"]
}

# Standalone host VMs
# Near-identical to the cluster VM resource but reads attributes from the
# host entry in YAML (h.vm.*) instead of from the expanded node_list, with
# the same defaults fallback and the same validation preconditions.
resource "proxmox_virtual_environment_vm" "standalone" {
  for_each  = local.standalone_hosts_provision
  name      = each.key
  node_name = local.proxmox_target_node
  vm_id     = try(each.value.vm.vm_id, -1)

  lifecycle {
    precondition {
      condition     = try(each.value.vm.vm_id, -1) > 0
      error_message = "Standalone host ${each.key} has invalid VM ID: ${try(each.value.vm.vm_id, -1)}"
    }

    precondition {
      condition     = length(local.vm_id_overlap_violations) == 0
      error_message = "VM ID overlap detected: ${join(", ", [for v in local.vm_id_overlap_violations : v.message])}"
    }

    ignore_changes = [initialization]
  }

  agent {
    enabled = true
    wait_for_ip {
      disabled = true
    }
  }

  timeout_clone = 600

  clone {
    vm_id   = local.template_id
    full    = !local.linked_clone
    retries = 2
  }

  cpu {
    cores = try(each.value.vm.cores, local.infra.defaults.vm.cores)
  }

  memory {
    dedicated = try(each.value.vm.memory_gb, local.infra.defaults.vm.memory_gb) * 1024
  }

  disk {
    datastore_id = try(each.value.vm.datastore, local.infra.defaults.vm.datastore)
    interface    = "scsi0"
    size         = try(each.value.vm.disk_gb, local.infra.defaults.vm.disk_gb)
  }

  network_device {
    bridge = "vmbr0"
  }

  smbios {
    serial = tostring(each.value.vm_id)
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${data.external.standalone_dns_lookup[each.key].result.ip}/24"
        gateway = local.gateway
      }
    }

    dns {
      domain  = local.dns_domain
      servers = local.dns_servers
    }

    user_account {
      username = "ansible"
      keys     = ["ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCuRwmKwRFe5YMo1AXZMUBlz2rXWboVpOChnKqY2zm1K/RVhAW98wZNilcvAshvNM3SkywHTMJA2M+CJtVdfpFijARPfY1Hq91dIo1BhG71WtwfmRnG1zz45CouOLmriPV5kh8TkOv4iPJyKY7juA9cVyekgniyynC99nlPMeaJmZ1xGgoEOCBWA3aSOG0TrmLI1AKYx+hVGb1lbMHiLVBrlwuv7UtCNWaPNILRbYLrWeqr2Tr8vf9lXj7aJq/xzTMrfGWRuIvmR+h5zymZFDctRmwfb6cYf4OJP6ztYYrg0VvK/bLkMRTgHx3Pxgobs0giOElAz4SVd+ZjcrM2P1uXYuIWKBzB7rO0sxZp/L0+X7pikDU4mAX5DGOBWECZa8/iajv9hk8GW5sFQDNmeS7evbOhi+rtW50+JZP4UUbXgT/cx0ADdbC2+vJqqIoIOvxuucCl4k5eNznhIqM9RRcS1GabIOtosoojZ9xoYhwu0vsX+FwX3SFp5NXXzl2HV0M= ansible@spacedock"]
    }

    vendor_data_file_id = "local:snippets/cloud-init-reboot.yaml"
  }
}

# Outputs are the "returns" of the module. They expose computed data to the
# outside world — here, the CI pipeline reads these to know what got created.
output "vm_names" {
  value = keys(local.vms)
}

output "standalone_vm_names" {
  value = keys(local.standalone_hosts_provision)
}
