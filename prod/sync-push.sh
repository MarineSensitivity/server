#!/usr/bin/env bash
# sync-push.sh — push log files from internal to external dev server
# run via cron on the BOEM internal production server
# requires: rclone configured with remote "ext_dev"

set -euo pipefail

LOG="/var/log/msens/sync-push.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
REMOTE="ext_dev"                         # rclone remote name
LOCAL_LOGS="/var/log/msens"             # local log directory
REMOTE_LOGS="/share/logs/prod"          # log destination on external server

echo "[$TIMESTAMP] === sync-push started ===" >> "$LOG"

# --- push log files for debugging ---
echo "[$TIMESTAMP] pushing log files..." >> "$LOG"
rclone copy \
  "${LOCAL_LOGS}" \
  "${REMOTE}:${REMOTE_LOGS}" \
  --include "*.log" \
  --transfers 2 \
  --log-file "$LOG" \
  --log-level INFO \
  2>> "$LOG"

# --- push shiny app logs (if directory exists) ---
# note: shiny container may log to stderr (captured via podman logs below)
#       rather than to /var/log/shiny-server on the host
if [ -d "/var/log/shiny-server" ]; then
  echo "[$TIMESTAMP] pushing shiny logs..." >> "$LOG"
  rclone copy \
    "/var/log/shiny-server" \
    "${REMOTE}:${REMOTE_LOGS}/shiny" \
    --include "*.log" \
    --transfers 2 \
    --log-file "$LOG" \
    --log-level INFO \
    2>> "$LOG"
else
  echo "[$TIMESTAMP] skipping shiny logs (no /var/log/shiny-server)" >> "$LOG"
fi

# --- push container logs ---
echo "[$TIMESTAMP] exporting podman logs..." >> "$LOG"
podman logs caddy  --since 24h > /tmp/podman-caddy.log  2>&1 || true
podman logs shiny  --since 24h > /tmp/podman-shiny.log  2>&1 || true
rclone copy \
  "/tmp" \
  "${REMOTE}:${REMOTE_LOGS}/podman" \
  --include "podman-*.log" \
  --log-file "$LOG" \
  --log-level INFO \
  2>> "$LOG"

TIMESTAMP_END=$(date '+%Y-%m-%d %H:%M:%S')
echo "[$TIMESTAMP_END] === sync-push completed ===" >> "$LOG"
