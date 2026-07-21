output "ansible_inventory" {
  value = merge(
    {
      all = {
        hosts = merge(
          { for name, vm in proxmox_virtual_environment_vm.vm :
            name => {
              ansible_host = "${name}.${local.dns_domain}"
            }
          },
          { for name, h in local.standalone_hosts :
            name => {
              ansible_host = h.connection.host
              ansible_user = h.connection.user
            }
          }
        )
      }
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
