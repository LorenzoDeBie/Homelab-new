# Observability Documentation

This document covers the monitoring and logging stack, including Prometheus, Grafana, Loki, and Promtail configuration and usage.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prometheus](#prometheus)
- [Grafana](#grafana)
- [Loki](#loki)
- [Promtail](#promtail)
- [Dashboards](#dashboards)
- [Alerting](#alerting)
- [Accessing Metrics and Logs](#accessing-metrics-and-logs)
- [Troubleshooting](#troubleshooting)

## Overview

The observability stack provides:

- **Metrics**: Prometheus collects and stores time-series metrics
- **Visualization**: Grafana displays dashboards and graphs
- **Logging**: Loki aggregates logs from all containers
- **Collection**: Promtail ships logs to Loki

### Components

| Component | Purpose | Port | Access |
|-----------|---------|------|--------|
| Prometheus | Metrics collection | 9090 | Internal |
| Grafana | Visualization | 3000 | Internal |
| Alertmanager | Alert routing | 9093 | Internal |
| Loki | Log aggregation | 3100 | Internal |
| Promtail | Log shipping | - | DaemonSet |

## Architecture

```
+------------------+     +------------------+     +------------------+
|   Applications   |     |   Applications   |     |   Kubernetes     |
| (with metrics)   |     | (stdout logs)    |     |   Components     |
+--------+---------+     +--------+---------+     +--------+---------+
         |                        |                        |
         | /metrics               | logs                   | /metrics
         v                        v                        v
+--------+---------+     +--------+---------+     +--------+---------+
|   Prometheus     |     |    Promtail      |     |   Prometheus     |
| ServiceMonitors  |     |   (DaemonSet)    |     | ServiceMonitors  |
+--------+---------+     +--------+---------+     +--------+---------+
         |                        |                        |
         | store                  | push                   | store
         v                        v                        v
+--------+------------------------+---------+     +--------+---------+
|              Prometheus                   |     |      Loki        |
|          (Time Series DB)                 |     | (Log Aggregator) |
+---------------------+---------------------+     +--------+---------+
                      |                                    |
                      | query                              | query
                      v                                    v
               +------+--------------------------------------+
               |                 Grafana                     |
               |             (Dashboards)                    |
               +---------------------------------------------+
                                    |
                                    v
                            +-------+-------+
                            |     User      |
                            +---------------+
```

## Prometheus

Prometheus scrapes metrics from applications and Kubernetes components.

### Installation

Deployed via kube-prometheus-stack Helm chart:

```yaml
# kubernetes/observability/kube-prometheus-stack/application.yaml
source:
  repoURL: https://prometheus-community.github.io/helm-charts
  chart: kube-prometheus-stack
  targetRevision: 67.4.0
```

### What's Scraped

The kube-prometheus-stack automatically discovers and scrapes:

| Target | Endpoint | Notes |
|--------|----------|-------|
| Kubernetes API Server | :6443/metrics | Built-in |
| kubelet | :10250/metrics | Per node |
| kube-controller-manager | :10257/metrics | Via Service |
| kube-scheduler | :10259/metrics | Via Service |
| etcd | :2381/metrics | Via Service |
| CoreDNS | :9153/metrics | Built-in |
| Cilium | :9962/metrics | ServiceMonitor |
| ArgoCD | various | ServiceMonitor |
| cert-manager | :9402/metrics | ServiceMonitor |

### Custom ServiceMonitors

To add monitoring for your application:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: my-app
  namespace: observability
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app: my-app
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
  namespaceSelector:
    matchNames:
      - my-namespace
```

### Configuration

Key Prometheus settings:

```yaml
prometheus:
  prometheusSpec:
    retention: 30d              # Keep metrics for 30 days
    retentionSize: 50GB         # Or until 50GB is used
    
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: nfs-config
          resources:
            requests:
              storage: 50Gi
    
    # Discover all ServiceMonitors
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
    
    resources:
      requests:
        cpu: 200m
        memory: 1Gi
      limits:
        memory: 4Gi
```

### Talos-Specific Configuration

Talos requires explicit endpoints for control plane components:

```yaml
kubeControllerManager:
  enabled: true
  endpoints:
    - 192.168.30.50  # Talos node IP
  service:
    port: 10257
    targetPort: 10257
  serviceMonitor:
    https: true
    insecureSkipVerify: true

kubeScheduler:
  enabled: true
  endpoints:
    - 192.168.30.50
  service:
    port: 10259
    targetPort: 10259

kubeEtcd:
  enabled: true
  endpoints:
    - 192.168.30.50
  service:
    port: 2381
    targetPort: 2381

kubeProxy:
  enabled: false  # Replaced by Cilium
```

### Access Prometheus UI

```bash
# Port forward
kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090

# Open http://localhost:9090
```

Or access via https://prometheus.int.lorenzodebie.be (if HTTPRoute configured).

## Grafana

Grafana provides visualization and dashboards.

### Access

**URL**: https://grafana.int.lorenzodebie.be

**Credentials**: Stored in SOPS-encrypted secret:
- Username: `admin`
- Password: (from `grafana-secret.sops.yaml`)

### Configuration

```yaml
grafana:
  enabled: true
  
  admin:
    existingSecret: grafana-admin
    userKey: admin-user
    passwordKey: admin-password
  
  persistence:
    enabled: true
    storageClassName: nfs-config
    size: 5Gi
  
  sidecar:
    dashboards:
      enabled: true
      searchNamespace: ALL
    datasources:
      enabled: true
      searchNamespace: ALL
  
  additionalDataSources:
    - name: Loki
      type: loki
      url: http://loki.observability.svc.cluster.local:3100
      access: proxy
```

### Data Sources

Pre-configured data sources:

| Name | Type | URL |
|------|------|-----|
| Prometheus | prometheus | http://prometheus:9090 |
| Loki | loki | http://loki:3100 |
| Alertmanager | alertmanager | http://alertmanager:9093 |

### Default Dashboards

The kube-prometheus-stack includes many dashboards:

- Kubernetes Cluster Overview
- Node Exporter Full
- Kubernetes Pod Resources
- CoreDNS
- etcd
- API Server
- And many more...

## Loki

Loki is a log aggregation system designed to be cost-effective and easy to operate.

### Installation

```yaml
# kubernetes/observability/loki/application.yaml
source:
  repoURL: https://grafana.github.io/helm-charts
  chart: loki
  targetRevision: 6.21.0
```

### Configuration

Single-binary mode for simple single-node setup:

```yaml
deploymentMode: SingleBinary

loki:
  auth_enabled: false
  
  commonConfig:
    replication_factor: 1
  
  storage:
    type: filesystem
  
  schemaConfig:
    configs:
      - from: "2024-01-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: loki_index_
          period: 24h
  
  limits_config:
    retention_period: 30d
    ingestion_rate_mb: 10
    ingestion_burst_size_mb: 20

singleBinary:
  replicas: 1
  persistence:
    enabled: true
    storageClass: nfs-config
    size: 50Gi
```

### Verify Loki

```bash
# Check pod
kubectl get pods -n observability -l app.kubernetes.io/name=loki

# Check logs
kubectl logs -n observability -l app.kubernetes.io/name=loki

# Test query
kubectl port-forward -n observability svc/loki 3100:3100
curl http://localhost:3100/ready
```

## Promtail

Promtail collects logs from all containers and ships them to Loki.

### Installation

```yaml
# kubernetes/observability/loki/promtail.yaml
source:
  repoURL: https://grafana.github.io/helm-charts
  chart: promtail
  targetRevision: 6.16.6
```

### Configuration

```yaml
config:
  clients:
    - url: http://loki.observability.svc.cluster.local:3100/loki/api/v1/push
  
  snippets:
    pipelineStages:
      - cri: {}  # Parse CRI log format

tolerations:
  - operator: Exists  # Run on all nodes including control plane

serviceMonitor:
  enabled: true
```

### How It Works

1. Promtail runs as DaemonSet on every node
2. Reads logs from `/var/log/pods/`
3. Parses container logs (CRI format)
4. Adds Kubernetes labels as log labels
5. Pushes to Loki

### Verify Promtail

```bash
# Check pods (one per node)
kubectl get pods -n observability -l app.kubernetes.io/name=promtail

# Check logs
kubectl logs -n observability -l app.kubernetes.io/name=promtail
```

## Dashboards

### Accessing Dashboards

1. Navigate to https://grafana.int.lorenzodebie.be
2. Login with admin credentials
3. Go to Dashboards > Browse

### Recommended Dashboards

**Kubernetes**:
- Kubernetes / Compute Resources / Cluster
- Kubernetes / Compute Resources / Namespace (Pods)
- Kubernetes / Networking / Cluster
- Node Exporter / Nodes

**Applications**:
- ArgoCD (if ServiceMonitor enabled)
- Cilium Agent
- cert-manager

### Import Custom Dashboards

1. Go to Dashboards > Import
2. Enter dashboard ID from [Grafana.com](https://grafana.com/grafana/dashboards/)
3. Or paste JSON

**Useful Dashboard IDs**:
- 1860: Node Exporter Full
- 15757: Kubernetes Views / Global
- 15758: Kubernetes Views / Namespaces
- 15759: Kubernetes Views / Nodes
- 15760: Kubernetes Views / Pods

### Create Dashboard ConfigMap

To persist custom dashboards via GitOps:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-dashboard
  namespace: observability
  labels:
    grafana_dashboard: "1"
data:
  my-dashboard.json: |
    {
      "title": "My Dashboard",
      ...
    }
```

The Grafana sidecar automatically discovers and imports dashboards.

## Alerting

### Alertmanager

Alertmanager handles alert routing and notifications.

**Access**: https://alertmanager.int.lorenzodebie.be

### Default Alerts

The kube-prometheus-stack includes many alerts:

| Category | Examples |
|----------|----------|
| Node | NodeDown, NodeMemoryPressure, NodeDiskPressure |
| Pod | KubePodCrashLooping, KubePodNotReady |
| Deployment | KubeDeploymentReplicasMismatch |
| Persistent Volume | KubePersistentVolumeFillingUp |
| API Server | KubeAPILatencyHigh |

### View Active Alerts

In Prometheus UI:
1. Go to Alerts tab
2. View firing and pending alerts

In Alertmanager UI:
1. View grouped alerts
2. Silence specific alerts

### Configure Alert Notifications

To add alert destinations, create an AlertmanagerConfig:

```yaml
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: notifications
  namespace: observability
spec:
  route:
    receiver: discord
    groupBy: [alertname, namespace]
  receivers:
    - name: discord
      discordConfigs:
        - webhookURL:
            name: discord-webhook
            key: url
```

### Create Custom Alerts

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: custom-alerts
  namespace: observability
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: custom
      rules:
        - alert: HighMemoryUsage
          expr: |
            (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) 
            / node_memory_MemTotal_bytes > 0.9
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "High memory usage detected"
            description: "Memory usage is above 90% for 5 minutes"
```

## Accessing Metrics and Logs

### Prometheus Queries (PromQL)

Common queries:

```promql
# CPU usage by pod
sum(rate(container_cpu_usage_seconds_total[5m])) by (pod)

# Memory usage by namespace
sum(container_memory_usage_bytes) by (namespace)

# HTTP request rate
sum(rate(http_requests_total[5m])) by (service)

# Pod restart count
sum(kube_pod_container_status_restarts_total) by (pod, namespace)

# Node CPU usage
100 - (avg by(instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
```

### Loki Queries (LogQL)

Common queries:

```logql
# All logs from a namespace
{namespace="media"}

# Logs from specific pod
{pod="sonarr-0"}

# Error logs
{namespace="media"} |= "error"

# JSON log parsing
{app="myapp"} | json | level="error"

# Rate of logs
rate({namespace="media"}[5m])

# Aggregate count
sum(count_over_time({namespace="media"}[1h])) by (pod)
```

### Grafana Explore

1. Go to Explore (compass icon)
2. Select data source (Prometheus or Loki)
3. Build queries using UI or type directly
4. View results as graph, table, or logs

### CLI Access

```bash
# Port forward Prometheus
kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090

# Query metrics
curl -s 'http://localhost:9090/api/v1/query?query=up' | jq

# Port forward Loki
kubectl port-forward -n observability svc/loki 3100:3100

# Query logs
curl -s 'http://localhost:3100/loki/api/v1/query_range?query={namespace="media"}&limit=10' | jq
```

## Troubleshooting

### Prometheus Not Scraping

```bash
# Check targets
kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090
# Open http://localhost:9090/targets

# Check ServiceMonitor
kubectl get servicemonitor -A
kubectl describe servicemonitor <name> -n <namespace>

# Verify labels match
kubectl get svc -n <namespace> --show-labels
```

### Grafana Dashboard Not Loading

```bash
# Check Grafana logs
kubectl logs -n observability -l app.kubernetes.io/name=grafana

# Check data source connectivity
kubectl exec -n observability -it <grafana-pod> -- \
  curl -s http://kube-prometheus-stack-prometheus:9090/api/v1/status/config

# Restart sidecar to reload dashboards
kubectl rollout restart deployment -n observability kube-prometheus-stack-grafana
```

### Loki Not Receiving Logs

```bash
# Check Promtail status
kubectl logs -n observability -l app.kubernetes.io/name=promtail

# Verify Loki is running
kubectl get pods -n observability -l app.kubernetes.io/name=loki

# Check Loki ready endpoint
kubectl exec -n observability -it <loki-pod> -- wget -qO- http://localhost:3100/ready

# Verify push endpoint
curl -X POST http://localhost:3100/loki/api/v1/push \
  -H "Content-Type: application/json" \
  -d '{"streams":[{"stream":{"test":"true"},"values":[["1234567890000000000","test log"]]}]}'
```

### High Memory Usage

```bash
# Check Prometheus memory
kubectl top pod -n observability -l app.kubernetes.io/name=prometheus

# Reduce retention
# In values: retention: 14d, retentionSize: 25GB

# Check cardinality
# In Prometheus UI: Status > TSDB Status
```

### Missing Kubernetes Metrics

For Talos, ensure control plane endpoints are correct:

```yaml
kubeControllerManager:
  endpoints:
    - 192.168.30.50  # Your Talos node IP
kubeScheduler:
  endpoints:
    - 192.168.30.50
kubeEtcd:
  endpoints:
    - 192.168.30.50
```

Verify pods can reach endpoints:

```bash
kubectl run -it --rm debug --image=busybox -- \
  wget -qO- https://192.168.30.50:10257/metrics --no-check-certificate
```
