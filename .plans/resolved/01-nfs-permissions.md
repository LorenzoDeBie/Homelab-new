# Issue 1: NFS Share Permissions Preventing PVC Provisioning

## Status: RESOLVED

## Affected Pods
- `authentik-postgresql-0` (authentik namespace)
- `overseerr-6c5694689f-mrs4l` (media namespace)
- `plex-7b64fd9c9f-4v66k` (media namespace)
- `prowlarr-986c798d9-6qm8d` (media namespace)
- `qbittorrent-686898d4f7-dx6f6` (media namespace)
- `radarr-77c8b64b5f-q7lvt` (media namespace)
- `sonarr-85dbb79f5b-42gqg` (media namespace)
- `kube-prometheus-stack-grafana-b674dfb4b-d9lnp` (observability namespace)

## Error Message
```
failed to provision volume with StorageClass "nfs-config": rpc error: code = Internal desc = failed to make subdirectory: mkdir /tmp/pvc-.../media: permission denied
```

## Root Cause
The NFS CSI driver cannot create subdirectories on the NFS share at `192.168.30.5:/mnt/main-hdd-raid1/k8s-config`. This is typically caused by:

1. **root_squash enabled** - NFS maps root user to `nobody`, preventing directory creation
2. **Restrictive directory permissions** - The share directory doesn't allow writes
3. **Ownership mismatch** - Directory owned by a user the CSI driver can't write as

## StorageClass Configuration
```yaml
# From kubernetes/core/nfs-csi/storageclass.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-config
provisioner: nfs.csi.k8s.io
parameters:
  server: 192.168.30.5
  share: /mnt/main-hdd-raid1/k8s-config
  mountPermissions: "0777"
  subDir: ${pvc.metadata.namespace}/${pvc.metadata.name}
  onDelete: retain
```

## Fix Steps

### Option A: Fix on NFS Server (Recommended)

1. SSH to the NFS server at `192.168.30.5`

2. Check current NFS export configuration:
   ```bash
   cat /etc/exports
   ```

3. Update the export to include `no_root_squash`:
   ```
   /mnt/main-hdd-raid1/k8s-config 192.168.30.0/24(rw,sync,no_subtree_check,no_root_squash)
   ```

4. Apply the new export configuration:
   ```bash
   exportfs -ra
   ```

5. Ensure directory permissions allow writes:
   ```bash
   chmod 777 /mnt/main-hdd-raid1/k8s-config
   # Or set appropriate ownership
   chown -R nobody:nogroup /mnt/main-hdd-raid1/k8s-config
   ```

### Option B: Pre-create Subdirectories

If you cannot modify NFS exports, pre-create the required subdirectories on the NFS server:

```bash
mkdir -p /mnt/main-hdd-raid1/k8s-config/authentik
mkdir -p /mnt/main-hdd-raid1/k8s-config/media
mkdir -p /mnt/main-hdd-raid1/k8s-config/observability
chmod -R 777 /mnt/main-hdd-raid1/k8s-config/*
```

## Verification

After fixing, delete the pending PVCs to trigger re-provisioning:
```bash
kubectl delete pvc -n authentik data-authentik-postgresql-0
kubectl delete pvc -n media overseerr plex prowlarr qbittorrent radarr sonarr
kubectl delete pvc -n observability kube-prometheus-stack-grafana
```

Then verify PVCs become Bound:
```bash
kubectl get pvc --all-namespaces
```

## Resolution (2026-01-21)

The NFS permissions issue has been resolved:

1. **NFS server permissions were fixed** - `no_root_squash` was enabled and directory permissions updated
2. **Stuck PVCs in Terminating state were resolved** by:
   - Deleting the deployments/statefulsets that were using the PVCs (they had `kubernetes.io/pvc-protection` finalizers)
   - The workloads were automatically recreated by ArgoCD
   - New PVCs were provisioned and bound successfully
3. **The static `media-pv` was released** - After the old `media` PVC was deleted, the PV was in `Released` state. The `claimRef` was cleared with:
   ```bash
   kubectl patch pv media-pv --type json -p '[{"op": "remove", "path": "/spec/claimRef"}]'
   ```
4. **The `media` PVC was recreated** by re-applying the storageclass.yaml:
   ```bash
   kubectl apply -f kubernetes/core/nfs-csi/storageclass.yaml
   ```

### Current State

All NFS PVCs are now `Bound`:
- `media` namespace: overseerr, plex, prowlarr, qbittorrent, radarr, sonarr, media (shared)
- `authentik` namespace: data-authentik-postgresql-0
- `observability` namespace: alertmanager, prometheus

All media pods are running. Other pods (authentik, grafana) have unrelated issues documented in other plan files.
