# AGENTS.md

GitOps repo for a small homelab: Proxmox → Talos Linux → Kubernetes → ArgoCD. There is no
application code here, only infrastructure config. ArgoCD auto-syncs `main`, so **a merge to
`main` is a production deploy**.

This repo is **public**. Everything you write in commits, PRs and issues is public too.

## Fixed choices and non-goals

These are decided. Don't propose replacing them or re-open them unless the user asks. The full
target state, with requirement IDs and current status, is in `docs/spec.md`.

- **Fixed:** Talos, Proxmox, Plex with Intel QuickSync, Tailscale for remote access, a
  Cloudflare tunnel for public apps. ArgoCD is preferred but not sacred.
- **No open ports on the home router.** Everything public goes out through the tunnel.
- **No HA for Plex**, and no HA as a goal in general. With no UPS, a power cut takes out every
  host at once, so the target is a fast, tested rebuild instead.
- **No UPS**, and no budget for one. Design for an unclean power loss.
- **No offsite backup of media.** App config and cluster state should be backed up offsite.

## Hard rules

1. **Never change live systems unless the user asks for that change in this session.** That
   covers `kubectl apply/edit/delete/patch`, `talosctl apply/upgrade/reset`, ArgoCD syncs,
   Terraform `apply`, and any write to Cloudflare or GitHub. Reading is fine. Changes go
   through Git and ArgoCD.
2. **Never print secret values.** Don't run `sops -d` to stdout, `kubectl get secret -o yaml`, or
   `cat` on Talos configs. If you need to check a secret, check which keys it has, not their
   values.
3. **Never modify or commit** `age.key`, `talos/clusterconfig/`, `*.tfstate`, `*.tfvars` or etcd
   snapshots (`*.snapshot`).
4. **Secrets are SOPS-encrypted only** (`*.sops.yaml`; rules in `.sops.yaml`). Encrypt before
   `git add`, then check with `git diff --cached` that only ciphertext is staged.
5. **Keep private information out of the repo, PRs and issues:** names of people, household
   details, account or bucket names, and step-by-step write-ups of security weaknesses. Describe
   security work as neutral hardening tasks.

## Where the truth lives

Read these files instead of trusting values copied elsewhere. Don't copy IPs or versions into
docs.

| What | Source |
|------|--------|
| Nodes, IPs, Talos/K8s versions, extensions | `talos/talconfig.yaml` |
| VMs and Proxmox hosts | `terraform/proxmox/` (real values sit in a git-ignored `*.tfvars`) |
| What ArgoCD deploys | `kubernetes/{core,apps,observability}/**/*application.yaml` |
| Public hostnames (tunnel) | `kubernetes/core/cloudflared/application.yaml` |
| Internal hostnames | `templates/httproute.yaml` per app, on `*.int.<domain>` via `internal-gateway` |
| Storage classes | `kubernetes/core/nfs-csi/templates/storage.yaml` (`nfs-config`, `nfs-media`), `local-path` |
| Dependency updates | `renovate.json5` |

`README.md`, `docs/` and `plans/` are partly out of date: some still say
"single-node" or use the old `192.168.30.x` addresses. If docs and code disagree, the code
wins. Fix the docs if you're touching that area anyway.

## How the repo is wired

- **Three root apps** (`core/argocd-apps.yaml`, `apps/apps.yaml`,
  `observability/observability.yaml`) recursively pick up every `*application.yaml` below them.
  To add an app, add a directory; there is no list to register it in.
- **One directory per app:** an umbrella `Chart.yaml` (upstream chart as a dependency),
  `values.yaml`, `templates/` for local manifests, and `application.yaml`. Copy the layout of
  an existing app such as `apps/media/radarr`.
- **Secrets:** one `secrets-application.yaml` per encrypted file, using the `sops-file` ArgoCD
  plugin with `FILE=<name>.sops.yaml`. Give it a lower sync-wave than the main app.
- **`.helmignore`** must exclude `application.yaml`, `*-application.yaml` and `*.sops.yaml`.
  Otherwise the umbrella chart renders them as part of the app.
- **Ingress:** Cilium Gateway API. The *arr apps route through `authentik-server` for
  forward-auth, not straight to the app.

## Known traps

- **Talos upgrades must use the factory image for each node's schematic.** wk01 needs `i915`
  for Plex transcoding. Use `talhelper gencommand upgrade`, never the plain
  `ghcr.io/siderolabs/installer` image. `talos/UPGRADE.md` is wrong about this.
- **Plex is pinned to `talos-wk01`** (iGPU passthrough), and its config is on `local-path` on
  that node, with a nightly copy to NFS. Don't move it or change its storage casually.
- **Cilium and Gateway API CRD versions are coupled.** Bump the CRDs in `core/gateway-api`
  when Cilium needs a newer version (see commit `605eded`).
- **Renovate automerges minor and patch updates straight to `main`** with no CI. A bad chart
  update deploys itself. Watch for this when you debug a sudden breakage.
- **There is one control plane** (no VIP). A restart of that VM takes the API server down.

## Before you open a PR

Run whatever applies; none of these needs cluster access:

```bash
# Helm umbrella chart
cd kubernetes/<category>/<app> && helm dependency build && helm template . -f values.yaml >/dev/null

# Talos config (writes to the git-ignored talos/clusterconfig/)
cd talos && talhelper genconfig

# Terraform
cd terraform/proxmox && terraform init -backend=false && terraform validate
```

Work on a branch, keep each PR to one concern, and say in the PR how you validated it.

## Agent skills

### Issue tracker

Issues live in this repo's GitHub Issues (public), managed with `gh`. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` and `docs/adr/` at the repo root, created when needed. See `docs/agents/domain.md`.
