# AGENTS.md - AI Agent Guidelines for Homelab Repository

This is a GitOps infrastructure-as-code repository for a single-node Kubernetes cluster on Talos Linux. **No application code** - purely infrastructure configuration.

**Stack:** Proxmox -> Talos Linux -> Kubernetes -> ArgoCD (GitOps) -> Applications

## Directory Structure

```
kubernetes/
├── bootstrap/        # Initial ArgoCD setup
├── core/             # Infrastructure (Cilium, cert-manager, Authentik)
├── apps/             # User applications (media stack)
└── observability/    # Monitoring (Prometheus, Grafana, Loki)
talos/                # Talos Linux config (talconfig.yaml)
terraform/proxmox/    # Terraform for Proxmox VM provisioning
```

## Commands Reference

### Validation Commands (No Cluster Required)

```bash
# Validate Helm chart
cd kubernetes/core/<app> && helm dependency build && helm template . --values values.yaml

# Validate Terraform
cd terraform/proxmox && terraform init && terraform validate

# Generate Talos configs (validates talconfig.yaml)
cd talos && talhelper genconfig
```

### Cluster Commands

```bash
# Terraform
cd terraform/proxmox && terraform plan && terraform apply

# Talos
talosctl apply-config --insecure --nodes 192.168.30.50 --file clusterconfig/homelab-talos-cp01.yaml
talosctl --talosconfig clusterconfig/talosconfig --nodes 192.168.30.50 health

# Kubernetes verification
kubectl get pods -n <namespace>
kubectl get gateway,httproute -A
argocd app list
```

### Secrets (SOPS)

```bash
sops --encrypt --in-place path/to/secret.sops.yaml  # Encrypt
sops path/to/secret.sops.yaml                        # Edit (decrypts in place)
```

## Code Style Guidelines

### YAML Formatting

- **2-space indentation** (no tabs)
- Comments above complex blocks, not inline
- Use `---` to separate multiple documents
- Lines under 120 characters

### Naming Conventions

| Type | Convention | Example |
|------|------------|---------|
| Kubernetes resources | kebab-case | `internal-gateway` |
| Namespaces | lowercase | `argocd`, `media` |
| Files | lowercase-hyphens | `cloudflare-secret.sops.yaml` |
| Terraform variables | snake_case | `vm_disk_size` |

### File Naming Patterns

| File | Purpose |
|------|---------|
| `application.yaml` | ArgoCD Application for main deployment |
| `secrets-application.yaml` | ArgoCD Application for SOPS secrets |
| `*.sops.yaml` | SOPS-encrypted secrets (safe to commit) |
| `values.yaml` | Helm values for upstream chart |
| `Chart.yaml` | Helm umbrella chart with dependencies |
| `.helmignore` | Must exclude: `application.yaml`, `*-application.yaml`, `*.sops.yaml` |
| `templates/*.yaml` | Local Kubernetes manifests |

## Required Patterns

### ArgoCD Application

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <app-name>
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "10"  # Control deploy order
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/LorenzoDeBie/Homelab-new.git
    targetRevision: main
    path: kubernetes/<category>/<app-name>
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
```

### HTTPRoute (Gateway API)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <service>
  namespace: <namespace>
spec:
  parentRefs:
    - name: internal-gateway
      namespace: kube-system
  hostnames:
    - <service>.int.lorenzodebie.be
  rules:
    - backendRefs:
        - name: <service>
          port: <port>
```

### Sync Waves

- `-10`: CRDs, GatewayClass
- `-5` to `-1`: Core dependencies (cert-manager, secrets)
- `0`: Default
- `5`: Secrets before apps
- `10`: Applications

## Critical Rules

1. **Never commit unencrypted secrets** - Use `*.sops.yaml` pattern
2. **Never apply with kubectl** - All changes go through Git/ArgoCD
3. **Never modify**: `age.key`, `talos/clusterconfig/`, `*.tfstate`
4. **Always include `.helmignore`** when creating Helm umbrella charts

### Terraform Style

```hcl
variable "example" {
  description = "Always include description"
  type        = string
  sensitive   = true  # For secrets
  default     = null
}
```

File organization: `versions.tf`, `variables.tf`, `main.tf`, `outputs.tf`

## IP Allocations

| IP | Purpose |
|----|---------|
| 192.168.30.50 | Kubernetes API |
| 192.168.30.51 | Kubelet node IP |
| 192.168.30.61 | Internal Gateway |
| 192.168.30.62-63 | Plex, qBittorrent |
| 192.168.30.64-80 | Available pool |

## Troubleshooting

```bash
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server  # ArgoCD
kubectl describe gateway internal-gateway -n kube-system             # Gateway
cilium status                                                         # Cilium
```

## Required Tools

```bash
brew install terraform talosctl talhelper kubectl helm argocd sops age
```
