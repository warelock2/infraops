# ===========================================================================
# Input variables (TF_VAR_* or -var flags).
#
# Each variable defaults to null, which signals "no override given". The
# locals in main.tf then coalesce: explicit variable wins, otherwise fall
# back to the value in infrastructure.yaml. So this file is the "escape
# hatch" — YAML is the default, variables are the emergency override.
# ===========================================================================

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

variable "vault_address" {
  description = "Vault server address"
  type        = string
  default     = "https://vault.afobl.com"
}

variable "template_id" {
  description = "Template VM ID to clone from (defaults to infrastructure.yaml platform.proxmox.template_id)"
  type        = number
  default     = null
}


