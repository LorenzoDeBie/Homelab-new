# Homelab Kubernetes Documentation

This documentation covers the complete setup and operation of a single-node Kubernetes cluster running on Talos Linux, managed with GitOps principles using ArgoCD.

## Architecture Overview

```
                                    +------------------+
                                    |    Cloudflare    |
                                    |    (DNS + CDN)   |
                                    +--------+---------+
                                             |
                              +--------------+--------------+
                              |                             |
                    +---------v---------+         +---------v---------+
                    | Cloudflare Tunnel |         |     Tailscale     |
                    | (Public Access)   |         | (Private Access)  |
                    +---------+---------+         +---------+---------+
                              |                             |
                              +-------------+---------------+
                                            |
+-----------------------------------------------------------------------------------+
|  Proxmox Host                             |                                       |
|  +--------------------------------------------------------------------------------+
|  |  Talos Linux VM (192.168.30.50)       |                                       |
|  |  CPU: 6 cores | RAM: 16GB | Disk: 100GB                                       |
|  |  +----------------------------------------------------------------------------+
|  |  |  Kubernetes Cluster                |                                       |
|  |  |                                    v                                       |
|  |  |  +------------------+    +------------------+    +------------------+      |
|  |  |  |     Cilium       |    |     ArgoCD       |    |  cert-manager    |      |
|  |  |  | (CNI + Gateway)  |    | (GitOps + SOPS)  |    | (TLS Certs)      |      |
|  |  |  +------------------+    +------------------+    +------------------+      |
|  |  |                                                                            |
|  |  |  +------------------+    +------------------+    +------------------+      |
|  |  |  |    Authentik     |    |   Media Stack    |    |  Observability   |      |
|  |  |  |     (SSO)        |    | Plex, Sonarr,    |    | Prometheus,      |      |
|  |  |  |                  |    | Radarr, etc.     |    | Grafana, Loki    |      |
|  |  |  +------------------+    +------------------+    +------------------+      |
|  |  +----------------------------------------------------------------------------+
|  +--------------------------------------------------------------------------------+
|                                                                                   |
|  +--------------------+                                                           |
|  |   Pi-hole LXC      |                                                           |
|  |   192.168.30.45    |                                                           |
|  +--------------------+                                                           |
+-----------------------------------------------------------------------------------+
        |
        | NFS (192.168.30.0/24)
        v
+------------------+
|    TrueNAS       |
| - /media         |
| - /k8s-config    |
+------------------+
```

## Component Summary

| Component | Purpose | Version |
|-----------|---------|---------|
| Talos Linux | Immutable Kubernetes OS | v1.9.1 |
| Kubernetes | Container orchestration | v1.32.0 |
| Cilium | CNI, Gateway API, L2 LoadBalancer | 1.16.5 |
| ArgoCD | GitOps continuous delivery | Latest |
| cert-manager | TLS certificate management | v1.16.2 |
| NFS CSI Driver | Dynamic storage provisioning | Latest |
| Cloudflare Tunnel | Zero-trust public access | 0.3.1 |
| Tailscale Operator | Private mesh VPN access | 1.78.1 |
| Authentik | SSO/Identity provider | 2024.10.4 |
| Prometheus Stack | Metrics collection | 67.4.0 |
| Loki | Log aggregation | 6.21.0 |

## Quick Links

| Document | Description |
|----------|-------------|
| [Prerequisites](prerequisites.md) | Tools and accounts needed before starting |
| [Installation](installation.md) | Step-by-step installation guide |
| [Architecture](architecture.md) | Detailed architecture documentation |
| [Configuration](configuration.md) | Configuration reference and customization |
| [Secrets](secrets.md) | SOPS encryption and secret management |
| [Networking](networking.md) | Network configuration deep dive |
| [Storage](storage.md) | NFS storage setup and management |
| [Applications](applications.md) | Application-specific documentation |
| [Observability](observability.md) | Monitoring and logging setup |
| [Maintenance](maintenance.md) | Ongoing maintenance procedures |
| [Troubleshooting](troubleshooting.md) | Common issues and solutions |

## Network Quick Reference

| Resource | IP Address | Notes |
|----------|------------|-------|
| Talos Node | 192.168.30.50 | Kubernetes control plane + worker |
| Gateway | 192.168.30.1 | Network gateway |
| Pi-hole DNS | 192.168.30.45 | Local DNS resolver |
| Internal Gateway LB | 192.168.30.61 | Gateway API endpoint |
| Plex LoadBalancer | 192.168.30.62 | Direct Plex access |
| qBittorrent BT | 192.168.30.63 | BitTorrent traffic |
| LoadBalancer Pool | 192.168.30.60-80 | Available IPs |

## Domain Quick Reference

| Type | Domain | Access Method |
|------|--------|---------------|
| Public | `plex.lorenzodebie.be` | Cloudflare Tunnel |
| Public | `requests.lorenzodebie.be` | Cloudflare Tunnel (Overseerr) |
| Internal | `*.int.lorenzodebie.be` | Gateway API + Tailscale |

## Getting Started

1. **New Installation**: Start with [Prerequisites](prerequisites.md), then follow [Installation](installation.md)
2. **Understanding the Setup**: Read [Architecture](architecture.md) for a complete overview
3. **Day-to-Day Operations**: See [Maintenance](maintenance.md) for upgrades and backups
4. **Having Issues**: Check [Troubleshooting](troubleshooting.md) for common problems

## Repository Structure

```
homelab-new/
├── terraform/proxmox/          # Terraform for Proxmox VM provisioning
├── talos/                      # Talos configuration (talhelper)
│   └── talconfig.yaml          # Talos cluster configuration
├── kubernetes/
│   ├── bootstrap/
│   │   ├── argocd/             # ArgoCD bootstrap configuration
│   │   └── sops/               # SOPS setup documentation
│   ├── core/                   # Core infrastructure
│   │   ├── argocd-apps.yaml    # Root App-of-Apps
│   │   ├── cilium/             # CNI and networking
│   │   ├── cert-manager/       # TLS certificates
│   │   ├── nfs-csi/            # Storage provisioner
│   │   ├── gateway-api/        # Gateway configuration
│   │   ├── cloudflared/        # Cloudflare Tunnel
│   │   ├── tailscale-operator/ # Tailscale VPN
│   │   └── authentik/          # SSO/Identity
│   ├── apps/
│   │   └── media/              # Media applications
│   └── observability/          # Monitoring stack
├── docs/                       # This documentation
├── .sops.yaml                  # SOPS configuration
└── README.md                   # Project overview
```

## Design Principles

This homelab follows several key design principles:

1. **GitOps**: All configuration is stored in Git; ArgoCD ensures the cluster matches the repository state
2. **Immutable Infrastructure**: Talos Linux provides an immutable, API-driven operating system
3. **Zero-Trust Access**: Public services use Cloudflare Tunnel; private services require Tailscale authentication
4. **Declarative Configuration**: Everything is defined in YAML manifests
5. **Secrets Encryption**: All secrets are encrypted with SOPS+age before committing to Git
6. **Single Source of Truth**: The Git repository is the authoritative source for cluster state
