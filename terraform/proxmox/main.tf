provider "proxmox" {
  pm_api_url      = var.proxmox_endpoint
  pm_tls_insecure = true # Set to false if you have valid SSL certs
}

# Talos control plane VMs
resource "proxmox_vm_qemu" "talos_control_planes" {
  for_each = var.control_plane_nodes

  name        = each.value.vm_name
  target_node = each.value.proxmox_node
  vmid        = each.value.vm_id

  description = "Talos Linux - Kubernetes control plane node for homelab"
  tags        = "kubernetes,talos,homelab,control-plane"

  # Boot from disk first, then ISO
  boot = "order=scsi0;ide2"

  # QEMU Guest Agent - Talos doesn't support it
  agent = 0

  # CPU Configuration
  cpu {
    cores   = each.value.vm_cores
    sockets = 1
    type    = "x86-64-v2-AES"
  }

  # Memory Configuration
  memory = each.value.vm_memory

  # Enable UEFI boot
  bios = "ovmf"

  # EFI disk for UEFI boot
  efidisk {
    storage = each.value.vm_storage
    efitype = "4m"
  }

  # Main disk
  disks {
    scsi {
      scsi0 {
        disk {
          storage    = each.value.vm_storage
          size       = each.value.vm_disk_size
          format     = "raw"
          discard    = true
          emulatessd = true
        }
      }
    }
    ide {
      ide2 {
        cdrom {
          iso = var.talos_iso_path
        }
      }
    }
  }

  # Network Configuration
  network {
    id     = 0
    bridge = each.value.vm_bridge
    model  = "virtio"
    tag    = each.value.vm_vlan_tag
  }

  # Operating System
  os_type = "l26" # Linux 2.6+ kernel

  # SCSI Controller
  scsihw = "virtio-scsi-single"

  # Start the VM after creation
  vm_state = "running"
}

# Talos worker VMs
resource "proxmox_vm_qemu" "talos_workers" {
  for_each = var.worker_nodes

  name        = each.value.vm_name
  target_node = each.value.proxmox_node
  vmid        = each.value.vm_id

  description = "Talos Linux - Kubernetes worker node for homelab"
  tags        = "kubernetes,talos,homelab,worker"

  # Boot from disk first, then ISO
  boot = "order=scsi0;ide2"

  # QEMU Guest Agent - Talos doesn't support it
  agent = 0

  # CPU Configuration
  cpu {
    cores   = each.value.vm_cores
    sockets = 1
    type    = "x86-64-v2-AES"
  }

  # Memory Configuration
  memory = each.value.vm_memory

  # Enable UEFI boot
  bios = "ovmf"

  # EFI disk for UEFI boot
  efidisk {
    storage = each.value.vm_storage
    efitype = "4m"
  }

  # Main disk
  disks {
    scsi {
      scsi0 {
        disk {
          storage    = each.value.vm_storage
          size       = each.value.vm_disk_size
          format     = "raw"
          discard    = true
          emulatessd = true
        }
      }
    }
    ide {
      ide2 {
        cdrom {
          iso = var.talos_iso_path
        }
      }
    }
  }

  # Network Configuration
  network {
    id     = 0
    bridge = each.value.vm_bridge
    model  = "virtio"
    tag    = each.value.vm_vlan_tag
  }

  # Operating System
  os_type = "l26" # Linux 2.6+ kernel

  # SCSI Controller
  scsihw = "virtio-scsi-single"

  # Start the VM after creation
  vm_state = "running"
}
