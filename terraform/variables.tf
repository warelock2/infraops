variable "proxmox_target_node" {
  description = "Proxmox node to create VMs on (defaults to infrastructure.yaml platform.proxmox.node)"
  type        = string
  default     = null
}

variable "dns_servers" {
  description = "DNS servers for VMs (defaults to infrastructure.yaml platform.proxmox.dns_servers)"
  type        = list(string)
  default     = null
}

variable "dns_domain" {
  description = "DNS search domain for VMs (defaults to infrastructure.yaml platform.proxmox.dns_domain)"
  type        = string
  default     = null
}

variable "template_id" {
  description = "Template VM ID to clone from (defaults to infrastructure.yaml platform.proxmox.template_id)"
  type        = number
  default     = null
}


