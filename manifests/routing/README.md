# Map Routing Infrastructure

Self-hosted OpenStreetMap routing stack for the logistics platform. Replaces paid Google Maps APIs with free, open-source alternatives.

## Components

| Service | Purpose | Port | Subdomain |
|---------|---------|------|-----------|
| **Valhalla** | Routing engine (ETA, distance matrix, isochrones) | 8002 | `routing.codevertexitsolutions.com` |
| **TileServer-GL** | Vector map tile server for MapLibre frontends | 8080 | `tiles.codevertexitsolutions.com` |

## Data Source

- **OpenStreetMap Kenya extract** from [Geofabrik](https://download.geofabrik.de/africa/kenya.html)
- Auto-refreshed weekly (Monday 2AM UTC) via CronJob
- Kenya PBF: ~200-300 MB, expands to ~2-3 GB Valhalla tiles

## Resource Requirements

| Component | CPU Request | Memory Request | Memory Limit | Disk |
|-----------|-----------|---------------|-------------|------|
| Valhalla | 1 core | 3Gi | 5Gi | 10Gi |
| TileServer | 250m | 512Mi | 1Gi | 5Gi |

## Deploy

```bash
# Apply all routing manifests
kubectl apply -k manifests/routing/

# Verify
kubectl get pods -n logistics -l part-of=map-services
kubectl logs -n logistics deploy/valhalla --tail=50
```

## Test Routing

```bash
# Health check
curl https://routing.codevertexitsolutions.com/status

# Route: Nairobi CBD to Westlands
curl "https://routing.codevertexitsolutions.com/route?json={\"locations\":[{\"lat\":-1.2864,\"lon\":36.8172},{\"lat\":-1.2635,\"lon\":36.8028}],\"costing\":\"auto\"}"

# Isochrone: 15-minute drive from Nairobi CBD
curl "https://routing.codevertexitsolutions.com/isochrone?json={\"locations\":[{\"lat\":-1.2864,\"lon\":36.8172}],\"costing\":\"auto\",\"contours\":[{\"time\":15}]}"
```

## Internal Access (from logistics-api)

```
http://valhalla.logistics.svc.cluster.local:8002
http://tileserver.logistics.svc.cluster.local:8080
```

## Data Refresh

The `valhalla-data-refresh` CronJob downloads fresh Kenya OSM data weekly. After download, restart the Valhalla pod to rebuild tiles:

```bash
kubectl rollout restart deployment/valhalla -n logistics
```

## Adding More Countries

Edit `valhalla-deployment.yaml` env `tile_urls` to add comma-separated PBF URLs:
```yaml
- name: tile_urls
  value: "https://download.geofabrik.de/africa/kenya-latest.osm.pbf,https://download.geofabrik.de/africa/uganda-latest.osm.pbf"
```

Increase memory limits proportionally (~1-2GB per country).
