# Networking Deep Dive

This document provides comprehensive documentation on the networking architecture, including Cilium configuration, Gateway API, LoadBalancer setup, DNS configuration, and external access methods.

## Table of Contents

- [Network Overview](#network-overview)
- [Cilium Configuration](#cilium-configuration)
- [Gateway API Setup](#gateway-api-setup)
- [L2 Announcements and LoadBalancer](#l2-announcements-and-loadbalancer)
- [DNS Configuration](#dns-configuration)
- [Cloudflare Tunnel](#cloudflare-tunnel)
- [Tailscale Integration](#tailscale-integration)
- [Traffic Flow Examples](#traffic-flow-examples)
- [Network Policies](#network-policies)

## Network Overview

### Talos Node IP Configuration

In a single-node Talos cluster, special care must be taken when the Kubernetes API endpoint IP matches the node IP. Talos automatically excludes the cluster endpoint IP from being used as the kubelet's node IP, which can cause issues with `kubectl port-forward` and other features that require direct node connectivity.

**The Problem:**
- Cluster endpoint: `192.168.30.50:6443`
- Node IP: `192.168.30.50`
- Talos excludes `192.168.30.50` from kubelet node IP selection
- kubelet has no valid node IP, causing "no preferred addresses found" errors

**The Solution:**
Configure a secondary IP address on the network interface and explicitly tell the kubelet to use it:

```yaml
# In talos/clusterconfig/homelab-talos-cp01.yaml
machine:
  kubelet:
    nodeIP:
      validSubnets:
        - 192.168.30.51/32  # Secondary IP for kubelet
  network:
    interfaces:
      - interface: ens18
        addresses:
          - 192.168.30.50/24  # Primary IP (cluster endpoint)
          - 192.168.30.51/24  # Secondary IP (kubelet node IP)
        routes:
          - network: 0.0.0.0/0
            gateway: 192.168.30.1
```

This configuration ensures:
- `192.168.30.50` is used for the Kubernetes API endpoint
- `192.168.30.51` is used as the kubelet's node IP
- `kubectl port-forward` and other node-to-pod communication works correctly

See [Troubleshooting - kubectl port-forward Fails](#kubectl-port-forward-fails) for more details on diagnosing this issue.

### Network Topology

```
                              Internet
                                 |
                    +------------v------------+
                    |      Cloudflare         |
                    |   DNS + CDN + Tunnel    |
                    +------------+------------+
                                 |
              +------------------+------------------+
              |                                     |
    +---------v---------+                 +---------v---------+
    | Cloudflare Tunnel |                 |     Tailscale     |
    | (Public Access)   |                 |  (Private Access) |
    +---------+---------+                 +---------+---------+
              |                                     |
              +------------------+------------------+
                                 |
                    +------------v------------+
                    |     Home Router         |
                    |     192.168.30.1        |
                    +------------+------------+
                                 |
         +-----------------------+-----------------------+
         |                       |                       |
+--------v--------+    +---------v---------+   +--------v--------+
|   Pi-hole       |    |    Talos Node     |   |    TrueNAS      |
|  192.168.30.45  |    |   192.168.30.50   |   |  192.168.30.XX  |
|     (DNS)       |    |   (Kubernetes)    |   |     (NFS)       |
+-----------------+    +---------+---------+   +-----------------+
                                 |
              +------------------+------------------+
              |                  |                  |
    +---------v------+  +--------v-------+  +------v---------+
    | Internal GW    |  | Plex LB        |  | qBittorrent    |
    | 192.168.30.61  |  | 192.168.30.62  |  | 192.168.30.63  |
    | (Gateway API)  |  | (LoadBalancer) |  | (LoadBalancer) |
    +----------------+  +----------------+  +----------------+
```

### IP Addressing

| Range | Purpose |
|-------|---------|
| 192.168.30.0/24 | Applications VLAN |
| 192.168.30.1 | Gateway/Router |
| 192.168.30.10-49 | Infrastructure devices |
| 192.168.30.50 | Kubernetes API endpoint |
| 192.168.30.51 | Talos node kubelet IP |
| 192.168.30.52-59 | Reserved for additional nodes |
| 192.168.30.60-80 | Cilium LoadBalancer pool |
| 192.168.30.81-254 | DHCP / Other devices |

> **Note**: The Talos node has two IP addresses: `192.168.30.50` (cluster endpoint) and `192.168.30.51` (kubelet node IP). See [Talos Node IP Configuration](#talos-node-ip-configuration) for details.

### Ports Reference

| Port | Service | Protocol |
|------|---------|----------|
| 6443 | Kubernetes API | TCP |
| 50000 | Talos API | TCP |
| 80 | HTTP (Gateway) | TCP |
| 443 | HTTPS (Gateway) | TCP |
| 32400 | Plex | TCP |
| 8080 | qBittorrent Web | TCP |
| 6881 | BitTorrent | TCP/UDP |

## Cilium Configuration

Cilium serves as the CNI (Container Network Interface) and provides:
- Pod networking
- Service load balancing (kube-proxy replacement)
- Gateway API implementation
- L2 announcements for LoadBalancer IPs
- Network observability via Hubble

### Installation Configuration

From `kubernetes/core/cilium/application.yaml`:

```yaml
helm:
  valuesObject:
    # Talos-specific settings
    ipam:
      mode: kubernetes
    
    # Replace kube-proxy entirely
    kubeProxyReplacement: true
    
    # Required capabilities for Talos
    securityContext:
      capabilities:
        ciliumAgent:
          - CHOWN
          - KILL
          - NET_ADMIN
          - NET_RAW
          - IPC_LOCK
          - SYS_ADMIN
          - SYS_RESOURCE
          - DAC_OVERRIDE
          - FOWNER
          - SETGID
          - SETUID
        cleanCiliumState:
          - NET_ADMIN
          - SYS_ADMIN
          - SYS_RESOURCE
    
    # Talos cgroup settings
    cgroup:
      autoMount:
        enabled: false
      hostRoot: /sys/fs/cgroup
    
    # Talos API proxy
    k8sServiceHost: localhost
    k8sServicePort: 7445
    
    # Enable Gateway API
    gatewayAPI:
      enabled: true
    
    # Enable L2 announcements for LoadBalancer
    l2announcements:
      enabled: true
    
    externalIPs:
      enabled: true
    
    # Hubble observability
    hubble:
      enabled: true
      relay:
        enabled: true
      ui:
        enabled: true
    
    # Single node, single replica
    operator:
      replicas: 1
```

### Verify Cilium Status

```bash
# Check Cilium pods
kubectl -n kube-system get pods -l app.kubernetes.io/part-of=cilium

# Check Cilium status (requires cilium CLI)
cilium status

# Check connectivity
cilium connectivity test
```

### Hubble Observability

Hubble provides network visibility:

```bash
# Port forward to Hubble UI
kubectl port-forward -n kube-system svc/hubble-ui 12000:80

# Open http://localhost:12000
```

Or via CLI:

```bash
# Install hubble CLI
brew install hubble

# Enable port forward
cilium hubble port-forward &

# Observe traffic
hubble observe
hubble observe --namespace media
hubble observe --to-pod sonarr
```

## Gateway API Setup

Gateway API is the successor to Ingress, providing more expressive routing.

### Components

```
+------------------+
|   GatewayClass   |  "cilium" - Defines Cilium as the controller
+--------+---------+
         |
+--------v---------+
|     Gateway      |  "internal-gateway" - Configures listeners
+--------+---------+
         |
         +------------------+------------------+
         |                  |                  |
+--------v-------+  +-------v--------+  +------v---------+
|   HTTPRoute    |  |   HTTPRoute    |  |   HTTPRoute    |
|    (sonarr)    |  |    (radarr)    |  |    (grafana)   |
+----------------+  +----------------+  +----------------+
```

### GatewayClass

```yaml
# kubernetes/core/gateway-api/gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: cilium
spec:
  controllerName: io.cilium/gateway-controller
```

### Gateway Configuration

```yaml
# kubernetes/core/gateway-api/gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: internal-gateway
  namespace: kube-system
  annotations:
    # Request specific LoadBalancer IP
    io.cilium/lb-ipam-ips: "192.168.30.61"
spec:
  gatewayClassName: cilium
  listeners:
    # HTTP listener (redirects to HTTPS)
    - name: http
      port: 80
      protocol: HTTP
      hostname: "*.int.lorenzodebie.be"
      allowedRoutes:
        namespaces:
          from: All
    
    # HTTPS listener with TLS termination
    - name: https
      port: 443
      protocol: HTTPS
      hostname: "*.int.lorenzodebie.be"
      allowedRoutes:
        namespaces:
          from: All
      tls:
        mode: Terminate
        certificateRefs:
          - name: internal-wildcard-tls
            namespace: kube-system
```

### HTTPRoute Example

```yaml
# kubernetes/apps/media/sonarr/httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: sonarr
  namespace: media
spec:
  parentRefs:
    - name: internal-gateway
      namespace: kube-system
  hostnames:
    - sonarr.int.lorenzodebie.be
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: sonarr
          port: 8989
```

### TLS Certificate

```yaml
# kubernetes/core/gateway-api/internal-certificate.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: internal-wildcard-tls
  namespace: kube-system
spec:
  secretName: internal-wildcard-tls
  issuerRef:
    name: letsencrypt-production
    kind: ClusterIssuer
  dnsNames:
    - "*.int.lorenzodebie.be"
    - "int.lorenzodebie.be"
```

### Verify Gateway

```bash
# Check Gateway status
kubectl get gateway -A
kubectl describe gateway internal-gateway -n kube-system

# Check HTTPRoutes
kubectl get httproute -A

# Check if Gateway has an IP
kubectl get svc -n kube-system | grep cilium-gateway
```

## L2 Announcements and LoadBalancer

Cilium L2 announcements allow LoadBalancer services to work without external load balancer hardware.

### How It Works

1. A Service of type `LoadBalancer` is created
2. Cilium IPAM assigns an IP from the configured pool
3. Cilium responds to ARP requests for that IP
4. Traffic to that IP is routed to the node running Cilium
5. Cilium forwards traffic to the appropriate pods

### L2 Announcement Policy

```yaml
# kubernetes/core/cilium/l2-announcement.yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: default-l2-policy
spec:
  # Announce on all ethernet interfaces
  interfaces:
    - ^eth[0-9]+
    - ^en[0-9]+
  externalIPs: true
  loadBalancerIPs: true
```

### IP Pool Configuration

```yaml
# kubernetes/core/cilium/l2-announcement.yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: default-pool
spec:
  blocks:
    - start: 192.168.30.60
      stop: 192.168.30.80
```

### Request Specific IP

For services that need a consistent IP:

```yaml
metadata:
  annotations:
    io.cilium/lb-ipam-ips: "192.168.30.62"
spec:
  type: LoadBalancer
```

### Verify L2 Announcements

```bash
# Check IP pool
kubectl get ciliumloadbalancerippool

# Check services with LoadBalancer IPs
kubectl get svc -A -o wide | grep LoadBalancer

# Check Cilium's view of L2 announcements
kubectl get ciliuml2announcementpolicy
```

## DNS Configuration

### Pi-hole Setup

Pi-hole serves as the local DNS resolver for internal services.

**Add DNS Records**:

1. Access Pi-hole admin: `http://192.168.30.45/admin`
2. Navigate to: Local DNS > DNS Records
3. Add records:

| Domain | IP Address |
|--------|------------|
| int.lorenzodebie.be | 192.168.30.61 |
| sonarr.int.lorenzodebie.be | 192.168.30.61 |
| radarr.int.lorenzodebie.be | 192.168.30.61 |
| prowlarr.int.lorenzodebie.be | 192.168.30.61 |
| qbittorrent.int.lorenzodebie.be | 192.168.30.61 |
| grafana.int.lorenzodebie.be | 192.168.30.61 |
| argocd.int.lorenzodebie.be | 192.168.30.61 |
| auth.int.lorenzodebie.be | 192.168.30.61 |
| talos.int.lorenzodebie.be | 192.168.30.50 |

**Alternative: Wildcard with dnsmasq**:

Edit `/etc/dnsmasq.d/02-internal.conf`:
```
address=/int.lorenzodebie.be/192.168.30.61
```

Restart dnsmasq:
```bash
pihole restartdns
```

### Verify DNS

```bash
# Test resolution
nslookup sonarr.int.lorenzodebie.be 192.168.30.45
dig @192.168.30.45 sonarr.int.lorenzodebie.be

# From within the cluster
kubectl run -it --rm debug --image=busybox -- nslookup sonarr.int.lorenzodebie.be
```

## Cloudflare Tunnel

Cloudflare Tunnel provides secure public access without opening firewall ports.

### How It Works

```
Internet User
     |
     v
Cloudflare Edge (CDN)
     |
     v
Cloudflare Tunnel (encrypted)
     |
     v
cloudflared Pod (in cluster)
     |
     v
Internal Service (Plex, Overseerr)
```

### Configuration

**Create Tunnel** (one-time):

```bash
# Login to Cloudflare
cloudflared tunnel login

# Create tunnel
cloudflared tunnel create homelab
# Note: Save the tunnel ID

# Get credentials
cat ~/.cloudflared/<tunnel-id>.json
```

**Configure DNS** in Cloudflare Dashboard:

| Record | Type | Value | Proxy |
|--------|------|-------|-------|
| plex | CNAME | `<tunnel-id>.cfargotunnel.com` | Yes |
| requests | CNAME | `<tunnel-id>.cfargotunnel.com` | Yes |

**Ingress Configuration** (in application.yaml):

```yaml
cloudflare:
  ingress:
    # Plex
    - hostname: plex.lorenzodebie.be
      service: http://plex.media.svc.cluster.local:32400
    
    # Overseerr
    - hostname: requests.lorenzodebie.be
      service: http://overseerr.media.svc.cluster.local:5055
    
    # Catch-all (required)
    - service: http_status:404
```

### Verify Tunnel

```bash
# Check cloudflared pod
kubectl get pods -n cloudflared

# Check logs
kubectl logs -n cloudflared -l app.kubernetes.io/name=cloudflare-tunnel

# Test public access
curl -I https://plex.lorenzodebie.be
```

## Tailscale Integration

Tailscale provides private mesh VPN access to internal services.

### Architecture

```
Your Device (Tailscale Client)
     |
     | Tailscale Network (WireGuard)
     v
Tailscale Operator (in cluster)
     |
     v
Kubernetes Services
```

### Operator Configuration

```yaml
# kubernetes/core/tailscale-operator/application.yaml
helm:
  valuesObject:
    oauth:
      clientId: ""      # From secret
      clientSecret: ""  # From secret
    
    operatorConfig:
      hostname: homelab-k8s-operator
```

### Expose Service via Tailscale

Add annotations to a Service:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
  annotations:
    tailscale.com/expose: "true"
    tailscale.com/hostname: "my-service"
spec:
  # ...
```

The service will be accessible at `my-service.tailnet-name.ts.net`.

### Subnet Router Configuration

The Tailscale Operator deploys a Connector that acts as a subnet router, advertising 
the homelab network (`192.168.30.0/24`) to your Tailnet.

**What this enables:**
- Access all internal services from any Tailscale-connected device
- Use existing `*.int.lorenzodebie.be` domains from remote locations
- No need to expose individual services to the internet

**Remote Access Setup:**

1. Connect to Tailscale on your device
2. Configure DNS (choose one):
   - **Option A (Recommended)**: Configure Tailscale DNS to use Pi-hole for `int.lorenzodebie.be`
   - **Option B**: Manually set your device DNS to `192.168.30.45` when on Tailscale
3. Access services normally: `https://grafana.int.lorenzodebie.be`

**Tailscale Admin Console Configuration:**

Before the subnet router works, you need to configure ACL tags and auto-approvers in the 
[Tailscale Admin Console](https://login.tailscale.com/admin/):

1. Navigate to **Access Controls** and add the following to your ACL policy:

```json
{
  "tagOwners": {
    "tag:k8s-operator": [],
    "tag:k8s": ["tag:k8s-operator"],
    "tag:k8s-subnet": ["tag:k8s-operator"]
  },
  "autoApprovers": {
    "routes": {
      "192.168.30.0/24": ["tag:k8s-subnet"]
    }
  }
}
```

2. (Optional) Configure Tailscale DNS for seamless resolution:
   - Navigate to **DNS** in the admin console
   - Add a nameserver: `192.168.30.45` (Pi-hole)
   - Restrict to domain: `int.lorenzodebie.be`

**Verify Subnet Router:**

```bash
# Check Connector status
kubectl get connector homelab-subnet-router

# Check subnet router pod
kubectl get pods -n tailscale -l tailscale.com/parent-resource=homelab-subnet-router

# In Tailscale admin console, verify:
# - Device "homelab-subnet-0" appears in Machines tab
# - Route "192.168.30.0/24" is approved
```

### Access via Tailscale

1. Connect to Tailscale on your device
2. Access services via their Tailscale hostname or IP
3. Alternatively, access via internal Gateway (192.168.30.61) using the subnet router

### Verify Tailscale

```bash
# Check operator
kubectl get pods -n tailscale

# Check exposed services
kubectl get svc -A -o json | jq '.items[] | select(.metadata.annotations["tailscale.com/expose"]=="true") | .metadata.name'

# From Tailscale admin
# Check Machines tab for "homelab-k8s-operator"
```

## Traffic Flow Examples

### Public Access to Plex

```
1. User browses to plex.lorenzodebie.be
2. Cloudflare DNS resolves to Cloudflare edge
3. Cloudflare edge connects to tunnel
4. cloudflared pod receives request
5. cloudflared forwards to plex.media.svc.cluster.local:32400
6. Kubernetes routes to Plex pod
7. Response flows back through tunnel
```

### Internal Access to Sonarr

```
1. User (on LAN) browses to sonarr.int.lorenzodebie.be
2. Pi-hole resolves to 192.168.30.61
3. Request hits internal-gateway (Cilium)
4. Gateway matches HTTPRoute for sonarr
5. Request forwarded to sonarr.media.svc.cluster.local:8989
6. Kubernetes routes to Sonarr pod
```

### Remote Access via Tailscale

```
1. User (remote) connects to Tailscale
2. User browses to sonarr.int.lorenzodebie.be
3. Tailscale routes traffic to home network
4. Pi-hole (or Tailscale MagicDNS) resolves to 192.168.30.61
5. (Same as internal access from step 3)
```

## Network Policies

While Cilium supports network policies, this setup currently uses a permissive model. For production, consider:

### Example Network Policy

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-gateway-ingress
  namespace: media
spec:
  endpointSelector:
    matchLabels:
      app: sonarr
  ingress:
    - fromEndpoints:
        - matchLabels:
            io.cilium.k8s.policy.serviceaccount: cilium-gateway
      toPorts:
        - ports:
            - port: "8989"
```

### Recommended Policies

1. **Default deny all ingress** (per namespace)
2. **Allow from Gateway** for web services
3. **Allow between media apps** for internal communication
4. **Allow from Prometheus** for metrics scraping

## Troubleshooting

### Service Not Reachable

```bash
# Check service exists
kubectl get svc -n <namespace>

# Check endpoints
kubectl get endpoints -n <namespace> <service-name>

# Check pod is running
kubectl get pods -n <namespace> -l app=<app-name>

# Test from within cluster
kubectl run -it --rm debug --image=busybox -- wget -qO- http://<service>.<namespace>.svc.cluster.local:<port>
```

### LoadBalancer IP Not Working

```bash
# Check IP pool has available IPs
kubectl get ciliumloadbalancerippool -o yaml

# Check L2 announcement policy
kubectl get ciliuml2announcementpolicy -o yaml

# Check Cilium agent logs
kubectl logs -n kube-system -l app.kubernetes.io/name=cilium-agent

# Verify ARP (from another machine on same network)
arp -a | grep 192.168.30.6
```

### Gateway Not Routing

```bash
# Check Gateway status
kubectl describe gateway internal-gateway -n kube-system

# Check HTTPRoute status
kubectl describe httproute <route-name> -n <namespace>

# Check certificate is valid
kubectl get certificate -n kube-system
kubectl describe certificate internal-wildcard-tls -n kube-system
```

### DNS Not Resolving

```bash
# Test Pi-hole directly
dig @192.168.30.45 sonarr.int.lorenzodebie.be

# Check Pi-hole logs
# In Pi-hole admin > Query Log

# Verify client is using Pi-hole as DNS
# Check /etc/resolv.conf or network settings
```
