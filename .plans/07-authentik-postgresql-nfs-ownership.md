# Issue 7: Authentik PostgreSQL Data Directory Ownership on NFS

## Status: OPEN

## Affected Components
- `authentik-postgresql-0` pod in `authentik` namespace - CrashLoopBackOff
- `authentik-worker-6f664468c8-67wtv` pod in `authentik` namespace - CrashLoopBackOff (downstream, cannot connect to PostgreSQL)

## Error Message
```
2026-01-21 19:07:20.148 UTC [72] FATAL:  data directory "/bitnami/postgresql/data" has wrong ownership
2026-01-21 19:07:20.148 UTC [72] HINT:  The server must be started by the user that owns the data directory.
```

## Root Cause
The PostgreSQL container runs as UID/GID 1001 (configured via `securityContext`):

```yaml
securityContext:
  runAsUser: 1001
  runAsGroup: 1001
  fsGroup: 1001
```

However, when the NFS volume is mounted, the directory ownership is determined by the NFS server, not by Kubernetes `fsGroup`. NFS typically ignores `fsGroup` unless specific mount options are used.

The NFS-mounted directory at `/bitnami/postgresql` is owned by root (or another user from the NFS server), but PostgreSQL requires the data directory to be owned by the user running the process (UID 1001).

## Fix Options

### Option A: Fix Permissions on NFS Server (Recommended)

Create and set ownership of the PostgreSQL data directory on the NFS server:

```bash
# SSH to NFS server at 192.168.30.5
ssh root@192.168.30.5

# Find the PVC subdirectory
ls -la /mnt/main-hdd-raid1/k8s-config/authentik/

# Set ownership to UID 1001 (PostgreSQL container user)
chown -R 1001:1001 /mnt/main-hdd-raid1/k8s-config/authentik/data-authentik-postgresql-0/
```

After setting permissions, delete and let the pod restart:
```bash
kubectl delete pod authentik-postgresql-0 -n authentik
```

### Option B: Add Init Container to Fix Permissions

Update the Authentik Helm values to add an init container that fixes permissions before PostgreSQL starts. This works even if NFS root_squash is disabled.

Edit `kubernetes/core/authentik/application.yaml`:

```yaml
postgresql:
  enabled: true
  primary:
    # Add init container to fix NFS permissions
    initContainers:
      - name: init-chmod-data
        image: busybox:latest
        command:
          - sh
          - -c
          - |
            chown -R 1001:1001 /bitnami/postgresql
            chmod 700 /bitnami/postgresql/data || true
        securityContext:
          runAsUser: 0
        volumeMounts:
          - name: data
            mountPath: /bitnami/postgresql
    persistence:
      enabled: true
      storageClass: nfs-config
      size: 8Gi
```

**Note:** This requires `no_root_squash` on the NFS export, which was already configured for Issue 1.

### Option C: Use Local Storage Instead of NFS

PostgreSQL has strict requirements for filesystem behavior that NFS may not fully support (fsync, file locking). Consider using local storage or a different storage backend:

1. Create a local-path StorageClass
2. Update the Authentik PostgreSQL to use local storage

```yaml
postgresql:
  primary:
    persistence:
      storageClass: local-path  # Instead of nfs-config
```

This approach is more reliable for databases but loses the ability to migrate pods between nodes.

### Option D: Use Bitnami-Specific Helm Values

The Bitnami PostgreSQL chart (used by Authentik) has specific options for volume permissions:

```yaml
postgresql:
  primary:
    # Use Bitnami's built-in volume permission init container
    volumePermissions:
      enabled: true
      # This adds an init container that runs as root to fix permissions
```

Edit `kubernetes/core/authentik/application.yaml`:

```yaml
postgresql:
  enabled: true
  auth:
    existingSecret: authentik-secrets
    secretKeys:
      adminPasswordKey: postgresql-password
      userPasswordKey: postgresql-password
  primary:
    # Enable volume permissions init container
    volumePermissions:
      enabled: true
    persistence:
      enabled: true
      storageClass: nfs-config
      size: 8Gi
```

## Recommended Fix

Use **Option D** (Bitnami volumePermissions) as it:
- Uses built-in chart functionality
- Requires minimal configuration changes
- Works with the existing NFS setup (assuming `no_root_squash` is enabled)

## Implementation

Edit `kubernetes/core/authentik/application.yaml`, add under `postgresql.primary`:

```yaml
postgresql:
  enabled: true
  auth:
    existingSecret: authentik-secrets
    secretKeys:
      adminPasswordKey: postgresql-password
      userPasswordKey: postgresql-password
  primary:
    volumePermissions:
      enabled: true
    persistence:
      enabled: true
      storageClass: nfs-config
      size: 8Gi
```

Commit and push:
```bash
git add kubernetes/core/authentik/application.yaml
git commit -m "fix(authentik): enable volumePermissions for PostgreSQL on NFS"
git push
```

## Verification

```bash
# Watch the pod restart
kubectl get pods -n authentik -w

# Check PostgreSQL logs
kubectl logs authentik-postgresql-0 -n authentik

# Once PostgreSQL is running, the worker should also start
kubectl get pods -n authentik

# Check authentik server is responding
kubectl logs -n authentik -l app.kubernetes.io/component=server --tail=20
```

## Related Issues
- Issue 1 (NFS Permissions) - RESOLVED: Enabled `no_root_squash` on NFS server
- Issue 2 (SOPS Secrets) - RESOLVED: Secrets are now deployed

## Notes
- The `authentik-worker` pod failure is a downstream issue - it cannot connect to PostgreSQL because PostgreSQL is not running. It will auto-recover once PostgreSQL is healthy.
- If `volumePermissions` doesn't work, fall back to Option A (manual NFS permission fix).
