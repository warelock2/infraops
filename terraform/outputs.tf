# ===========================================================================
# Outputs — the module's "return values".
#
# This output is consumed by the CI pipeline (and the golden template tooling)
# to derive an Ansible inventory. It merges:
#   - the cluster node VMs (proxmox_virtual_environment_vm.vm) with FQDNs
#   - the standalone hosts with their declared connection info
#   - per-group host assignments (control/worker/docker_services)
#   - the per-cluster groups computed in locals.cluster_groups
#
# The final structure is one big map that Ansible can load directly as an
# inventory (groups -> hosts -> host_vars).
# ===========================================================================
output "ansible_inventory" {
  value = merge(
    {
      all = {
        hosts = merge(
          # Cluster node VMs: ansible_host is their FQDN (VM name + dns_domain).
          { for name, vm in proxmox_virtual_environment_vm.vm :
            name => {
              ansible_host = "${name}.${local.dns_domain}"
            }
          },
          # Standalone hosts: connection info comes from the YAML, but the
          # FQDN is derived as <name>.<dns_domain> unless connection.host is
          # an explicit override (e.g. an IP for the firewall).
          { for name, h in local.standalone_hosts :
            name => {
              ansible_host = try(coalesce(h.connection.host, "${name}.${local.dns_domain}"), "${name}.${local.dns_domain}")
              ansible_user = try(h.connection.user, "ansible")
            }
          }
        )
      }
      # Group assignment by name pattern: <type>-<cluster>-control-NN matches
      # control plane nodes, <type>-<cluster>-worker-NN matches workers.
      # regexall returns a list; length > 0 means "matches".
      k8s_control = {
        hosts = {
          for name, vm in proxmox_virtual_environment_vm.vm :
          name => {}
          if length(regexall("k8s-.+-control-", name)) > 0
        }
      }
      k8s_worker = {
        hosts = {
          for name, vm in proxmox_virtual_environment_vm.vm :
          name => {}
          if length(regexall("k8s-.+-worker-", name)) > 0
        }
      }
      # Standalone hosts that opted in to configuration management (i.e. the
      # ones Ansible is allowed to configure). This is the enforcement filter
      # applied to inventory generation.
      docker_services = {
        hosts = {
          for name, h in local.standalone_hosts :
          name => {}
          if contains(h.enforcement, "configuration_management")
        }
      }
    },
    local.cluster_groups
  )
}
