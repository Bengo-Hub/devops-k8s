#!/bin/sh
set -e

MBTILES_FILE="/data/kenya.mbtiles"

# Download Kenya mbtiles if not present
if [ ! -f "$MBTILES_FILE" ]; then
  echo "Downloading Kenya OpenMapTiles data..."
  # OpenMapTiles provides free country-level extracts
  # Alternative: use Planetiler to generate from PBF
  wget -q -O "$MBTILES_FILE" \
    "https://data.source.coop/protomaps/openstreetmap/tiles/v4/kenya.pmtiles" \
    2>/dev/null || true

  # Fallback: if pmtiles download fails, try mbtiles from another source
  if [ ! -f "$MBTILES_FILE" ] || [ ! -s "$MBTILES_FILE" ]; then
    echo "Primary download failed, using Protomaps extract..."
    rm -f "$MBTILES_FILE"
    # Note: In production, pre-build mbtiles using Planetiler and bake into image
    echo "ERROR: No tile data available. Mount mbtiles at /data/kenya.mbtiles"
    echo "Generate with: java -jar planetiler.jar --area=kenya --output=/data/kenya.mbtiles"
    exit 1
  fi
fi

echo "Starting TileServer GL..."
exec node /usr/src/app/ --config /data/config.json --port 8080 --verbose
