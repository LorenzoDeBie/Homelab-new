# Issue 3: StorageClass YAML Not Deployed via ArgoCD

## Status: PARTIALLY RESOLVED (Low Priority)

## Current State (as of 2026-01-21)
The StorageClasses `nfs-config` and `nfs-media` ARE currently deployed in the cluster. All PVCs are bound and working correctly after manual intervention (see Issue 1 resolution).

The storage resources were manually applied during Issue 1 resolution:
```bash
kubectl apply -f kubernetes/core/nfs-csi/storageclass.yaml
```

This deployed:
- StorageClass `nfs-media` 
- StorageClass `nfs-config`
- PersistentVolume `media-pv` (10Ti, bound to media/media PVC)
- PersistentVolumeClaim `media` in namespace `media`

## The Problem
The file `kubernetes/core/nfs-csi/storageclass.yaml` contains:
- StorageClass `nfs-media`
- StorageClass `nfs-config`
- PersistentVolume `media-pv`
- PersistentVolumeClaim `media` (in namespace `media`)

The ArgoCD `core` Application only includes `*/application.yaml` files, so `storageclass.yaml` should NOT be deployed. Yet the StorageClasses exist, suggesting they were applied manually or through another mechanism.

## Risk
If someone syncs or recreates the ArgoCD applications, the StorageClasses may not be redeployed because they're not matched by the include pattern.

## Fix Options

### Option A: Rename to application.yaml Pattern (Simple)

Rename `storageclass.yaml` to include it in the pattern:

```bash
# This won't work as-is because application.yaml is expected to be an ArgoCD Application
# Instead, restructure the directory
```

### Option B: Create Dedicated Application for Storage Resources (Recommended)

1. Create `kubernetes/core/nfs-csi/storage-resources.yaml`:
   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: nfs-storage-resources
     namespace: argocd
     annotations:
       argocd.argoproj.io/sync-wave: "-2"
     finalizers:
       - resources-finalizer.argocd.argoproj.io
   spec:
     project: default
     source:
       repoURL: https://github.com/LorenzoDeBie/Homelab-new.git
       targetRevision: main
       path: kubernetes/core/nfs-csi
       directory:
         include: "storageclass.yaml"
     destination:
       server: https://kubernetes.default.svc
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
       syncOptions:
         - ServerSideApply=true
   ```

2. Update the include pattern OR add this as a separate source

### Option C: Update Core Application Include Pattern

Change the `core` Application to include more file types:

```yaml
# kubernetes/core/argocd-apps.yaml
spec:
  source:
    path: kubernetes/core
    directory:
      recurse: true
      include: "{*/application.yaml,*/storageclass.yaml}"
```

### Option D: Use Kustomize Base (Best Long-term)

Create `kubernetes/core/nfs-csi/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - storageclass.yaml
```

Then update `application.yaml` to use Kustomize instead of Helm for the storage resources, or create a separate Application that points to this directory with Kustomize.

## Verification

```bash
# Ensure StorageClasses exist
kubectl get sc nfs-config nfs-media

# Ensure the PV and PVC for media exist
kubectl get pv media-pv
kubectl get pvc media -n media
```

## Note
This issue is lower priority than Issues 1 and 2 because the resources currently exist. However, it should be fixed to ensure proper GitOps management.
