# TileServer GL - Vector tile server for MapLibre GL JS frontends
# Serves OpenStreetMap vector tiles for Kenya region
# Data source: OpenMapTiles (pre-built mbtiles) or Planetiler

FROM maptiler/tileserver-gl:latest

# Copy custom config
COPY config.json /data/config.json

EXPOSE 8080

# The entrypoint starts tileserver-gl with /data as the working directory
# On first run, download Kenya mbtiles via init script
COPY entrypoint.sh /custom-entrypoint.sh
USER root
RUN chmod +x /custom-entrypoint.sh
USER node

ENTRYPOINT ["/custom-entrypoint.sh"]
