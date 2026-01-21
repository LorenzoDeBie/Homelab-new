provider "proxmox" {
  pm_api_url          = var.proxmox_endpoint
  pm_tls_insecure     = true # Set to false if you have valid SSL certs
}

# Talos VM
# Note: Telmate/proxmox doesn't support downloading ISOs directly.
# The ISO must be pre-uploaded to Proxmox storage.
# Upload the Talos ISO to your Proxmox node before running terraform apply.
resource "proxmox_vm_qemu" "talos" {
  name        = var.vm_name
  target_node = var.proxmox_node
  vmid        = var.vm_id

  description = "Talos Linux - Single node Kubernetes cluster for homelab"
  tags        = "kubernetes,talos,homelab"

  # Boot from disk first, then ISO
  boot = "order=scsi0;ide2"

  # QEMU Guest Agent - Talos doesn't support it
  agent = 0

  # CPU Configuration
  cpu {
    cores   = var.vm_cores
    sockets = 1
    type    = "x86-64-v2-AES"
  }

  # Memory Configuration
  memory = var.vm_memory

  # Enable UEFI boot
  bios = "ovmf"

  # EFI disk for UEFI boot
  efidisk {
    storage = var.vm_storage
    efitype = "4m"
  }

  # Main disk
  disks {
    scsi {
      scsi0 {
        disk {
          storage    = var.vm_storage
          size       = var.vm_disk_size
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
    bridge = var.vm_bridge
    model  = "virtio"
    tag    = var.vm_vlan_tag
  }

  # Operating System
  os_type = "l26" # Linux 2.6+ kernel

  # SCSI Controller
  scsihw = "virtio-scsi-single"

  # Start the VM after creation
  vm_state = "running"
}
