#!/usr/bin/env bash
# sync-pull.sh — pull data and static content from external dev server,
#                pull app/server code from GitHub
# run via cron on the BOEM internal production server
# requires: rclone configured with remote "ext_dev", git installed

set -euo pipefail

LOG="/var/log/msens/sync-pull.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
REMOTE="ext_dev"                         # rclone remote name
REMOTE_DATA="/share/data"               # data on external server
REMOTE_BIG="/share/data/big"            # large files on external server
REMOTE_WWW="/share/public/www"          # static website on external server
LOCAL_DATA="/share/data"                # local data directory
LOCAL_BIG="/share/data/big"             # local big data directory
LOCAL_WWW="/share/public/www"           # local static website directory

# github repos (app source pulled via git, not rclone)
GH_APPS="/share/github/MarineSensitivity/apps"
GH_SERVER="/share/github/MarineSensitivity/server"

echo "[$TIMESTAMP] === sync-pull started ===" >> "$LOG"

# --- data files (duckdb, gpkg, csv, tif) via rclone sftp ---
echo "[$TIMESTAMP] pulling data files..." >> "$LOG"
rclone sync \
  "${REMOTE}:${REMOTE_DATA}/derived/v3" \
  "${LOCAL_DATA}/derived/v3" \
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

# --- big data files (sdm.duckdb) via rclone sftp ---
echo "[$TIMESTAMP] pulling big data files..." >> "$LOG"
rclone sync \
  "${REMOTE}:${REMOTE_BIG}/v3" \
  "${LOCAL_BIG}/v3" \
  --include "*.duckdb" \
  --transfers 2 \
  --checkers 4 \
  --log-file "$LOG" \
  --log-level INFO \
  --stats-one-line \
  2>> "$LOG"

# --- pmtiles via rclone sftp ---
echo "[$TIMESTAMP] pulling pmtiles..." >> "$LOG"
rclone sync \
  "${REMOTE}:${REMOTE_DATA}/derived" \
  "${LOCAL_DATA}/derived" \
  --include "*.pmtiles" \
  --transfers 2 \
  --log-file "$LOG" \
  --log-level INFO \
  2>> "$LOG"

# --- static website (docs, homepage) via rclone sftp ---
echo "[$TIMESTAMP] pulling static website..." >> "$LOG"
rclone sync \
  "${REMOTE}:${REMOTE_WWW}" \
  "${LOCAL_WWW}" \
  --transfers 8 \
  --checkers 16 \
  --log-file "$LOG" \
  --log-level INFO \
  2>> "$LOG"

# --- shiny app source code via git pull from GitHub ---
echo "[$TIMESTAMP] pulling app code from GitHub..." >> "$LOG"
if [ -d "$GH_APPS/.git" ]; then
  cd "$GH_APPS"
  git fetch origin >> "$LOG" 2>&1
  git checkout main >> "$LOG" 2>&1
  git pull origin main >> "$LOG" 2>&1
  echo "[$TIMESTAMP] apps repo updated" >> "$LOG"
else
  echo "[$TIMESTAMP] WARNING: $GH_APPS is not a git repo, skipping" >> "$LOG"
fi

# --- server config via git pull from GitHub ---
echo "[$TIMESTAMP] pulling server config from GitHub..." >> "$LOG"
if [ -d "$GH_SERVER/.git" ]; then
  cd "$GH_SERVER"
  git fetch origin >> "$LOG" 2>&1
  git checkout main >> "$LOG" 2>&1
  git pull origin main >> "$LOG" 2>&1
  echo "[$TIMESTAMP] server repo updated" >> "$LOG"
else
  echo "[$TIMESTAMP] WARNING: $GH_SERVER is not a git repo, skipping" >> "$LOG"
fi

TIMESTAMP_END=$(date '+%Y-%m-%d %H:%M:%S')
echo "[$TIMESTAMP_END] === sync-pull completed ===" >> "$LOG"
