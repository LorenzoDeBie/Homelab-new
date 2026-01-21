output "vm_id" {
  description = "The VM ID"
  value       = proxmox_vm_qemu.talos.vmid
}

output "vm_name" {
  description = "The VM name"
  value       = proxmox_vm_qemu.talos.name
}

output "vm_node" {
  description = "The Proxmox node the VM is running on"
  value       = proxmox_vm_qemu.talos.target_node
}
