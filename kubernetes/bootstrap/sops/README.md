# SOPS Age Key Setup

This directory contains instructions for setting up SOPS with age encryption.

## Generate Age Key

```bash
# Install age
brew install age  # macOS
# or: apt install age  # Debian/Ubuntu

# Generate a new age key
age-keygen -o age.key

# Output will show:
# Public key: age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

## Configure SOPS

1. Copy the public key from the output above
2. Update `/.sops.yaml` and replace `AGE_PUBLIC_KEY_PLACEHOLDER` with your public key

## Create Kubernetes Secret

The private key needs to be available to ArgoCD for decryption:

```bash
# Create the secret in the argocd namespace
kubectl create namespace argocd
kubectl create secret generic sops-age \
  --namespace argocd \
  --from-file=keys.txt=age.key
```

## Encrypt a Secret

```bash
# Create a secret file
cat > secret.sops.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: my-secret
type: Opaque
stringData:
  password: super-secret-value
EOF

# Encrypt it
sops --encrypt --in-place secret.sops.yaml
```

## Decrypt for Viewing

```bash
sops --decrypt secret.sops.yaml
```

## Important

- **NEVER commit `age.key` to git** - it contains the private key
- **DO commit `.sops.yaml`** - it only contains the public key
- **DO commit `*.sops.yaml` files** - they are encrypted
