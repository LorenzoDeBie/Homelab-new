# Maintenance Guide

This document covers ongoing maintenance procedures including upgrades, backups, and disaster recovery for the homelab Kubernetes cluster.

## Table of Contents

- [Regular Maintenance Tasks](#regular-maintenance-tasks)
- [Talos Upgrades](#talos-upgrades)
- [Kubernetes Upgrades](#kubernetes-upgrades)
- [Application Updates](#application-updates)
- [Backup Strategies](#backup-strategies)
- [Disaster Recovery](#disaster-recovery)
- [Certificate Management](#certificate-management)
- [Storage Maintenance](#storage-maintenance)
- [Security Maintenance](#security-maintenance)

## Regular Maintenance Tasks

### Daily (Automated)

- ArgoCD syncs applications automatically
- Prometheus scrapes metrics
- Promtail collects logs
- cert-manager renews certificates (as needed)

### Weekly (Recommended)

| Task | Command/Action |
|------|----------------|
| Check ArgoCD sync status | `kubectl get applications -n argocd` |
| Review Grafana dashboards | Check for anomalies |
| Check disk usage | `kubectl get pvc -A` |
| Review alerts | Alertmanager UI |

### Monthly

| Task | Action |
|------|--------|
| Review and apply security updates | Check for CVEs in container images |
| Check for Helm chart updates | Update `targetRevision` in Application manifests |
| Test backup restoration | See [Disaster Recovery](#disaster-recovery) |
| Review access logs | Check Authentik audit logs |
| Clean old images | Talos handles this automatically |

### Quarterly

| Task | Action |
|------|--------|
| Kubernetes version upgrade | See [Kubernetes Upgrades](#kubernetes-upgrades) |
| Talos version upgrade | See [Talos Upgrades](#talos-upgrades) |
| Review and rotate secrets | See [Security Maintenance](#security-maintenance) |
| Capacity planning | Review resource usage trends |

## Talos Upgrades

### Before Upgrading

1. **Check Release Notes**: Review [Talos releases](https://github.com/siderolabs/talos/releases)
2. **Backup Configuration**: Ensure `talos/clusterconfig/` is committed and backed up
3. **Check Compatibility**: Verify Kubernetes version compatibility
4. **Create VM Snapshot**: In Proxmox, snapshot the Talos VM

### Upgrade Process

1. **Update talconfig.yaml**:
   ```yaml
   # talos/talconfig.yaml
   talosVersion: v1.9.2  # New version
   ```

2. **Regenerate Configurations**:
   ```bash
   cd talos
   talhelper genconfig
   ```

3. **Perform Upgrade**:
   ```bash
   # Using the Talos installer image
   talosctl --talosconfig clusterconfig/talosconfig \
     --nodes 192.168.30.50 \
     upgrade --image ghcr.io/siderolabs/installer:v1.9.2
   ```

4. **Monitor Upgrade**:
   ```bash
   # Watch node status
   talosctl --nodes 192.168.30.50 health
   
   # Watch pods
   kubectl get pods -A -w
   ```

5. **Verify**:
   ```bash
   # Check Talos version
   talosctl --nodes 192.168.30.50 version
   
   # Check node status
   kubectl get nodes
   ```

### Rollback

If the upgrade fails:

1. **Rollback VM** (if snapshot taken):
   - Proxmox > VM > Snapshots > Rollback

2. **Or Rollback via Talos**:
   ```bash
   talosctl --nodes 192.168.30.50 rollback
   ```

## Kubernetes Upgrades

Kubernetes upgrades are tied to Talos versions. Each Talos version supports specific Kubernetes versions.

### Check Compatibility

See [Talos Support Matrix](https://www.talos.dev/docs/support-matrix/)

### Upgrade Process

1. **Update talconfig.yaml**:
   ```yaml
   # talos/talconfig.yaml
   kubernetesVersion: v1.33.0  # New version
   ```

2. **Regenerate and Apply**:
   ```bash
   cd talos
   talhelper genconfig
   
   talosctl --talosconfig clusterconfig/talosconfig \
     --nodes 192.168.30.50 \
     apply-config --file clusterconfig/homelab-talos-cp01.yaml
   ```

3. **Trigger Upgrade**:
   ```bash
   talosctl --nodes 192.168.30.50 upgrade-k8s --to v1.33.0
   ```

4. **Monitor**:
   ```bash
   kubectl get nodes -w
   kubectl get pods -A | grep -v Running
   ```

### Verify

```bash
# Check Kubernetes version
kubectl version

# Check all components healthy
kubectl get componentstatuses  # Deprecated but still works
kubectl get --raw='/healthz'
```

## Application Updates

### ArgoCD Managed Applications

ArgoCD automatically syncs applications to match Git. To update:

1. **Update Helm Chart Version**:
   ```yaml
   # kubernetes/core/cilium/application.yaml
   spec:
     source:
       targetRevision: 1.16.6  # New version
   ```

2. **Commit and Push**:
   ```bash
   git add .
   git commit -m "Update Cilium to 1.16.6"
   git push
   ```

3. **ArgoCD Syncs Automatically** (or manually):
   ```bash
   argocd app sync cilium
   ```

### Check for Updates

```bash
# List current versions
kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,VERSION:.spec.source.targetRevision

# Check Helm repos for updates
helm repo update
helm search repo cilium/cilium --versions | head
```

### Update Strategy

For critical infrastructure:

1. **Test in staging first** (if available)
2. **Read release notes** for breaking changes
3. **Update one component at a time**
4. **Verify before proceeding**

### Rollback Application

```bash
# View sync history
argocd app history <app-name>

# Rollback to previous version
argocd app rollback <app-name> <history-id>

# Or revert Git commit and push
git revert HEAD
git push
```

## Backup Strategies

### What to Backup

| Data | Location | Method | Frequency |
|------|----------|--------|-----------|
| SOPS age key | `age.key` | Manual, offline | Once, then secure storage |
| Talos configs | `talos/clusterconfig/` | Git | On change |
| Git repository | GitHub/GitLab | Git hosting | Continuous |
| Application configs | TrueNAS `/k8s-config` | ZFS snapshots | Daily |
| Media | TrueNAS `/media` | ZFS snapshots | Daily/Weekly |
| Kubernetes secrets | Cluster | Velero (optional) | Daily |
| etcd | Talos node | etcd snapshot | Daily |

### etcd Backup

```bash
# Create etcd snapshot
talosctl --nodes 192.168.30.50 etcd snapshot /tmp/etcd-backup.db

# Copy to local machine
talosctl --nodes 192.168.30.50 copy /tmp/etcd-backup.db ./etcd-backup.db
```

### Automate etcd Backup

Create a CronJob:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: etcd-backup
  namespace: kube-system
spec:
  schedule: "0 2 * * *"  # Daily at 2 AM
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: backup
              image: ghcr.io/siderolabs/talosctl:v1.9.1
              command:
                - /bin/sh
                - -c
                - |
                  talosctl etcd snapshot /backup/etcd-$(date +%Y%m%d).db
              volumeMounts:
                - name: backup
                  mountPath: /backup
                - name: talosconfig
                  mountPath: /var/run/secrets/talos.dev
          volumes:
            - name: backup
              persistentVolumeClaim:
                claimName: etcd-backups
            - name: talosconfig
              secret:
                secretName: talos-secrets
          restartPolicy: OnFailure
```

### TrueNAS Snapshots

Configure automatic snapshots:

1. TrueNAS > Tasks > Periodic Snapshot Tasks
2. Create tasks for both datasets:
   - `/mnt/pool/media` - Weekly, keep 4
   - `/mnt/pool/k8s-config` - Daily, keep 14

### Critical Backup: age.key

**This is the most critical backup item!**

Without `age.key`, you cannot:
- Decrypt any secrets in the repository
- Add new secrets
- Restore the cluster fully

Backup locations:
1. Password manager (1Password, Bitwarden)
2. Encrypted USB drive in safe location
3. Printed paper copy in secure location
4. Separate cloud storage (encrypted)

## Disaster Recovery

### Scenario 1: Pod/Deployment Failure

**Resolution**: ArgoCD auto-heals, or:

```bash
# Force resync
argocd app sync <app-name> --force

# Restart deployment
kubectl rollout restart deployment <name> -n <namespace>
```

### Scenario 2: Node Failure (Recoverable)

**Resolution**: Reboot and wait for recovery

```bash
# Reboot node
talosctl --nodes 192.168.30.50 reboot

# Wait for health
talosctl --nodes 192.168.30.50 health --wait-timeout 10m

# Verify pods
kubectl get pods -A
```

### Scenario 3: Node Corruption (Reinstall Required)

**Resolution**: Reinstall Talos, restore etcd

1. **Boot from Talos ISO** (via Proxmox)

2. **Apply Configuration**:
   ```bash
   talosctl apply-config --insecure \
     --nodes 192.168.30.50 \
     --file talos/clusterconfig/homelab-talos-cp01.yaml
   ```

3. **Restore etcd** (if backup available):
   ```bash
   talosctl --nodes 192.168.30.50 etcd recover \
     --backup-path=/path/to/etcd-backup.db
   ```

4. **Or Bootstrap Fresh**:
   ```bash
   talosctl --nodes 192.168.30.50 bootstrap
   ```

5. **Apply ArgoCD Apps**:
   ```bash
   kubectl apply -f kubernetes/core/argocd-apps.yaml
   kubectl apply -f kubernetes/apps/apps.yaml
   kubectl apply -f kubernetes/observability/observability.yaml
   ```

### Scenario 4: Complete Data Loss

**Resolution**: Full rebuild from Git + backups

1. **Provision new infrastructure** (Terraform)
2. **Install Talos** (from talconfig)
3. **Bootstrap Kubernetes**
4. **Install ArgoCD and apply apps**
5. **Restore NFS data from TrueNAS backups**
6. **Recreate SOPS secret from backed-up age.key**

### Scenario 5: Lost age.key

**This is the worst-case scenario.**

If age.key is truly lost:
- All encrypted secrets are unrecoverable
- You must regenerate all secrets manually:
  - Cloudflare API token
  - Tailscale OAuth
  - Authentik secrets
  - Grafana password
  - Cloudflare Tunnel credentials
- Create new age.key and re-encrypt everything

**Prevention**: Multiple secure backups of age.key!

## Certificate Management

### cert-manager Handles Certificates

Certificates are automatically:
- Issued by Let's Encrypt
- Renewed before expiration (30 days before)
- Stored as Kubernetes secrets

### Check Certificate Status

```bash
# List all certificates
kubectl get certificates -A

# Check specific certificate
kubectl describe certificate internal-wildcard-tls -n kube-system

# Check certificate secret
kubectl get secret internal-wildcard-tls -n kube-system -o yaml
```

### Manual Certificate Renewal

If automatic renewal fails:

```bash
# Delete the certificate secret (forces re-issue)
kubectl delete secret internal-wildcard-tls -n kube-system

# Or annotate certificate to trigger renewal
kubectl annotate certificate internal-wildcard-tls \
  -n kube-system \
  cert-manager.io/issue-temporary-certificate="true"
```

### Troubleshoot Certificate Issues

```bash
# Check cert-manager logs
kubectl logs -n cert-manager -l app.kubernetes.io/name=cert-manager

# Check certificate events
kubectl describe certificate <name> -n <namespace>

# Check order/challenge status
kubectl get orders -A
kubectl get challenges -A
```

## Storage Maintenance

### Monitor Disk Usage

```bash
# PVC usage (requires metrics-server)
kubectl get pvc -A

# Actual usage on TrueNAS
ssh truenas "zfs list -o name,used,avail,refer"
```

### Expand PVC

NFS CSI supports volume expansion:

1. **Update PVC**:
   ```yaml
   spec:
     resources:
       requests:
         storage: 100Gi  # Increased from 50Gi
   ```

2. **Apply**:
   ```bash
   kubectl apply -f pvc.yaml
   ```

### Clean Old Data

```bash
# Check Prometheus data
kubectl exec -n observability prometheus-kube-prometheus-stack-prometheus-0 -- \
  df -h /prometheus

# Reduce retention if needed (edit values in application.yaml)
```

### NFS Performance Tuning

If experiencing slow NFS:

1. **Check TrueNAS network utilization**
2. **Consider jumbo frames** (MTU 9000)
3. **Increase NFS threads** (TrueNAS > Services > NFS)
4. **Check for disk bottlenecks**

## Security Maintenance

### Rotate Secrets

Periodically rotate sensitive credentials:

1. **Generate new secret value**
2. **Update in source system** (Cloudflare, Tailscale, etc.)
3. **Update SOPS file**:
   ```bash
   sops kubernetes/core/component/secret.sops.yaml
   # Edit value
   # Save (auto-encrypts)
   ```
4. **Commit and push**
5. **ArgoCD applies new secret**

### Security Updates

```bash
# Check for vulnerable images
kubectl get pods -A -o jsonpath="{.items[*].spec.containers[*].image}" | tr ' ' '\n' | sort -u

# Update images by changing tags in application.yaml
# Or use automated tools like Renovate
```

### Audit Access

```bash
# Check Authentik audit logs
# Access https://auth.int.lorenzodebie.be/if/admin/
# Navigate to Events > Logs

# Check Kubernetes audit logs (if enabled)
kubectl logs -n kube-system -l component=kube-apiserver
```

### Review ArgoCD Access

```bash
# List ArgoCD users
argocd account list

# Check RBAC
kubectl get configmap argocd-rbac-cm -n argocd -o yaml
```

## Maintenance Checklist

### Pre-Maintenance

- [ ] Create VM snapshot in Proxmox
- [ ] Verify backups are current
- [ ] Check ArgoCD sync status
- [ ] Review pending alerts
- [ ] Notify users of potential downtime

### Post-Maintenance

- [ ] Verify all pods are running
- [ ] Check ArgoCD sync status
- [ ] Verify external access (Cloudflare, Tailscale)
- [ ] Check certificate status
- [ ] Verify Grafana dashboards load
- [ ] Test application functionality
- [ ] Remove old VM snapshots (keep last 2-3)
