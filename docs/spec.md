# Homelab target-state spec

This document says what the homelab **should be**. Each requirement has an ID, a check that proves
it, and a status that says where things stand today. Issues and PRs reference requirement IDs,
e.g. "Implements REC-1".

Status values: **met**, **partial**, **planned**, **deferred** (wanted eventually, but no work
planned; don't create tickets for it. A parked design may exist as a `needs-triage` issue). When
a PR changes a status, update it here in the same PR.

## 1. Purpose and scope

A small homelab that serves media to the household and a few remote users, plus the supporting
services (SSO, monitoring, remote access). It should run without attention and survive an
unclean power cut. When something does break, it should be easy to notice and fast to rebuild
from Git and backups.

In scope: the Proxmox hosts, the Talos/Kubernetes cluster and everything ArgoCD deploys, the
NAS as far as the cluster depends on it, Tailscale and the Cloudflare tunnel.

## 2. Constraints and non-goals

### Fixed choices

| Area | Choice |
|------|--------|
| Virtualisation | Proxmox VE |
| Cluster OS | Talos Linux |
| Media | Plex with Intel QuickSync hardware transcoding |
| Remote access (private) | Tailscale |
| Public exposure | Cloudflare tunnel |
| Delivery | GitOps from this repo (ArgoCD today; open to alternatives) |

### Non-goals

- **No inbound ports on the home router.** Public services go out through the tunnel only.
- **No high availability**, for Plex or anything else. There is no UPS, so a power cut takes
  every host down at once. A tested rebuild is the target instead.
- **No UPS.** The design assumes unclean power loss.
- **No offsite backup of media.** Media can be re-acquired; the app configs that make that
  possible are backed up.
- **No multi-control-plane cluster** unless spare hardware appears.

### Recovery targets

| Data | RPO (max data loss) | Where it must survive |
|------|---------------------|-----------------------|
| Cluster state (etcd) | 24 h | NAS + offsite |
| App config (*arr, SSO, Plex) | 24 h | NAS + offsite |
| Metrics and logs | Not protected | Rebuilt empty |
| Media | Not protected | NAS only (RAID) |

| Scenario | RTO (time to all-green) |
|----------|-------------------------|
| Power cut, power returns | 20 min, no human action |
| One Proxmox host lost | 2 h after replacement hardware is available |
| Full cluster rebuild | 2 h |

## 3. Topology

Described by role. Concrete names, IPs and versions live in `talos/talconfig.yaml` and
`terraform/proxmox/`.

- **Proxmox host with iGPU:** the control-plane VM and the Plex worker VM (iGPU passthrough).
  Also a Pi-hole container.
- **Second Proxmox host:** one general-purpose worker VM.
- **NAS:** NFS for app config and media, a second Pi-hole, and offsite sync. It has out-of-band
  management (IPMI).
- **Network:** TP-Link Omada gateway and switches with two VLANs: management (Proxmox hosts, NAS,
  DNS) and apps (Talos nodes, load-balancer IPs). Tailscale routes both. Traffic between the
  VLANs is governed by SEC-8.

## 4. Service catalogue

| Service | Purpose | Users | Reached via | Data and protection | Acceptable downtime |
|---------|---------|-------|-------------|---------------------|---------------------|
| Plex | Media playback | Household (mostly LAN), a few remote users | LAN; tunnel for remote | Config on node-local disk, nightly copy to NAS | Hours; remote users accept outages |
| Sonarr, Radarr, Prowlarr, Bazarr | Media management | Admin | Internal gateway + SSO | `nfs-config` | Days |
| Download clients (usenet, torrent) | Fetching media | Admin | Internal gateway + SSO | `nfs-config` | Days |
| Seerr | Media requests | Household, remote users | Tunnel | `nfs-config` | Days |
| Tautulli | Plex statistics | Admin | Internal gateway + SSO | `nfs-config` | Days |
| Homepage | Dashboard | Admin | Internal gateway + SSO | None | Days |
| Authentik | SSO for internal apps | Admin | Internal gateway | Postgres on `nfs-config` | Hours (blocks internal UIs) |
| ArgoCD | GitOps delivery | Admin | Internal gateway, OIDC | Rebuilt from Git | Hours |
| Prometheus, Grafana, Loki, Alertmanager | Monitoring and alerting | Admin | Internal gateway, OIDC | Rebuildable | Hours, if OBS-1 covers the gap |
| Tailscale subnet router and exit node | Remote admin access, travel VPN | Admin, household | Tailnet | None | Hours |
| Cloudflare tunnel | Public exposure | Remote users | Internet | None | Hours |

## 5. Requirements

### Recovery (REC)

| ID | Requirement | Verify | Status |
|----|-------------|--------|--------|
| REC-1 | After power returns, every host, VM and service comes back without human action within the RTO. | Breaker drill: power off at the breaker, restore, time to all-green. | partial |
| REC-2 | The cluster can be rebuilt from Git, the age key and the latest etcd snapshot by following a written runbook. | Restore drill into a fresh VM, at least yearly. | planned |
| REC-3 | Remote admin access (tailnet route to the home networks, Proxmox UI, NAS out-of-band management) works while the cluster is down. | Stop the cluster VMs, reach Proxmox and IPMI over Tailscale. | planned |
| REC-4 | Losing the Plex host or its iGPU does not take down the rest of the cluster. | Shut down the Plex worker VM; other apps stay up. | partial |

### Backup (BAK)

| ID | Requirement | Verify | Status |
|----|-------------|--------|--------|
| BAK-1 | etcd is snapshotted daily to the NAS, with at least 7 days retained. | Snapshot files with recent timestamps on the NAS. | planned |
| BAK-2 | App config on `nfs-config` (excluding metrics and logs) is copied offsite daily from a consistent NAS snapshot. | Offsite bucket shows a copy under 24 h old. | planned |
| BAK-3 | Plex config is copied nightly from node-local disk to the NAS. | Backup job succeeds; copy is under 24 h old. | met |
| BAK-4 | The SOPS age key has at least two independent copies, one of them usable without any homelab hardware. | Recover the key from the second copy. | partial |
| BAK-5 | A restore from offsite is tested for at least one app per year. | App starts with restored config. | planned |

### Observability (OBS)

| ID | Requirement | Verify | Status |
|----|-------------|--------|--------|
| OBS-1 | If the cluster or its alerting stops working, an alert reaches the admin from outside the homelab within 15 minutes. | Stop Alertmanager; external dead man's switch fires. | planned |
| OBS-2 | etcd, nodes, NFS mounts and certificates are monitored, with alerts on failure. | `up` is 1 for every scrape target; test alert fires. | partial |
| OBS-3 | Backup jobs (BAK-1, BAK-2, BAK-3) alert when they fail or don't run. | Break a job; alert fires. | planned |

### Change safety (CHG)

| ID | Requirement | Verify | Status |
|----|-------------|--------|--------|
| CHG-1 | Every PR to `main` runs automated checks: Helm render, Kubernetes schema validation, Talos config generation, Terraform validation. | CI runs on a test PR. | planned |
| CHG-2 | `main` is protected. Changes land through PRs with green checks. | Direct push is rejected. | planned |
| CHG-3 | Renovate automerges only low-risk updates, after CI passes. Core platform components (CNI, Gateway API, ArgoCD, cert-manager, Talos) need a manual merge. | Renovate config review; a core update opens a PR without merging. | planned |
| CHG-4 | Every chart and image version is pinned. No `latest` or `*`. | Search the repo for unpinned versions. | partial |
| CHG-5 | The Talos upgrade runbook keeps each node's system extensions. | After an upgrade, the extensions are still listed on each node. | planned |
| CHG-6 | VM definitions, including start-at-boot and boot order, are managed in Terraform. | `terraform plan` shows no drift after a UI change is reverted. | met |

### Security (SEC)

| ID | Requirement | Verify | Status |
|----|-------------|--------|--------|
| SEC-1 | No inbound ports are open on the home router; public services are reachable only through the tunnel. | External port scan of the home IP shows nothing open. | met |
| SEC-2 | Internal web UIs require SSO, except apps with their own login (Plex, Seerr). | Each internal hostname redirects to SSO or its own login. | met |
| SEC-3 | OIDC clients verify the identity provider's TLS certificate. | No skip-verify flags in the repo. | planned |
| SEC-4 | Secrets exist in Git only as SOPS ciphertext. Decrypted secrets and etcd snapshots are never stored in the working tree. | Gitignore covers snapshot files; no plaintext secrets in history. | partial |
| SEC-5 | In-cluster components get least-privilege access. Only components whose job requires it can read Secrets cluster-wide. | RBAC review of monitoring and logging components. | planned |
| SEC-6 | Download client traffic leaves through a VPN, with no traffic when the VPN is down. | Client reports the VPN exit IP; stopping the VPN stops traffic. | planned |
| SEC-7 | Guest devices on the tailnet can use the exit node only, not the home networks. | ACL test from a guest device. | planned |
| SEC-8 | Inter-VLAN traffic is limited to what services need. The apps VLAN reaches the NAS only for NFS and DNS, and the management interfaces (Proxmox, NAS UI, IPMI) are reachable only from admin devices and the tailnet. | From a cluster pod: NFS and DNS work, Proxmox UI and IPMI are blocked. From the tailnet: management interfaces work. | deferred |

When SEC-8 is picked up: move the subnet router out of the cluster first (REC-3), so a rule
mistake can't lock out remote access, and allow DNS to both resolvers.

### Performance (PERF)

| ID | Requirement | Verify | Status |
|----|-------------|--------|--------|
| PERF-1 | The media apps' UIs stay responsive while downloads and library scans run, with their config still on shared NAS storage (not pinned to one node). | Time an app operation and a SQLite write benchmark during a download plus rescan, against a recorded baseline. | deferred (design: #190) |

### Simplicity (SIM)

| ID | Requirement | Verify | Status |
|----|-------------|--------|--------|
| SIM-1 | Adding an app means adding one directory, with no hand-written ArgoCD Application per app. | Add a test app with one directory. | planned |
| SIM-2 | ArgoCD has a single values file, shared by bootstrap and self-management. | One values file in the repo. | planned |
| SIM-3 | Nothing is deployed that isn't used: no replaced apps, dead tunnel routes or orphaned volumes. | Inventory review against the service catalogue. | planned |
| SIM-4 | Documentation matches the running system. AGENTS.md and this spec are authoritative; other docs are updated or removed. | No references to the old single-node layout or retired addresses. | partial |

## 6. Out of scope

- Hardware purchases (UPS, extra hosts).
- Offsite media backup.
- Exposing additional services publicly.
- Changing the fixed choices in section 2.
