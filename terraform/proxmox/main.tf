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

  # QEMU Guest Agent - provided by the siderolabs/qemu-guest-agent extension
  # in talos/talconfig.yaml
  agent = 1

  # These VMs are IPv4-only on VLAN 40. Without this the provider stalls on
  # every plan waiting for an IPv6 address that never arrives.
  skip_ipv6 = true

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

  # Start the VM after creation. power_state supersedes the deprecated vm_state.
  power_state = "running"

  lifecycle {
    ignore_changes = [
      disks["ide"],
      startup_shutdown
    ]
  }
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

  # QEMU Guest Agent - provided by the siderolabs/qemu-guest-agent extension
  # in talos/talconfig.yaml
  agent = 1

  # These VMs are IPv4-only on VLAN 40. Without this the provider stalls on
  # every plan waiting for an IPv6 address that never arrives.
  skip_ipv6 = true

  # Raw QEMU args. talos-wk01 needs the Intel IGD OpRegion flag for iGPU
  # passthrough; without it Plex loses hardware transcoding.
  args = each.value.vm_args

  # PCI passthrough. id = 0 corresponds to hostpci0, which is what vm_args
  # above refers to - the two must be set together or the VM will not start.
  dynamic "pci" {
    for_each = each.value.vm_hostpci != null ? [each.value.vm_hostpci] : []
    content {
      id     = 0
      raw_id = pci.value
      pcie   = true
    }
  }

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

  # Main disk, plus an optional data disk backing local-path-provisioner
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
      dynamic "scsi1" {
        for_each = each.value.vm_data_disk_size != null ? [1] : []
        content {
          disk {
            storage    = each.value.vm_data_storage
            size       = each.value.vm_data_disk_size
            format     = "raw"
            discard    = true
            emulatessd = true
          }
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

  # Start the VM after creation. power_state supersedes the deprecated vm_state.
  power_state = "running"

  lifecycle {
    ignore_changes = [
      disks["ide"],
      startup_shutdown
    ]
  }
}
