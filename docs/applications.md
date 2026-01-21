# Application Documentation

This document provides detailed information about each application in the homelab, including configuration, initial setup, and integration between services.

## Table of Contents

- [Application Overview](#application-overview)
- [Media Stack Architecture](#media-stack-architecture)
- [Plex](#plex)
- [Sonarr](#sonarr)
- [Radarr](#radarr)
- [Prowlarr](#prowlarr)
- [qBittorrent](#qbittorrent)
- [Overseerr](#overseerr)
- [Authentik](#authentik)
- [Integration Guide](#integration-guide)

## Application Overview

### Media Stack

| Application | Purpose | Port | Access |
|-------------|---------|------|--------|
| Plex | Media server | 32400 | Public (Tunnel) |
| Sonarr | TV show management | 8989 | Internal |
| Radarr | Movie management | 7878 | Internal |
| Prowlarr | Indexer manager | 9696 | Internal |
| qBittorrent | Torrent client | 8080 | Internal |
| Overseerr | Request management | 5055 | Public (Tunnel) |

### Supporting Services

| Application | Purpose | Port | Access |
|-------------|---------|------|--------|
| Authentik | SSO/Identity | 9000 | Internal |
| ArgoCD | GitOps | 443 | Internal |
| Grafana | Dashboards | 3000 | Internal |
| Prometheus | Metrics | 9090 | Internal |

## Media Stack Architecture

```
+------------------+
|    Overseerr     |  <-- Users request movies/shows
+--------+---------+
         |
         | API calls
         v
+--------+---------+     +------------------+
|     Sonarr       | <-->|     Radarr       |
| (TV Shows)       |     | (Movies)         |
+--------+---------+     +--------+---------+
         |                        |
         +------------+-----------+
                      |
         +------------v-----------+
         |       Prowlarr         |  <-- Manages indexers
         +------------+-----------+
                      |
         +------------v-----------+
         |     qBittorrent        |  <-- Downloads content
         +------------+-----------+
                      |
         +------------v-----------+
         |     NFS Storage        |  <-- /media (shared)
         +------------+-----------+
                      |
         +------------v-----------+
         |        Plex            |  <-- Serves media
         +------------------------+
```

### Data Flow

1. **Request**: User requests content via Overseerr
2. **Search**: Sonarr/Radarr queries Prowlarr for indexers
3. **Download**: qBittorrent downloads to `/media/downloads`
4. **Import**: Sonarr/Radarr hardlinks to `/media/tv` or `/media/movies`
5. **Serve**: Plex detects new content and serves to users

## Plex

### Overview

Plex Media Server organizes and streams media to various devices.

**Access**:
- Public: https://plex.lorenzodebie.be
- Direct: http://192.168.30.62:32400

### Configuration

```yaml
# Key environment variables
env:
  TZ: Europe/Brussels
  PLEX_ADVERTISE_URL: https://plex.lorenzodebie.be:443
  PLEX_NO_AUTH_NETWORKS: 192.168.0.0/16  # Skip auth for local
```

### Initial Setup

1. Access Plex at http://192.168.30.62:32400/web
2. Sign in with your Plex account
3. Name your server
4. Add libraries:
   - **Movies**: `/media/movies`
   - **TV Shows**: `/media/tv`
5. Configure remote access (optional, Tunnel handles this)

### Storage Paths

| Path | Purpose | Mode |
|------|---------|------|
| /config | Plex database and settings | RW |
| /media | Media library | RO |
| /transcode | Temporary transcoding | EmptyDir |

### Plex Pass Features

If you have Plex Pass:
- Enable Hardware Transcoding
- Enable Skip Intro
- Configure Tidal/Live TV if desired

### Verify Setup

```bash
# Check pod status
kubectl get pods -n media -l app.kubernetes.io/name=plex

# Check logs
kubectl logs -n media -l app.kubernetes.io/name=plex

# Check LoadBalancer IP
kubectl get svc -n media plex
```

## Sonarr

### Overview

Sonarr automates TV show downloading and organization.

**Access**: https://sonarr.int.lorenzodebie.be

### Configuration

```yaml
env:
  TZ: Europe/Brussels
  SONARR__AUTH__METHOD: External           # For SSO
  SONARR__AUTH__REQUIRED: DisabledForLocalAddresses
```

### Initial Setup

1. Access Sonarr at https://sonarr.int.lorenzodebie.be
2. Go to Settings > Media Management:
   - Enable "Rename Episodes"
   - Set root folder: `/media/tv`
   - Enable hardlinks
3. Go to Settings > Download Clients:
   - Add qBittorrent
   - Host: `qbittorrent.media.svc.cluster.local`
   - Port: `8080`
   - Category: `tv`
4. Go to Settings > Indexers:
   - Add indexers via Prowlarr sync

### Root Folder Configuration

```
Name: TV Shows
Path: /media/tv
```

### Download Client Settings

```
Name: qBittorrent
Host: qbittorrent.media.svc.cluster.local
Port: 8080
Category: tv
Remove Completed: Yes (after seeding)
```

### API Key

Find API key: Settings > General > Security > API Key

You'll need this for:
- Prowlarr integration
- Overseerr integration

## Radarr

### Overview

Radarr automates movie downloading and organization.

**Access**: https://radarr.int.lorenzodebie.be

### Initial Setup

1. Access Radarr at https://radarr.int.lorenzodebie.be
2. Go to Settings > Media Management:
   - Enable "Rename Movies"
   - Set root folder: `/media/movies`
   - Enable hardlinks
3. Go to Settings > Download Clients:
   - Add qBittorrent (same as Sonarr)
   - Category: `movies`
4. Go to Settings > Indexers:
   - Add indexers via Prowlarr sync

### Root Folder Configuration

```
Name: Movies
Path: /media/movies
```

### Quality Profiles

Recommended profile modifications:
- Create "1080p" profile for most content
- Create "4K" profile for high-quality releases
- Adjust size limits based on your storage

## Prowlarr

### Overview

Prowlarr manages indexers and syncs them to Sonarr/Radarr.

**Access**: https://prowlarr.int.lorenzodebie.be

### Initial Setup

1. Access Prowlarr at https://prowlarr.int.lorenzodebie.be
2. Add indexers:
   - Click "Add Indexer"
   - Search for your preferred indexers
   - Configure credentials for private trackers
3. Configure apps (Sonarr/Radarr):
   - Go to Settings > Apps
   - Add Sonarr:
     - Name: Sonarr
     - Sync Level: Full Sync
     - Prowlarr Server: `http://prowlarr.media.svc.cluster.local:9696`
     - Sonarr Server: `http://sonarr.media.svc.cluster.local:8989`
     - API Key: (from Sonarr)
   - Add Radarr similarly

### Indexer Categories

Prowlarr auto-maps categories, but verify:
- TV indexers map to Sonarr
- Movie indexers map to Radarr

### Sync Status

After configuration, Prowlarr automatically pushes indexers to Sonarr/Radarr. Check Settings > Indexers in each app.

## qBittorrent

### Overview

qBittorrent handles torrent downloading.

**Access**: https://qbittorrent.int.lorenzodebie.be

### Configuration

The BitTorrent port is exposed via LoadBalancer for incoming connections:
- Web UI: Port 8080 (via Gateway)
- BitTorrent: Port 6881 (via LoadBalancer 192.168.30.63)

### Initial Setup

1. Access qBittorrent at https://qbittorrent.int.lorenzodebie.be
2. Default credentials: admin/adminadmin (change immediately!)
3. Go to Options (gear icon):

**Downloads**:
```
Default Save Path: /media/downloads/complete
Keep incomplete torrents in: /media/downloads/incomplete
```

**Connection**:
```
Listening Port: 6881
Enable UPnP: No (we use static port)
```

**BitTorrent**:
```
Enable DHT: Yes
Enable PeX: Yes
Enable Local Peer Discovery: Yes
```

**Web UI**:
```
Enable Web UI: Yes
IP Address: 0.0.0.0
Port: 8080
Authentication: Required (set strong password)
```

### Categories

Create categories for organization:
- `tv` - Sonarr downloads
- `movies` - Radarr downloads
- `manual` - Manual downloads

### Router Port Forwarding

For best speeds, forward port 6881 to 192.168.30.63:
```
External Port: 6881
Internal IP: 192.168.30.63
Internal Port: 6881
Protocol: TCP + UDP
```

## Overseerr

### Overview

Overseerr provides a user-friendly interface for requesting media.

**Access**: https://requests.lorenzodebie.be

### Initial Setup

1. Access Overseerr at https://requests.lorenzodebie.be
2. Sign in with Plex account
3. Configure Plex:
   - Server: `http://plex.media.svc.cluster.local:32400`
   - Get libraries from Plex
4. Configure Radarr:
   - Hostname: `radarr.media.svc.cluster.local`
   - Port: `7878`
   - API Key: (from Radarr)
   - Quality Profile: Select default
   - Root Folder: `/media/movies`
5. Configure Sonarr:
   - Hostname: `sonarr.media.svc.cluster.local`
   - Port: `8989`
   - API Key: (from Sonarr)
   - Quality Profile: Select default
   - Root Folder: `/media/tv`

### User Management

- Plex users are automatically imported
- Configure permissions per user
- Set request limits if desired

### Notifications

Configure notifications in Settings > Notifications:
- Discord webhook
- Email
- Telegram
- And more

## Authentik

### Overview

Authentik provides SSO (Single Sign-On) and identity management.

**Access**: https://auth.int.lorenzodebie.be

### Initial Setup

1. Access Authentik at https://auth.int.lorenzodebie.be
2. Login with bootstrap credentials:
   - Email: (from secrets)
   - Password: (from secrets)
3. Complete initial wizard
4. Change admin password

### SSO Integration

To protect an application with Authentik:

1. Create Application in Authentik:
   - Admin Interface > Applications > Create
   - Name: e.g., "Grafana"
   - Slug: e.g., "grafana"
   - Provider: Create new OAuth2/OpenID Provider

2. Create Provider:
   - Name: e.g., "Grafana OAuth"
   - Authorization flow: default-provider-authorization-explicit-consent
   - Client ID: (auto-generated, save this)
   - Client Secret: (generate and save)
   - Redirect URIs: `https://grafana.int.lorenzodebie.be/login/generic_oauth`

3. Configure Application:
   - In Grafana, configure OAuth:
   ```ini
   [auth.generic_oauth]
   enabled = true
   name = Authentik
   client_id = <client-id>
   client_secret = <client-secret>
   auth_url = https://auth.int.lorenzodebie.be/application/o/authorize/
   token_url = https://auth.int.lorenzodebie.be/application/o/token/
   api_url = https://auth.int.lorenzodebie.be/application/o/userinfo/
   ```

### Forward Auth (Proxy Provider)

For apps without native SSO:

1. Create Proxy Provider in Authentik
2. Add ForwardAuth middleware to HTTPRoute
3. Authentik intercepts unauthenticated requests

## Integration Guide

### Complete Integration Diagram

```
+----------------+
| Prowlarr       |
| (Indexers)     |
+-------+--------+
        |
        | Sync indexers
        v
+-------+--------+     +----------------+
| Sonarr         |<--->| Radarr         |
| API: 8989      |     | API: 7878      |
+-------+--------+     +-------+--------+
        |                      |
        | Send to download     |
        v                      v
+-------+------------------------+
| qBittorrent                    |
| API: 8080                      |
| BT: 6881                       |
+-------+------------------------+
        |
        | Download complete
        v
+-------+--------+     +----------------+
| /media/downloads|---->| Hardlink to:   |
|                |     | /media/tv      |
|                |     | /media/movies  |
+----------------+     +-------+--------+
                              |
                              v
                       +------+-------+
                       | Plex         |
                       | Scans library|
                       +--------------+
```

### Service Discovery

All services communicate via Kubernetes DNS:

| Service | Internal URL |
|---------|--------------|
| Plex | `http://plex.media.svc.cluster.local:32400` |
| Sonarr | `http://sonarr.media.svc.cluster.local:8989` |
| Radarr | `http://radarr.media.svc.cluster.local:7878` |
| Prowlarr | `http://prowlarr.media.svc.cluster.local:9696` |
| qBittorrent | `http://qbittorrent.media.svc.cluster.local:8080` |
| Overseerr | `http://overseerr.media.svc.cluster.local:5055` |

### API Keys Reference

| Application | Location |
|-------------|----------|
| Sonarr | Settings > General > API Key |
| Radarr | Settings > General > API Key |
| Prowlarr | Settings > General > API Key |
| Plex | Settings > Network > Plex Token (or via API) |

### Testing Integration

**Test Sonarr -> qBittorrent**:
1. Go to Sonarr > System > Tasks > Test All
2. Check qBittorrent shows green

**Test Prowlarr -> Sonarr/Radarr**:
1. Go to Prowlarr > Settings > Apps > Test All
2. Verify indexers appear in Sonarr/Radarr

**Test full flow**:
1. Search for a show in Sonarr
2. Add and search for releases
3. Verify download starts in qBittorrent
4. After completion, verify Plex library updates

## Application Customization

### Adding New Media Application

1. Create application directory:
```
kubernetes/apps/media/newapp/
├── application.yaml
└── httproute.yaml
```

2. Define ArgoCD Application:
```yaml
# application.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: newapp
  namespace: argocd
spec:
  source:
    repoURL: https://bjw-s.github.io/helm-charts
    chart: app-template
    # ...
```

3. Create HTTPRoute for Gateway access:
```yaml
# httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: newapp
  namespace: media
spec:
  parentRefs:
    - name: internal-gateway
      namespace: kube-system
  hostnames:
    - newapp.int.lorenzodebie.be
  rules:
    - backendRefs:
        - name: newapp
          port: 8080
```

4. Add DNS record to Pi-hole

### Resource Recommendations

| Application | CPU Request | Memory Request | Memory Limit |
|-------------|-------------|----------------|--------------|
| Plex | 100m | 1Gi | 8Gi |
| Sonarr | 50m | 256Mi | 1Gi |
| Radarr | 50m | 256Mi | 1Gi |
| Prowlarr | 50m | 128Mi | 512Mi |
| qBittorrent | 100m | 256Mi | 1Gi |
| Overseerr | 50m | 128Mi | 512Mi |
