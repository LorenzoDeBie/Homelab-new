# Issue 7: Authentik PostgreSQL Data Directory Ownership on NFS

## Status: RESOLVED (2026-01-21)

## Affected Components
- `authentik-postgresql-0` pod in `authentik` namespace - CrashLoopBackOff
- `authentik-worker-6f664468c8-67wtv` pod in `authentik` namespace - CrashLoopBackOff (downstream, cannot connect to PostgreSQL)

## Error Message
```
2026-01-21 19:07:20.148 UTC [72] FATAL:  data directory "/bitnami/postgresql/data" has wrong ownership
2026-01-21 19:07:20.148 UTC [72] HINT:  The server must be started by the user that owns the data directory.
```

## Root Cause
The PostgreSQL container runs as UID/GID 1001 (configured via `securityContext`), but the NFS share uses `Mapall` to map all access to the `media` user (UID 3001). This caused a mismatch between the running user and file ownership.

## Solution Applied

Instead of using `volumePermissions` (which requires `no_root_squash` on NFS), we configured PostgreSQL to run as UID/GID 3001 to match the NFS `Mapall` setting.

Edit to `kubernetes/core/authentik/application.yaml`:

```yaml
postgresql:
  enabled: true
  auth:
    existingSecret: authentik-secrets
    secretKeys:
      adminPasswordKey: postgresql-password
      userPasswordKey: postgresql-password
  # Run as UID/GID 3001 (media user) to match NFS Mapall setting
  # This avoids needing root_squash disabled on NFS
  primary:
    containerSecurityContext:
      runAsUser: 3001
      runAsGroup: 3001
    podSecurityContext:
      fsGroup: 3001
    persistence:
      enabled: true
      storageClass: nfs-config
      size: 8Gi
```

## Additional Steps Required

After applying the fix, the PostgreSQL data directory needed to be cleared on the NFS server due to corrupted partial initialization data:

```bash
# On TrueNAS server
rm -rf /mnt/main-hdd-raid1/k8s-config/authentik/data-authentik-postgresql-0/*
```

## Verification

All pods are now healthy:

```
$ kubectl get pods -n authentik
NAME                                READY   STATUS    RESTARTS   AGE
authentik-postgresql-0              1/1     Running   0          5m26s
authentik-server-785db8dccd-7hljh   1/1     Running   0          5m5s
authentik-worker-6f664468c8-4hptr   1/1     Running   0          3m29s
```

ArgoCD shows the application as Healthy and Synced.

## Related Issues
- Issue 1 (NFS Permissions) - RESOLVED
- Issue 2 (SOPS Secrets) - RESOLVED

## Lessons Learned
- When using NFS with `Mapall`, configure container UIDs to match the mapped user instead of trying to change file ownership
- This approach is more secure as it doesn't require `no_root_squash` on the NFS export
