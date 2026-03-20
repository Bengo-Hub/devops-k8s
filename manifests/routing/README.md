# Map Routing Infrastructure

Self-hosted OpenStreetMap routing stack for the logistics platform. Replaces paid Google Maps APIs with free, open-source alternatives.

## Components

| Service | Purpose | Port | Subdomain | Managed By |
|---------|---------|------|-----------|------------|
| **Valhalla** | Routing engine (ETA, distance matrix, isochrones, map matching) | 8002 | `routing.codevertexitsolutions.com` | ArgoCD (`apps/valhalla/`) |
| **TileServer-GL** | Vector map tile server for MapLibre frontends | 8080 | `tiles.codevertexitsolutions.com` | ArgoCD (`apps/tileserver/`) |

## Data Source

- **OpenStreetMap Kenya extract** from [Geofabrik](https://download.geofabrik.de/africa/kenya.html)
- Auto-refreshed weekly (Monday 2AM UTC) via CronJob `valhalla-data-refresh`
- Kenya PBF: ~326 MB, expands to ~2-3 GB Valhalla tiles

## Deployment (ArgoCD)

Both services are managed via ArgoCD with auto-sync, selfHeal, and prune enabled. **Do not deploy manually** — changes to `apps/valhalla/values.yaml` or `apps/tileserver/values.yaml` trigger automatic sync.

```bash
# Check sync status
kubectl get applications -n argocd valhalla tileserver

# Force refresh (if stuck)
kubectl patch application valhalla -n argocd --type=merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

## Resource Requirements

| Component | CPU Request | Memory Request | Memory Limit | Disk | HPA | VPA |
|-----------|-----------|---------------|-------------|------|-----|-----|
| Valhalla | 1 core | 3Gi | 5Gi | 10Gi | 1 replica (PVC) | Recommendation mode |
| TileServer | 250m | 512Mi | 1Gi | 5Gi | Up to 2 replicas | Recommendation mode |

## Valhalla API Reference

Base URL: `https://routing.codevertexitsolutions.com` (external) or `http://valhalla.logistics.svc.cluster.local:8002` (internal)

### Status / Health Check

```
GET /status
```

Returns version, available actions, and tileset timestamp.

### Route

```
GET /route?json={"locations":[{"lat":-1.2864,"lon":36.8172},{"lat":-1.2635,"lon":36.8028}],"costing":"auto"}
```

**Costing modes:** `auto`, `bicycle`, `pedestrian`, `motor_scooter`, `motorcycle`

Response includes: `trip.legs[].shape` (encoded polyline), `trip.summary.length` (km), `trip.summary.time` (seconds).

### Distance Matrix (Sources to Targets)

```
GET /sources_to_targets?json={"sources":[{"lat":-1.2864,"lon":36.8172}],"targets":[{"lat":-1.2635,"lon":36.8028},{"lat":-1.2921,"lon":36.8219}],"costing":"auto"}
```

Returns N×M matrix of `distance` (km) and `time` (seconds).

### Isochrone (Reachability)

```
GET /isochrone?json={"locations":[{"lat":-1.2864,"lon":36.8172}],"costing":"auto","contours":[{"time":15}]}
```

Returns GeoJSON polygon of area reachable within `time` minutes.

### Locate (Map Matching)

```
GET /locate?json={"locations":[{"lat":-1.2864,"lon":36.8172}],"costing":"auto"}
```

Snaps coordinates to nearest road network.

### Trace Route (GPS Track Matching)

```
POST /trace_route
{"shape":[{"lat":-1.2864,"lon":36.8172},...],"costing":"auto","shape_match":"map_snap"}
```

Matches GPS traces to road network for accurate route reconstruction.

### Optimized Route (TSP)

```
POST /optimized_route
{"locations":[{"lat":-1.2864,"lon":36.8172},{"lat":-1.2635,"lon":36.8028},...],"costing":"auto"}
```

Solves the Travelling Salesman Problem for multiple delivery stops.

### Height (Elevation)

```
GET /height?json={"shape":[{"lat":-1.2864,"lon":36.8172}],"range":true}
```

Returns elevation data for coordinates.

## TileServer API Reference

Base URL: `https://tiles.codevertexitsolutions.com` (external) or `http://tileserver.logistics.svc.cluster.local:8080` (internal)

### Tile Endpoints

| Endpoint | Format | Usage |
|----------|--------|-------|
| `/{style}/{z}/{x}/{y}.png` | Raster tiles | `<img>` tags, Leaflet |
| `/data/{source}/{z}/{x}/{y}.pbf` | Vector tiles | MapLibre GL JS |
| `/styles/{style}/style.json` | Style JSON | MapLibre style URL |
| `/` | Viewer | Browser tile preview |

### MapLibre Integration

```javascript
import { BengoMap } from '@bengo-hub/maps';

<BengoMap
  tileServerUrl="https://tiles.codevertexitsolutions.com"
  routingApiUrl="https://logisticsapi.codevertexitsolutions.com/api/v1/{tenant}/routing"
/>
```

## Logistics-API Integration

The logistics-api wraps Valhalla with caching, rate limiting, and tenant scoping:

| Logistics-API Endpoint | Valhalla Endpoint | Description |
|----------------------|-------------------|-------------|
| `GET /{tenant}/routing/route` | `/route` | Route with ETA + distance |
| `GET /{tenant}/routing/eta` | `/route` | ETA only (minutes) |
| `POST /{tenant}/routing/matrix` | `/sources_to_targets` | Distance/duration matrix |
| `GET /{tenant}/routing/isochrone` | `/isochrone` | Reachability polygon |
| `GET /{tenant}/routing/health` | `/status` | Provider health check |
| `GET /api/v1/track/{code}` | — | Public tracking (no auth) |

**Rate limits** per tenant plan (see `subscriptions-api` tier limits):
- `routing_requests_per_day`: 100 (Starter) / 1000 (Growth) / 10000 (Professional)
- `live_tracking_requests_per_day`: 500 / 5000 / unlimited
- `map_loads_per_day`: 200 / 2000 / unlimited

## Internal Access (from cluster services)

```
Valhalla:    http://valhalla.logistics.svc.cluster.local:8002
TileServer:  http://tileserver.logistics.svc.cluster.local:8080
```

## Data Refresh

The `valhalla-data-refresh` CronJob downloads fresh Kenya OSM data weekly (Monday 2AM UTC). After download, the Valhalla pod must be restarted to rebuild tiles:

```bash
# Check CronJob status
kubectl get cronjobs -n logistics

# Manual trigger
kubectl create job --from=cronjob/valhalla-data-refresh valhalla-refresh-manual -n logistics

# Restart Valhalla to rebuild tiles after data refresh
kubectl rollout restart deployment/valhalla -n logistics
```

## Adding More Countries

Edit `apps/valhalla/values.yaml` env `tile_urls` to add comma-separated PBF URLs:

```yaml
env:
  - name: tile_urls
    value: "https://download.geofabrik.de/africa/kenya-latest.osm.pbf,https://download.geofabrik.de/africa/uganda-latest.osm.pbf"
```

Increase memory limits proportionally (~1-2GB per country).

## PostgreSQL Extensions

The shared PostgreSQL cluster (`infra/postgresql`) includes:
- **PostGIS 3.6.2** — Geospatial queries (delivery zones, proximity search)
- **pgvector 0.7.4** — Vector similarity search (address embeddings)

Enabled on `postgres` and `logistics` databases. Use `CREATE EXTENSION IF NOT EXISTS postgis;` on new databases.
