# Storage Configuration

This document covers the storage architecture, NFS CSI driver setup, StorageClasses, and TrueNAS configuration for the homelab Kubernetes cluster.

## Table of Contents

- [Storage Architecture](#storage-architecture)
- [TrueNAS Configuration](#truenas-configuration)
- [NFS CSI Driver](#nfs-csi-driver)
- [StorageClasses](#storageclasses)
- [Media Storage (Hardlinks)](#media-storage-hardlinks)
- [Application Configuration Storage](#application-configuration-storage)
- [Backup Strategies](#backup-strategies)
- [Troubleshooting](#troubleshooting)

## Storage Architecture

### Overview

```
+------------------------------------------------------------------+
|                       TrueNAS Server                              |
|                                                                   |
|  +----------------------------+  +----------------------------+   |
|  |   Pool: tank (or yours)   |  |                            |   |
|  |                            |  |                            |   |
|  |  +----------------------+  |  |  +----------------------+  |   |
|  |  | Dataset: media       |  |  |  | Dataset: k8s-config  |  |   |
|  |  | /mnt/tank/media      |  |  |  | /mnt/tank/k8s-config |  |   |
|  |  |                      |  |  |  |                      |  |   |
|  |  | ├── downloads/       |  |  |  | ├── media/           |  |   |
|  |  | │   ├── complete/    |  |  |  | │   ├── sonarr/      |  |   |
|  |  | │   └── incomplete/  |  |  |  | │   ├── radarr/      |  |   |
|  |  | ├── tv/              |  |  |  | │   ├── prowlarr/    |  |   |
|  |  | │   └── Shows/       |  |  |  | │   ├── plex/        |  |   |
|  |  | └── movies/          |  |  |  | │   └── qbittorrent/ |  |   |
|  |  |     └── Films/       |  |  |  | ├── observability/   |  |   |
|  |  +----------------------+  |  |  | │   ├── prometheus/  |  |   |
|  |                            |  |  | │   ├── grafana/     |  |   |
|  +----------------------------+  |  | │   └── loki/        |  |   |
|                                  |  | └── authentik/       |  |   |
|                                  |  +----------------------+  |   |
|                                  +----------------------------+   |
+------------------------------------------------------------------+
              |                              |
              | NFS v4.1                     | NFS v4.1
              |                              |
     +--------v--------+            +--------v--------+
     | StorageClass:   |            | StorageClass:   |
     | nfs-media       |            | nfs-config      |
     | (Static PV)     |            | (Dynamic)       |
     +-----------------+            +-----------------+
              |                              |
     +--------v--------+            +--------v--------+
     | PV: media-pv    |            | PVCs created    |
     | 10Ti            |            | per application |
     +-----------------+            +-----------------+
              |
     +--------v--------+
     | PVC: media      |
     | namespace: media|
     +-----------------+
              |
     +--------v--------+
     | Mounted by:     |
     | - Plex (RO)     |
     | - Sonarr (RW)   |
     | - Radarr (RW)   |
     | - qBittorrent   |
     +-----------------+
```

### Storage Principles

1. **Separation of concerns**: Media files separate from config files
2. **Hardlink support**: Single volume for all media apps
3. **Persistence**: Data survives pod restarts and redeployments
4. **ZFS benefits**: Compression, snapshots, data integrity

## TrueNAS Configuration

### Prerequisites

- TrueNAS CORE or SCALE
- ZFS pool created
- Network connectivity to Kubernetes node (192.168.30.0/24)

### Create Datasets

**Via TrueNAS Web UI**:

1. Navigate to Storage > Pools > Your Pool
2. Click the three dots > Add Dataset

**Media Dataset**:
```
Name: media
Compression: lz4
Sync: Standard
Case Sensitivity: Sensitive
Share Type: Generic
```

**K8s-Config Dataset**:
```
Name: k8s-config
Compression: lz4
Sync: Standard
Case Sensitivity: Sensitive
Share Type: Generic
```

### Create NFS Shares

**Via TrueNAS Web UI**:

1. Navigate to Sharing > NFS
2. Click Add

**Media Share**:
```
Path: /mnt/<pool>/media
Maproot User: root
Maproot Group: wheel
Enabled: Yes
Networks: 192.168.30.0/24
```

**K8s-Config Share**:
```
Path: /mnt/<pool>/k8s-config
Maproot User: root
Maproot Group: wheel
Enabled: Yes
Networks: 192.168.30.0/24
```

### Enable NFS Service

1. Navigate to Services
2. Enable NFS
3. Configure:
   - Number of servers: 4 (or more for heavy loads)
   - Enable NFSv4: Yes
   - Require Kerberos: No

### Set Permissions

```bash
# SSH to TrueNAS or use Shell in web UI
chmod 777 /mnt/<pool>/media
chmod 777 /mnt/<pool>/k8s-config

# Or via Web UI: Storage > Pools > Dataset > Edit Permissions
# Mode: 777
# Apply recursively: Yes (for existing data)
```

### Create Media Directory Structure

```bash
# On TrueNAS
mkdir -p /mnt/<pool>/media/downloads/complete
mkdir -p /mnt/<pool>/media/downloads/incomplete
mkdir -p /mnt/<pool>/media/tv
mkdir -p /mnt/<pool>/media/movies

chmod -R 777 /mnt/<pool>/media
```

### Verify NFS Export

From your workstation or Proxmox:

```bash
# Show exports
showmount -e <truenas-ip>

# Test mount
sudo mkdir -p /mnt/test
sudo mount -t nfs <truenas-ip>:/mnt/<pool>/media /mnt/test
ls /mnt/test
sudo umount /mnt/test
```

## NFS CSI Driver

The NFS CSI driver enables Kubernetes to dynamically provision NFS volumes.

### Installation

The driver is deployed via ArgoCD:

```yaml
# kubernetes/core/nfs-csi/application.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nfs-csi
  namespace: argocd
spec:
  source:
    repoURL: https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts
    chart: csi-driver-nfs
    targetRevision: v4.9.0
  destination:
    namespace: kube-system
```

### Verify Installation

```bash
# Check CSI driver pods
kubectl get pods -n kube-system -l app.kubernetes.io/name=csi-driver-nfs

# Check CSI driver
kubectl get csidrivers
# Should show: nfs.csi.k8s.io
```

## StorageClasses

### nfs-media (Static)

Used for the shared media volume. Static because we want a single PV shared by all media apps.

```yaml
# kubernetes/core/nfs-csi/storageclass.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-media
provisioner: nfs.csi.k8s.io
parameters:
  server: TRUENAS_IP          # Update with your TrueNAS IP
  share: /mnt/POOL_NAME/media # Update with your pool name
  mountPermissions: "0777"
reclaimPolicy: Retain
volumeBindingMode: Immediate
mountOptions:
  - nfsvers=4.1
  - hard
  - noatime
```

### nfs-config (Dynamic)

Used for application configuration. Dynamic provisioning creates subdirectories automatically.

```yaml
# kubernetes/core/nfs-csi/storageclass.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-config
provisioner: nfs.csi.k8s.io
parameters:
  server: TRUENAS_IP              # Update with your TrueNAS IP
  share: /mnt/POOL_NAME/k8s-config # Update with your pool name
  mountPermissions: "0777"
  subDir: ${pvc.metadata.namespace}/${pvc.metadata.name}
  onDelete: retain
reclaimPolicy: Retain
volumeBindingMode: Immediate
mountOptions:
  - nfsvers=4.1
  - hard
  - noatime
```

### Verify StorageClasses

```bash
kubectl get storageclass
# Should show:
# NAME         PROVISIONER      RECLAIMPOLICY   VOLUMEBINDINGMODE
# nfs-media    nfs.csi.k8s.io   Retain          Immediate
# nfs-config   nfs.csi.k8s.io   Retain          Immediate
```

## Media Storage (Hardlinks)

### Why Single Media Volume?

The *arr applications (Sonarr, Radarr) and qBittorrent need to share the same filesystem to use hardlinks:

```
Download Flow (without hardlinks - BAD):
1. qBittorrent downloads to /downloads/complete/movie.mkv
2. Radarr copies to /movies/Movie (2024)/movie.mkv
3. Result: 2x disk space used, download can't seed

Download Flow (with hardlinks - GOOD):
1. qBittorrent downloads to /downloads/complete/movie.mkv
2. Radarr creates hardlink at /movies/Movie (2024)/movie.mkv
3. Result: 1x disk space, same file, seeding continues
```

Hardlinks only work on the same filesystem, hence a single shared volume.

### Static PV Configuration

```yaml
# kubernetes/core/nfs-csi/storageclass.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: media-pv
spec:
  capacity:
    storage: 10Ti  # Adjust to your dataset size
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: nfs-media
  csi:
    driver: nfs.csi.k8s.io
    volumeHandle: media-pv
    volumeAttributes:
      server: TRUENAS_IP
      share: /mnt/POOL_NAME/media
  mountOptions:
    - nfsvers=4.1
    - hard
    - noatime
```

### Shared PVC

```yaml
# kubernetes/core/nfs-csi/storageclass.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: media
  namespace: media
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs-media
  resources:
    requests:
      storage: 10Ti
  volumeName: media-pv
```

### Mount in Applications

Each media app mounts the shared PVC:

```yaml
# In application Helm values
persistence:
  media:
    enabled: true
    type: persistentVolumeClaim
    existingClaim: media
    globalMounts:
      - path: /media      # Plex: read-only
        readOnly: true    # Sonarr/Radarr: read-write
```

### Directory Mapping

| App | Mount Path | TrueNAS Path |
|-----|------------|--------------|
| qBittorrent | /media/downloads | /mnt/pool/media/downloads |
| Sonarr | /media | /mnt/pool/media |
| Radarr | /media | /mnt/pool/media |
| Plex | /media | /mnt/pool/media |

### Configure *arr Apps for Hardlinks

In Sonarr/Radarr settings:

1. **Root Folder**: Set to `/media/tv` or `/media/movies`
2. **Download Client**: 
   - Remote Path: `/media/downloads/complete`
   - Category: `tv` or `movies` (optional)

## Application Configuration Storage

Each application gets its own PVC from the `nfs-config` StorageClass.

### Dynamic Provisioning

When an app requests storage:

```yaml
persistence:
  config:
    enabled: true
    type: persistentVolumeClaim
    storageClass: nfs-config
    accessMode: ReadWriteOnce
    size: 5Gi
```

The NFS CSI driver creates:
```
/mnt/<pool>/k8s-config/<namespace>/<pvc-name>/
```

### Example Structure

```
/mnt/tank/k8s-config/
├── media/
│   ├── sonarr-config/
│   │   └── config.xml
│   ├── radarr-config/
│   │   └── config.xml
│   ├── prowlarr-config/
│   │   └── config.xml
│   ├── plex-config/
│   │   └── Plex Media Server/
│   └── qbittorrent-config/
│       └── qBittorrent.conf
├── observability/
│   ├── prometheus-data/
│   ├── grafana-data/
│   └── loki-data/
└── authentik/
    ├── postgresql-data/
    └── redis-data/
```

## Backup Strategies

### ZFS Snapshots (Recommended)

Configure automatic snapshots on TrueNAS:

1. Navigate to Tasks > Periodic Snapshot Tasks
2. Create task:
   - Dataset: `<pool>/media` and `<pool>/k8s-config`
   - Recursive: Yes
   - Lifetime: 2 weeks (adjust as needed)
   - Schedule: Daily

### Manual Snapshot

```bash
# On TrueNAS
zfs snapshot tank/media@backup-$(date +%Y%m%d)
zfs snapshot tank/k8s-config@backup-$(date +%Y%m%d)
```

### List Snapshots

```bash
zfs list -t snapshot
```

### Restore from Snapshot

```bash
# Restore entire dataset
zfs rollback tank/k8s-config@backup-20240101

# Or restore specific files
cd /mnt/tank/k8s-config/.zfs/snapshot/backup-20240101/
cp -r media/sonarr-config /mnt/tank/k8s-config/media/
```

### Replication (Off-site Backup)

For disaster recovery, configure ZFS replication to another TrueNAS or ZFS system:

1. Navigate to Tasks > Replication Tasks
2. Configure SSH connection to remote
3. Set up replication schedule

## Troubleshooting

### PVC Stuck in Pending

```bash
# Check PVC status
kubectl describe pvc <pvc-name> -n <namespace>

# Common issues:
# - NFS server unreachable
# - Wrong server IP in StorageClass
# - NFS share not exported
```

**Verify NFS connectivity**:
```bash
# From Talos node (via talosctl)
talosctl --nodes 192.168.30.50 read /proc/mounts | grep nfs

# Or run a debug pod
kubectl run -it --rm debug --image=busybox -- \
  sh -c "mount -t nfs <truenas-ip>:/mnt/<pool>/media /mnt && ls /mnt"
```

### Mount Failed: Permission Denied

```bash
# Check TrueNAS share permissions
# - Maproot User should be 'root'
# - Network should include Kubernetes node

# Check dataset permissions
# Should be 777 or appropriate user mapping
```

### Stale NFS Handle

Pods may fail with "stale NFS file handle" after TrueNAS restart:

```bash
# Restart affected pods
kubectl rollout restart deployment <deployment-name> -n <namespace>

# Or delete pod to force recreation
kubectl delete pod <pod-name> -n <namespace>
```

### Performance Issues

```bash
# Check NFS stats on TrueNAS
nfsstat -s

# Increase NFS servers if needed
# Services > NFS > Number of servers

# Consider:
# - Enabling jumbo frames (MTU 9000) if supported
# - Using async writes (less safe but faster)
# - Checking network bandwidth
```

### Check Mount Inside Pod

```bash
kubectl exec -it <pod-name> -n <namespace> -- df -h
kubectl exec -it <pod-name> -n <namespace> -- ls -la /media
```

### Verify PV/PVC Binding

```bash
# Check all PVs
kubectl get pv

# Check all PVCs
kubectl get pvc -A

# Describe specific PVC
kubectl describe pvc media -n media
```

### CSI Driver Logs

```bash
# NFS CSI controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=csi-driver-nfs -c nfs

# NFS CSI node logs
kubectl logs -n kube-system -l app.kubernetes.io/name=csi-driver-nfs -c nfs --all-containers
```
