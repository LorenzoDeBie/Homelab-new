terraform {
  # >= 1.3 for optional() attributes in object type constraints
  required_version = ">= 1.3"

  required_providers {
    proxmox = {
      source  = "Telmate/proxmox"
      version = "3.0.2-rc09"
    }
  }
}
