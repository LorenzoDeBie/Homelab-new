# Issue 2: SOPS-Encrypted Secrets Not Being Deployed

## Status: RESOLVED

## Affected Pods (as of 2026-01-21)
- `authentik-server-785db8dccd-rmxk6` - CreateContainerConfigError (missing `authentik-secrets`)
- `authentik-worker-6f664468c8-67wtv` - CreateContainerConfigError (missing `authentik-secrets`)
- `authentik-postgresql-0` - Waiting for secret mount (missing `authentik-secrets`)
- `cloudflared-cloudflare-tunnel-*` - ContainerCreating (missing `cloudflared-credentials`)
- `operator-*` (tailscale) - ContainerCreating (missing `operator-oauth`)

> **Note**: The NFS permissions issue (Issue 1) has been resolved. The authentik pods are now failing purely due to missing secrets, not storage issues.

## Error Messages
```
# Authentik pods:
Error: secret "authentik-secrets" not found

# Cloudflared pod:
MountVolume.SetUp failed for volume "creds" : secret "cloudflared-credentials" not found

# Tailscale operator:
MountVolume.SetUp failed for volume "oauth" : secret "operator-oauth" not found
```

## Root Cause
The ArgoCD `core` Application is configured to only include `*/application.yaml` files:

```yaml
# From kubernetes/core/argocd-apps.yaml
spec:
  source:
    path: kubernetes/core
    directory:
      recurse: true
      include: "*/application.yaml"  # <-- Only matches application.yaml files
```

The SOPS-encrypted secret files exist but are never deployed:
- `kubernetes/core/authentik/secrets.sops.yaml`
- `kubernetes/core/cloudflared/credentials.sops.yaml`
- `kubernetes/core/tailscale-operator/oauth-secret.sops.yaml`

Additionally, ArgoCD is not configured to decrypt SOPS files.

## Secret Files (SOPS-encrypted with age)

| File | Secret Name | Namespace |
|------|-------------|-----------|
| `kubernetes/core/authentik/secrets.sops.yaml` | `authentik-secrets` | `authentik` |
| `kubernetes/core/cloudflared/credentials.sops.yaml` | `cloudflared-credentials` | `cloudflared` |
| `kubernetes/core/tailscale-operator/oauth-secret.sops.yaml` | `operator-oauth` | `tailscale` |

Age public key: `age1g6uhy72aszly2j77d0wmy4mwy5f9ezxe2w9fu2ensal4mn5uufyqqpcf8h`

## Fix Options

### Option A: Use KSOPS with ArgoCD (Recommended)

1. **Install KSOPS in ArgoCD repo-server**

   Update ArgoCD deployment to include KSOPS. Add to ArgoCD Helm values or patch:
   ```yaml
   repoServer:
     env:
       - name: XDG_CONFIG_HOME
         value: /.config
       - name: SOPS_AGE_KEY_FILE
         value: /.config/sops/age/keys.txt
     volumes:
       - name: sops-age
         secret:
           secretName: sops-age-key
     volumeMounts:
       - name: sops-age
         mountPath: /.config/sops/age
   ```

2. **Create the age private key secret in ArgoCD namespace**
   ```bash
   kubectl create secret generic sops-age-key \
     --namespace argocd \
     --from-file=keys.txt=/path/to/age.key
   ```

3. **Create kustomization.yaml files for each component**

   Example for `kubernetes/core/authentik/kustomization.yaml`:
   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   
   generators:
     - secrets-generator.yaml
   
   resources:
     - application.yaml
   ```

   And `kubernetes/core/authentik/secrets-generator.yaml`:
   ```yaml
   apiVersion: viaduct.ai/v1
   kind: ksops
   metadata:
     name: authentik-secrets
   files:
     - secrets.sops.yaml
   ```

4. **Update ArgoCD core Application to use Kustomize**
   ```yaml
   spec:
     source:
       path: kubernetes/core
       directory:
         recurse: true
         # Remove the include filter or change to use kustomization
   ```

### Option B: Separate Secrets Application

Create a dedicated Application for secrets using a directory-based approach:

1. Create `kubernetes/core/secrets/kustomization.yaml`:
   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   
   resources:
     - ../authentik/secrets.sops.yaml
     - ../cloudflared/credentials.sops.yaml
     - ../tailscale-operator/oauth-secret.sops.yaml
   ```

2. Create `kubernetes/core/secrets/application.yaml` that uses KSOPS

### Option C: Manual Secret Deployment (Quick Fix)

Decrypt and apply secrets manually (not GitOps, but unblocks immediately):

```bash
# Ensure SOPS_AGE_KEY_FILE is set or age key is in default location
export SOPS_AGE_KEY_FILE=/path/to/age.key

# Decrypt and apply each secret
sops --decrypt kubernetes/core/authentik/secrets.sops.yaml | kubectl apply -f -
sops --decrypt kubernetes/core/cloudflared/credentials.sops.yaml | kubectl apply -f -
sops --decrypt kubernetes/core/tailscale-operator/oauth-secret.sops.yaml | kubectl apply -f -
```

## Verification

```bash
# Check secrets exist
kubectl get secret authentik-secrets -n authentik
kubectl get secret cloudflared-credentials -n cloudflared
kubectl get secret operator-oauth -n tailscale

# Pods should transition out of error states
kubectl get pods -A | grep -E "authentik|cloudflared|tailscale"
```

## Resolution (2026-01-21)

The SOPS secrets deployment issue was resolved using a custom ArgoCD Config Management Plugin (CMP) approach:

### Changes Made

1. **Created secrets-application.yaml files** for each component:
   - `kubernetes/core/authentik/secrets-application.yaml`
   - `kubernetes/core/cloudflared/secrets-application.yaml`
   - `kubernetes/core/tailscale-operator/secrets-application.yaml`

   Each uses the `sops-file` CMP plugin and passes the encrypted filename via the `FILE` environment variable.

2. **Updated ArgoCD core application** (`kubernetes/core/argocd-apps.yaml`):
   - Changed include pattern from `*/application.yaml` to `*/*application.yaml` to match both `application.yaml` and `secrets-application.yaml` files

3. **Added SOPS CMP plugin to ArgoCD** (`kubernetes/bootstrap/argocd/values.yaml`):
   - Added `sops-file` plugin configuration under `configs.cmp.plugins`
   - Added sidecar container `sops-plugin` to repo-server that runs the CMP server
   - Mounted the age key secret and SOPS binary to the sidecar
   - ArgoCD passes Application env vars with `ARGOCD_ENV_` prefix, so `FILE` becomes `ARGOCD_ENV_FILE`

4. **Updated sops-age secret** with the correct private key matching the public key used to encrypt the SOPS files

### Key Learnings

- ArgoCD CMP plugins require a sidecar container in the repo-server deployment
- Application `plugin.env` variables are passed to the CMP with `ARGOCD_ENV_` prefix (not `PARAM_` as some docs suggest)
- The CMP plugin ConfigMap is created by `configs.cmp` but the sidecar must be configured via `repoServer.extraContainers`

### Verification

All secrets are now deployed and synced:
```bash
$ kubectl get application -n argocd | grep secret
authentik-secrets     Synced        Healthy
cloudflared-secrets   Synced        Healthy
tailscale-secrets     Synced        Healthy

$ kubectl get secret authentik-secrets -n authentik
NAME                TYPE     DATA   AGE
authentik-secrets   Opaque   4      Xs

$ kubectl get secret cloudflared-credentials -n cloudflared
NAME                      TYPE     DATA   AGE
cloudflared-credentials   Opaque   3      Xs

$ kubectl get secret operator-oauth -n tailscale
NAME             TYPE     DATA   AGE
operator-oauth   Opaque   2      Xs
```

The tailscale-operator pod is now running successfully. Other pods (authentik, cloudflared) have unrelated configuration issues documented separately.
