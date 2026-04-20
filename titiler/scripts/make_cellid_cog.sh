#!/bin/bash
# Thin wrapper around make_cellid_cog.py — see that script for details.
# GDAL CLI tools aren't on PATH in the titiler base image, so we use rasterio
# directly through the Python script.
set -euo pipefail
exec python3 "$(dirname "$0")/make_cellid_cog.py" "$@"
