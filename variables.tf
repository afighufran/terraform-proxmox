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

variable "datastore_id" {
  description = "Default VM datastore"
  type        = string
}

variable "network_bridge" {
  description = "Default network bridge"
  type        = string
  default     = "vmbr0"
}