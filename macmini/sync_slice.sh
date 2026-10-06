#!/usr/bin/env bash
# mac mini modeling machine: pull the slice of the laptop's ~/_big/msens the modeling work reads
# (not all 673 GB). run ON the mini as bbest; idempotent (rsync).
#   ~/Github/MarineSensitivity/server/macmini/sync_slice.sh
#   SLICE_SDM_DB=1 …/sync_slice.sh      # also the v9 sdm.duckdb (27 GB), for the og-vs-v9 comparison
set -euo pipefail

SRC=${SLICE_SRC:-laptop}                 # ssh host alias of the laptop (~/.ssh/config)
DST=$HOME/_big/msens
VER=${SLICE_VER:-v9}

pull() { # pull <path relative to ~/_big/msens>
  mkdir -p "$DST/$(dirname "$1")"
  rsync -a --partial "$SRC:_big/msens/$1" "$DST/$(dirname "$1")/"
}

pull derived/v2/ply_programareas_2026.gpkg          # program areas (canonical geometry, v2-v9)
pull derived/zones                                  # zone_cell per zone set x grid
pull derived/r_cellid_global.tif                    # the global05 cell-id lookup image
pull derived/ply_subregions_usa_2025-06.gpkg
pull raw/fisheries.noaa.gov/All_NMFS_Critical_Habitat   # nmfs critical habitat snapshot (v9 input)
pull raw/bio-oracle.org
pull derived/speciesgrids_global05.duckdb             # obis+gbif records per species x global05 cell (search effort)
pull derived/obis_grid.duckdb                        # obis records per species x cell, with year range
[ "${SLICE_SDM_DB:-0}" = 1 ] && pull "derived/$VER/sdm.duckdb"

du -sh "$DST"/derived "$DST"/raw
