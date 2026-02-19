#!/usr/bin/env bash
# sync-pull.sh — pull data and static content from external dev server
# run via cron on the BOEM internal production server
# requires: rclone configured with remote "ext_dev"

set -euo pipefail

LOG="/var/log/msens/sync-pull.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
REMOTE="ext_dev"                         # rclone remote name
REMOTE_DATA="/share/data"               # data on external server
REMOTE_BIG="/share/data/big"            # large files on external server
REMOTE_WWW="/share/public/www"          # static website on external server
REMOTE_APPS="/share/shiny_apps"         # shiny app symlinks on external server
LOCAL_DATA="/share/data"                # local data directory
LOCAL_BIG="/share/data/big"             # local big data directory
LOCAL_WWW="/share/public/www"           # local static website directory
LOCAL_APPS="/share/shiny_apps"          # local shiny apps directory

echo "[$TIMESTAMP] === sync-pull started ===" >> "$LOG"

# --- data files (duckdb, gpkg, csv, tif) ---
echo "[$TIMESTAMP] pulling data files..." >> "$LOG"
rclone sync \
  "${REMOTE}:${REMOTE_DATA}/derived" \
  "${LOCAL_DATA}/derived" \
  --include "*.duckdb" \
  --include "*.gpkg" \
  --include "*.csv" \
  --include "*.tif" \
  --transfers 4 \
  --checkers 8 \
  --log-file "$LOG" \
  --log-level INFO \
  --stats-one-line \
  2>> "$LOG"

# --- big data files (sdm.duckdb) ---
echo "[$TIMESTAMP] pulling big data files..." >> "$LOG"
rclone sync \
  "${REMOTE}:${REMOTE_BIG}" \
  "${LOCAL_BIG}" \
  --include "*.duckdb" \
  --transfers 2 \
  --checkers 4 \
  --log-file "$LOG" \
  --log-level INFO \
  --stats-one-line \
  2>> "$LOG"

# --- pmtiles ---
echo "[$TIMESTAMP] pulling pmtiles..." >> "$LOG"
rclone sync \
  "${REMOTE}:${REMOTE_DATA}/derived" \
  "${LOCAL_DATA}/derived" \
  --include "*.pmtiles" \
  --transfers 2 \
  --log-file "$LOG" \
  --log-level INFO \
  2>> "$LOG"

# --- static website (docs, homepage) ---
echo "[$TIMESTAMP] pulling static website..." >> "$LOG"
rclone sync \
  "${REMOTE}:${REMOTE_WWW}" \
  "${LOCAL_WWW}" \
  --transfers 8 \
  --checkers 16 \
  --log-file "$LOG" \
  --log-level INFO \
  2>> "$LOG"

# --- shiny apps ---
echo "[$TIMESTAMP] pulling shiny apps..." >> "$LOG"
rclone sync \
  "${REMOTE}:${REMOTE_APPS}" \
  "${LOCAL_APPS}" \
  --transfers 4 \
  --log-file "$LOG" \
  --log-level INFO \
  2>> "$LOG"

TIMESTAMP_END=$(date '+%Y-%m-%d %H:%M:%S')
echo "[$TIMESTAMP_END] === sync-pull completed ===" >> "$LOG"
