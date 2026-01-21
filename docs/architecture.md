# Architecture Documentation

This document provides a detailed overview of the homelab architecture, including component relationships, network topology, storage design, and GitOps workflow.

## Table of Contents

- [High-Level Architecture](#high-level-architecture)
- [Infrastructure Layer](#infrastructure-layer)
- [Kubernetes Cluster](#kubernetes-cluster)
- [Networking Architecture](#networking-architecture)
- [Storage Architecture](#storage-architecture)
- [GitOps Workflow](#gitops-workflow)
- [Access Patterns](#access-patterns)
- [Security Model](#security-model)

## High-Level Architecture

```
                                   Internet
                                      |
                    +----------------+----------------+
                    |                                 |
              Cloudflare CDN                    Tailscale VPN
              (DNS + Tunnel)                    (Mesh Network)
                    |                                 |
                    +----------------+----------------+
                                     |
                    +----------------v----------------+
                    |         Home Network            |
                    |        192.168.30.0/24          |
                    +----------------+----------------+
                                     |
          +--------------+-----------+-----------+--------------+
          |              |           |           |              |
     +----v----+   +-----v-----+ +---v---+ +-----v-----+  +-----v-----+
     | Router  |   |  Pi-hole  | | Talos | |  TrueNAS  |  |  Proxmox  |
     | Gateway |   |   (DNS)   | | (K8s) | |   (NFS)   |  |  (Host)   |
     | .30.1   |   |   .30.45  | | .30.50| |   .30.XX  |  |  .30.10   |
     +---------+   +-----------+ +---+---+ +-----------+  +-----------+
                                     |
                    +----------------v----------------+
                    |       Kubernetes Cluster        |
                    |                                 |
                    |  +---------+   +-----------+   |
                    |  | Cilium  |   |  ArgoCD   |   |
                    |  |  (CNI)  |   |  (GitOps) |   |
                    |  +---------+   +-----------+   |
                    |                                 |
                    |  +-----------------------------+|
                    |  |      Applications           ||
                    |  | Media | Auth | Observability||
                    |  +-----------------------------+|
                    +---------------------------------+
```

## Infrastructure Layer

### Proxmox Virtualization

Proxmox VE hosts the Talos virtual machine. Using virtualization provides:

- **Snapshot capability**: Easy rollback before upgrades
- **Resource flexibility**: Adjust CPU/RAM as needed
- **Isolation**: Kubernetes runs isolated from other workloads
- **Hardware abstraction**: Easier migration between physical hosts

**VM Specification**:
| Resource | Allocation |
|----------|------------|
| CPU | 6 cores (x86-64-v2-AES) |
| RAM | 16GB |
| Disk | 100GB (NVMe/SSD recommended) |
| Network | VLAN 30 (vmbr0) |
| Boot | UEFI (OVMF) |

### Talos Linux

Talos is an immutable, API-driven Linux distribution designed specifically for Kubernetes. Key characteristics:

- **No SSH**: System managed entirely via API
- **Immutable root**: OS is read-only, preventing drift
- **Minimal attack surface**: No shell, no package manager
- **Declarative configuration**: All settings in YAML
- **Secure by default**: Strong default security posture

**Why Talos over traditional distributions**:
1. Reduced operational overhead
2. Consistent, reproducible deployments
3. Automatic security hardening
4. Perfect for GitOps workflows

### TrueNAS Storage

TrueNAS provides enterprise-grade storage via NFS:

- **ZFS**: Data integrity, compression, snapshots
- **NFS exports**: Shared storage for Kubernetes
- **Separate concerns**: Storage managed independently from compute

## Kubernetes Cluster

### Cluster Configuration

Single-node cluster running both control plane and worker roles:

```yaml
Cluster: homelab
  Node: talos-cp01 (192.168.30.50)
    Roles: control-plane, worker
    Taints: none (allows workloads on control plane)
```

**Why single-node**:
- Homelab simplicity
- Reduced resource requirements
- Sufficient for personal use
- Can scale to multi-node later

### Component Stack

```
+------------------------------------------------------------------+
|                        Kubernetes Layer                           |
+------------------------------------------------------------------+
|                                                                   |
|  Core Platform                                                    |
|  +-------------------+  +-------------------+  +----------------+ |
|  |     Cilium        |  |    cert-manager   |  |   NFS CSI      | |
|  | CNI, Gateway API, |  | TLS certificates  |  | Storage driver | |
|  | L2 LoadBalancer   |  | Let's Encrypt     |  | TrueNAS        | |
|  +-------------------+  +-------------------+  +----------------+ |
|                                                                   |
|  Access Layer                                                     |
|  +-------------------+  +-------------------+  +----------------+ |
|  |   Cloudflare      |  |    Tailscale      |  |   Authentik    | |
|  |   Tunnel          |  |    Operator       |  |   SSO/IdP      | |
|  | Public access     |  | Private access    |  | Authentication | |
|  +-------------------+  +-------------------+  +----------------+ |
|                                                                   |
|  Applications                                                     |
|  +-------------------+  +-------------------+  +----------------+ |
|  |   Media Stack     |  |  Observability    |  |   (Future)     | |
|  | Plex, *arr apps   |  | Prometheus,       |  |                | |
|  | qBittorrent       |  | Grafana, Loki     |  |                | |
|  +-------------------+  +-------------------+  +----------------+ |
|                                                                   |
+------------------------------------------------------------------+
|                         ArgoCD (GitOps)                          |
+------------------------------------------------------------------+
```

### Namespace Organization

```
Namespaces:
├── kube-system        # Core Kubernetes + Cilium
├── argocd             # GitOps controller
├── cert-manager       # TLS certificate management
├── cloudflared        # Cloudflare Tunnel
├── tailscale          # Tailscale operator
├── authentik          # Identity provider
├── media              # Media applications
└── observability      # Monitoring stack
```

## Networking Architecture

### Network Topology

```
                          Internet
                             |
                    +--------v--------+
                    |    Cloudflare   |
                    |   (CDN + DNS)   |
                    +--------+--------+
                             |
                    +--------v--------+
                    |  Home Router    |
                    |  192.168.30.1   |
                    +--------+--------+
                             |
              +--------------+--------------+
              |                             |
     +--------v--------+           +--------v--------+
     |    Pi-hole      |           | Applications    |
     |  192.168.30.45  |           |     VLAN        |
     |   (DNS)         |           | 192.168.30.0/24 |
     +-----------------+           +--------+--------+
                                            |
                       +--------------------+--------------------+
                       |                    |                    |
              +--------v--------+  +--------v--------+  +--------v--------+
              |  Talos Node     |  | Internal GW LB  |  | LoadBalancer    |
              |  192.168.30.50  |  |  192.168.30.61  |  |    Pool         |
              |  (API Server)   |  | (Gateway API)   |  | .60-.80         |
              +-----------------+  +-----------------+  +-----------------+
```

### IP Address Allocation

| IP Range | Purpose |
|----------|---------|
| 192.168.30.1 | Network gateway |
| 192.168.30.10-49 | Infrastructure (Proxmox, TrueNAS, Pi-hole) |
| 192.168.30.50-59 | Kubernetes nodes |
| 192.168.30.60-80 | Kubernetes LoadBalancer pool |
| 192.168.30.81-254 | DHCP / other devices |

### Traffic Flow

**Public Access (Cloudflare Tunnel)**:
```
User -> Cloudflare Edge -> Cloudflare Tunnel -> cloudflared Pod -> Service
```

**Internal Access (Gateway API)**:
```
User -> Pi-hole DNS -> Internal Gateway (192.168.30.61) -> HTTPRoute -> Service
```

**Tailscale Access**:
```
User (Tailnet) -> Tailscale Proxy -> Service (via MagicDNS or exposed)
```

### Cilium Features Used

| Feature | Purpose |
|---------|---------|
| CNI | Pod networking |
| Gateway API | Ingress controller replacement |
| L2 Announcements | LoadBalancer IP advertisement |
| kube-proxy replacement | Improved performance |
| Hubble | Network observability |

## Storage Architecture

### Storage Topology

```
+------------------------------------------------------------------+
|                       TrueNAS Server                              |
|  +----------------------------+  +----------------------------+   |
|  |   Dataset: media           |  |   Dataset: k8s-config      |   |
|  |   /mnt/<pool>/media        |  |   /mnt/<pool>/k8s-config   |   |
|  |                            |  |                            |   |
|  |   ├── downloads/           |  |   ├── media/               |   |
|  |   │   ├── complete/        |  |   │   ├── sonarr/          |   |
|  |   │   └── incomplete/      |  |   │   ├── radarr/          |   |
|  |   ├── tv/                  |  |   │   └── prowlarr/        |   |
|  |   └── movies/              |  |   ├── observability/       |   |
|  |                            |  |   │   ├── prometheus/      |   |
|  |   (Single PV - hardlinks)  |  |   │   └── grafana/         |   |
|  +----------------------------+  |   └── authentik/           |   |
|                                  +----------------------------+   |
+------------------------------------------------------------------+
        |                                   |
        | NFS v4.1                          | NFS v4.1
        |                                   |
+-------v----------+               +--------v---------+
| PV: media-pv     |               | StorageClass:    |
| (Static)         |               | nfs-config       |
| ReadWriteMany    |               | (Dynamic)        |
+------------------+               +------------------+
        |                                   |
        v                                   v
+------------------+               +------------------+
| PVC: media       |               | PVCs per app     |
| namespace: media |               | (auto-created)   |
+------------------+               +------------------+
```

### Storage Classes

**nfs-media** (Static):
- Single PV shared by all media apps
- Enables hardlinks between downloads and library
- Critical for *arr apps to work correctly

**nfs-config** (Dynamic):
- Auto-provisions subdirectories per PVC
- Used for application configuration
- Each app gets isolated config storage

### Why Single Media PV

The *arr applications (Sonarr, Radarr, etc.) use hardlinks to:
1. Avoid duplicating data when files are moved
2. Enable instant "moves" without copying
3. Allow seeding to continue after import

Hardlinks only work within the same filesystem, so all media apps must share the same PV.

## GitOps Workflow

### Repository Structure

```
homelab/
├── kubernetes/
│   ├── bootstrap/
│   │   └── argocd/         # ArgoCD configuration
│   ├── core/
│   │   ├── argocd-apps.yaml  # Root App-of-Apps
│   │   ├── cilium/
│   │   ├── cert-manager/
│   │   └── ...
│   ├── apps/
│   │   └── media/
│   └── observability/
├── talos/
│   └── talconfig.yaml
└── terraform/
    └── proxmox/
```

### App-of-Apps Pattern

```
                    +------------------+
                    |    ArgoCD        |
                    +--------+---------+
                             |
              +--------------+--------------+
              |              |              |
     +--------v------+ +-----v------+ +-----v--------+
     |     core      | |    apps    | | observability|
     | (App-of-Apps) | |(App-of-Apps| | (App-of-Apps)|
     +-------+-------+ +-----+------+ +------+-------+
             |               |               |
    +--------+--------+      |        +------+------+
    |    |    |   |   |      |        |     |       |
  cilium cert nfs gw auth   media   prom  loki  promtail
         mgr  csi  api       apps   stack
```

### Sync Waves

ArgoCD sync waves control deployment order:

| Wave | Components |
|------|------------|
| -10 | Cilium (CNI must be first) |
| -5 | cert-manager (certificates needed early) |
| 0 | Default (most applications) |
| 5 | cloudflared, tailscale (need other services) |
| 10 | authentik (depends on storage, certs) |

### Secret Management Flow

```
Developer                    Git Repository               ArgoCD
    |                             |                          |
    | 1. Create secret.sops.yaml  |                          |
    |----------->                 |                          |
    |                             |                          |
    | 2. sops --encrypt           |                          |
    |----------->                 |                          |
    |                             |                          |
    | 3. git push                 |                          |
    |---------------------------->|                          |
    |                             |                          |
    |                             | 4. Sync                  |
    |                             |------------------------->|
    |                             |                          |
    |                             |      5. SOPS decrypt     |
    |                             |      (using age key)     |
    |                             |                          |
    |                             | 6. Apply plain Secret    |
    |                             |<-------------------------|
```

## Access Patterns

### Public Services

Services exposed via Cloudflare Tunnel:

| Service | Domain | Tunnel Ingress |
|---------|--------|----------------|
| Plex | plex.lorenzodebie.be | plex.media:32400 |
| Overseerr | requests.lorenzodebie.be | overseerr.media:5055 |

**Benefits**:
- No port forwarding required
- DDoS protection
- SSL termination at edge
- Zero-trust access possible

### Private Services

Services exposed via Gateway API:

| Service | Domain | Backend |
|---------|--------|---------|
| ArgoCD | argocd.int.lorenzodebie.be | argocd-server.argocd:443 |
| Grafana | grafana.int.lorenzodebie.be | grafana.observability:80 |
| Sonarr | sonarr.int.lorenzodebie.be | sonarr.media:8989 |
| ... | *.int.lorenzodebie.be | various |

**Access Methods**:
1. LAN: Direct access via Pi-hole DNS
2. Remote: Tailscale VPN connection

## Security Model

### Defense Layers

```
Layer 1: Network (VLAN isolation, firewall rules)
    |
Layer 2: Access Control (Cloudflare, Tailscale)
    |
Layer 3: Authentication (Authentik SSO)
    |
Layer 4: Authorization (Kubernetes RBAC)
    |
Layer 5: Encryption (TLS everywhere, SOPS for secrets)
```

### Key Security Features

| Component | Security Feature |
|-----------|-----------------|
| Talos | Immutable OS, no SSH, API-only |
| Cilium | Network policies, identity-based |
| Cloudflare | WAF, DDoS protection, bot management |
| Tailscale | Device authentication, ACLs |
| Authentik | SSO, MFA, audit logging |
| cert-manager | Automated TLS, short-lived certs |
| SOPS | Encrypted secrets in Git |

### Secret Protection

1. **At Rest**: Encrypted with SOPS (age) in Git
2. **In Transit**: TLS for all communications
3. **In Use**: Kubernetes Secrets with RBAC

### Trust Boundaries

```
Untrusted          Trusted (after auth)      Trusted (internal)
    |                      |                        |
Internet -> Cloudflare -> Authentik -> Applications
            Tailscale  ->
```
