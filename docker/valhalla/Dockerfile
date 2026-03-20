# Valhalla routing engine with Kenya OpenStreetMap data
# Provides: routing, ETA, distance matrix, isochrones, map matching
# Data source: Geofabrik Kenya extract (~200-300 MB PBF)

FROM ghcr.io/gis-ops/docker-valhalla/valhalla:latest

ENV tile_urls=https://download.geofabrik.de/africa/kenya-latest.osm.pbf
ENV use_tiles_ignore_pbf=True
ENV build_elevation=False
ENV build_admins=True
ENV build_time_zones=True
ENV serve_tiles=True
ENV force_rebuild=False

# Valhalla service config overrides
ENV server_threads=4
ENV default_max_locations=50
ENV default_max_distance=500.0

EXPOSE 8002

# The entrypoint from the base image handles:
# 1. Download PBF if not cached
# 2. Build tiles if not present
# 3. Start valhalla_service
