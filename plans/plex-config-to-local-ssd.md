# Plex Config Migration - NFS HDD to Local SSD

> **Status: COMPLETED 2026-08-16.** Total Plex downtime ~35 minutes, of which
> 14 was the data copy. Verified after cutover: `/config` is `/dev/sdb1` (xfs),
> `du` on the config tree dropped from >120s to 1s, machineIdentifier and
> claimed status preserved, 92 movies / 31 shows / 2852 episodes / 413 watch
> history rows / 44 accounts all intact.
>
> Lessons recorded in "What actually happened" at the bottom - read that before
> reusing this runbook.

## Problem
Plex stores its library in SQLite (`com.plexapp.plugins.library.db` 47MB,
`com.plexapp.plugins.library.blobs.db` 119MB, plus `-wal`/`-shm`). The config PVC lives on
`nfs-config` -> `192.168.30.5:/mnt/main-hdd-raid1/k8s-config/media/plex`.

Three compounding issues:
1. SQLite over NFS. The mount reports `local_lock=none`, so every database lock is a
   network round-trip instead of a local `fcntl`.
2. Spinning HDD RAID1. Random 4K I/O against a seek-bound array.
3. Contention. The same pool serves the whole media library to nzbget, qbittorrent and
   the *arr scanners, so Plex stalls exactly when downloads and imports are busy.

Measured: `du -sh` on the 4.0GB config directory took over 120 seconds.

## Solution
`talos-wk01` has an unused 107GB `data-zfs` (SSD) backed disk at `/dev/sdb` - no partition
table, never claimed. Plex is already pinned to `talos-wk01` for the Intel iGPU, and the
config is only 4.0GB.

- Talos `UserVolumeConfig` claims `/dev/sdb` and mounts it at `/var/mnt/local-path`.
- `local-path-provisioner` serves a `local-path` StorageClass from that directory.
- Plex's config PVC moves to `local-path`.

Media stays on NFS (`nfs-media`, read-only) - it is large sequential reads, which NFS
over HDD handles fine. Transcode stays on `emptyDir`, already local.

## Changes in Git
| File | Change |
|------|--------|
| `talos/talconfig.yaml` | `UserVolumeConfig` named `local-path` on `talos-wk01` |
| `kubernetes/core/local-path-provisioner/` | New umbrella chart + ArgoCD Application |
| `kubernetes/apps/media/plex/values.yaml` | config `storageClass: local-path` |
| `kubernetes/core/nfs-csi/templates/storage.yaml` | Removed the `nfs-plex` StorageClass |

## Execution

### Step 1 - Claim the disk on talos-wk01
```bash
cd talos
SOPS_AGE_KEY_FILE=../age.key talhelper genconfig
talosctl --talosconfig clusterconfig/talosconfig --nodes 192.168.40.52 \
  apply-config --file clusterconfig/homelab-talos-wk01.yaml
```

Verify the volume is provisioned and mounted (no reboot required for user volumes):
```bash
talosctl --talosconfig clusterconfig/talosconfig --nodes 192.168.40.52 \
  get volumestatus | grep local-path
talosctl --talosconfig clusterconfig/talosconfig --nodes 192.168.40.52 \
  get discoveredvolumes | grep sdb
```
Expect a `u-local-path` volume, phase `ready`, location `/dev/sdb1`, xfs.

### Step 2 - Deploy the provisioner
Commit and push. The `core` app-of-apps globs `*/*application.yaml` under
`kubernetes/core`, so it registers automatically.

```bash
kubectl get sc local-path
kubectl get pods -n kube-system -l app.kubernetes.io/name=local-path-provisioner
```

### Step 3 - Migrate the data (Plex downtime starts here)

Stop ArgoCD fighting the manual steps:
```bash
argocd app set plex --sync-policy none
kubectl scale deploy/plex -n media --replicas=0
```

Delete the old PVC. `reclaimPolicy: Retain` and `onDelete: retain` mean the NAS data at
`/mnt/main-hdd-raid1/k8s-config/media/plex` survives untouched:
```bash
kubectl delete pvc plex -n media
```

Apply the migration job below. It mounts the old NFS path read-only via a static PV and
the new `local-path` PVC, then copies. The Job's `nodeSelector` is what triggers
`WaitForFirstConsumer` to bind the new PV on `talos-wk01`.

```bash
kubectl apply -f plex-migrate.yaml   # manifest at the bottom of this file
kubectl wait --for=condition=complete job/plex-config-migrate -n media --timeout=30m
kubectl logs -n media job/plex-config-migrate | tail -20
```

Verify sizes match, then clean up and restart Plex:
```bash
kubectl delete -f plex-migrate.yaml
argocd app set plex --sync-policy automated --self-heal
argocd app sync plex
kubectl get pvc plex -n media          # expect STORAGECLASS local-path
kubectl exec -n media deploy/plex -- df -h /config
```

`df -h /config` must show a local xfs filesystem, not `192.168.30.5:...`.

### Step 4 - Validate
- Plex UI loads, libraries intact, watch history intact.
- `du -sh "/config/Library/Application Support/Plex Media Server"` returns in under a second.
- Start a 4K transcode while nzbget is downloading; the UI should stay responsive.

## Rollback
The NFS copy is untouched at `/mnt/main-hdd-raid1/k8s-config/media/plex`. Revert
`kubernetes/apps/media/plex/values.yaml` to `storageClass: nfs-config`, delete the
`local-path` PVC, and let ArgoCD re-provision against NFS. Any watch history recorded
after the cutover is lost on rollback.

## Follow-ups (not in this change)
1. **Plex memory limit exceeds the node.** `limits.memory: 8Gi` on a node with 7.6Gi
   allocatable, and `requests: 2000m CPU / 4Gi` on a 4-core / 8GB node. The scheduler
   already logged repeated `FailedScheduling: Insufficient cpu / Insufficient memory` for
   Plex. Actual steady-state usage is 145Mi / 17m. This is an independent cause of
   "server stops responding" and should be brought down to something like
   `requests: 500m / 1Gi`, `limits: 6Gi`.
2. **`/dev/sdb` is not managed by Terraform.** `terraform/proxmox/main.tf` only declares
   `scsi0`; the `vm_data_disk_size` / `vm_data_storage` keys in `terraform.auto.tfvars`
   are unused. A `terraform apply` may try to detach the disk. Add `scsi1` to the
   `talos_workers` resource before the next apply.
3. **Other SQLite apps on NFS.** sonarr, radarr, prowlarr, bazarr, qbittorrent, tautulli
   and the Prometheus/Loki PVCs are all on `nfs-config` with the same problem, though
   their databases are far smaller. `talos-wk02` has no second disk, so moving those
   needs a disk added there first.

---

## What actually happened

Five things diverged from the plan above. Fix the runbook before reusing it.

### 1. Suspend both ArgoCD apps, not just `plex`
The `apps` root app-of-apps has `selfHeal: true` and reverts a suspended child
within minutes. Both `apps` and `plex` must be suspended, or the sync policy
change has to go through Git.

### 2. Apply the Talos change surgically, not with the full config
`talosctl apply-config` with the talhelper-generated file also carried unrelated
drift: the installer image would have flipped from `metal-installer:v1.12.4` to
`nocloud-installer:v1.12.5`, changing future upgrade behaviour. Used instead:

```bash
talosctl --nodes 192.168.40.52 patch machineconfig --patch @uservolume.yaml
```

**This drift is still present.** The repo and the running node disagree about
the installer image. Worth reconciling deliberately, separately.

### 3. `pathPattern` was rejected, twice
local-path-provisioner requires any `pathPattern` to start with
`{{ .PVC.Namespace }}/{{ .PVC.Name }}/` *and* carry a further path segment.
Both `namespace-name` and `namespace/name` were rejected. Dropped it; the
default naming (`pvc-<uid>_<namespace>_<name>`) needs no configuration.

### 4. StorageClass.parameters is immutable
Changing it makes ArgoCD retry a forbidden patch forever. The chart's
`storageClass.annotations` now carries `argocd.argoproj.io/sync-options:
Replace=true`.

**Worse: ArgoCD does not detect a *removed* key in `parameters` as a diff.** It
reported `Synced` while the live StorageClass still held the stale value. The
StorageClass had to be deleted by hand to force a clean recreate. This is a
general footgun in this repo, not specific to this chart - any change that only
removes a field can show as Synced while the cluster disagrees with Git.

After changing the StorageClass, restart the provisioner: it caches the class
and keeps using the old parameters otherwise.

### 5. Serial rsync was ~20x too slow
`rsync -aHAX` over NFS managed 174MB in 9 minutes - a ~3.5 hour projection. Two
causes: `-A` (ACLs) and `-X` (xattrs) each add per-file round-trips, and the
workload is latency-bound, not bandwidth-bound. Replaced with `rsync -a` plus
8-way parallelism over each heavy tree's immediate children. Copy finished in 14
minutes. See the appendix job.

Note `du`-based progress via the kubelet stats API is unreliable for `local`
volumes - it reported 2.13GB when the real figure was 174MB. Measure with
`kubectl exec ... du -sh` against the target instead.

### 6. kubelet needs `rbind`, not `bind`, for /var/mnt
The original `talconfig.yaml` mounted `/var/mnt` into kubelet with `bind`. A
plain bind mount does not carry submounts, so a Talos user volume mounted during
boot - before kubelet starts - is invisible to kubelet, which silently falls back
to the bare directory on the EPHEMERAL partition.

This did not show up during the migration because the user volume was created
while the node was running: `rshared` propagates mounts made *after* kubelet
starts. The first reboot exposed it, and Plex failed with
`MountVolume.NewMounter initialization failed ... path does not exist`.

Fixed by changing the option to `rbind`. Verified across a reboot.

**Diagnostic trap:** `talosctl ls` and `talosctl usage` do not cross mount
boundaries. Pointed at `/var/mnt/local-path` they list the empty mount *point*,
not the mounted filesystem, which reads exactly like an empty disk. This
produced a false "the data is gone" conclusion and an unnecessary second
migration. To inspect a user volume's real contents, use a pod with a hostPath
mount and run `df`/`du` inside it.

### 7. iGPU passthrough flags are load-bearing and undeclared
Terraform stripped `hostpci0` because it was configured only on the hypervisor,
and the VM then refused to start because `args` still referenced it. The
working config, recovered from the pve-beelink journal, is:

```
hostpci0: 00:02.0,pcie=1,x-vga=1,rombar=0
```

`x-vga=1` is essential: without it the Alder Lake-N iGPU hangs the Talos guest
during i915 init at ~4.8s into boot. Now declared in `main.tf` as
`primary_gpu = true` / `rombar = false`.

**When a VM config is lost, search the journal before reconstructing it:**
`journalctl | grep -i hostpci` on the Proxmox host records every `qm set`.

### Rollback is still available
The pre-migration copy is untouched on the NAS at
`/mnt/main-hdd-raid1/k8s-config/media/plex`, and PV
`pvc-2a24d9fe-4a30-4269-84a8-fde6d6fadee0` is `Released`, not deleted. Delete
both once you are confident, to reclaim ~4GB.

---

## Appendix: plex-migrate.yaml

```yaml
# Static PV pointing at the existing Plex config on the NAS, read-only.
apiVersion: v1
kind: PersistentVolume
metadata:
  name: plex-config-nfs-old
spec:
  capacity:
    storage: 50Gi
  accessModes:
    - ReadOnlyMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  csi:
    driver: nfs.csi.k8s.io
    volumeHandle: plex-config-nfs-old
    volumeAttributes:
      server: 192.168.30.5
      share: /mnt/main-hdd-raid1/k8s-config/media/plex
  mountOptions:
    - nfsvers=4.1
    - hard
    - noatime
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: plex-config-nfs-old
  namespace: media
spec:
  accessModes:
    - ReadOnlyMany
  storageClassName: ""
  volumeName: plex-config-nfs-old
  resources:
    requests:
      storage: 50Gi
---
# New PVC on local-path. Same name and size the Helm chart will render, so ArgoCD
# adopts it instead of creating a second one when Plex is re-enabled.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: plex
  namespace: media
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 50Gi
---
apiVersion: batch/v1
kind: Job
metadata:
  name: plex-config-migrate
  namespace: media
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      nodeSelector:
        kubernetes.io/hostname: talos-wk01
      containers:
        - name: copy
          image: alpine:3.22
          command:
            - sh
            - -euxc
            - |
              apk add --no-cache rsync findutils
              SRC=/src
              DST=/dst
              PMS="Library/Application Support/Plex Media Server"

              # No -A/-X: ACL and xattr preservation costs extra NFS round-trips
              # per file, and Plex needs neither (ownership is reset below).
              RS="rsync -a --numeric-ids"

              # Pass 1: everything except the heavy trees. Small and sequential.
              $RS \
                --exclude="/$PMS/Metadata/" \
                --exclude="/$PMS/Media/" \
                --exclude="/$PMS/Cache/" \
                "$SRC/" "$DST/"
              echo "=== pass 1 done ==="

              # Pass 2: heavy trees, parallel over immediate children. This is a
              # latency-bound workload, so concurrency is what buys throughput.
              for top in Metadata Media Cache; do
                [ -d "$SRC/$PMS/$top" ] || continue
                mkdir -p "$DST/$PMS/$top"
                ls -1 "$SRC/$PMS/$top" \
                  | xargs -P 8 -I{} $RS "$SRC/$PMS/$top/{}" "$DST/$PMS/$top/"
                echo "=== $top done ==="
              done

              chown -R 3001:3001 "$DST"
              echo "=== TARGET ==="; du -sh "$DST"
          volumeMounts:
            - name: src
              mountPath: /src
              readOnly: true
            - name: dst
              mountPath: /dst
      volumes:
        - name: src
          persistentVolumeClaim:
            claimName: plex-config-nfs-old
            readOnly: true
        - name: dst
          persistentVolumeClaim:
            claimName: plex
```
