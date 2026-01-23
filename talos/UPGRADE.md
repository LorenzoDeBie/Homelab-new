# Talos Upgrade Guide

This document describes how to upgrade Talos OS and Kubernetes on the homelab cluster.

## Prerequisites

- `talosctl` and `talhelper` CLI tools installed
- Access to the cluster node (192.168.30.50)
- Renovate PR merged with the new version in `talconfig.yaml`

## Upgrade Process

### 1. Merge the Renovate PR

Renovate creates PRs when new Talos or Kubernetes versions are available. Review and merge the PR on GitHub.

### 2. Pull changes locally

```bash
cd ~/Developer/homelab-new
git pull origin main
```

### 3. Regenerate Talos configs

```bash
cd talos
talhelper genconfig
```

This regenerates `clusterconfig/homelab-talos-cp01.yaml` with the new version.

### 4. Check current versions

```bash
# Current Talos version
talosctl --talosconfig clusterconfig/talosconfig --nodes 192.168.30.50 version

# Current Kubernetes version
kubectl version
```

### 5. Review release notes

Before upgrading, check the release notes for breaking changes:

- **Talos**: https://github.com/siderolabs/talos/releases
- **Kubernetes**: https://github.com/kubernetes/kubernetes/releases

## Talos OS Upgrade

Upgrade the Talos OS image on the node:

```bash
# Replace v1.x.x with the target version from talconfig.yaml
talosctl --talosconfig clusterconfig/talosconfig --nodes 192.168.30.50 upgrade \
  --image ghcr.io/siderolabs/installer:v1.x.x
```

The node will:
1. Download the new Talos image
2. Stage the upgrade
3. Reboot automatically

### Wait for node recovery

```bash
# Monitor health (may take 2-5 minutes)
talosctl --talosconfig clusterconfig/talosconfig --nodes 192.168.30.50 health

# Verify new version
talosctl --talosconfig clusterconfig/talosconfig --nodes 192.168.30.50 version
```

## Kubernetes Upgrade

If updating Kubernetes version, apply the new machine config after the Talos upgrade:

```bash
talosctl --talosconfig clusterconfig/talosconfig --nodes 192.168.30.50 \
  apply-config --file clusterconfig/homelab-talos-cp01.yaml
```

Then trigger the Kubernetes upgrade:

```bash
talosctl --talosconfig clusterconfig/talosconfig --nodes 192.168.30.50 \
  upgrade-k8s --to v1.x.x
```

### Verify Kubernetes

```bash
kubectl get nodes
kubectl get pods -A
```

## Expected Downtime

| Operation | Downtime |
|-----------|----------|
| Talos upgrade | ~2-5 minutes (reboot) |
| Kubernetes upgrade | ~1-2 minutes (API restart) |

**Note**: This is a single-node cluster. All workloads will be unavailable during upgrades.

## Rollback

### Talos Rollback

If the Talos upgrade fails, rollback to the previous version:

```bash
talosctl --talosconfig clusterconfig/talosconfig --nodes 192.168.30.50 rollback
```

### Kubernetes Rollback

Kubernetes rollback requires reverting `kubernetesVersion` in `talconfig.yaml`, regenerating configs, and re-applying.

## Troubleshooting

### Node not coming back up

1. Check Proxmox console for boot issues
2. Verify network connectivity
3. Check Talos logs via console

### Kubernetes pods not starting

```bash
# Check node status
kubectl describe node talos-cp01

# Check system pods
kubectl get pods -n kube-system

# Check Cilium status
cilium status
```

### Health check failing

```bash
# Detailed health info
talosctl --talosconfig clusterconfig/talosconfig --nodes 192.168.30.50 health --verbose

# Service status
talosctl --talosconfig clusterconfig/talosconfig --nodes 192.168.30.50 services
```

## Version Compatibility

Talos versions support specific Kubernetes version ranges. Always check the [Talos support matrix](https://www.talos.dev/latest/introduction/support-matrix/) before upgrading.

| Talos Version | Kubernetes Range |
|---------------|------------------|
| v1.12.x | v1.32.x - v1.35.x |

## Quick Reference

```bash
# Set these for convenience
export TALOSCONFIG=~/Developer/homelab-new/talos/clusterconfig/talosconfig
export NODE=192.168.30.50

# Common commands
talosctl --nodes $NODE version
talosctl --nodes $NODE health
talosctl --nodes $NODE services
talosctl --nodes $NODE logs kubelet
talosctl --nodes $NODE dmesg
```
