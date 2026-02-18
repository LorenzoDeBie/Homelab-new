output "worker_vm_ids" {
  description = "Worker VM IDs keyed by worker name"
  value       = { for name, vm in proxmox_vm_qemu.talos_workers : name => vm.vmid }
}

output "worker_vm_nodes" {
  description = "Worker target nodes keyed by worker name"
  value       = { for name, vm in proxmox_vm_qemu.talos_workers : name => vm.target_node }
}

output "control_plane_vm_ids" {
  description = "Additional control plane VM IDs keyed by name"
  value       = { for name, vm in proxmox_vm_qemu.talos_control_planes : name => vm.vmid }
}

output "control_plane_vm_nodes" {
  description = "Additional control plane target nodes keyed by name"
  value       = { for name, vm in proxmox_vm_qemu.talos_control_planes : name => vm.target_node }
}
