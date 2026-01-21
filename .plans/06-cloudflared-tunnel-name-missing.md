# Issue 6: Cloudflared Tunnel Name/ID Not Configured in Helm Values

## Status: OPEN

## Affected Components
- `cloudflared-cloudflare-tunnel-c96cb67fc-rk4cq` pod in `cloudflared` namespace - CrashLoopBackOff

## Error Message
```
"cloudflared tunnel run" requires the ID or name of the tunnel to run as the last command line argument or in the configuration file.
See 'cloudflared tunnel run --help'.
```

## Root Cause
The cloudflared Helm chart creates a ConfigMap with an empty `tunnel:` value:

```yaml
# From ConfigMap cloudflared-cloudflare-tunnel
tunnel:                    # <-- EMPTY!
credentials-file: /etc/cloudflared/creds/credentials.json
```

While the `cloudflared-credentials` secret contains the `TunnelID`, the Helm chart expects the tunnel ID to be specified in the Helm values under `cloudflare.tunnel`, not just in the credentials secret.

The current `application.yaml` does not specify the `cloudflare.tunnel` value:

```yaml
cloudflare:
  secretName: cloudflared-credentials
  ingress:
    - hostname: plex.lorenzodebie.be
      service: http://plex.media.svc.cluster.local:32400
    # ...
```

## Fix Steps

### Step 1: Get the Tunnel ID from the Secret

```bash
kubectl get secret cloudflared-credentials -n cloudflared -o jsonpath='{.data.TunnelID}' | base64 -d
```

This returns: `f725ee00-7559-4fa2-ad97-cf4044b3770b`

### Step 2: Update the Helm Values

Edit `kubernetes/core/cloudflared/application.yaml` to add the `tunnel` value:

```yaml
spec:
  source:
    helm:
      valuesObject:
        cloudflare:
          # Add the tunnel ID here
          tunnel: f725ee00-7559-4fa2-ad97-cf4044b3770b
          
          # Existing configuration
          secretName: cloudflared-credentials
          ingress:
            - hostname: plex.lorenzodebie.be
              service: http://plex.media.svc.cluster.local:32400
            # ...
```

### Step 3: Commit and Push

```bash
git add kubernetes/core/cloudflared/application.yaml
git commit -m "fix(cloudflared): add tunnel ID to Helm values"
git push
```

### Step 4: Sync ArgoCD

ArgoCD should automatically sync, or force sync:

```bash
argocd app sync cloudflared
```

## Alternative Fix: Use credentials.json Format

The cloudflare-tunnel Helm chart may also support reading the tunnel ID directly from `credentials.json` if the secret is structured correctly. The current secret has separate keys:

```yaml
data:
  TunnelID: ...
  AccountTag: ...
  TunnelSecret: ...
```

Some versions of the chart expect a single `credentials.json` key containing:

```json
{
  "AccountTag": "...",
  "TunnelSecret": "...",
  "TunnelName": "...",
  "TunnelID": "..."
}
```

If using this format, update `credentials.sops.yaml` to use a single `credentials.json` key instead of separate keys.

## Verification

```bash
# Check pod is running
kubectl get pods -n cloudflared

# Check logs for successful tunnel connection
kubectl logs -n cloudflared -l app.kubernetes.io/name=cloudflare-tunnel --tail=20

# Test endpoints
curl -I https://plex.lorenzodebie.be
curl -I https://requests.lorenzodebie.be
```

## Related Documentation
- Cloudflare Tunnel Helm Chart: https://github.com/cloudflare/helm-charts/tree/main/charts/cloudflare-tunnel
- Cloudflare Tunnel Configuration: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/local-management/configuration-file/
