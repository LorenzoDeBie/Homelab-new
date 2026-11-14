# Homelab Kubernetes Cluster

GitOps repo for a small homelab: Proxmox VMs running Talos Linux, one control plane and a few
workers, with ArgoCD deploying everything from `main`.

```
Proxmox hosts
└── Talos Linux VMs (terraform/proxmox, talos/talconfig.yaml)
    └── Kubernetes
        ├── Cilium (CNI, Gateway API, LoadBalancer IPs)
        ├── ArgoCD (GitOps, SOPS-encrypted secrets)
        ├── cert-manager, Cloudflare tunnel, Tailscale operator, Authentik
        ├── Media stack (Plex on the iGPU worker, *arr apps)
        └── Observability (Prometheus, Grafana, Loki)

NAS (NFS)
├── media share
└── app config share (nfs-config), including etcd snapshots and the Plex config copy
```

## Where to start

| You want to | Read |
|-------------|------|
| Know how the repo works and its rules | [AGENTS.md](AGENTS.md) |
| Know the target state and what is done | [docs/spec.md](docs/spec.md) |
| Build or rebuild the cluster | [docs/rebuild.md](docs/rebuild.md) |
| Upgrade Talos, Kubernetes or apps | [docs/maintenance.md](docs/maintenance.md) |
| Everything else | [docs/](docs/index.md) (partly out of date; the code wins) |

Node addresses, versions and hostnames are not repeated here. Read them from the source files
listed in [AGENTS.md](AGENTS.md#where-the-truth-lives).

## Bootstrapping

There is one procedure for a first install and for disaster recovery:
[docs/rebuild.md](docs/rebuild.md). It covers the VMs, the Talos bootstrap (with etcd recovery
from the latest snapshot), the SOPS age-key secret, the ArgoCD bootstrap and restoring the
Plex config.

Talos installs and upgrades must use the factory image for each node's schematic, generated
by `talhelper` (`talhelper gencommand upgrade`). Never use the plain
`ghcr.io/siderolabs/installer` image: the Plex worker needs its `i915` extension.
