#!/bin/bash
#
# Generate a single-band uint32 cell-id COG in standard -180..180° longitude.
#
# Source: multi-band Bio-Oracle/planarea raster (band 1 = cell_id as float32/NaN,
#         longitudes in 0-360° convention, extent 141.1-296.25° E).
# Target: single-band uint32 COG in -180..180°, nodata=0, no overviews
#         (nearest-neighbor resampling at native resolution is fine for z ≤ 4
#         over a 3103×2006 source; overviews would interpolate integer cell_ids
#         into bogus values).
#
# Run this one-time setup step before launching the TiTiler msens factory,
# and re-run whenever the source COG regenerates.
#
# Requires: gdal >= 3.1 (for -of COG), gdal_calc.py on PATH (numpy-enabled GDAL).
#
# Usage:
#   bash make_cellid_cog.sh [SRC] [DST]
#
# Or from host (without entering the container):
#   docker compose exec titiler bash /opt/msens/scripts/make_cellid_cog.sh
#
set -euo pipefail

SRC="${1:-/share/data/derived/r_bio-oracle_planarea.tif}"
DST="${2:-/share/data/derived/r_cellid.tif}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "src: $SRC"
echo "dst: $DST"
echo "tmp: $TMP"
echo

# 1) extract band 1 (cell_id as float32 with NaN nodata)
echo "== 1/4 extracting band 1 ..."
gdal_translate -q -b 1 -of GTiff -ot Float32 \
  "$SRC" "$TMP/b1_f32.tif"

# 2) cast NaN → 0 and Float32 → UInt32
echo "== 2/4 casting NaN → 0, Float32 → UInt32 ..."
gdal_calc.py --quiet \
  -A "$TMP/b1_f32.tif" \
  --outfile="$TMP/b1_u32.tif" \
  --calc="where(isnan(A), 0, A).astype('uint32')" \
  --type=UInt32 \
  --NoDataValue=0 \
  --overwrite

# 3) warp from 0-360° → -180..180° with antimeridian split,
#    keeping native pixel size (0.05°), nearest neighbor
echo "== 3/4 warping to -180..180 (antimeridian split, nearest-neighbor) ..."
gdalwarp -q \
  -t_srs EPSG:4326 \
  -te -180 -17.7 180 82.6 \
  -tr 0.05 0.05 \
  -r near \
  -wrapdateline \
  -wo SOURCE_EXTRA=20 \
  -of GTiff \
  -co COMPRESS=LZW \
  -co TILED=YES \
  -co BIGTIFF=IF_SAFER \
  -dstnodata 0 \
  "$TMP/b1_u32.tif" "$TMP/wgs84.tif"

# 4) write as COG (no overviews — nearest on native is fast enough, and
#    any interpolating overview would corrupt integer cell_ids)
echo "== 4/4 writing COG ..."
gdal_translate -q -of COG \
  -co COMPRESS=LZW \
  -co OVERVIEWS=NONE \
  -co BIGTIFF=IF_SAFER \
  "$TMP/wgs84.tif" "$DST"

echo
echo "== done."
gdalinfo -stats "$DST" | head -40
