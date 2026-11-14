
# ==========================================
# Proxmox Bulk VM Provisioning
# ==========================================

locals {
  # OS template mapping
  os_templates = {
    "Ubuntu 26.04" = var.template_id
    # "Ubuntu 24.04" = 9001
  }

  # Read CSV inventory
  inventory = csvdecode(file("${path.module}/vms.csv"))

  # Normalize CSV data
  vm_rows = [
    for vm in local.inventory : {
      name      = trimspace(vm["Name"])
      os        = trimspace(vm["Operating System"])
      disk_type = trimspace(vm["Disk Type"])
      qty       = tonumber(vm["Qty"])
      cpu       = tonumber(vm["vCPU"])
      ram_gb    = tonumber(vm["Memory (GB)"])
      disk_gb   = tonumber(vm["Disk (GB)"])

      ip_addresses = [
        for ip in split("|", vm["IP Address"]) : trimspace(ip)
      ]

      gateway = trimspace(vm["Gateway"])

      dns_servers = compact([
        for dns in split("|", vm["DNS"]) : trimspace(dns)
      ])

      vlan_id = trimspace(vm["VLAN"]) == "" ? null : tonumber(vm["VLAN"])
    }
    if trimspace(vm["Name"]) != ""
  ]

  # Expand Qty into individual VM instances
  vm_instances = flatten([
    for vm in local.vm_rows : [
      for i in range(vm.qty >= 1 && vm.qty <= 1024 && vm.qty == floor(vm.qty) ? vm.qty : 0) : {

        # VM Naming
        # Qty = 1: original name
        # Qty > 1: name-01, name-02, name-03
        name = vm.qty > 1 ? format(
          "%s-%02d", vm.name, i + 1
        ) : vm.name

        # PoC: "POC"; Production: vm.disk_type
        storage_key = vm.disk_type

        os        = vm.os
        disk_type = vm.disk_type
        cpu       = vm.cpu
        ram_gb    = vm.ram_gb
        disk_gb   = vm.disk_gb

        # Network Configuration
        ip_cidr = (
          length(vm.ip_addresses) == 1 &&
          lower(vm.ip_addresses[0]) == "dhcp"
        ) ? "dhcp" : try(vm.ip_addresses[i], "")

        gateway     = vm.gateway
        dns_servers = vm.dns_servers
        vlan_id     = vm.vlan_id
      }
    ]
  ])

  vms = {
    for vm in local.vm_instances : vm.name => vm
  }

  static_ips = [
    for vm in local.vm_instances : split("/", vm.ip_cidr)[0]
    if vm.ip_cidr != "dhcp"
  ]
}

# ==========================================
# Preserve Previous Test VM
# ==========================================

removed {
  from = proxmox_virtual_environment_vm.test_vm

  lifecycle {
    destroy = false
  }
}

# ==========================================
# VM Provisioning
# ==========================================

resource "proxmox_virtual_environment_vm" "vm" {
  for_each = local.vms

  name        = each.key
  node_name   = var.default_node
  description = "Provisioned by Terraform"

  # Clone
  clone {
    vm_id        = local.os_templates[each.value.os]
    full         = true
    datastore_id = var.storage_mapping[each.value.storage_key]
  }

  # CPU
  cpu {
    cores = each.value.cpu
  }

  # RAM
  memory {
    dedicated = each.value.ram_gb * 1024
  }

  # Boot Disk
  disk {
    datastore_id = var.storage_mapping[each.value.storage_key]
    interface    = "scsi0"
    size         = each.value.disk_gb
  }

  # Network Interface
  network_device {
    bridge  = var.network_bridge
    model   = "virtio"
    vlan_id = each.value.vlan_id
  }

  # Cloud-Init
  initialization {
    datastore_id = var.storage_mapping[each.value.storage_key]
    interface    = "ide0"

    # IPv4
    ip_config {
      ipv4 {
        address = each.value.ip_cidr

        gateway = (
          each.value.ip_cidr == "dhcp" ||
          each.value.gateway == ""
        ) ? null : each.value.gateway
      }
    }

    # DNS
    dynamic "dns" {
      for_each = length(each.value.dns_servers) > 0 ? [
        each.value.dns_servers
      ] : []

      content {
        servers = dns.value
      }
    }
  }

  # QEMU Guest Agent
  agent {
    enabled = true
  }

  # Start VM
  started = true

  # Safety
  lifecycle {
    prevent_destroy = false

    precondition {
      condition = (
        each.value.ip_cidr == "dhcp" ||
        can(cidrnetmask(each.value.ip_cidr))
      )

      error_message = "Invalid IPv4 CIDR for ${each.key}."
    }

    precondition {
      condition = each.value.vlan_id == null ? true : (
        each.value.vlan_id >= 1 &&
        each.value.vlan_id <= 4094 &&
        each.value.vlan_id == floor(each.value.vlan_id)
      )

      error_message = "Invalid VLAN ID for ${each.key}."
    }
  }
}

# ==========================================
# Outputs and Inventory Validation
# ==========================================

output "vm_ids" {
  value = {
    for name, vm in proxmox_virtual_environment_vm.vm :
    name => vm.vm_id
  }
}

output "total_vms" {
  value = length(local.vm_instances)

  precondition {
    condition = alltrue([
      for vm in local.vm_rows : (
        vm.qty >= 1 &&
        vm.qty <= 1024 &&
        vm.qty == floor(vm.qty) &&
        vm.cpu >= 1 &&
        vm.cpu == floor(vm.cpu) &&
        vm.ram_gb > 0 &&
        vm.ram_gb * 1024 == floor(vm.ram_gb * 1024) &&
        vm.disk_gb > 0 &&
        vm.disk_gb == floor(vm.disk_gb)
      )
    ])

    error_message = "Invalid VM specification in CSV."
  }

  # Validate Storage Mapping
  precondition {
    condition = alltrue([
      for vm in local.vm_rows :
      contains(
        keys(var.storage_mapping),
        vm.disk_type
      )
    ])

    error_message = "Invalid Disk Type in CSV. Check storage_mapping in terraform.tfvars."
  }

  # Validate IP Quantity
  precondition {
    condition = alltrue([
      for vm in local.vm_rows : (
        (
          length(vm.ip_addresses) == 1 &&
          lower(vm.ip_addresses[0]) == "dhcp"
        ) ||
        (
          length(vm.ip_addresses) == vm.qty &&
          alltrue([
            for ip in vm.ip_addresses :
            can(cidrnetmask(ip))
          ])
        )
      )
    ])

    error_message = "Static IP count must match VM Qty and each IP must be valid IPv4 CIDR."
  }

  # Validate Duplicate IP
  precondition {
    condition = (
      length(distinct(local.static_ips)) ==
      length(local.static_ips)
    )

    error_message = "Duplicate static IP addresses detected."
  }
}

output "total_vcpus" {
  value = sum(concat([0], [
    for vm in local.vm_instances : vm.cpu
  ]))
}

output "total_memory_gb" {
  value = sum(concat([0], [
    for vm in local.vm_instances : vm.ram_gb
  ]))
}

output "total_disk_gb" {
  value = sum(concat([0], [
    for vm in local.vm_instances : vm.disk_gb
  ]))
}

output "vm_network" {
  value = {
    for name, vm in local.vms : name => {
      ip_address = vm.ip_cidr
      gateway    = vm.ip_cidr == "dhcp" || vm.gateway == "" ? null : vm.gateway
      dns        = vm.dns_servers
      vlan       = vm.vlan_id
    }
  }
}