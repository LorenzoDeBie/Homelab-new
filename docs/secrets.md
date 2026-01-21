# Secrets Management Guide

This document covers the secrets management approach using SOPS (Secrets OPerationS) with age encryption, enabling secure storage of secrets directly in Git.

## Table of Contents

- [Overview](#overview)
- [SOPS and Age Setup](#sops-and-age-setup)
- [Encrypting Secrets](#encrypting-secrets)
- [Decrypting Secrets](#decrypting-secrets)
- [ArgoCD Integration](#argocd-integration)
- [Secrets Inventory](#secrets-inventory)
- [Best Practices](#best-practices)
- [Key Rotation](#key-rotation)
- [Troubleshooting](#troubleshooting)

## Overview

### Why SOPS + Age?

- **GitOps Compatible**: Encrypted secrets can be safely committed to Git
- **Auditability**: All secret changes tracked in version control
- **Simplicity**: age is simpler than GPG while being equally secure
- **ArgoCD Integration**: Native support via sops-age plugin

### How It Works

```
+------------------+     +------------------+     +------------------+
|  Plain Secret    | --> |  SOPS Encrypt    | --> |  Encrypted in    |
|  (local only)    |     |  (with age key)  |     |  Git Repository  |
+------------------+     +------------------+     +------------------+
                                                          |
                                                          v
+------------------+     +------------------+     +------------------+
|  Kubernetes      | <-- |  SOPS Decrypt    | <-- |  ArgoCD Sync     |
|  Secret          |     |  (repo-server)   |     |  (detects .sops) |
+------------------+     +------------------+     +------------------+
```

## SOPS and Age Setup

### Install Tools

```bash
# macOS
brew install sops age

# Linux
# age
sudo apt install age
# or download from https://github.com/FiloSottile/age/releases

# sops
curl -LO https://github.com/getsops/sops/releases/download/v3.9.0/sops-v3.9.0.linux.amd64
sudo mv sops-v3.9.0.linux.amd64 /usr/local/bin/sops
sudo chmod +x /usr/local/bin/sops
```

### Generate Age Key

```bash
# Generate a new age key pair
age-keygen -o age.key

# Output shows:
# Public key: age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

The file `age.key` contains:
```
# created: 2024-01-01T00:00:00Z
# public key: age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
AGE-SECRET-KEY-1XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
```

### Configure SOPS

The `.sops.yaml` file tells SOPS how to encrypt files:

```yaml
# .sops.yaml
creation_rules:
  # Encrypt Kubernetes secrets (only data/stringData fields)
  - path_regex: .*\.sops\.yaml$
    encrypted_regex: ^(data|stringData)$
    age: >-
      age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

  # Encrypt Talos secrets (full file)
  - path_regex: talos/.*secret.*\.yaml$
    age: >-
      age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

**Important**: Replace the placeholder with your actual public key (from `age.key`).

### Configure Local Environment

For local decryption, SOPS needs to know where your private key is:

```bash
# Option 1: Environment variable
export SOPS_AGE_KEY_FILE=/path/to/age.key

# Option 2: Default location
mkdir -p ~/.config/sops/age
cp age.key ~/.config/sops/age/keys.txt
```

## Encrypting Secrets

### Create a New Secret

1. Create the plain-text secret file:

```yaml
# kubernetes/core/example/secret.sops.yaml
apiVersion: v1
kind: Secret
metadata:
  name: my-secret
  namespace: my-namespace
type: Opaque
stringData:
  username: admin
  password: super-secret-password
  api-key: abc123xyz
```

2. Encrypt the file in-place:

```bash
sops --encrypt --in-place kubernetes/core/example/secret.sops.yaml
```

3. The file now contains encrypted values:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: my-secret
  namespace: my-namespace
type: Opaque
stringData:
  username: ENC[AES256_GCM,data:xxxxx,iv:xxxxx,tag:xxxxx,type:str]
  password: ENC[AES256_GCM,data:xxxxx,iv:xxxxx,tag:xxxxx,type:str]
  api-key: ENC[AES256_GCM,data:xxxxx,iv:xxxxx,tag:xxxxx,type:str]
sops:
  age:
    - recipient: age1xxxxxxxxxx
      enc: |
        -----BEGIN AGE ENCRYPTED FILE-----
        ...
        -----END AGE ENCRYPTED FILE-----
  # ... metadata
```

### Encrypt to a New File

```bash
sops --encrypt secret.yaml > secret.sops.yaml
```

### Edit Encrypted File Directly

SOPS can decrypt, open in editor, and re-encrypt:

```bash
sops kubernetes/core/example/secret.sops.yaml
```

This opens your `$EDITOR` with decrypted content.

## Decrypting Secrets

### View Decrypted Content

```bash
# Decrypt to stdout
sops --decrypt kubernetes/core/example/secret.sops.yaml

# Decrypt to file
sops --decrypt kubernetes/core/example/secret.sops.yaml > /tmp/plain-secret.yaml
```

### Extract Specific Value

```bash
# Get a specific key
sops --decrypt --extract '["stringData"]["password"]' secret.sops.yaml
```

## ArgoCD Integration

ArgoCD is configured to automatically decrypt SOPS files during sync.

### Configuration

The ArgoCD repo-server is configured with:

1. **SOPS binary installed** (via init container)
2. **Age key mounted** (from `sops-age` secret)
3. **Config Management Plugin** (detects `.sops.yaml` files)

From `kubernetes/bootstrap/argocd/values.yaml`:

```yaml
configs:
  cmp:
    plugins:
      sops:
        allowConcurrency: true
        discover:
          fileName: "*.sops.yaml"
        generate:
          command:
            - sh
            - "-c"
            - |
              sops --decrypt $ARGOCD_ENV_FILE

repoServer:
  volumes:
    - name: sops-age
      secret:
        secretName: sops-age
  volumeMounts:
    - name: sops-age
      mountPath: /home/argocd/.config/sops/age
  env:
    - name: SOPS_AGE_KEY_FILE
      value: /home/argocd/.config/sops/age/keys.txt
```

### Creating the ArgoCD Secret

During installation, create the `sops-age` secret:

```bash
kubectl create secret generic sops-age \
  --namespace argocd \
  --from-file=keys.txt=age.key
```

### Verify ArgoCD Can Decrypt

```bash
# Check repo-server logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server

# Check if secret is mounted
kubectl exec -n argocd -it deploy/argocd-repo-server -- \
  ls -la /home/argocd/.config/sops/age/
```

## Secrets Inventory

### All Secrets in This Repository

| Secret File | Namespace | Purpose | Keys |
|-------------|-----------|---------|------|
| `cert-manager/cloudflare-secret.sops.yaml` | cert-manager | Cloudflare API for DNS challenge | `api-token` |
| `cloudflared/credentials.sops.yaml` | cloudflared | Cloudflare Tunnel credentials | `credentials.json` |
| `tailscale-operator/oauth-secret.sops.yaml` | tailscale | Tailscale OAuth | `client_id`, `client_secret` |
| `authentik/secrets.sops.yaml` | authentik | Authentik configuration | `secret-key`, `postgresql-password`, `bootstrap-password`, `bootstrap-email` |
| `kube-prometheus-stack/grafana-secret.sops.yaml` | observability | Grafana admin credentials | `admin-user`, `admin-password` |

### Secret Details

#### Cloudflare API Token

```yaml
# kubernetes/core/cert-manager/cloudflare-secret.sops.yaml
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-api-token
  namespace: cert-manager
type: Opaque
stringData:
  api-token: <your-cloudflare-api-token>
```

**Obtain from**: Cloudflare Dashboard > Profile > API Tokens

**Permissions needed**: Zone:DNS:Edit

#### Cloudflare Tunnel Credentials

```yaml
# kubernetes/core/cloudflared/credentials.sops.yaml
apiVersion: v1
kind: Secret
metadata:
  name: cloudflared-credentials
  namespace: cloudflared
type: Opaque
stringData:
  credentials.json: |
    {
      "AccountTag": "<account-tag>",
      "TunnelID": "<tunnel-id>",
      "TunnelSecret": "<tunnel-secret>"
    }
```

**Obtain from**: `~/.cloudflared/<tunnel-id>.json` after running `cloudflared tunnel create`

#### Tailscale OAuth

```yaml
# kubernetes/core/tailscale-operator/oauth-secret.sops.yaml
apiVersion: v1
kind: Secret
metadata:
  name: operator-oauth
  namespace: tailscale
type: Opaque
stringData:
  client_id: <oauth-client-id>
  client_secret: <oauth-client-secret>
```

**Obtain from**: Tailscale Admin > Settings > OAuth clients

#### Authentik Secrets

```yaml
# kubernetes/core/authentik/secrets.sops.yaml
apiVersion: v1
kind: Secret
metadata:
  name: authentik-secrets
  namespace: authentik
type: Opaque
stringData:
  secret-key: <random-32-char-string>
  postgresql-password: <random-24-char-string>
  bootstrap-password: <your-admin-password>
  bootstrap-email: <your-email>
```

**Generate random values**: `openssl rand -base64 32`

#### Grafana Admin

```yaml
# kubernetes/observability/kube-prometheus-stack/grafana-secret.sops.yaml
apiVersion: v1
kind: Secret
metadata:
  name: grafana-admin
  namespace: observability
type: Opaque
stringData:
  admin-user: admin
  admin-password: <your-grafana-password>
```

## Best Practices

### Key Management

1. **Never commit `age.key` to Git**
   - Add to `.gitignore`: `age.key`
   - Store securely offline

2. **Backup the age key**
   - Store in password manager
   - Keep offline backup (USB, printed)
   - Consider multiple backup locations

3. **Limit key access**
   - Only share with trusted operators
   - Consider separate keys for different environments

### Secret Hygiene

1. **Use `.sops.yaml` naming convention**
   - Makes encrypted files obvious
   - Required for ArgoCD plugin detection

2. **Only encrypt sensitive values**
   - Use `encrypted_regex` to encrypt only `data`/`stringData`
   - Keeps metadata readable for review

3. **Review before committing**
   ```bash
   # Verify file is encrypted
   grep -q "ENC\[AES256_GCM" secret.sops.yaml && echo "Encrypted" || echo "NOT ENCRYPTED!"
   ```

4. **Rotate secrets regularly**
   - Change passwords periodically
   - Re-encrypt with new values

### Git Workflow

```bash
# Before committing, verify encryption
for f in $(find . -name "*.sops.yaml"); do
  if ! grep -q "sops:" "$f"; then
    echo "WARNING: $f may not be encrypted!"
  fi
done
```

## Key Rotation

### Rotate Age Key

If your age key is compromised:

1. **Generate new key**:
   ```bash
   age-keygen -o age-new.key
   ```

2. **Update `.sops.yaml`** with new public key

3. **Re-encrypt all secrets**:
   ```bash
   # For each secret file
   sops --decrypt old-secret.sops.yaml | \
     sops --encrypt --age <new-public-key> /dev/stdin > new-secret.sops.yaml
   mv new-secret.sops.yaml old-secret.sops.yaml
   ```

4. **Update ArgoCD secret**:
   ```bash
   kubectl delete secret sops-age -n argocd
   kubectl create secret generic sops-age \
     --namespace argocd \
     --from-file=keys.txt=age-new.key
   
   # Restart repo-server
   kubectl rollout restart deployment argocd-repo-server -n argocd
   ```

5. **Commit and push changes**

### Add Additional Recipients

To allow multiple keys to decrypt:

```yaml
# .sops.yaml
creation_rules:
  - path_regex: .*\.sops\.yaml$
    encrypted_regex: ^(data|stringData)$
    age: >-
      age1key1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx,
      age1key2xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

Then update existing secrets:
```bash
sops updatekeys secret.sops.yaml
```

## Troubleshooting

### "Failed to get the data key"

**Cause**: SOPS cannot find the private key

**Solution**:
```bash
# Check if key file exists
ls -la ~/.config/sops/age/keys.txt

# Or set environment variable
export SOPS_AGE_KEY_FILE=/path/to/age.key
```

### ArgoCD Shows Sync Failed

**Cause**: ArgoCD cannot decrypt secrets

**Check**:
```bash
# View repo-server logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server -f

# Check if secret is mounted
kubectl exec -n argocd -it deploy/argocd-repo-server -- \
  cat /home/argocd/.config/sops/age/keys.txt
```

**Solution**:
```bash
# Recreate the secret
kubectl delete secret sops-age -n argocd
kubectl create secret generic sops-age \
  --namespace argocd \
  --from-file=keys.txt=age.key
kubectl rollout restart deployment argocd-repo-server -n argocd
```

### "Error: MAC mismatch"

**Cause**: File was modified after encryption or wrong key

**Solution**:
```bash
# Verify you have the correct key
sops --decrypt secret.sops.yaml

# If it fails, you may need the original key that encrypted it
```

### Accidentally Committed Unencrypted Secret

**Immediate actions**:
1. **Rotate the exposed credentials immediately**
2. Remove from Git history:
   ```bash
   git filter-branch --force --index-filter \
     "git rm --cached --ignore-unmatch path/to/secret.yaml" \
     --prune-empty --tag-name-filter cat -- --all
   git push origin --force --all
   ```
3. Encrypt properly and commit

### Verify File is Encrypted

```bash
# Quick check
head -20 secret.sops.yaml | grep -E "(ENC\[|sops:)"

# Detailed check
sops --decrypt secret.sops.yaml > /dev/null 2>&1 && echo "Valid SOPS file" || echo "Not a valid SOPS file"
```
