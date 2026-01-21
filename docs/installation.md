# Installation Guide

This guide walks through the complete installation process for the homelab Kubernetes cluster. The installation is divided into three phases:

1. **Infrastructure**: Provision Talos VM and bootstrap the cluster
2. **Core Platform**: Install CNI, ArgoCD, and configure GitOps
3. **Applications**: Deploy all applications via ArgoCD

## Table of Contents

- [Phase 1: Infrastructure Setup](#phase-1-infrastructure-setup)
- [Phase 2: Core Platform Bootstrap](#phase-2-core-platform-bootstrap)
- [Phase 3: Application Deployment](#phase-3-application-deployment)
- [Post-Installation](#post-installation)

## Phase 1: Infrastructure Setup

### 1.1 Clone the Repository

```bash
git clone https://github.com/YOUR_USERNAME/homelab.git
cd homelab
```

### 1.2 Generate SOPS Age Key

SOPS with age encryption is used to encrypt all secrets in the repository.

```bash
# Generate a new age keypair
age-keygen -o age.key

# Output will show something like:
# Public key: age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

# Copy the public key (starts with "age1")
cat age.key | grep "public key" | cut -d: -f2 | tr -d ' '
```

Update `.sops.yaml` with your public key:

```bash
# Replace the placeholder with your actual public key
sed -i '' 's/AGE_PUBLIC_KEY_PLACEHOLDER/age1your_actual_public_key_here/g' .sops.yaml
```

**Important**: Keep `age.key` secure and never commit it to Git. Back it up to multiple secure locations.

### 1.3 Configure Terraform Variables

```bash
cd terraform/proxmox

# Create your variables file
cat > terraform.tfvars << 'EOF'
# Proxmox connection
proxmox_endpoint = "https://192.168.30.10:8006"  # Your Proxmox URL
proxmox_node     = "pve"                          # Your node name

# Authentication (choose one method)
# Option 1: API Token (recommended)
proxmox_api_token = "terraform@pve!terraform=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# Option 2: Username/Password
# proxmox_username = "root@pam"
# proxmox_password = "your-password"

# VM Configuration
vm_id        = 200
vm_name      = "talos-homelab"
vm_cores     = 6
vm_memory    = 16384      # 16GB in MB
vm_disk_size = 100        # GB
vm_storage   = "local-lvm"
vm_bridge    = "vmbr0"
vm_vlan_tag  = 30         # Set to null if not using VLANs

# Talos ISO
# Get URL from https://factory.talos.dev
# Select: metal, amd64, no extensions (or add your extensions)
talos_iso_url     = "https://factory.talos.dev/image/.../v1.9.1/metal-amd64.iso"
talos_iso_storage = "local"
EOF
```

### 1.4 Get Talos ISO URL

1. Go to [Talos Factory](https://factory.talos.dev)
2. Select Talos version (e.g., v1.9.1)
3. Select platform: `metal`
4. Select architecture: `amd64`
5. Add extensions if needed (e.g., `qemu-guest-agent` for Proxmox)
6. Copy the ISO URL
7. Update `talos_iso_url` in `terraform.tfvars`

### 1.5 Provision the VM

```bash
cd terraform/proxmox

# Initialize Terraform
terraform init

# Review the plan
terraform plan

# Apply (creates the VM)
terraform apply
```

The VM will boot from the Talos ISO. You should see it in the Proxmox console showing the Talos maintenance screen with the IP address.

### 1.6 Configure Talos

Review and update the Talos configuration:

```bash
cd ../../talos

# Review talconfig.yaml and update:
# - IP addresses if different
# - Domain names
# - Any other customizations
vim talconfig.yaml
```

Key settings to verify in `talconfig.yaml`:

```yaml
clusterName: homelab
talosVersion: v1.9.1
kubernetesVersion: v1.32.0
endpoint: https://192.168.30.50:6443

nodes:
  - hostname: talos-cp01
    ipAddress: 192.168.30.50
    networkInterfaces:
      - addresses:
          - 192.168.30.50/24  # Primary: Kubernetes API endpoint
          - 192.168.30.51/24  # Secondary: Kubelet node IP
    # ... additional network configuration
```

> **Important**: The node requires two IP addresses. The primary IP is used for the Kubernetes API endpoint, while the secondary IP is used as the kubelet's node IP. This is necessary because Talos excludes the cluster endpoint IP from kubelet node IP selection, which would otherwise break `kubectl port-forward`. See [Networking - Talos Node IP Configuration](networking.md#talos-node-ip-configuration) for details.

### 1.7 Generate Talos Configs

```bash
# Generate configuration files
talhelper genconfig

# This creates:
# - clusterconfig/homelab-talos-cp01.yaml  (node config)
# - clusterconfig/talosconfig               (client config)
```

### 1.8 Apply Talos Configuration

```bash
# Apply config to the node (must be running and showing maintenance screen)
talosctl apply-config --insecure \
  --nodes 192.168.30.50 \
  --file clusterconfig/homelab-talos-cp01.yaml

# The node will reboot and install Talos to disk
```

Wait for the node to reboot (1-2 minutes).

### 1.9 Bootstrap the Cluster

```bash
# Set up talosctl to use the generated config
export TALOSCONFIG=$(pwd)/clusterconfig/talosconfig

# Check node health
talosctl --nodes 192.168.30.50 health

# Bootstrap etcd (only needed once, on first control plane node)
talosctl --nodes 192.168.30.50 bootstrap

# Wait for bootstrap to complete
talosctl --nodes 192.168.30.50 health --wait-timeout 10m
```

### 1.10 Get Kubeconfig

```bash
# Get kubeconfig and merge into default location
talosctl --nodes 192.168.30.50 kubeconfig ~/.kube/config

# Or save to a separate file
talosctl --nodes 192.168.30.50 kubeconfig ./kubeconfig

# Verify connection
kubectl get nodes
```

Expected output:
```
NAME         STATUS     ROLES           AGE   VERSION
talos-cp01   NotReady   control-plane   1m    v1.32.0
```

The node shows `NotReady` because we haven't installed a CNI yet.

### Phase 1 Verification

```bash
# Verify Talos is healthy
talosctl --nodes 192.168.30.50 health

# Verify Kubernetes API is accessible
kubectl cluster-info

# Verify node exists (will be NotReady without CNI)
kubectl get nodes
```

## Phase 2: Core Platform Bootstrap

### 2.1 Install Cilium (CNI)

The cluster cannot schedule pods until a CNI is installed.

```bash
# Add Helm repository
helm repo add cilium https://helm.cilium.io
helm repo update

# Install Cilium with Talos-specific configuration
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

Verify Cilium installation:

```bash
# Check Cilium status
kubectl -n kube-system get pods -l app.kubernetes.io/part-of=cilium

# Verify node is now Ready
kubectl get nodes
```

Expected output:
```
NAME         STATUS   ROLES           AGE   VERSION
talos-cp01   Ready    control-plane   5m    v1.32.0
```

### 2.2 Create ArgoCD Namespace and SOPS Secret

```bash
# Create namespace
kubectl create namespace argocd

# Create the SOPS age secret (ArgoCD needs this to decrypt secrets)
kubectl create secret generic sops-age \
  --namespace argocd \
  --from-file=keys.txt=../age.key
```

### 2.3 Install ArgoCD

```bash
# Add Helm repository
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Install ArgoCD with SOPS support
cd ../kubernetes/bootstrap/argocd
helm install argocd argo/argo-cd \
  --namespace argocd \
  --values values.yaml

# Wait for ArgoCD to be ready
kubectl -n argocd wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server --timeout=300s
```

### 2.4 Access ArgoCD UI

```bash
# Get the initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo  # Add newline

# Port forward to access the UI
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open https://localhost:8080 in your browser:
- Username: `admin`
- Password: (from the command above)

### 2.5 Configure Git Repository

Update repository URLs in the manifests:

```bash
cd ../../../

# Update the repository URL in all App-of-Apps files
# Replace YOUR_GITHUB_USERNAME with your actual username
sed -i '' 's|https://github.com/YOUR_GITHUB_USERNAME/homelab.git|https://github.com/YOUR_ACTUAL_USERNAME/homelab.git|g' \
  kubernetes/core/argocd-apps.yaml \
  kubernetes/apps/apps.yaml \
  kubernetes/observability/observability.yaml
```

### 2.6 Update Configuration Files

Before encrypting secrets, update configuration with your values:

```bash
# Update TrueNAS IP and pool name
sed -i '' 's/TRUENAS_IP/192.168.30.XX/g' kubernetes/core/nfs-csi/storageclass.yaml
sed -i '' 's/POOL_NAME/your-pool-name/g' kubernetes/core/nfs-csi/storageclass.yaml

# Update email in cert-manager
sed -i '' 's/YOUR_EMAIL@example.com/your@email.com/g' kubernetes/core/cert-manager/clusterissuer.yaml
```

### 2.7 Configure and Encrypt Secrets

Each secret file needs to be populated with actual values, then encrypted.

#### Cloudflare API Token

```bash
# Edit the secret file
cat > kubernetes/core/cert-manager/cloudflare-secret.sops.yaml << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-api-token
  namespace: cert-manager
type: Opaque
stringData:
  api-token: YOUR_CLOUDFLARE_API_TOKEN
EOF

# Encrypt with SOPS
sops --encrypt --in-place kubernetes/core/cert-manager/cloudflare-secret.sops.yaml
```

#### Tailscale OAuth

```bash
cat > kubernetes/core/tailscale-operator/oauth-secret.sops.yaml << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: operator-oauth
  namespace: tailscale
type: Opaque
stringData:
  client_id: YOUR_TAILSCALE_CLIENT_ID
  client_secret: YOUR_TAILSCALE_CLIENT_SECRET
EOF

sops --encrypt --in-place kubernetes/core/tailscale-operator/oauth-secret.sops.yaml
```

#### Authentik Secrets

```bash
cat > kubernetes/core/authentik/secrets.sops.yaml << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: authentik-secrets
  namespace: authentik
type: Opaque
stringData:
  secret-key: $(openssl rand -base64 32)
  postgresql-password: $(openssl rand -base64 24)
  bootstrap-password: your-admin-password
  bootstrap-email: your@email.com
EOF

# Generate random values
AUTHENTIK_SECRET_KEY=$(openssl rand -base64 32)
AUTHENTIK_PG_PASSWORD=$(openssl rand -base64 24)

# Update the file with generated values
sed -i '' "s|\$(openssl rand -base64 32)|$AUTHENTIK_SECRET_KEY|g" kubernetes/core/authentik/secrets.sops.yaml
sed -i '' "s|\$(openssl rand -base64 24)|$AUTHENTIK_PG_PASSWORD|g" kubernetes/core/authentik/secrets.sops.yaml

sops --encrypt --in-place kubernetes/core/authentik/secrets.sops.yaml
```

#### Grafana Admin

```bash
cat > kubernetes/observability/kube-prometheus-stack/grafana-secret.sops.yaml << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: grafana-admin
  namespace: observability
type: Opaque
stringData:
  admin-user: admin
  admin-password: your-grafana-password
EOF

sops --encrypt --in-place kubernetes/observability/kube-prometheus-stack/grafana-secret.sops.yaml
```

### 2.8 Create Cloudflare Tunnel

```bash
# Login to Cloudflare
cloudflared tunnel login

# Create tunnel
cloudflared tunnel create homelab

# Note the tunnel ID from the output
# Credentials are saved to ~/.cloudflared/<tunnel-id>.json

# View credentials
cat ~/.cloudflared/<tunnel-id>.json
```

Create the Cloudflare Tunnel secret:

```bash
cat > kubernetes/core/cloudflared/credentials.sops.yaml << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: cloudflared-credentials
  namespace: cloudflared
type: Opaque
stringData:
  credentials.json: |
    {
      "AccountTag": "YOUR_ACCOUNT_TAG",
      "TunnelID": "YOUR_TUNNEL_ID",
      "TunnelSecret": "YOUR_TUNNEL_SECRET"
    }
EOF

# Copy values from ~/.cloudflared/<tunnel-id>.json
# Then encrypt
sops --encrypt --in-place kubernetes/core/cloudflared/credentials.sops.yaml
```

Create DNS records in Cloudflare:
- `plex.lorenzodebie.be` -> CNAME to `<tunnel-id>.cfargotunnel.com` (Proxied)
- `requests.lorenzodebie.be` -> CNAME to `<tunnel-id>.cfargotunnel.com` (Proxied)

### 2.9 Commit and Push

```bash
git add -A
git commit -m "Configure homelab with encrypted secrets"
git push origin main
```

### 2.10 Apply Root Applications

```bash
# Apply the App-of-Apps manifests
kubectl apply -f kubernetes/core/argocd-apps.yaml
kubectl apply -f kubernetes/apps/apps.yaml
kubectl apply -f kubernetes/observability/observability.yaml
```

ArgoCD will now automatically sync all applications.

### Phase 2 Verification

```bash
# Check ArgoCD applications
kubectl get applications -n argocd

# Watch sync progress
watch kubectl get applications -n argocd

# Check all pods across namespaces
kubectl get pods -A
```

## Phase 3: Application Deployment

Phase 3 is mostly automatic - ArgoCD deploys everything. However, some applications need initial configuration.

### 3.1 Wait for Core Components

Monitor ArgoCD until core components are healthy:

```bash
# Required before applications work:
# - cilium (CNI)
# - cert-manager (TLS)
# - nfs-csi (storage)
# - gateway-api (ingress)

kubectl get applications -n argocd | grep -E "cilium|cert-manager|nfs-csi|gateway-api"
```

All should show `Synced` and `Healthy`.

### 3.2 Configure Pi-hole DNS

Add DNS records to Pi-hole for internal access:

1. Access Pi-hole admin (http://192.168.30.45/admin)
2. Go to Local DNS > DNS Records
3. Add wildcard record:
   - Domain: `int.lorenzodebie.be` (Pi-hole may not support wildcards - add individual records)
   - IP: `192.168.30.61`

Or add individual records:
```
sonarr.int.lorenzodebie.be     -> 192.168.30.61
radarr.int.lorenzodebie.be     -> 192.168.30.61
prowlarr.int.lorenzodebie.be   -> 192.168.30.61
qbittorrent.int.lorenzodebie.be -> 192.168.30.61
grafana.int.lorenzodebie.be    -> 192.168.30.61
argocd.int.lorenzodebie.be     -> 192.168.30.61
auth.int.lorenzodebie.be       -> 192.168.30.61
```

### 3.3 Verify Applications

```bash
# Check all pods are running
kubectl get pods -n media
kubectl get pods -n observability

# Check PVCs are bound
kubectl get pvc -A

# Check services have LoadBalancer IPs
kubectl get svc -A | grep LoadBalancer
```

### Phase 3 Verification

```bash
# Test internal access (requires DNS configured)
curl -k https://sonarr.int.lorenzodebie.be

# Test public access
curl https://plex.lorenzodebie.be/web

# Check certificate status
kubectl get certificates -A
```

## Post-Installation

### Access Services

**Public (via Cloudflare Tunnel)**:
- Plex: https://plex.lorenzodebie.be
- Overseerr: https://requests.lorenzodebie.be

**Internal (via Gateway + Tailscale/LAN)**:
- ArgoCD: https://argocd.int.lorenzodebie.be
- Grafana: https://grafana.int.lorenzodebie.be
- Sonarr: https://sonarr.int.lorenzodebie.be
- Radarr: https://radarr.int.lorenzodebie.be
- Prowlarr: https://prowlarr.int.lorenzodebie.be
- qBittorrent: https://qbittorrent.int.lorenzodebie.be
- Authentik: https://auth.int.lorenzodebie.be

### Initial Application Setup

See [Applications Documentation](applications.md) for:
- Plex initial setup and library configuration
- Sonarr/Radarr root folder configuration
- Prowlarr indexer setup
- qBittorrent settings
- Authentik SSO integration

### Save Important Files

Securely back up these files:

1. **age.key**: SOPS private key - required to decrypt any secrets
2. **talos/clusterconfig/**: Talos configuration and secrets
3. **terraform.tfvars**: Infrastructure configuration (if contains sensitive data)

### Cleanup

```bash
# Delete initial ArgoCD admin secret (after changing password)
kubectl delete secret argocd-initial-admin-secret -n argocd

# Remove the Talos ISO from VM (optional - keeps boot faster)
# Done via Proxmox UI: VM > Hardware > CD/DVD Drive > Remove
```

## Next Steps

- [Architecture](architecture.md) - Understand how everything fits together
- [Secrets Management](secrets.md) - Learn how to manage secrets
- [Maintenance](maintenance.md) - Ongoing operations and upgrades
- [Troubleshooting](troubleshooting.md) - Common issues and solutions
