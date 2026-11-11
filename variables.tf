# Proxmox API
variable "proxmox_endpoint" {
  description = "Proxmox VE API endpoint"
  type        = string
}

variable "proxmox_insecure" {
  description = "Skip TLS certificate verification"
  type        = bool
  default     = false
}

# Proxmox VM defaults
variable "default_node" {
  description = "Default target Proxmox node"
  type        = string
}

variable "template_id" {
  description = "VM template ID"
  type        = number
}

variable "network_bridge" {
  description = "Default network bridge"
  type        = string
  default     = "vmbr0"
}

variable "storage_mapping" {
  description = "Mapping storage profile to Proxmox datastore"
  type        = map(string)
}
