# Map & Routing Infrastructure

Self-hosted OpenStreetMap stack for the logistics platform. Replaces paid Google Maps APIs with free, open-source alternatives — zero per-request costs at any scale.

## Architecture

```
Geofabrik (free OSM data)
    │
    ├─→ Planetiler ──→ kenya.mbtiles ──→ TileServer-GL ──→ tiles.codevertexitsolutions.com
    │   (weekly CronJob)                  (vector tiles)     (MapLibre GL JS frontends)
    │
    └─→ Valhalla ──→ routing graph ──→ logistics-api ──→ routing.codevertexitsolutions.com
        (auto-rebuild)                  (ETA, directions)    (tenant-scoped, rate-limited)
```

## Components

| Service | Purpose | Port | Domain |
|---------|---------|------|--------|
| **TileServer-GL** | Vector tile server for MapLibre frontends | 8080 | `tiles.codevertexitsolutions.com` |
| **Planetiler** | Generates OpenMapTiles mbtiles from OSM data | — | CronJob (weekly) |
| **Valhalla** | Routing engine (ETA, distance matrix, isochrones) | 8002 | `routing.codevertexitsolutions.com` |

## Data Pipeline

Both tile and routing data come from **Geofabrik Kenya OSM extract** (free, updated daily):

| Job | Schedule | Source | Output |
|-----|----------|--------|--------|
| `planetiler-tile-refresh` | Monday 3 AM UTC | `geofabrik.de/africa/kenya-latest.osm.pbf` | `/data/tiles/kenya.mbtiles` (~200MB) |
| `valhalla-data-refresh` | Monday 2 AM UTC | `geofabrik.de/africa/kenya-latest.osm.pbf` | Valhalla routing graph (~300MB) |

## Manifests

```
manifests/routing/
├── kustomization.yaml
├── README.md
├── tileserver-pvc.yaml          # 5Gi PVC for mbtiles data
├── tileserver-config.yaml       # TileServer-GL config (osm-bright style)
├── tileserver-deployment.yaml   # TileServer-GL + Planetiler init container
├── tileserver-service.yaml      # Service + Ingress (tiles.codevertexitsolutions.com)
├── planetiler-cronjob.yaml      # Weekly tile regeneration
├── valhalla-pvc.yaml            # 10Gi PVC for routing data
├── valhalla-deployment.yaml     # Valhalla routing engine
├── valhalla-service.yaml        # Service + Ingress (routing.codevertexitsolutions.com)
└── valhalla-cronjob.yaml        # Weekly OSM data refresh
```

## First Deployment

On first deployment, the tileserver init container runs Planetiler to generate Kenya tiles (~5-10 min). Subsequent restarts skip this if tiles exist.

```bash
# Apply all manifests
kubectl apply -k manifests/routing/

# Watch tile generation progress on first run
kubectl logs -f deployment/tileserver -n logistics -c init-tiles
```

## Operations

### Manual tile refresh

```bash
# Trigger Planetiler to regenerate tiles
kubectl create job --from=cronjob/planetiler-tile-refresh tiles-manual -n logistics

# After completion, restart tileserver to load new tiles
kubectl rollout restart deployment/tileserver -n logistics
```

### Manual Valhalla data refresh

```bash
kubectl create job --from=cronjob/valhalla-data-refresh valhalla-manual -n logistics
kubectl rollout restart deployment/valhalla -n logistics
```

### Check status

```bash
kubectl get pods -n logistics -l part-of=map-services
kubectl get cronjobs -n logistics
```

## Tile API

Base URL: `https://tiles.codevertexitsolutions.com`
Internal: `http://tileserver.logistics.svc.cluster.local:8080`

| Endpoint | Format | Usage |
|----------|--------|-------|
| `/styles/osm-bright/style.json` | Style JSON | MapLibre style URL |
| `/data/v3/{z}/{x}/{y}.pbf` | Vector tiles | MapLibre GL JS |
| `/styles/osm-bright/{z}/{x}/{y}.png` | Raster tiles | Fallback / `<img>` |
| `/health` | JSON | Health check |

### MapLibre Integration

```tsx
import { MapProvider, MapContainer } from '@bengo-hub/maps';

<MapProvider
  tileServerUrl="https://tiles.codevertexitsolutions.com"
  apiBaseUrl="https://logisticsapi.codevertexitsolutions.com/api/v1"
  authToken={jwt}
>
  <MapContainer center={[36.82, -1.29]} zoom={13} />
</MapProvider>
```

## Valhalla API

Base URL: `https://routing.codevertexitsolutions.com`
Internal: `http://valhalla.logistics.svc.cluster.local:8002`

| Endpoint | Purpose |
|----------|---------|
| `GET /route?json={...}` | Turn-by-turn routing |
| `GET /sources_to_targets?json={...}` | Distance/time matrix |
| `GET /isochrone?json={...}` | Reachability polygon |
| `GET /locate?json={...}` | Snap to road |
| `POST /optimized_route` | Multi-stop optimization (TSP) |
| `GET /status` | Health / version check |

**Costing modes:** `auto`, `bicycle`, `pedestrian`, `motor_scooter`, `motorcycle`

## Adding Countries

1. Update `planetiler-cronjob.yaml` — change `--area=kenya` to `--area=kenya,uganda`
2. Update `valhalla-deployment.yaml` — add PBF URLs to `tile_urls`
3. Increase PVC sizes and memory limits proportionally (~1-2GB per country)

## Resource Requirements

| Component | CPU Req | Mem Req | Mem Limit | Disk |
|-----------|---------|---------|-----------|------|
| TileServer | 250m | 512Mi | 1Gi | 5Gi (tiles) |
| Planetiler (Job) | 1 | 3Gi | 6Gi | shared PVC |
| Valhalla | 1 | 3Gi | 5Gi | 10Gi |
