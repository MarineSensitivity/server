#!/usr/bin/env bash
# monitor-heartbeat.sh — run on external dev server to detect internal downtime
# checks the heartbeat.json file; alerts if stale (>15 min)
# run via cron every 10 minutes on the external server
# requires: jq installed

set -euo pipefail

HEARTBEAT_FILE="/share/logs/prod/heartbeat.json"
STALE_MINUTES=15
LOG="/var/log/msens/monitor-heartbeat.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# log alert (add email notification later via SES, msmtp, or webhook)
send_alert() {
  local subject="$1"
  local body="$2"
  echo "[$TIMESTAMP] ALERT: $subject — $body" >> "$LOG"
}

if [ ! -f "$HEARTBEAT_FILE" ]; then
  send_alert \
    "[MST] Internal server heartbeat MISSING" \
    "heartbeat file not found at ${HEARTBEAT_FILE}"
  exit 1
fi

# get last heartbeat timestamp
LAST_BEAT=$(jq -r '.timestamp' "$HEARTBEAT_FILE" 2>/dev/null)
if [ -z "$LAST_BEAT" ] || [ "$LAST_BEAT" = "null" ]; then
  send_alert \
    "[MST] Internal server heartbeat PARSE ERROR" \
    "could not parse heartbeat timestamp from ${HEARTBEAT_FILE}"
  exit 1
fi

# calculate age in minutes
LAST_EPOCH=$(date -d "$LAST_BEAT" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_BEAT" +%s)
NOW_EPOCH=$(date +%s)
AGE_MIN=$(( (NOW_EPOCH - LAST_EPOCH) / 60 ))

if [ "$AGE_MIN" -gt "$STALE_MINUTES" ]; then
  # read service statuses
  CADDY_STATUS=$(jq -r '.services.caddy' "$HEARTBEAT_FILE" 2>/dev/null || echo "unknown")
  SHINY_STATUS=$(jq -r '.services.shiny' "$HEARTBEAT_FILE" 2>/dev/null || echo "unknown")

  send_alert \
    "[MST] Internal server DOWN - no heartbeat for ${AGE_MIN}min" \
    "last heartbeat: ${LAST_BEAT}, caddy=${CADDY_STATUS}, shiny=${SHINY_STATUS}"
else
  echo "[$TIMESTAMP] OK: heartbeat age ${AGE_MIN}min (threshold: ${STALE_MINUTES}min)" >> "$LOG"
fi
