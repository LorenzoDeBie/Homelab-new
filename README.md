# Homelab Kubernetes Cluster

Single-node Kubernetes cluster running on Talos Linux, managed by ArgoCD with GitOps.

## Architecture

```
Proxmox Host
└── Talos Linux VM (6 CPU / 16GB RAM)
    └── Kubernetes
        ├── Cilium (CNI + Gateway API + LoadBalancer)
        ├── ArgoCD (GitOps)
        ├── cert-manager (TLS certificates)
        ├── Cloudflare Tunnel (public access)
        ├── Tailscale Operator (private access)
        ├── Authentik (SSO/Identity)
        ├── Media Stack (Plex, *arr apps)
        └── Observability (Prometheus, Grafana, Loki)

TrueNAS
├── /mnt/<pool>/media (shared media storage)
└── /mnt/<pool>/k8s-config (application configs)
```

## Prerequisites

### Tools to Install

```bash
# macOS
brew install terraform talosctl talhelper kubectl helm argocd sops age

# Verify installations
terraform version
talosctl version --client
kubectl version --client
helm version
argocd version --client
sops --version
age --version
```

### Accounts to Create

1. **Cloudflare** (free): https://cloudflare.com
   - Transfer your domain or add it to Cloudflare
   - Create an API token with Zone:DNS:Edit permissions

2. **Tailscale** (free): https://tailscale.com
   - Create an OAuth client in Settings > OAuth clients

## Setup Instructions

### Phase 1: Infrastructure Setup

#### 1.1 Create TrueNAS NFS Shares

On TrueNAS, create two datasets and NFS shares:

```
Datasets:
- <pool>/media        (for media files)
- <pool>/k8s-config   (for application configs)

NFS Share settings:
- Maproot User: root
- Maproot Group: wheel
- Enabled: Yes
- Network: 192.168.30.0/24
```

#### 1.2 Set Up SOPS Encryption

```bash
# Generate age key
age-keygen -o age.key

# Save the public key (starts with "age1...")
# Update .sops.yaml with your public key
sed -i '' 's/AGE_PUBLIC_KEY_PLACEHOLDER/age1your_public_key_here/g' .sops.yaml

# Keep age.key safe - you'll need it for decryption
# DO NOT commit age.key to git
```

#### 1.3 Create Proxmox API Token (Optional)

If you prefer API tokens over username/password:

```bash
# On Proxmox host
pveum user add terraform@pve
pveum aclmod / -user terraform@pve -role PVEVMAdmin
pveum user token add terraform@pve terraform -privsep=0

# Save the token ID and secret
```

#### 1.4 Configure Terraform

```bash
cd terraform/proxmox

# Copy example and edit with your values
cp terraform.tfvars.example terraform.tfvars
vim terraform.tfvars

# Required changes:
# - proxmox_endpoint: Your Proxmox URL
# - proxmox_node: Your node name
# - proxmox_password or proxmox_api_token
# - talos_iso_url: Get from https://factory.talos.dev
```

#### 1.5 Provision Talos VM

```bash
cd terraform/proxmox

terraform init
terraform plan
terraform apply

# VM will boot from Talos ISO
```

#### 1.6 Apply Talos Configuration

```bash
cd talos

# Generate Talos configs using talhelper
talhelper genconfig

# Apply config to the node (VM must be running and booted from ISO)
talosctl apply-config --insecure \
  --nodes 192.168.30.50 \
  --file clusterconfig/homelab-talos-cp01.yaml

# Wait for node to reboot and become ready
talosctl --talosconfig clusterconfig/talosconfig \
  --nodes 192.168.30.50 \
  health

# Bootstrap the cluster
talosctl --talosconfig clusterconfig/talosconfig \
  --nodes 192.168.30.50 \
  bootstrap

# Get kubeconfig
talosctl --talosconfig clusterconfig/talosconfig \
  --nodes 192.168.30.50 \
  kubeconfig ~/.kube/config
```

### Phase 2: Core Platform Bootstrap

#### 2.1 Install Cilium (CNI)

The cluster needs a CNI before pods can run:

```bash
# Add Cilium Helm repo
helm repo add cilium https://helm.cilium.io
helm repo update

# Install Cilium
helm install cilium cilium/cilium \
  --namespace kube-system \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=true \
  --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
  --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
  --set cgroup.autoMount.enabled=false \
  --set cgroup.hostRoot=/sys/fs/cgroup \
  --set k8sServiceHost=localhost \
  --set k8sServicePort=7445 \
  --set gatewayAPI.enabled=true \
  --set l2announcements.enabled=true \
  --set externalIPs.enabled=true \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set operator.replicas=1

# Wait for Cilium to be ready
kubectl -n kube-system wait --for=condition=ready pod -l app.kubernetes.io/name=cilium-agent --timeout=300s
```

#### 2.2 Install ArgoCD

```bash
# Create namespace
kubectl create namespace argocd

# Create SOPS age secret
kubectl create secret generic sops-age \
  --namespace argocd \
  --from-file=keys.txt=../age.key

# Add ArgoCD Helm repo
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Install ArgoCD
helm install argocd argo/argo-cd \
  --namespace argocd \
  --values kubernetes/bootstrap/argocd/values.yaml

# Wait for ArgoCD to be ready
kubectl -n argocd wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server --timeout=300s

# Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Port forward to access UI
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Open https://localhost:8080, login with admin/<password>
```

#### 2.3 Configure Git Repository

```bash
# Create a Git repository for your homelab
# Push this code to your repository

# Update repository URLs in these files:
# - kubernetes/core/argocd-apps.yaml
# - kubernetes/apps/apps.yaml
# - kubernetes/observability/observability.yaml

# Add repository to ArgoCD
argocd repo add https://github.com/YOUR_USERNAME/homelab.git
```

#### 2.4 Encrypt Secrets with SOPS

Before applying ArgoCD applications, encrypt all secrets:

```bash
# Encrypt each secret file
cd kubernetes

# Cloudflare API token
sops --encrypt --in-place core/cert-manager/cloudflare-secret.sops.yaml

# Cloudflare Tunnel credentials (after creating tunnel)
sops --encrypt --in-place core/cloudflared/credentials.sops.yaml

# Tailscale OAuth credentials
sops --encrypt --in-place core/tailscale-operator/oauth-secret.sops.yaml

# Authentik secrets
sops --encrypt --in-place core/authentik/secrets.sops.yaml

# Grafana admin password
sops --encrypt --in-place observability/kube-prometheus-stack/grafana-secret.sops.yaml
```

#### 2.5 Apply Root Applications

```bash
# Apply the root App-of-Apps
kubectl apply -f kubernetes/core/argocd-apps.yaml
kubectl apply -f kubernetes/apps/apps.yaml
kubectl apply -f kubernetes/observability/observability.yaml

# ArgoCD will now sync all applications
```

### Phase 3: External Access Setup

#### 3.1 Cloudflare Tunnel

```bash
# Install cloudflared locally
brew install cloudflared

# Login to Cloudflare
cloudflared tunnel login

# Create tunnel
cloudflared tunnel create homelab

# Get tunnel credentials
cat ~/.cloudflared/<tunnel-id>.json

# Update kubernetes/core/cloudflared/credentials.sops.yaml with values
# Then encrypt with SOPS

# Create DNS records in Cloudflare dashboard:
# - plex.lorenzodebie.be -> <tunnel-id>.cfargotunnel.com (CNAME, Proxied)
# - requests.lorenzodebie.be -> <tunnel-id>.cfargotunnel.com (CNAME, Proxied)
```

#### 3.2 Tailscale

```bash
# Create OAuth client at https://login.tailscale.com/admin/settings/oauth

# Update kubernetes/core/tailscale-operator/oauth-secret.sops.yaml
# Then encrypt with SOPS

# After Tailscale operator is running, services with Tailscale annotations
# will be accessible via your tailnet
```

#### 3.3 Pi-hole DNS Records

Add these records to Pi-hole for internal access:

```
# Gateway IP for all internal services
*.int.lorenzodebie.be -> 192.168.30.61

# Or individual records
sonarr.int.lorenzodebie.be -> 192.168.30.61
radarr.int.lorenzodebie.be -> 192.168.30.61
prowlarr.int.lorenzodebie.be -> 192.168.30.61
qbittorrent.int.lorenzodebie.be -> 192.168.30.61
grafana.int.lorenzodebie.be -> 192.168.30.61
argocd.int.lorenzodebie.be -> 192.168.30.61
auth.int.lorenzodebie.be -> 192.168.30.61
talos.int.lorenzodebie.be -> 192.168.30.50
```

## Configuration Reference

### Update TrueNAS IP

Update these files with your TrueNAS IP and pool name:

```
kubernetes/core/nfs-csi/storageclass.yaml
  - server: TRUENAS_IP
  - share: /mnt/POOL_NAME/media
  - share: /mnt/POOL_NAME/k8s-config
```

### Update Email Address

Update these files with your email:

```
kubernetes/core/cert-manager/clusterissuer.yaml
  - email: YOUR_EMAIL@example.com

kubernetes/core/authentik/secrets.sops.yaml
  - bootstrap-email: YOUR_EMAIL@example.com
```

### IP Allocations

| Service | IP |
|---------|-----|
| Talos Node | 192.168.30.50 |
| Internal Gateway | 192.168.30.61 |
| Plex LoadBalancer | 192.168.30.62 |
| qBittorrent BT | 192.168.30.63 |
| Available Pool | 192.168.30.64-80 |

## Accessing Services

### Public (via Cloudflare Tunnel)

- Plex: https://plex.lorenzodebie.be
- Overseerr: https://requests.lorenzodebie.be

### Internal (via Gateway/Tailscale)

- ArgoCD: https://argocd.int.lorenzodebie.be
- Grafana: https://grafana.int.lorenzodebie.be
- Sonarr: https://sonarr.int.lorenzodebie.be
- Radarr: https://radarr.int.lorenzodebie.be
- Prowlarr: https://prowlarr.int.lorenzodebie.be
- qBittorrent: https://qbittorrent.int.lorenzodebie.be
- Authentik: https://auth.int.lorenzodebie.be

## Maintenance

### Update Talos

```bash
# Download new Talos version
# Update talos/talconfig.yaml with new version

# Generate new configs
cd talos
talhelper genconfig

# Apply upgrade
talosctl --talosconfig clusterconfig/talosconfig \
  --nodes 192.168.30.50 \
  upgrade --image ghcr.io/siderolabs/installer:v1.9.x
```

### Backup

- **Talos configs**: `talos/clusterconfig/` (encrypted, keep secure)
- **SOPS age key**: `age.key` (CRITICAL - keep multiple backups)
- **Application data**: NFS shares on TrueNAS (configure TrueNAS snapshots)

## Troubleshooting

### Pods stuck in Pending

```bash
# Check if NFS CSI is working
kubectl get pvc -A
kubectl describe pvc <pvc-name> -n <namespace>

# Check if Cilium is healthy
cilium status
```

### ArgoCD sync issues

```bash
# Check ArgoCD logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server

# Check SOPS decryption
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server -c sops
```

### Gateway not working

```bash
# Check Gateway status
kubectl get gateway -A
kubectl describe gateway internal-gateway -n kube-system

# Check HTTPRoutes
kubectl get httproute -A
```
