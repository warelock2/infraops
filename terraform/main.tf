terraform {
  required_version = ">= 1.7"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.70"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }

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
      s3 = "http://minio.afobl.com:9000"
    }
  }
}

provider "vault" {
  address          = var.vault_address
  skip_child_token = true
}

data "vault_generic_secret" "proxmox" {
  path = "secret/infraops/proxmox"
}

provider "proxmox" {
  endpoint  = data.vault_generic_secret.proxmox.data["endpoint"]
  api_token = data.vault_generic_secret.proxmox.data["api_token"]
  insecure  = try(yamldecode(file("${path.root}/../conf/infrastructure.yaml")).platform.proxmox.tls_self_signed, false)
}

locals {
  infra = yamldecode(file("${path.root}/../conf/infrastructure.yaml"))

  managed_clusters = [
    for c in try(local.infra.clusters, []) : c
    if contains(try(c.enforcement, []), "infrastructure_provisioning")
  ]

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

  vms = { for n in local.node_list : n.name => {
    vm_id     = n.vm_id
    cores     = n.cores
    memory    = n.memory_gb * 1024
    disk      = n.disk_gb
    datastore = n.datastore
  } }

  standalone_hosts = {
    for h in try(local.infra.hosts, []) : h.name => h
  }

  # Standalone hosts that Terraform should provision
  standalone_hosts_provision = {
    for h in try(local.infra.hosts, []) : h.name => h
    if contains(try(h.enforcement, []), "infrastructure_provisioning")
  }

  # Per-cluster groups with OIDC issuer URL override
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

  # Resolved values: TF_VAR overrides from infrastructure.yaml
  proxmox_target_node = coalesce(var.proxmox_target_node, local.infra.platform.proxmox.node)
  dns_servers         = coalesce(var.dns_servers, local.infra.platform.proxmox.dns_servers)
  dns_domain          = coalesce(var.dns_domain, local.infra.platform.proxmox.dns_domain)
  template_id         = coalesce(var.template_id, local.infra.platform.proxmox.template_id)
  linked_clone        = try(local.infra.platform.proxmox.linked_clone, false)
  gateway             = local.infra.defaults.gateway

  # VM ID validation
  all_vm_ids = concat(
    [for n in local.node_list : n.vm_id if n.vm_id > 0],
    [for h in local.standalone_hosts_provision : try(h.vm.vm_id, -1) if try(h.vm.vm_id, -1) > 0]
  )

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

  vm_id_overlap_violations = [
    for i in range(length(local.all_vm_ids)) : {
      id      = local.all_vm_ids[i]
      message = "VM ID ${local.all_vm_ids[i]} is used multiple times"
    }
    if length([for j in range(length(local.all_vm_ids)) : local.all_vm_ids[j] if local.all_vm_ids[j] == local.all_vm_ids[i]]) > 1
  ]
}

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

data "external" "dns_lookup" {
  for_each   = local.vms
  depends_on = [terraform_data.dns_alloc]
  program    = ["sh", "${path.root}/../scripts/dns-lookup.sh", "${each.key}.${local.dns_domain}"]
}

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
data "external" "standalone_dns_lookup" {
  for_each   = local.standalone_hosts_provision
  depends_on = [terraform_data.standalone_dns_alloc]
  program    = ["sh", "${path.root}/../scripts/dns-lookup.sh", "${each.key}.${local.dns_domain}"]
}

# Standalone host VMs
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

output "vm_names" {
  value = keys(local.vms)
}

output "standalone_vm_names" {
  value = keys(local.standalone_hosts_provision)
}
