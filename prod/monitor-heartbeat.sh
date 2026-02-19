#!/usr/bin/env bash
# monitor-heartbeat.sh — run on external dev server to detect internal downtime
# checks the heartbeat.json file; alerts if stale (>15 min)
# run via cron every 10 minutes on the external server

set -euo pipefail

HEARTBEAT_FILE="/share/logs/prod/heartbeat.json"
ALERT_EMAIL="ben@ecoquants.com"
STALE_MINUTES=15

if [ ! -f "$HEARTBEAT_FILE" ]; then
  echo "ALERT: heartbeat file not found at ${HEARTBEAT_FILE}" |
    mail -s "[MST] Internal server heartbeat MISSING" "$ALERT_EMAIL"
  exit 1
fi

# get last heartbeat timestamp
LAST_BEAT=$(jq -r '.timestamp' "$HEARTBEAT_FILE" 2>/dev/null)
if [ -z "$LAST_BEAT" ] || [ "$LAST_BEAT" = "null" ]; then
  echo "ALERT: could not parse heartbeat timestamp" |
    mail -s "[MST] Internal server heartbeat PARSE ERROR" "$ALERT_EMAIL"
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

  cat <<EOF | mail -s "[MST] Internal server DOWN - no heartbeat for ${AGE_MIN}min" "$ALERT_EMAIL"
The BOEM internal production server has not sent a heartbeat
in ${AGE_MIN} minutes (threshold: ${STALE_MINUTES} min).

Last heartbeat: ${LAST_BEAT}
Last known service states:
  caddy: ${CADDY_STATUS}
  shiny: ${SHINY_STATUS}

Please investigate.
EOF
fi
