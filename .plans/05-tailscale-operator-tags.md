# Issue 5: Tailscale Operator OAuth Tag Permission Error

## Status: OPEN

## Affected Components
- `operator-6ffdcc744d-6j6vr` pod in `tailscale` namespace - CrashLoopBackOff

## Error Message
```
2026/01/21 19:04:48 LocalBackend state is NeedsLogin; running StartLoginInteractive...
{"level":"fatal","ts":"2026-01-21T19:04:48Z","logger":"startup","msg":"creating operator authkey: Status: 400, Message: \"requested tags [tag:k8s-operator] are invalid or not permitted\""}
```

## Root Cause
The Tailscale OAuth client credentials stored in the `operator-oauth` secret do not have permission to create auth keys with the `tag:k8s-operator` tag.

This is a Tailscale ACL/admin console configuration issue, not a Kubernetes configuration issue.

## Fix Steps

### Step 1: Update Tailscale ACL Policy

In the Tailscale admin console (https://login.tailscale.com/admin/acls), add the `tag:k8s-operator` tag definition:

```json
{
  "tagOwners": {
    "tag:k8s-operator": ["autogroup:admin"]
  }
}
```

### Step 2: Update OAuth Client Permissions

1. Go to Tailscale admin console: https://login.tailscale.com/admin/settings/oauth
2. Find the OAuth client used for the k8s operator
3. Ensure it has the following scopes:
   - `devices:read`
   - `devices:write` 
   - `auth_keys` (with ability to create keys for `tag:k8s-operator`)

### Step 3: Regenerate OAuth Client (if needed)

If the existing OAuth client cannot be updated, create a new one:
1. Create new OAuth client with required scopes
2. Update the SOPS-encrypted secret `kubernetes/core/tailscale-operator/oauth-secret.sops.yaml`:
   ```bash
   # Decrypt, edit, and re-encrypt
   sops kubernetes/core/tailscale-operator/oauth-secret.sops.yaml
   ```
3. Commit and push changes
4. ArgoCD will automatically sync the new secret

### Step 4: Restart the Operator Pod

After fixing the OAuth permissions:
```bash
kubectl rollout restart deployment -n tailscale operator
```

## Verification

```bash
# Check pod is running
kubectl get pods -n tailscale

# Check logs for successful startup
kubectl logs -n tailscale -l app.kubernetes.io/name=tailscale-operator --tail=50

# Operator should show as authenticated in Tailscale admin console
```

## Related Documentation
- Tailscale Kubernetes Operator: https://tailscale.com/kb/1236/kubernetes-operator
- Tailscale OAuth Clients: https://tailscale.com/kb/1215/oauth-clients
- Tailscale ACL Tags: https://tailscale.com/kb/1068/tags

## Notes
- The `operator-oauth` secret is now correctly deployed (Issue 2 resolved)
- This is purely a Tailscale admin console configuration issue
- The tag must be defined in ACLs before the OAuth client can use it
