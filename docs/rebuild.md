# Cluster rebuild runbook

How to rebuild the cluster from Git, the SOPS age key and the latest etcd snapshot (spec
REC-2). The target is all-green within 2 hours (spec "Recovery targets").

> **Not drilled yet.** The restore drill is tracked in issue #170. The times below are
> estimates. Replace them with measured ones after the drill.

Follow the steps in order, in one shell (later steps use variables set earlier). Each step
says how to check whether it is already done, so you can pick up again after an interruption.
Commands run from the repo root unless the block starts with a `cd`.

| Step | What | Estimate |
|------|------|----------|
| 0 | [Gather inputs](#0-gather-inputs) | 10 min |
| 1 | [New VMs](#1-new-vms) | 20 min |
| 2 | [Talos bootstrap with etcd recovery](#2-talos-bootstrap-with-etcd-recovery) | 25 min |
| 3 | [SOPS age-key secret](#3-sops-age-key-secret) | 5 min |
| 4 | [ArgoCD bootstrap](#4-argocd-bootstrap) | 30 min |
| 5 | [Restore the Plex config](#5-restore-the-plex-config) | 20 min |
| 6 | [Final checks](#6-final-checks) | 10 min |

**Partial rebuilds.** Lost only a worker VM: do step 1, generate the configs and do 2a for
that node, approve its CSR (2e), and do step 5 if it was talos-wk01. Lost only the control
plane VM: do steps 0 to 2; the workers keep their certificates (same cluster secrets) and
rejoin on their own.

## Where the values come from

Don't copy IPs or versions into this doc or into commands. Take them from:

| Value | Source |
|-------|--------|
| Node names, IPs, Talos and Kubernetes versions, extensions | `talos/talconfig.yaml` |
| Cluster secrets (CA, etcd and secretbox keys) | `talos/talsecret.sops.yaml` |
| VM sizes, hosts, disks, iGPU passthrough | `terraform/proxmox/variables.tf` and the git-ignored `*.tfvars` |
| NAS server and share | `kubernetes/core/nfs-csi/templates/storage.yaml` (`nfs-config`) |
| Chart versions | `Chart.yaml` of each app (Cilium in `kubernetes/core/cilium`, ArgoCD in `kubernetes/core/argocd`) |
| Snapshot schedule and retention | `kubernetes/core/etcd-backup/values.yaml` |

## 0. Gather inputs

You need:

- **A workstation** with this repo on `main`, network access to the node VLAN, and these
  tools: `terraform`, `talhelper`, `talosctl`, `kubectl`, `helm`, `sops`, `yq`. Use a
  `talosctl` with the same minor version as `talosVersion` in `talos/talconfig.yaml`.
- **The age key** (spec BAK-4). Keep it outside the repo, or at the repo root where it is
  git-ignored, and point SOPS at it:

  ```bash
  REPO=$(git rev-parse --show-toplevel); cd "$REPO"
  export SOPS_AGE_KEY_FILE=/path/to/age.key
  sops --decrypt talos/talsecret.sops.yaml >/dev/null && echo "age key OK"
  ```

- **The Terraform inputs:** the real `*.tfvars` for `terraform/proxmox` (git-ignored) and the
  local state, if it survived.
- **Working Proxmox hosts, NAS and DNS (Pi-hole).** This runbook does not rebuild those.
- **The latest etcd snapshot.** The `etcd-backup` CronJob (`kubernetes/core/etcd-backup`)
  stores one per day in `<nfs-config share>/etcd-backup/etcd-snapshots/` on the NAS, named
  `etcd-<UTC timestamp>.db`. Copy the newest one to a directory **outside the repo** (spec SEC-4),
  for example over SMB or `scp` from the NAS:

  ```bash
  mkdir -p ~/rebuild
  # copy the newest etcd-*.db from the NAS into ~/rebuild/, then:
  SNAPSHOT=$(ls -1 ~/rebuild/etcd-*.db | sort | tail -n 1); echo "$SNAPSHOT"
  ```

  The job checks every snapshot with `etcdutl snapshot status` before storing it, and only
  finished files carry the `etcd-*.db` name. Anything since that snapshot (up to 24 h, the RPO)
  is lost from cluster state; ArgoCD re-applies whatever is in Git.

  **No usable snapshot?** Follow the same steps, but use the fresh-bootstrap variants marked
  *Without a snapshot*. Everything that lived only in etcd is then gone; app data on
  `nfs-config` survives (see step 4).

## 1. New VMs

**Talos ISO.** Print the factory ISO URL for each node; version and schematic come from
`talos/talconfig.yaml`:

```bash
talhelper genurl image --config-file talos/talconfig.yaml
```

The ISO only boots Talos into maintenance mode. The installer image for each node, with that
node's extensions, comes from its machine config in step 2, so all VMs can share one ISO. The
Proxmox provider cannot download ISOs: upload it to each Proxmox host's ISO storage, under the
name `talos_iso_path` in your tfvars expects.

**Check the tfvars.** The `talos-wk01` entry must have its data disk (`vm_data_disk_size`,
`vm_data_storage`, backs `local-path`) and iGPU passthrough (`vm_hostpci`, `vm_args`). See the
comments in `terraform/proxmox/variables.tf` and `main.tf`; without them Plex has no config
disk and no transcoding.

**Create the VMs.**

```bash
cd "$REPO/terraform/proxmox"
terraform init
terraform plan
terraform apply
```

- **State present, VMs gone:** the plan creates the missing VMs. Nothing else to do.
- **VM still exists but is broken:** replace it, for example
  `terraform apply -replace='proxmox_vm_qemu.talos_control_planes["<key>"]'`. Keys are in
  `terraform state list`.
- **State lost:** VMs with the same `vm_id` still on Proxmox block the create. Check in the
  Proxmox UI that they are the dead ones, then remove them there (or `terraform import` them)
  and run the plan again.

The VMs start, find an empty disk and boot the ISO. Each shows its maintenance-mode IP on the
Proxmox console. If that IP differs from the node's `ipAddress` in `talos/talconfig.yaml`,
use the console IP for the `--insecure` apply in step 2a.

## 2. Talos bootstrap with etcd recovery

**Generate the machine configs** (into the git-ignored `talos/clusterconfig/`):

```bash
cd "$REPO/talos"
talhelper genconfig
export TALOSCONFIG=$PWD/clusterconfig/talosconfig
CP=$(yq '.nodes[] | select(.controlPlane) | .ipAddress' talconfig.yaml); echo "$CP"
grep -H 'image: factory.talos.dev/' clusterconfig/*.yaml
```

- `talhelper genconfig` decrypts `talsecret.sops.yaml`, so the new nodes get the **same**
  cluster CA and secretbox key as the old ones. That is required: Kubernetes Secrets in the
  snapshot are encrypted with that key. Never run `talhelper gensecret` during a rebuild.
- The `grep` must show one factory installer image per node, built from that node's
  schematic (talos-wk01's differs because it has `i915`). Never replace it with the plain
  `ghcr.io/siderolabs/installer` image.

### 2a. Apply the configs

```bash
talhelper gencommand apply --extra-flags=--insecure
```

This prints one `talosctl apply-config --insecure` per node. Run them all (pipe to `sh`, or
paste them; swap in the console IP for `--nodes` where step 1 told you to). Each node installs
Talos to disk and reboots, which takes a few minutes. For a single node, add
`--node <hostname>`.

### 2b. Wait for etcd to be ready for recovery

```bash
talosctl --nodes "$CP" service etcd
```

Repeat until `STATE` is `Preparing`: etcd is waiting to be bootstrapped. Until the node has
rebooted from disk the call fails to connect; that is expected.

### 2c. Bootstrap etcd from the snapshot

Run this **once**:

```bash
talosctl --nodes "$CP" bootstrap --recover-from="$SNAPSHOT"
```

Don't add `--recover-skip-hash-check`: the snapshot comes from `talosctl etcd snapshot` and
carries its integrity hash. That flag is only for a database file copied out of a data
directory.

*Without a snapshot:* run `talosctl --nodes "$CP" bootstrap` instead.

### 2d. Kubeconfig and health

```bash
talosctl --nodes "$CP" kubeconfig
talosctl --nodes "$CP" health --wait-timeout 30m
talosctl --nodes "$CP" etcd status
kubectl get nodes
```

`talosctl kubeconfig` merges the admin kubeconfig into `~/.kube/config`. With the snapshot
restored, Cilium and everything else ArgoCD had deployed are already in the cluster, so the
nodes go `Ready` once the Cilium pods start on them.

*Without a snapshot:* the nodes stay `NotReady` until there is a CNI, and `talosctl health`
waits for that. Install Cilium from the chart version and values ArgoCD uses (ArgoCD adopts it
in step 4):

```bash
cd "$REPO"
helm dependency build kubernetes/core/cilium
yq '.cilium' kubernetes/core/cilium/values.yaml > /tmp/cilium-values.yaml
helm install cilium kubernetes/core/cilium/charts/cilium-*.tgz \
  --namespace kube-system -f /tmp/cilium-values.yaml \
  --set prometheus.serviceMonitor.enabled=false \
  --set operator.prometheus.serviceMonitor.enabled=false \
  --set hubble.metrics.serviceMonitor.enabled=false
kubectl -n kube-system rollout status daemonset/cilium --timeout=10m
```

The ServiceMonitors are off because their CRDs only arrive with
kube-prometheus-stack; ArgoCD turns them back on.

### 2e. Approve kubelet serving certificates

The kubelets run with `rotate-server-certificates` and nothing in the cluster approves their
serving CSRs. Until you do, `kubectl logs`, `kubectl exec` and metrics-server fail.

```bash
kubectl get csr
kubectl certificate approve <name>   # each Pending kubernetes.io/kubelet-serving CSR from a node
```

## 3. SOPS age-key secret

ArgoCD's repo-server decrypts every `*.sops.yaml` with the key in Secret `sops-age`
(namespace `argocd`, key `keys.txt`).

**Check** (shows key names and sizes, not values):

```bash
cd "$REPO"
kubectl -n argocd describe secret sops-age
```

With the snapshot restored it is already there, with a `keys.txt` entry. If it is missing
(fresh bootstrap, or it was never in the snapshot), create it:

```bash
kubectl apply -f kubernetes/bootstrap/argocd/namespace.yaml
kubectl -n argocd create secret generic sops-age --from-file=keys.txt="$SOPS_AGE_KEY_FILE"
```

If the repo-server was already running without it, restart it so it mounts the key:
`kubectl -n argocd rollout restart deployment/argocd-repo-server`.

## 4. ArgoCD bootstrap

**Check:**

```bash
kubectl -n argocd get pods
kubectl -n argocd get applications
```

With the snapshot restored, ArgoCD and its Applications are already there; skip to
*Root apps*.

*Without a snapshot*, or if ArgoCD is broken, install it with the chart version pinned in
`kubernetes/core/argocd/Chart.yaml` and the bootstrap values (which include the SOPS plugin):

```bash
helm dependency build kubernetes/core/argocd
helm install argocd kubernetes/core/argocd/charts/argo-cd-*.tgz \
  --namespace argocd -f kubernetes/bootstrap/argocd/values.yaml
kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=10m
kubectl -n argocd rollout status deployment/argocd-server --timeout=10m
```

**Root apps.** Apply the three app-of-apps (harmless if they already exist):

```bash
kubectl apply -f kubernetes/core/argocd-apps.yaml \
  -f kubernetes/apps/apps.yaml \
  -f kubernetes/observability/observability.yaml
```

`core` includes `kubernetes/core/argocd/application.yaml`, so ArgoCD takes over its own
install. Watch until everything is `Synced` and `Healthy`:

```bash
kubectl -n argocd get applications -w
```

Sync waves bring up secrets, Cilium and ArgoCD first. If an app shows a SOPS error, recheck
step 3. If talos-wk01 was rebuilt, `plex` stays unhealthy until step 5.

*Without a snapshot:* PVCs on `nfs-config` come back on their old NAS directories, because the
StorageClass names them `<namespace>/<pvc name>`, so app config survives. Anything that lived
only in the cluster is new: certificates are reissued, Tailscale devices register again, and
local-path volumes start empty.

## 5. Restore the Plex config

**Skip this step if talos-wk01's data disk survived.** Plex then starts on its own config.

Plex keeps its config on a `local-path` volume on talos-wk01's data disk, and a new VM has an
empty disk. With the snapshot restored, the old PersistentVolume points at a directory that no
longer exists, so the Plex pod hangs in `ContainerCreating`. Without a snapshot, Plex may
already have started on an empty volume as a new, unclaimed server. Either way, replace the
volume with the nightly NAS copy before Plex runs for real.

The backup CronJob refuses to run against a config without a library database, so the NAS copy
is safe meanwhile. It is still paused below, to be sure.

```bash
# Stop ArgoCD undoing the manual steps. Pause the root app too: it would
# otherwise restore plex's sync policy within minutes.
kubectl -n argocd patch application apps --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl -n argocd patch application plex --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'

# Stop Plex and the nightly backup.
kubectl -n media scale deployment/plex --replicas=0
kubectl -n media patch cronjob plex-config-backup -p '{"spec":{"suspend":true}}'

# The NAS copy must be Bound.
kubectl -n media get pvc plex-config-backup

# Drop the empty or dangling volume.
PV=$(kubectl -n media get pvc plex -o jsonpath='{.spec.volumeName}'); echo "$PV"
kubectl -n media delete pvc plex
kubectl delete pv "$PV"

# Copy the NAS copy onto a new local-path volume.
kubectl apply -f docs/plex-config-restore.yaml
kubectl -n media wait --for=condition=complete job/plex-config-restore --timeout=60m
kubectl -n media logs job/plex-config-restore | tail -n 20
kubectl -n media delete job plex-config-restore   # keep the PVC

# Hand Plex back to ArgoCD.
kubectl apply -f kubernetes/apps/apps.yaml
kubectl -n media patch cronjob plex-config-backup -p '{"spec":{"suspend":false}}'
kubectl -n media scale deployment/plex --replicas=1
```

`kubectl -n media get pvc plex` shows the new volume (it binds once the Job is scheduled). If
the Job fails, read its log: it refuses to run when the NAS copy has no library database or
the target is not empty.

**Check:**

```bash
kubectl -n argocd get application plex -o jsonpath='{.spec.syncPolicy.automated}{"\n"}'
kubectl -n media get pods -o wide            # plex Running on talos-wk01
kubectl -n media exec deployment/plex -- df -h /config   # a local disk, not the NAS
```

Open Plex: the libraries and watch history are there, and it is the same server, not a new
one asking to be claimed. Then run the backup once:
`kubectl -n media create job --from=cronjob/plex-config-backup plex-config-backup-after-rebuild`.

## 6. Final checks

```bash
kubectl -n argocd get applications          # all Synced and Healthy
kubectl get pods -A | grep -vE 'Running|Completed'
kubectl -n etcd-backup create job --from=cronjob/etcd-backup etcd-backup-after-rebuild
```

- The manual etcd backup gives the rebuilt cluster a fresh snapshot. Check that it lands on
  the NAS.
- Check a public hostname (`kubernetes/core/cloudflared/application.yaml`) through the tunnel
  and an internal one (`*.int.<domain>`) over Tailscale.
- Delete `~/rebuild/` and `/tmp/cilium-values.yaml`. `talos/clusterconfig/` stays git-ignored.
- Write down how long each step took and update the estimates above.
