# Configuration Reference

This document provides a comprehensive reference for all configurable values in the homelab setup, including where to find them and how to modify them.

## Table of Contents

- [Configuration Files Overview](#configuration-files-overview)
- [IP Address Allocations](#ip-address-allocations)
- [Domain and Hostname Mappings](#domain-and-hostname-mappings)
- [Terraform Variables](#terraform-variables)
- [Talos Configuration](#talos-configuration)
- [Kubernetes Configuration](#kubernetes-configuration)
- [Application Configuration](#application-configuration)
- [Environment Variables](#environment-variables)

## Configuration Files Overview

| File | Purpose | Encryption |
|------|---------|------------|
| `terraform/proxmox/terraform.tfvars` | Proxmox and VM settings | No (gitignored) |
| `talos/talconfig.yaml` | Talos cluster configuration | No |
| `.sops.yaml` | SOPS encryption rules | No |
| `kubernetes/bootstrap/argocd/values.yaml` | ArgoCD Helm values | No |
| `kubernetes/core/*/application.yaml` | ArgoCD Application definitions | No |
| `kubernetes/core/*/*.sops.yaml` | Encrypted secrets | Yes |

## IP Address Allocations

### Network Overview

| Setting | Value |
|---------|-------|
| Network | 192.168.30.0/24 |
| VLAN ID | 30 |
| Gateway | 192.168.30.1 |
| Subnet Mask | 255.255.255.0 (/24) |

### Static Allocations

| IP Address | Hostname | Purpose | Configured In |
|------------|----------|---------|---------------|
| 192.168.30.1 | gateway | Network gateway/router | Router |
| 192.168.30.10 | proxmox | Proxmox host | Proxmox |
| 192.168.30.45 | pihole | Pi-hole DNS | Proxmox LXC |
| 192.168.30.50 | talos-cp01 | Talos Kubernetes node | `talos/talconfig.yaml` |

### Kubernetes LoadBalancer Pool

Configured in `kubernetes/core/cilium/l2-announcement.yaml`:

| IP Address | Service | Configured In |
|------------|---------|---------------|
| 192.168.30.60 | Pool start | `l2-announcement.yaml` |
| 192.168.30.61 | Internal Gateway | `gateway-api/gateway.yaml` |
| 192.168.30.62 | Plex | `apps/media/plex/application.yaml` |
| 192.168.30.63 | qBittorrent BT | `apps/media/qbittorrent/application.yaml` |
| 192.168.30.64-80 | Available | Auto-assigned |

### Modifying IP Allocations

**To change the Talos node IP**:
```yaml
# talos/talconfig.yaml
nodes:
  - hostname: talos-cp01
    ipAddress: 192.168.30.50  # Change this
    networkInterfaces:
      - addresses:
          - 192.168.30.50/24  # And this
        routes:
          - network: 0.0.0.0/0
            gateway: 192.168.30.1  # And gateway if needed
```

**To change the LoadBalancer pool**:
```yaml
# kubernetes/core/cilium/l2-announcement.yaml
spec:
  blocks:
    - start: 192.168.30.60  # Change pool range
      stop: 192.168.30.80
```

**To change a service's LoadBalancer IP**:
```yaml
# In the application's service definition
metadata:
  annotations:
    io.cilium/lb-ipam-ips: "192.168.30.62"  # Specific IP from pool
```

## Domain and Hostname Mappings

### Public Domains

| Domain | Service | Access Method | Configured In |
|--------|---------|---------------|---------------|
| lorenzodebie.be | Root domain | Cloudflare | Cloudflare Dashboard |
| plex.lorenzodebie.be | Plex | Cloudflare Tunnel | `cloudflared/application.yaml` |
| requests.lorenzodebie.be | Overseerr | Cloudflare Tunnel | `cloudflared/application.yaml` |

### Internal Domains

| Domain | Service | IP Target | Configured In |
|--------|---------|-----------|---------------|
| *.int.lorenzodebie.be | Wildcard | 192.168.30.61 | Pi-hole + Gateway |
| argocd.int.lorenzodebie.be | ArgoCD | 192.168.30.61 | HTTPRoute |
| grafana.int.lorenzodebie.be | Grafana | 192.168.30.61 | HTTPRoute |
| sonarr.int.lorenzodebie.be | Sonarr | 192.168.30.61 | HTTPRoute |
| radarr.int.lorenzodebie.be | Radarr | 192.168.30.61 | HTTPRoute |
| prowlarr.int.lorenzodebie.be | Prowlarr | 192.168.30.61 | HTTPRoute |
| qbittorrent.int.lorenzodebie.be | qBittorrent | 192.168.30.61 | HTTPRoute |
| auth.int.lorenzodebie.be | Authentik | 192.168.30.61 | HTTPRoute |
| talos.int.lorenzodebie.be | Talos API | 192.168.30.50 | Direct |

### Modifying Domains

**To change the base domain**:

1. Update Cloudflare DNS configuration
2. Update cert-manager ClusterIssuer:
   ```yaml
   # kubernetes/core/cert-manager/clusterissuer.yaml
   selector:
     dnsZones:
       - lorenzodebie.be  # Your domain
   ```
3. Update Gateway hostnames:
   ```yaml
   # kubernetes/core/gateway-api/gateway.yaml
   listeners:
     - hostname: "*.int.lorenzodebie.be"  # Your internal domain
   ```
4. Update Certificate:
   ```yaml
   # kubernetes/core/gateway-api/internal-certificate.yaml
   dnsNames:
     - "*.int.lorenzodebie.be"
     - "int.lorenzodebie.be"
   ```
5. Update all HTTPRoute hostnames

## Terraform Variables

### File: `terraform/proxmox/terraform.tfvars`

| Variable | Default | Description |
|----------|---------|-------------|
| `proxmox_endpoint` | - | Proxmox API URL (e.g., `https://192.168.30.10:8006`) |
| `proxmox_node` | - | Proxmox node name (e.g., `pve`) |
| `proxmox_username` | `root@pam` | Proxmox username |
| `proxmox_password` | - | Proxmox password (or use API token) |
| `proxmox_api_token` | - | Proxmox API token (recommended) |
| `vm_id` | `200` | VM ID for Talos |
| `vm_name` | `talos-homelab` | VM name |
| `vm_cores` | `6` | CPU cores |
| `vm_memory` | `16384` | RAM in MB (16GB) |
| `vm_disk_size` | `100` | Disk size in GB |
| `vm_storage` | `local-lvm` | Proxmox storage pool |
| `vm_bridge` | `vmbr0` | Network bridge |
| `vm_vlan_tag` | `30` | VLAN tag (null for no VLAN) |
| `talos_iso_url` | - | Talos ISO download URL |
| `talos_iso_storage` | `local` | Storage for ISO |

### Example Configuration

```hcl
# terraform/proxmox/terraform.tfvars

proxmox_endpoint  = "https://192.168.30.10:8006"
proxmox_node      = "pve"
proxmox_api_token = "terraform@pve!terraform=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

vm_id        = 200
vm_name      = "talos-homelab"
vm_cores     = 6
vm_memory    = 16384
vm_disk_size = 100
vm_storage   = "local-lvm"
vm_bridge    = "vmbr0"
vm_vlan_tag  = 30

talos_iso_url     = "https://factory.talos.dev/image/xxxxx/v1.9.1/metal-amd64.iso"
talos_iso_storage = "local"
```

## Talos Configuration

### File: `talos/talconfig.yaml`

| Setting | Value | Description |
|---------|-------|-------------|
| `clusterName` | `homelab` | Kubernetes cluster name |
| `talosVersion` | `v1.9.1` | Talos Linux version |
| `kubernetesVersion` | `v1.32.0` | Kubernetes version |
| `endpoint` | `https://192.168.30.50:6443` | Kubernetes API endpoint |
| `allowSchedulingOnControlPlanes` | `true` | Allow pods on control plane |

### Node Configuration

```yaml
nodes:
  - hostname: talos-cp01
    ipAddress: 192.168.30.50
    installDisk: /dev/sda
    controlPlane: true
    networkInterfaces:
      - deviceSelector:
          busPath: "0*"
        dhcp: false
        addresses:
          - 192.168.30.50/24
        routes:
          - network: 0.0.0.0/0
            gateway: 192.168.30.1
        mtu: 1500
```

### Important Patches

| Patch | Purpose |
|-------|---------|
| `cluster.network.cni.name: none` | Disable default CNI (using Cilium) |
| `cluster.proxy.disabled: true` | Disable kube-proxy (Cilium replaces it) |
| `machine.network.nameservers` | Set DNS to Pi-hole |
| `machine.kubelet.extraMounts` | Mount `/var/mnt` for NFS |

## Kubernetes Configuration

### ArgoCD Configuration

**File**: `kubernetes/bootstrap/argocd/values.yaml`

Key settings:

```yaml
global:
  domain: argocd.int.lorenzodebie.be

configs:
  params:
    server.insecure: true  # TLS terminated at Gateway

repoServer:
  env:
    - name: SOPS_AGE_KEY_FILE
      value: /home/argocd/.config/sops/age/keys.txt
```

### Cilium Configuration

**File**: `kubernetes/core/cilium/application.yaml`

| Setting | Value | Purpose |
|---------|-------|---------|
| `ipam.mode` | `kubernetes` | Use Kubernetes IPAM |
| `kubeProxyReplacement` | `true` | Replace kube-proxy |
| `gatewayAPI.enabled` | `true` | Enable Gateway API |
| `l2announcements.enabled` | `true` | Enable L2 LoadBalancer |
| `hubble.enabled` | `true` | Enable observability |

### Storage Configuration

**File**: `kubernetes/core/nfs-csi/storageclass.yaml`

Update these placeholders:

```yaml
parameters:
  server: TRUENAS_IP        # e.g., 192.168.30.20
  share: /mnt/POOL_NAME/media  # e.g., /mnt/tank/media
```

## Application Configuration

### Media Applications

| Application | Port | Config Path | Media Path |
|-------------|------|-------------|------------|
| Plex | 32400 | /config | /media (read-only) |
| Sonarr | 8989 | /config | /media |
| Radarr | 7878 | /config | /media |
| Prowlarr | 9696 | /config | - |
| qBittorrent | 8080 | /config | /media |
| Overseerr | 5055 | /config | - |

### Observability

| Application | Port | Retention |
|-------------|------|-----------|
| Prometheus | 9090 | 30 days / 50GB |
| Grafana | 3000 | Persistent |
| Loki | 3100 | 30 days |

## Environment Variables

### Plex

```yaml
env:
  TZ: Europe/Brussels
  PLEX_ADVERTISE_URL: https://plex.lorenzodebie.be:443
  PLEX_NO_AUTH_NETWORKS: 192.168.0.0/16
```

### Sonarr/Radarr

```yaml
env:
  TZ: Europe/Brussels
  SONARR__AUTH__METHOD: External
  SONARR__AUTH__REQUIRED: DisabledForLocalAddresses
```

### Authentik

Set via SOPS-encrypted secret:

| Variable | Purpose |
|----------|---------|
| `AUTHENTIK_SECRET_KEY` | Application secret |
| `AUTHENTIK_POSTGRESQL__PASSWORD` | Database password |
| `AUTHENTIK_BOOTSTRAP_PASSWORD` | Initial admin password |
| `AUTHENTIK_BOOTSTRAP_EMAIL` | Admin email |

## Configuration Checklist

When setting up a new installation, update these files:

### Required Changes

- [ ] `.sops.yaml` - Add your age public key
- [ ] `terraform/proxmox/terraform.tfvars` - Proxmox settings
- [ ] `talos/talconfig.yaml` - Verify IP addresses
- [ ] `kubernetes/core/nfs-csi/storageclass.yaml` - TrueNAS IP and pool
- [ ] `kubernetes/core/cert-manager/clusterissuer.yaml` - Your email
- [ ] `kubernetes/core/argocd-apps.yaml` - Your Git repository URL
- [ ] All `*.sops.yaml` files - Your actual secrets

### Optional Changes

- [ ] `kubernetes/core/cilium/l2-announcement.yaml` - IP pool range
- [ ] `kubernetes/core/gateway-api/gateway.yaml` - Internal domain
- [ ] HTTPRoute files - Service hostnames
- [ ] Application resource limits

## Applying Configuration Changes

### Terraform Changes

```bash
cd terraform/proxmox
terraform plan
terraform apply
```

### Talos Changes

```bash
cd talos
talhelper genconfig
talosctl --nodes 192.168.30.50 apply-config --file clusterconfig/homelab-talos-cp01.yaml
```

### Kubernetes Changes

Most changes are applied automatically by ArgoCD when pushed to Git.

For manual application:

```bash
kubectl apply -f kubernetes/path/to/resource.yaml
```

### Secret Changes

```bash
# Decrypt, edit, re-encrypt
sops kubernetes/path/to/secret.sops.yaml

# Or decrypt to edit
sops --decrypt kubernetes/path/to/secret.sops.yaml > /tmp/secret.yaml
# Edit /tmp/secret.yaml
sops --encrypt /tmp/secret.yaml > kubernetes/path/to/secret.sops.yaml
rm /tmp/secret.yaml

# Commit and push
git add -A
git commit -m "Update secrets"
git push
```
