# Issue 4: PodSecurity Policy Blocking Node Exporter

## Status: RESOLVED

## Affected Components
- `kube-prometheus-stack-prometheus-node-exporter` DaemonSet (0/1 pods running)
- `kube-prometheus-stack-grafana` Deployment (not deployed - ArgoCD sync blocked)

## Error Message
```
Error creating: pods "kube-prometheus-stack-prometheus-node-exporter-*" is forbidden: 
violates PodSecurity "baseline:latest": host namespaces (hostNetwork=true, hostPID=true), 
hostPath volumes (volumes "proc", "sys", "root"), hostPort (container "node-exporter" uses hostPort 9100)
```

## Root Cause
The `observability` namespace has a PodSecurity policy set to `baseline` which restricts:
- Host namespaces (hostNetwork, hostPID)
- HostPath volumes
- HostPorts

The Prometheus node-exporter requires all of these to collect host-level metrics.

## Impact
1. **Node Exporter**: Cannot run, so no host-level metrics (CPU, memory, disk, network) are collected
2. **Grafana**: The ArgoCD sync for kube-prometheus-stack is waiting for node-exporter to become healthy before proceeding, which blocks Grafana deployment

## Fix Options

### Option A: Set Namespace to Privileged (Recommended for observability)

The observability namespace needs privileged access for monitoring components:

```bash
kubectl label namespace observability pod-security.kubernetes.io/enforce=privileged --overwrite
kubectl label namespace observability pod-security.kubernetes.io/warn=privileged --overwrite
```

Or update the namespace manifest in `kubernetes/apps/observability/namespace.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: observability
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/warn: privileged
```

### Option B: Disable Node Exporter

If you don't need host-level metrics, disable node-exporter in the kube-prometheus-stack values:

```yaml
# In kube-prometheus-stack Helm values
nodeExporter:
  enabled: false
```

This will allow the ArgoCD sync to complete without node-exporter.

### Option C: Modify ArgoCD Sync Strategy

Change the kube-prometheus-stack Application to not wait for node-exporter health:

```yaml
spec:
  syncPolicy:
    syncOptions:
      - SkipDryRunOnMissingResource=true
    # Or use selective sync with health checks disabled for DaemonSets
```

## Verification

After applying the fix:

```bash
# Check node-exporter pods are running
kubectl get pods -n observability -l app.kubernetes.io/name=prometheus-node-exporter

# Check Grafana deployment exists
kubectl get deployment -n observability kube-prometheus-stack-grafana

# Check ArgoCD sync status
kubectl get application kube-prometheus-stack -n argocd
```

## Related Issues
- This issue was discovered while resolving Issue 1 (NFS Permissions)
- The Grafana PVC issue is now resolved; only the PodSecurity issue remains

## Resolution (2026-01-21)

The PodSecurity issue was resolved by implementing Option A with a GitOps approach:

1. **Created a dedicated namespace application** at `kubernetes/observability/namespace/`:
   - `namespace.yaml`: Defines the `observability` namespace with `pod-security.kubernetes.io/enforce: privileged` and `pod-security.kubernetes.io/warn: privileged` labels
   - `application.yaml`: ArgoCD Application that deploys the namespace at sync-wave `-3` (before other observability components)

2. **Updated kube-prometheus-stack and loki applications** to remove `CreateNamespace=true` since the namespace is now managed by the dedicated namespace application

This ensures:
- The namespace is created with proper PodSecurity labels before any workloads are deployed
- The configuration is GitOps-managed and will persist across cluster recreations
- Node-exporter can run with the required privileged capabilities (hostNetwork, hostPID, hostPath volumes)
