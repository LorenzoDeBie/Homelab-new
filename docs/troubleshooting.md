# Troubleshooting Guide

This document provides solutions to common issues you may encounter with the homelab Kubernetes cluster.

## Table of Contents

- [Quick Diagnostics](#quick-diagnostics)
- [Pods Issues](#pods-issues)
- [Networking Issues](#networking-issues)
- [Storage Issues](#storage-issues)
- [Certificate Issues](#certificate-issues)
- [ArgoCD Issues](#argocd-issues)
- [Talos Issues](#talos-issues)
- [Application-Specific Issues](#application-specific-issues)
- [Useful Commands Reference](#useful-commands-reference)

## Quick Diagnostics

### Overall Cluster Health

```bash
# Check nodes
kubectl get nodes

# Check all pods
kubectl get pods -A | grep -v Running

# Check events
kubectl get events -A --sort-by='.lastTimestamp' | tail -20

# Check ArgoCD apps
kubectl get applications -n argocd

# Check Talos health
talosctl --nodes 192.168.30.50 health
```

### Quick Status Script

```bash
#!/bin/bash
echo "=== Nodes ==="
kubectl get nodes

echo -e "\n=== Unhealthy Pods ==="
kubectl get pods -A | grep -v -E "Running|Completed"

echo -e "\n=== PVC Status ==="
kubectl get pvc -A | grep -v Bound

echo -e "\n=== ArgoCD Apps ==="
kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,STATUS:.status.sync.status,HEALTH:.status.health.status

echo -e "\n=== Recent Events ==="
kubectl get events -A --sort-by='.lastTimestamp' | tail -10
```

## Pods Issues

### Pod Stuck in Pending

**Symptoms**: Pod shows `Pending` status indefinitely

**Common Causes and Solutions**:

1. **Insufficient Resources**
   ```bash
   kubectl describe pod <pod-name> -n <namespace>
   # Look for: "Insufficient cpu" or "Insufficient memory"
   
   # Check node resources
   kubectl describe node talos-cp01 | grep -A 10 "Allocated resources"
   ```
   
   **Solution**: Reduce resource requests or add node capacity

2. **No Available PersistentVolume**
   ```bash
   kubectl describe pod <pod-name> -n <namespace>
   # Look for: "persistentvolumeclaim not found" or "waiting for first consumer"
   
   # Check PVC
   kubectl get pvc -n <namespace>
   kubectl describe pvc <pvc-name> -n <namespace>
   ```
   
   **Solution**: Check NFS CSI driver (see [Storage Issues](#storage-issues))

3. **Node Selector/Taints**
   ```bash
   kubectl describe pod <pod-name> -n <namespace>
   # Look for: "node(s) didn't match node selector" or taint tolerations
   ```
   
   **Solution**: Adjust node selectors or tolerations

### Pod CrashLoopBackOff

**Symptoms**: Pod keeps restarting

```bash
# Check pod logs
kubectl logs <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace> --previous

# Check events
kubectl describe pod <pod-name> -n <namespace>
```

**Common Causes**:

1. **Application Error**: Check logs for application-specific errors
2. **Missing Config/Secret**: Verify all ConfigMaps and Secrets exist
3. **Failed Health Check**: Check liveness/readiness probe configuration
4. **Permission Issues**: Check if pod can access mounted volumes

### Pod in ImagePullBackOff

**Symptoms**: Pod cannot pull container image

```bash
kubectl describe pod <pod-name> -n <namespace>
# Look for: "Failed to pull image" or "ImagePullBackOff"
```

**Solutions**:

1. **Image Not Found**: Verify image name and tag
2. **Registry Auth Required**: Create imagePullSecret
3. **Network Issues**: Check DNS and network connectivity

### Pod Not Starting After Deployment

```bash
# Check deployment status
kubectl get deployment <name> -n <namespace>
kubectl describe deployment <name> -n <namespace>

# Check replica set
kubectl get rs -n <namespace>
kubectl describe rs <name> -n <namespace>
```

## Networking Issues

### Service Not Reachable

**Symptoms**: Cannot connect to service

1. **Check Service Exists**:
   ```bash
   kubectl get svc -n <namespace>
   kubectl describe svc <service-name> -n <namespace>
   ```

2. **Check Endpoints**:
   ```bash
   kubectl get endpoints <service-name> -n <namespace>
   # If empty, no pods match the selector
   ```

3. **Test from Within Cluster**:
   ```bash
   kubectl run -it --rm debug --image=busybox -- \
     wget -qO- http://<service>.<namespace>.svc.cluster.local:<port>
   ```

### LoadBalancer IP Not Assigned

**Symptoms**: Service shows `<pending>` for EXTERNAL-IP

```bash
# Check service
kubectl get svc <name> -n <namespace>

# Check Cilium IP pool
kubectl get ciliumloadbalancerippool -o yaml

# Check L2 announcement policy
kubectl get ciliuml2announcementpolicy -o yaml

# Check Cilium logs
kubectl logs -n kube-system -l app.kubernetes.io/name=cilium-agent --tail=50
```

**Solutions**:

1. **IP Pool Exhausted**: Expand pool range in `l2-announcement.yaml`
2. **L2 Policy Missing**: Apply the CiliumL2AnnouncementPolicy
3. **Cilium Not Ready**: Wait for Cilium pods to be ready

### Gateway Not Routing Traffic

**Symptoms**: Cannot access services via Gateway

1. **Check Gateway Status**:
   ```bash
   kubectl get gateway -A
   kubectl describe gateway internal-gateway -n kube-system
   ```

2. **Check HTTPRoute**:
   ```bash
   kubectl get httproute -A
   kubectl describe httproute <name> -n <namespace>
   ```

3. **Check Gateway Service**:
   ```bash
   kubectl get svc -n kube-system | grep cilium-gateway
   ```

4. **Check TLS Certificate**:
   ```bash
   kubectl get certificate internal-wildcard-tls -n kube-system
   kubectl describe certificate internal-wildcard-tls -n kube-system
   ```

### DNS Resolution Failing

**Symptoms**: Pods cannot resolve hostnames

1. **Test CoreDNS**:
   ```bash
   kubectl run -it --rm debug --image=busybox -- nslookup kubernetes.default
   ```

2. **Check CoreDNS Pods**:
   ```bash
   kubectl get pods -n kube-system -l k8s-app=kube-dns
   kubectl logs -n kube-system -l k8s-app=kube-dns
   ```

3. **Check CoreDNS ConfigMap**:
   ```bash
   kubectl get configmap coredns -n kube-system -o yaml
   ```

### Cloudflare Tunnel Not Working

**Symptoms**: Cannot access public URLs

1. **Check cloudflared Pod**:
   ```bash
   kubectl get pods -n cloudflared
   kubectl logs -n cloudflared -l app.kubernetes.io/name=cloudflare-tunnel
   ```

2. **Check Tunnel Status**:
   ```bash
   # In Cloudflare Dashboard > Zero Trust > Tunnels
   # Verify tunnel shows as "Healthy"
   ```

3. **Verify Credentials**:
   ```bash
   kubectl get secret cloudflared-credentials -n cloudflared
   ```

## Storage Issues

### PVC Stuck in Pending

**Symptoms**: PVC shows `Pending` status

```bash
# Check PVC
kubectl describe pvc <pvc-name> -n <namespace>

# Check StorageClass
kubectl get storageclass
kubectl describe storageclass nfs-config
```

**Common Causes**:

1. **NFS Server Unreachable**:
   ```bash
   # Test from debug pod
   kubectl run -it --rm debug --image=busybox -- \
     ping <truenas-ip>
   ```

2. **Wrong Server/Share in StorageClass**:
   ```bash
   kubectl get storageclass nfs-config -o yaml
   # Verify server and share parameters
   ```

3. **NFS CSI Driver Not Running**:
   ```bash
   kubectl get pods -n kube-system -l app.kubernetes.io/name=csi-driver-nfs
   ```

### NFS Mount Failed

**Symptoms**: Pod fails with mount error

```bash
kubectl describe pod <pod-name> -n <namespace>
# Look for: "mount failed" or "connection refused"
```

**Solutions**:

1. **Check TrueNAS NFS Service**:
   - Verify NFS service is running
   - Check share exports include Kubernetes network

2. **Check Network Connectivity**:
   ```bash
   kubectl run -it --rm debug --image=busybox -- \
     nc -zv <truenas-ip> 2049
   ```

3. **Check NFS Export**:
   ```bash
   # From workstation
   showmount -e <truenas-ip>
   ```

### Stale NFS Handle

**Symptoms**: Pod shows "stale NFS file handle" error

**Solution**:
```bash
# Restart the affected pod
kubectl delete pod <pod-name> -n <namespace>

# If persistent, restart the node (last resort)
talosctl --nodes 192.168.30.50 reboot
```

### Permission Denied on NFS

**Symptoms**: Application cannot write to NFS mount

**Solutions**:

1. **Check TrueNAS Permissions**:
   - Dataset permissions should be 777 or appropriate user
   - Maproot User: root
   - Maproot Group: wheel

2. **Check Pod Security Context**:
   ```yaml
   securityContext:
     runAsUser: 0  # or appropriate UID
     runAsGroup: 0
     fsGroup: 0
   ```

## Certificate Issues

### Certificate Not Issued

**Symptoms**: Certificate shows `False` for Ready

```bash
kubectl describe certificate <name> -n <namespace>
kubectl get certificaterequest -n <namespace>
kubectl get order -n <namespace>
kubectl get challenge -n <namespace>
```

**Common Issues**:

1. **DNS Challenge Failing**:
   ```bash
   # Check challenge status
   kubectl describe challenge -n <namespace>
   
   # Check cert-manager logs
   kubectl logs -n cert-manager -l app.kubernetes.io/name=cert-manager
   ```

2. **Cloudflare API Token Invalid**:
   ```bash
   # Verify secret exists
   kubectl get secret cloudflare-api-token -n cert-manager
   
   # Test token (from local machine)
   curl -X GET "https://api.cloudflare.com/client/v4/zones" \
     -H "Authorization: Bearer <token>" \
     -H "Content-Type: application/json"
   ```

3. **Rate Limited**:
   - Let's Encrypt has rate limits
   - Check https://letsencrypt.org/docs/rate-limits/
   - Use staging ClusterIssuer for testing

### Certificate Expired

**Symptoms**: Browser shows certificate error

```bash
# Check certificate expiry
kubectl get certificate -A
kubectl describe certificate <name> -n <namespace>

# Force renewal
kubectl delete secret <certificate-secret-name> -n <namespace>
```

## ArgoCD Issues

### Application Sync Failed

**Symptoms**: Application shows `OutOfSync` or `Degraded`

```bash
# Check application status
argocd app get <app-name>

# View sync errors
argocd app sync <app-name> --dry-run

# Check ArgoCD logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller
```

**Common Causes**:

1. **Invalid Manifest**: Syntax error in YAML
2. **Missing CRD**: CRD not installed yet
3. **SOPS Decryption Failed**: See below

### SOPS Decryption Failed

**Symptoms**: ArgoCD cannot decrypt secrets

```bash
# Check repo-server logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server

# Verify SOPS secret exists
kubectl get secret sops-age -n argocd

# Check secret is mounted
kubectl exec -n argocd deploy/argocd-repo-server -- \
  ls -la /home/argocd/.config/sops/age/
```

**Solution**:
```bash
# Recreate SOPS secret
kubectl delete secret sops-age -n argocd
kubectl create secret generic sops-age \
  --namespace argocd \
  --from-file=keys.txt=age.key

# Restart repo-server
kubectl rollout restart deployment argocd-repo-server -n argocd
```

### ArgoCD Cannot Access Git Repository

**Symptoms**: Application shows repository error

```bash
# Check repo configuration
argocd repo list

# Test repository access
argocd repo get <repo-url>

# Check repo-server logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server
```

**Solutions**:

1. **Add Repository**:
   ```bash
   argocd repo add https://github.com/user/repo.git
   ```

2. **For Private Repos**:
   ```bash
   argocd repo add https://github.com/user/repo.git \
     --username git \
     --password <token>
   ```

### Force Sync Application

```bash
# Sync with force and prune
argocd app sync <app-name> --force --prune

# Hard refresh (clear cache)
argocd app get <app-name> --hard-refresh
argocd app sync <app-name>
```

## Talos Issues

### Cannot Connect to Talos API

**Symptoms**: `talosctl` commands fail

```bash
# Check talosconfig is set
echo $TALOSCONFIG

# Or specify explicitly
talosctl --talosconfig /path/to/talosconfig --nodes 192.168.30.50 version
```

**Solutions**:

1. **Set TALOSCONFIG**:
   ```bash
   export TALOSCONFIG=/path/to/talos/clusterconfig/talosconfig
   ```

2. **Check Network Connectivity**:
   ```bash
   ping 192.168.30.50
   nc -zv 192.168.30.50 50000
   ```

### Talos Node Not Booting

**Symptoms**: VM not starting or stuck at boot

**Check via Proxmox Console**:

1. **Boot Issues**:
   - Verify UEFI boot is enabled
   - Check boot order (disk before ISO)

2. **Configuration Issues**:
   - Boot from ISO and check maintenance mode
   - Verify configuration syntax

### Kubernetes API Not Responding

**Symptoms**: `kubectl` commands fail

```bash
# Check Talos health
talosctl --nodes 192.168.30.50 health

# Check etcd
talosctl --nodes 192.168.30.50 etcd members

# Check kubelet logs
talosctl --nodes 192.168.30.50 logs kubelet
```

### Node Shows NotReady

**Symptoms**: `kubectl get nodes` shows NotReady

```bash
# Check conditions
kubectl describe node talos-cp01

# Check Cilium (CNI)
kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium-agent

# Check kubelet
talosctl --nodes 192.168.30.50 logs kubelet | tail -50
```

## Application-Specific Issues

### Plex Not Accessible

1. **Check LoadBalancer**:
   ```bash
   kubectl get svc plex -n media
   # Verify EXTERNAL-IP is assigned
   ```

2. **Check Pod**:
   ```bash
   kubectl get pods -n media -l app.kubernetes.io/name=plex
   kubectl logs -n media -l app.kubernetes.io/name=plex
   ```

3. **Check Port**:
   ```bash
   curl http://192.168.30.62:32400/web
   ```

### Sonarr/Radarr Cannot Connect to qBittorrent

1. **Verify qBittorrent Service**:
   ```bash
   kubectl get svc qbittorrent -n media
   ```

2. **Test Connection**:
   ```bash
   kubectl run -it --rm debug --image=busybox -- \
     wget -qO- http://qbittorrent.media.svc.cluster.local:8080
   ```

3. **Check Credentials**: Verify username/password in Sonarr/Radarr settings

### Grafana Cannot Load Dashboards

1. **Check Data Sources**:
   ```bash
   kubectl exec -n observability deploy/kube-prometheus-stack-grafana -- \
     curl -s http://localhost:3000/api/datasources
   ```

2. **Check Prometheus**:
   ```bash
   kubectl get pods -n observability -l app.kubernetes.io/name=prometheus
   ```

3. **Restart Sidecar**:
   ```bash
   kubectl rollout restart deployment kube-prometheus-stack-grafana -n observability
   ```

## Useful Commands Reference

### Kubernetes

```bash
# Get all resources in namespace
kubectl get all -n <namespace>

# Describe resource
kubectl describe <resource> <name> -n <namespace>

# View logs
kubectl logs <pod> -n <namespace>
kubectl logs <pod> -n <namespace> --previous  # Previous container
kubectl logs <pod> -n <namespace> -f  # Follow

# Execute in pod
kubectl exec -it <pod> -n <namespace> -- /bin/sh

# Port forward
kubectl port-forward svc/<service> <local>:<remote> -n <namespace>

# View events
kubectl get events -n <namespace> --sort-by='.lastTimestamp'

# Resource usage
kubectl top pods -n <namespace>
kubectl top nodes
```

### Talos

```bash
# Health check
talosctl --nodes 192.168.30.50 health

# View logs
talosctl --nodes 192.168.30.50 logs <service>
talosctl --nodes 192.168.30.50 logs kubelet
talosctl --nodes 192.168.30.50 logs containerd

# Dashboard (interactive)
talosctl --nodes 192.168.30.50 dashboard

# Get running services
talosctl --nodes 192.168.30.50 services

# Restart service
talosctl --nodes 192.168.30.50 service <service> restart

# Reboot node
talosctl --nodes 192.168.30.50 reboot
```

### ArgoCD

```bash
# Login
argocd login localhost:8080

# List apps
argocd app list

# Get app details
argocd app get <app-name>

# Sync app
argocd app sync <app-name>

# View logs
argocd app logs <app-name>

# Delete app
argocd app delete <app-name>
```

### Cilium

```bash
# Status
cilium status

# Connectivity test
cilium connectivity test

# Hubble observe
cilium hubble port-forward &
hubble observe
hubble observe --namespace <namespace>
```

### Debug Pod

Quick debug pod for network testing:

```bash
kubectl run -it --rm debug --image=busybox -- sh

# Inside pod:
wget -qO- http://service.namespace.svc.cluster.local:port
nslookup service.namespace.svc.cluster.local
ping <ip>
nc -zv <host> <port>
```

For more tools:

```bash
kubectl run -it --rm debug --image=nicolaka/netshoot -- bash

# Inside pod:
curl, dig, nslookup, ping, traceroute, tcpdump, etc.
```
