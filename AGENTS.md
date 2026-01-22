# AGENTS.md - AI Agent Guidelines for Homelab Repository

This document provides guidelines for AI coding agents working on this infrastructure-as-code repository.

## Repository Overview

This is a GitOps homelab infrastructure repository for a single-node Kubernetes cluster running on Talos Linux. There is no application code to build - this is purely infrastructure configuration.

**Stack:** Proxmox (hypervisor) -> Talos Linux (OS) -> Kubernetes -> ArgoCD (GitOps) -> Applications

## Directory Structure

```
kubernetes/           # Kubernetes manifests (ArgoCD manages these)
├── bootstrap/        # ArgoCD configuration
├── core/             # Core infrastructure (Cilium, cert-manager, Authentik, etc.)
├── apps/             # User applications (media stack)
└── observability/    # Monitoring (Prometheus, Grafana, Loki)
talos/                # Talos Linux configuration (talconfig.yaml)
terraform/proxmox/    # Terraform for Proxmox VM provisioning
docs/                 # Documentation
```

## Required CLI Tools

```bash
# Install on macOS
brew install terraform talosctl talhelper kubectl helm argocd sops age
```

## Commands Reference

### Talos Configuration

```bash
# Generate Talos configs from talconfig.yaml
cd talos && talhelper genconfig

# Apply config to node
talosctl apply-config --insecure --nodes 192.168.30.50 --file clusterconfig/homelab-talos-cp01.yaml

# Check node health
talosctl --talosconfig clusterconfig/talosconfig --nodes 192.168.30.50 health
```

### Terraform (Proxmox)

```bash
cd terraform/proxmox
terraform init
terraform plan
terraform apply
```

### Helm Charts

```bash
# Download dependencies for an umbrella chart
cd kubernetes/core/authentik
helm dependency build

# Template chart locally (validation)
helm template . --values values.yaml
```

### Secrets Management (SOPS)

```bash
# Encrypt a secret file
sops --encrypt --in-place path/to/secret.sops.yaml

# Decrypt for editing
sops path/to/secret.sops.yaml

# Create new encrypted secret (encryption happens automatically due to .sops.yaml)
sops kubernetes/core/example/new-secret.sops.yaml
```

### Kubernetes Validation

```bash
# Verify resources after ArgoCD sync
kubectl get pods -n <namespace>
kubectl describe pod <pod> -n <namespace>
kubectl logs -n <namespace> <pod>

# Check Gateway API resources
kubectl get gateway,httproute -A
```

## File Patterns & Naming Conventions

### Kubernetes Manifests

| File | Purpose |
|------|---------|
| `application.yaml` | ArgoCD Application definition for main deployment |
| `secrets-application.yaml` | Separate ArgoCD Application for SOPS-encrypted secrets |
| `*.sops.yaml` | SOPS-encrypted Secret manifests (safe to commit) |
| `values.yaml` | Helm values passed to upstream chart |
| `Chart.yaml` | Helm umbrella chart definition with dependencies |
| `.helmignore` | Excludes ArgoCD/SOPS files from Helm packaging |
| `templates/*.yaml` | Local Kubernetes manifests (HTTPRoutes, etc.) |

### Naming Rules

- **Kubernetes resources:** kebab-case (`internal-gateway`, `nfs-config`)
- **Namespaces:** lowercase (`argocd`, `media`, `authentik`)
- **Files:** lowercase with hyphens (`cloudflare-secret.sops.yaml`)
- **Terraform variables:** snake_case (`vm_disk_size`, `proxmox_endpoint`)

## Code Style Guidelines

### YAML Formatting

- Use 2-space indentation
- Place descriptive comments above complex blocks
- Use `---` to separate multiple documents in one file
- Keep lines under 120 characters where practical

### ArgoCD Application Template

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <app-name>
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "10"  # Optional: control deploy order
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/LorenzoDeBie/Homelab-new.git
    targetRevision: main
    path: kubernetes/core/<app-name>
    helm:
      valueFiles:
        - values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: <target-namespace>
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

### Helm Umbrella Chart Structure

When deploying an upstream Helm chart with local templates:

```
component/
├── Chart.yaml           # Declares upstream dependency
├── Chart.lock           # Lock file (auto-generated)
├── charts/              # Downloaded deps (gitignored)
├── values.yaml          # Values passed to subchart
├── .helmignore          # Must exclude: application.yaml, *-application.yaml, *.sops.yaml
├── application.yaml     # ArgoCD Application
├── secrets-application.yaml  # ArgoCD Application for SOPS secrets
└── templates/
    └── httproute.yaml   # Local manifests alongside upstream
```

### Secrets Pattern

Secrets are handled via separate ArgoCD Applications using the SOPS plugin:

```yaml
# secrets-application.yaml
spec:
  source:
    plugin:
      name: sops-file
      env:
        - name: FILE
          value: secrets.sops.yaml
```

Use sync-wave annotations to ensure secrets deploy before the main app.

### Terraform Style

- Include `description` for all variables
- Mark sensitive variables with `sensitive = true`
- Use `# Comment` style for inline documentation
- Organize: `versions.tf`, `variables.tf`, `main.tf`, `outputs.tf`

## Critical Files - Do Not Modify

- `age.key` - SOPS private key (not in repo, never commit)
- `talos/clusterconfig/` - Generated Talos configs with secrets (gitignored)
- `*.tfstate`, `*.tfstate.*` - Terraform state files
- `.sops.yaml` - SOPS encryption rules (modify carefully)

## GitOps Workflow

1. Make changes to manifests in this repository
2. Commit and push to `main` branch
3. ArgoCD automatically detects changes and syncs
4. Verify in ArgoCD UI or via `argocd app list`

**Do NOT apply manifests directly with kubectl** (except for initial bootstrap). All changes should go through Git.

## Sync Waves

Use `argocd.argoproj.io/sync-wave` annotations to control deployment order:

- `-10`: CRDs, GatewayClass (must exist first)
- `0`: Certificates, basic resources
- `5`: Secrets (before apps that need them)
- `10`: Main applications

## Common Patterns

### HTTPRoute for Internal Gateway

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <service-name>
  namespace: <namespace>
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: internal-gateway
      namespace: kube-system
  hostnames:
    - <service>.int.lorenzodebie.be
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: <service>
          port: <port>
```

### LoadBalancer with Static IP (Cilium L2)

```yaml
service:
  type: LoadBalancer
  annotations:
    io.cilium/lb-ipam-ips: "192.168.30.XX"
```

## IP Allocations

| Range | Purpose |
|-------|---------|
| 192.168.30.50 | Kubernetes API endpoint |
| 192.168.30.51 | Kubelet node IP |
| 192.168.30.61 | Internal Gateway |
| 192.168.30.62 | Plex LoadBalancer |
| 192.168.30.63 | qBittorrent BitTorrent |
| 192.168.30.64-80 | Available pool |

## Troubleshooting Tips

```bash
# ArgoCD sync issues
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server

# Check SOPS decryption
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server -c sops

# Gateway/HTTPRoute issues
kubectl get gateway,httproute -A
kubectl describe gateway internal-gateway -n kube-system

# Cilium status
cilium status
```
