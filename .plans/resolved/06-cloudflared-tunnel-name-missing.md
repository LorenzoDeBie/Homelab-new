# Issue 6: Cloudflared Tunnel Name/ID Not Configured in Helm Values

## Status: RESOLVED

## Resolution Date: 2026-01-21

## Affected Components
- `cloudflared-cloudflare-tunnel` deployment in `cloudflared` namespace

## Original Error
```
"cloudflared tunnel run" requires the ID or name of the tunnel to run as the last command line argument or in the configuration file.
See 'cloudflared tunnel run --help'.
```

## Root Cause
Two issues were identified:

1. **Missing `tunnelName` in Helm values**: The cloudflare-tunnel Helm chart uses `tunnelName` (not `tunnel` or `tunnelId`) to populate the `tunnel:` field in the ConfigMap.

2. **Incorrect secret format**: The Helm chart expects a `credentials.json` key in the secret containing the full credentials JSON, not separate keys for `TunnelID`, `AccountTag`, and `TunnelSecret`.

3. **Duplicate catch-all ingress rule**: The application.yaml specified a catch-all rule (`- service: http_status:404`) but the chart also automatically adds one, causing the error: "Rule #3 is matching the hostname '', but this will match every hostname".

## Fix Applied

### 1. Updated `kubernetes/core/cloudflared/application.yaml`:
- Added `tunnelName: f725ee00-7559-4fa2-ad97-cf4044b3770b` to the Helm values
- Removed the explicit catch-all rule (chart adds one automatically)

```yaml
cloudflare:
  tunnelName: f725ee00-7559-4fa2-ad97-cf4044b3770b
  secretName: cloudflared-credentials
  ingress:
    - hostname: plex.lorenzodebie.be
      service: http://plex.media.svc.cluster.local:32400
    - hostname: requests.lorenzodebie.be
      service: http://overseerr.media.svc.cluster.local:5055
```

### 2. Updated `kubernetes/core/cloudflared/credentials.sops.yaml`:
- Changed from separate keys to a single `credentials.json` key with the full JSON object

Before:
```yaml
stringData:
  TunnelID: f725ee00-7559-4fa2-ad97-cf4044b3770b
  AccountTag: ...
  TunnelSecret: ...
```

After:
```yaml
stringData:
  credentials.json: |
    {"AccountTag":"...","TunnelSecret":"...","TunnelID":"f725ee00-7559-4fa2-ad97-cf4044b3770b"}
```

## Verification

```bash
# Pod is running
$ kubectl get pods -n cloudflared
NAME                                            READY   STATUS    RESTARTS   AGE
cloudflared-cloudflare-tunnel-df66c5b89-fqkd7   1/1     Running   0          30s

# Tunnel connected to multiple Cloudflare edge locations
$ kubectl logs -n cloudflared deployment/cloudflared-cloudflare-tunnel --tail=10
2026-01-21T20:05:40Z INF Starting tunnel tunnelID=f725ee00-7559-4fa2-ad97-cf4044b3770b
2026-01-21T20:05:40Z INF Registered tunnel connection connIndex=0 location=bru03 protocol=quic
2026-01-21T20:05:40Z INF Registered tunnel connection connIndex=1 location=ams13 protocol=quic
2026-01-21T20:05:41Z INF Registered tunnel connection connIndex=2 location=ams08 protocol=quic
2026-01-21T20:05:42Z INF Registered tunnel connection connIndex=3 location=bru03 protocol=quic
```

## Lessons Learned
1. The `cloudflare-tunnel` Helm chart uses `tunnelName` to set the `tunnel` config value, not `tunnel` or `tunnelId`
2. When using `secretName`, the secret must contain a `credentials.json` key with the full JSON credentials
3. The chart automatically adds a catch-all `http_status:404` rule - do not add one manually

## Related Documentation
- Cloudflare Tunnel Helm Chart: https://github.com/cloudflare/helm-charts/tree/main/charts/cloudflare-tunnel
- Cloudflare Tunnel Configuration: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/local-management/configuration-file/
