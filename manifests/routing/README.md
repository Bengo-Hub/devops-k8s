# Map and Routing Infrastructure

Self-hosted OpenStreetMap stack for the logistics platform: vector tiles from TileServer-GL and routing from Valhalla, both built from the free Geofabrik Kenya extract.

```
Geofabrik kenya-latest.osm.pbf (updated daily)
    │
    ├─→ planetiler-tile-refresh (weekly) ──→ kenya.mbtiles ──→ tileserver ──→ tiles.codevertexafrica.com
    │
    └─→ valhalla-data-refresh   (weekly) ──→ valhalla_tiles.tar ──→ valhalla ──→ routing.codevertexafrica.com
```

## Where things are defined

| What | Source | Managed by |
|------|--------|------------|
| tileserver Deployment, Service, Ingress, volume `tileserver-media` | `apps/tileserver/values.yaml` (chart `charts/app`) | Application `tileserver` |
| valhalla Deployment, Service, Ingress, volume `valhalla-media` | `apps/valhalla/values.yaml` (chart `charts/app`) | Application `valhalla` |
| `tileserver-config.yaml`, `planetiler-cronjob.yaml`, `valhalla-cronjob.yaml`, `map-refresh-rbac.yaml` | this directory | Application `map-data-refresh` |

The kustomize Deployment, Service and PVC files that used to live here, and `scripts/deploy-routing.sh` which applied them, were removed on 2026-11-07: they duplicated the chart apps, and running them would have overwritten the live services.

## Weekly data refresh

Both jobs run Sunday night (EAT) and follow the same pattern, every step tested against prod on 2026-11-07:

1. Build the new data away from the live files (a scratch or staging directory on the same volume).
2. If upstream has not changed since the live data was built, discard the build. No restart, no outage.
3. Otherwise swap the new data in, restart the server, and verify the server reports the new version (a tile and a route must also work). On failure the previous files are restored and the server restarted, and the Job fails.
4. Delete the previous version and the build directory, so nothing old is left behind.

| Job | Schedule | Built from | Version check |
|-----|----------|------------|---------------|
| `valhalla-data-refresh` | Sunday 20:00 UTC (23:00 EAT) | Latest Geofabrik extract, built with the live valhalla image in `staging/` | `tileset_last_modified` in `/status?verbose=true` moves forward; marker `.tiles-source.sha256` records the extract the live tiles came from |
| `planetiler-tile-refresh` | Sunday 20:15 UTC (23:15 EAT) | Sources refreshed in place in `/data/sources` (ETag check), built in `/data/tiles-build` | `planetiler:osm:osmosisreplicationseq` in `/data/v3.json` must equal the new archive's |

Why it is built this way:

- planetiler `--download` only downloads **missing** sources. `--refresh_osm` and friends are what fetch a newer version. Without them the April 2026 extract would have been reused forever.
- docker-valhalla's `file_hashes.txt` hashes the download URL, not the data, so valhalla never rebuilds on its own when a new extract arrives. Its tiles also live in `valhalla_tiles.tar`, so deleting a `valhalla_tiles` directory does nothing.
- The water polygons host (osmdata.openstreetmap.de) is sometimes unreachable. The planetiler job probes it first and keeps the cached copy rather than failing.
- All map images are pinned by digest (`image.digest` in `apps/valhalla` and `apps/tileserver`, and in the two CronJobs). planetiler `:latest` is a moving main-branch snapshot. To upgrade valhalla, change the digest in `apps/valhalla/values.yaml` and `valhalla-cronjob.yaml` together: its tiles are built by that image.

### Checking freshness

```bash
# OSM sequence and time the served tiles were built from
curl -s https://tiles.codevertexafrica.com/data/v3.json | jq '."planetiler:osm:osmosisreplicationseq", ."planetiler:osm:osmosisreplicationtime"'
# Current upstream sequence
curl -s https://download.geofabrik.de/africa/kenya-updates/state.txt
# Routing tiles build time (unix seconds)
curl -s 'https://routing.codevertexafrica.com/status?verbose=true' | jq .tileset_last_modified
```

### Running a refresh by hand

```bash
kubectl -n logistics create job --from=cronjob/valhalla-data-refresh valhalla-refresh-manual-$(date +%s)
kubectl -n logistics create job --from=cronjob/planetiler-tile-refresh tiles-refresh-manual-$(date +%s)
```

Run these off peak: a swap restarts the server (both use Recreate), so tiles or routing are briefly unavailable.

Last proven run (2026-11-08 00:12-00:32 UTC, both started this way before their first scheduled Sunday run): valhalla found a newer extract, built 927 tiles in about 4 minutes and was serving them about 7 minutes after the start; planetiler moved OSM sequence 4398 to 4399 in about 5 minutes. Each restart took under a minute, and only the current extract and archive were left on the volumes.

## Tile API

Base URL: `https://tiles.codevertexafrica.com`, internal `http://tileserver.logistics.svc.cluster.local:8080`

| Endpoint | Format | Usage |
|----------|--------|-------|
| `/styles/osm-bright/style.json` | Style JSON | MapLibre style URL |
| `/data/v3/{z}/{x}/{y}.pbf` | Vector tiles | MapLibre GL JS |
| `/data/v3.json` | TileJSON | Metadata, including the OSM sequence |
| `/styles/osm-bright/{z}/{x}/{y}.png` | Raster tiles | Fallback / `<img>` |
| `/health` | JSON | Health check |

### MapLibre integration

```tsx
import { MapProvider, MapContainer } from '@bengo-hub/maps';

<MapProvider
  tileServerUrl="https://tiles.codevertexafrica.com"
  apiBaseUrl="https://logisticsapi.codevertexafrica.com/api/v1"
  authToken={jwt}
>
  <MapContainer center={[36.82, -1.29]} zoom={13} />
</MapProvider>
```

## Valhalla API

Base URL: `https://routing.codevertexafrica.com`, internal `http://valhalla.logistics.svc.cluster.local:8002`

| Endpoint | Purpose |
|----------|---------|
| `POST /route` | Turn-by-turn routing |
| `POST /sources_to_targets` | Distance/time matrix |
| `POST /isochrone` | Reachability polygon |
| `POST /locate` | Snap to road |
| `POST /optimized_route` | Multi-stop optimization |
| `GET /status?verbose=true` | Health, version, tileset build time |

Costing modes: `auto`, `bicycle`, `pedestrian`, `motor_scooter`, `motorcycle`.

## Adding countries

1. `planetiler-cronjob.yaml`: change `--area=kenya` (planetiler accepts one Geofabrik area per run, so several countries need a combined extract via `--osm_url`).
2. `valhalla-cronjob.yaml`: add the extra extract URLs to `tile_urls` (space separated), and the same in `apps/valhalla/values.yaml`.
3. Raise the volume sizes and memory limits roughly in line with the extract sizes.
