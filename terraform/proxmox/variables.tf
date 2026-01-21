variable "proxmox_endpoint" {
  description = "Proxmox API endpoint URL"
  type        = string
  # Example: "https://192.168.30.10:8006/api2/json"
}

variable "proxmox_username" {
  description = "Proxmox username (e.g., root@pam)"
  type        = string
  default     = "root@pam"
}

variable "proxmox_password" {
  description = "Proxmox password (use API token instead for production)"
  type        = string
  sensitive   = true
  default     = null
}

variable "proxmox_node" {
  description = "Proxmox node name"
  type        = string
  # Example: "pve"
}

variable "vm_id" {
  description = "VM ID for the Talos node"
  type        = number
  default     = 200
}

variable "vm_name" {
  description = "VM name"
  type        = string
  default     = "talos-homelab"
}

variable "vm_cores" {
  description = "Number of CPU cores"
  type        = number
  default     = 4
}

variable "vm_memory" {
  description = "Memory in MB"
  type        = number
  default     = 12288
}

variable "vm_disk_size" {
  description = "Disk size in GB"
  type        = number
  default     = 100
}

variable "vm_storage" {
  description = "Storage pool for VM disk"
  type        = string
  default     = "local-lvm"
}

variable "vm_bridge" {
  description = "Network bridge"
  type        = string
  default     = "vmbr0"
}

variable "vm_vlan_tag" {
  description = "VLAN tag (set to -1 for no VLAN)"
  type        = number
  default     = 30
}

variable "talos_iso_path" {
  description = "Path to Talos ISO on Proxmox storage (e.g., local:iso/talos-v1.12.1-amd64.iso). ISO must be pre-uploaded."
  type        = string
  default     = "local:iso/talos-v1.12.1-amd64.iso"
}
