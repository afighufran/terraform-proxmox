# ==========================================
# Proxmox Bulk VM Provisioning
# ==========================================

locals {

  # ----------------------------------------
  # OS Template Mapping
  # ----------------------------------------
  os_templates = {
    "Ubuntu 26.04" = var.template_id

    # Production:
    # "Ubuntu 24.04" = 9001
  }

  # ----------------------------------------
  # Read CSV Inventory
  # ----------------------------------------
  inventory = csvdecode(
    file("${path.module}/vms.csv")
  )

  # ----------------------------------------
  # Normalize CSV Data
  # ----------------------------------------
  vm_rows = [
    for vm in local.inventory : {
      name      = trimspace(vm["Name"])
      os        = trimspace(vm["Operating System"])
      disk_type = trimspace(vm["Disk Type"])

      qty     = tonumber(vm["Qty"])
      cpu     = tonumber(vm["vCPU"])
      ram_gb  = tonumber(vm["Memory (GB)"])
      disk_gb = tonumber(vm["Disk (GB)"])
    }
    if trimspace(vm["Name"]) != ""
  ]

  # ----------------------------------------
  # Expand VM Quantity
  # ----------------------------------------
  vm_instances = flatten([
    for vm in local.vm_rows : [
      for i in range(vm.qty) : {

        # VM Naming
        name = i == 0 ? vm.name : format(
          "%s-%02d", vm.name, i + 1
        )

        # ----------------------------------
        # Storage Selection
        # ----------------------------------
        # PoC:  "POC"
        # Prod: vm.disk_type
        storage_key = "POC"

        os        = vm.os
        disk_type = vm.disk_type

        cpu     = vm.cpu
        ram_gb  = vm.ram_gb
        disk_gb = vm.disk_gb
      }
    ]
  ])

  # ----------------------------------------
  # Build VM Map
  # ----------------------------------------
  vms = {
    for vm in local.vm_instances :
    vm.name => vm
  }
}

# ==========================================
# Previous Test VM
# Keep VM, remove from Terraform state
# Requires Terraform >= 1.7
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

  # VM Identity
  name        = each.key
  node_name   = var.default_node
  description = "Provisioned by Terraform"

  # Clone Template
  clone {
    vm_id = local.os_templates[each.value.os]
    full  = true

    datastore_id = var.storage_mapping[
      each.value.storage_key
    ]
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
    datastore_id = var.storage_mapping[
      each.value.storage_key
    ]

    interface = "scsi0"
    size      = each.value.disk_gb
  }

  # Network
  network_device {
    bridge = var.network_bridge
    model  = "virtio"
  }

  # QEMU Guest Agent
  agent {
    enabled = true
  }

  # Start VM
  started = true

  # Safety
  lifecycle {
    prevent_destroy = true

    precondition {
      condition = alltrue([
        for vm in local.vm_rows :
        vm.qty >= 1 &&
        vm.qty == floor(vm.qty) &&
        vm.cpu >= 1 &&
        vm.ram_gb > 0 &&
        vm.disk_gb > 0
      ])

      error_message = "Invalid VM specification in CSV."
    }
  }
}

# ==========================================
# Outputs
# ==========================================

output "vm_ids" {
  description = "Provisioned VM IDs"

  value = {
    for name, vm in proxmox_virtual_environment_vm.vm :
    name => vm.vm_id
  }
}

output "total_vms" {
  value = length(local.vm_instances)
}

output "total_vcpus" {
  value = sum([
    for vm in local.vm_instances : vm.cpu
  ])
}

output "total_memory_gb" {
  value = sum([
    for vm in local.vm_instances : vm.ram_gb
  ])
}

output "total_disk_gb" {
  value = sum([
    for vm in local.vm_instances : vm.disk_gb
  ])
}
