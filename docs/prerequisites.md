# Prerequisites

This document covers everything you need before starting the homelab Kubernetes installation.

## Table of Contents

- [Required Tools](#required-tools)
- [Account Setup](#account-setup)
- [Infrastructure Requirements](#infrastructure-requirements)
- [TrueNAS Configuration](#truenas-configuration)
- [Proxmox Configuration](#proxmox-configuration)
- [Network Planning](#network-planning)

## Required Tools

Install all required CLI tools on your workstation.

### macOS (using Homebrew)

```bash
# Core tools
brew install terraform
brew install talosctl
brew install talhelper
brew install kubectl
brew install helm
brew install argocd

# Secrets management
brew install sops
brew install age

# Optional but recommended
brew install k9s              # Terminal UI for Kubernetes
brew install cloudflared      # Cloudflare Tunnel CLI
```

### Linux (Debian/Ubuntu)

```bash
# Terraform
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform

# talosctl
curl -sL https://talos.dev/install | sh

# talhelper
curl -sLO https://github.com/budimanjojo/talhelper/releases/latest/download/talhelper_linux_amd64.tar.gz
tar xzf talhelper_linux_amd64.tar.gz
sudo mv talhelper /usr/local/bin/

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# argocd CLI
curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
sudo install -m 555 argocd /usr/local/bin/argocd

# sops
curl -LO https://github.com/getsops/sops/releases/latest/download/sops-v3.9.0.linux.amd64
sudo mv sops-v3.9.0.linux.amd64 /usr/local/bin/sops
sudo chmod +x /usr/local/bin/sops

# age
sudo apt install age
```

### Verify Installations

```bash
# Run these commands to verify all tools are installed
terraform version
talosctl version --client
talhelper --version
kubectl version --client
helm version
argocd version --client
sops --version
age --version
```

Expected output (versions may vary):

```
Terraform v1.9.x
Client:
    Tag:         v1.9.1
talhelper version x.x.x
Client Version: v1.32.x
version.BuildInfo{Version:"v3.x.x"}
argocd: v2.x.x
sops 3.9.0
v1.2.0
```

## Account Setup

### Cloudflare Account

Cloudflare is used for DNS management, TLS certificates (DNS challenge), and Tunnel for public access.

1. **Create Account**: Sign up at [cloudflare.com](https://cloudflare.com) (free tier is sufficient)

2. **Add Your Domain**:
   - Go to "Add a Site" and enter your domain
   - Follow the instructions to update your domain's nameservers
   - Wait for DNS propagation (can take up to 24 hours)

3. **Create API Token**:
   - Go to Profile > API Tokens > Create Token
   - Use "Edit zone DNS" template
   - Configure permissions:
     - Zone > Zone > Read
     - Zone > DNS > Edit
   - Zone Resources: Include > Specific zone > your domain
   - Create and save the token securely

4. **Note Your Zone ID**:
   - Go to your domain's overview page
   - Copy the Zone ID from the right sidebar

### Tailscale Account

Tailscale provides private mesh VPN access to internal services.

1. **Create Account**: Sign up at [tailscale.com](https://tailscale.com) (free for personal use)

2. **Install Tailscale** on your devices:
   - Follow instructions at [tailscale.com/download](https://tailscale.com/download)

3. **Create OAuth Client**:
   - Go to Settings > OAuth clients
   - Click "Generate OAuth client"
   - Description: "Kubernetes Operator"
   - Scopes: Select the following:
     - `devices:read`
     - `devices:write`
   - Tags: `tag:k8s` (create the tag if needed)
   - Save the Client ID and Client Secret securely

4. **Configure ACLs** (optional but recommended):
   - Go to Access Controls
   - Add tags and rules for your Kubernetes services

## Infrastructure Requirements

### Proxmox Host

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| CPU | 4 cores | 8+ cores |
| RAM | 16GB | 32GB |
| Storage | 100GB SSD | 200GB+ NVMe |
| Network | 1Gbps | 1Gbps+ |

The Talos VM will use:
- 6 CPU cores
- 16GB RAM
- 100GB disk

### TrueNAS Server

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| RAM | 16GB | 32GB+ |
| Storage | 4TB usable | 10TB+ usable |
| Network | 1Gbps | 10Gbps |

TrueNAS provides NFS storage for:
- Media files (TV shows, movies)
- Application configuration data

### Network

- Dedicated VLAN recommended (e.g., 192.168.30.0/24)
- Static IP for Talos VM
- Pi-hole or other DNS server for internal resolution
- Router capable of VLAN tagging (if using VLANs)

## TrueNAS Configuration

### Create Datasets

1. **Create Media Dataset**:
   ```
   Pool > Add Dataset
   Name: media
   Compression: lz4
   Sync: Standard
   ```

2. **Create Kubernetes Config Dataset**:
   ```
   Pool > Add Dataset
   Name: k8s-config
   Compression: lz4
   Sync: Standard
   ```

### Configure NFS Shares

1. **Enable NFS Service**:
   - Services > NFS > Enable
   - Settings:
     - Number of servers: 4
     - Enable NFSv4: Yes

2. **Create Media Share**:
   ```
   Shares > NFS > Add
   Path: /mnt/<pool>/media
   Maproot User: root
   Maproot Group: wheel
   Enabled: Yes
   Networks: 192.168.30.0/24
   ```

3. **Create Config Share**:
   ```
   Shares > NFS > Add
   Path: /mnt/<pool>/k8s-config
   Maproot User: root
   Maproot Group: wheel
   Enabled: Yes
   Networks: 192.168.30.0/24
   ```

### Set Permissions

```bash
# On TrueNAS shell or via SSH
chmod 777 /mnt/<pool>/media
chmod 777 /mnt/<pool>/k8s-config
```

### Verify NFS

From your workstation (or Proxmox host):

```bash
# Test mounting the share
sudo mount -t nfs <truenas-ip>:/mnt/<pool>/media /mnt/test
ls /mnt/test
sudo umount /mnt/test
```

## Proxmox Configuration

### Create API Token (Recommended)

Using API tokens is more secure than username/password authentication.

1. **Create Terraform User**:
   ```bash
   # SSH to Proxmox host
   pveum user add terraform@pve
   ```

2. **Create Role**:
   ```bash
   pveum role add TerraformRole -privs "Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit Pool.Allocate Sys.Audit Sys.Console Sys.Modify SDN.Use VM.Allocate VM.Audit VM.Clone VM.Config.CDROM VM.Config.Cloudinit VM.Config.CPU VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.Migrate VM.Monitor VM.PowerMgmt"
   ```

3. **Assign Role to User**:
   ```bash
   pveum aclmod / -user terraform@pve -role TerraformRole
   ```

4. **Create API Token**:
   ```bash
   pveum user token add terraform@pve terraform -privsep=0
   ```

5. **Save the Output**:
   ```
   Token ID: terraform@pve!terraform
   Token Secret: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   ```

### Prepare ISO Storage

Ensure you have an ISO storage location configured:

1. **Verify Local Storage**:
   - Datacenter > Storage > local
   - Content should include "ISO image"

2. **Or Create Dedicated Storage**:
   - Datacenter > Storage > Add > Directory
   - ID: iso-storage
   - Directory: /var/lib/vz/template/iso
   - Content: ISO image

### Network Configuration

If using VLANs:

1. **Create VLAN-aware Bridge** (if not exists):
   - Node > System > Network
   - Create > Linux Bridge
   - Name: vmbr0
   - VLAN aware: Yes
   - Bridge ports: (your physical NIC)

## Network Planning

### IP Address Allocation

Plan your IP allocations before starting:

| IP Address | Purpose | Notes |
|------------|---------|-------|
| 192.168.30.1 | Gateway | Router/firewall |
| 192.168.30.45 | Pi-hole | DNS resolver |
| 192.168.30.50 | Talos Node | Kubernetes |
| 192.168.30.60-80 | LoadBalancer Pool | Cilium L2 announcements |
| 192.168.30.61 | Internal Gateway | Gateway API endpoint |
| 192.168.30.62 | Plex | Direct access |
| 192.168.30.63 | qBittorrent | BitTorrent traffic |

### DNS Records

You will need to configure these DNS records:

**Cloudflare (Public)**:
| Record | Type | Value |
|--------|------|-------|
| plex.lorenzodebie.be | CNAME | `<tunnel-id>.cfargotunnel.com` |
| requests.lorenzodebie.be | CNAME | `<tunnel-id>.cfargotunnel.com` |

**Pi-hole (Internal)**:
| Record | Type | Value |
|--------|------|-------|
| *.int.lorenzodebie.be | A | 192.168.30.61 |
| talos.int.lorenzodebie.be | A | 192.168.30.50 |

## Pre-Installation Checklist

Before proceeding to installation, verify:

- [ ] All CLI tools installed and verified
- [ ] Cloudflare account created with domain added
- [ ] Cloudflare API token created and saved
- [ ] Tailscale account created
- [ ] Tailscale OAuth client created and credentials saved
- [ ] Proxmox host accessible
- [ ] Proxmox API token created (or have root credentials)
- [ ] TrueNAS datasets created
- [ ] TrueNAS NFS shares configured
- [ ] Network IP addresses planned
- [ ] Router/firewall rules configured for the VLAN

## Next Steps

Once all prerequisites are complete, proceed to [Installation](installation.md).
