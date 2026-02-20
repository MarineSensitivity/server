#!/usr/bin/env bash
# ping.sh — health check for internal production server
# pushes a heartbeat timestamp to the external server
# if heartbeat stops arriving, external monitoring detects downtime
# run via cron every 5 minutes on the BOEM internal server

set -euo pipefail

REMOTE="ext_dev"
HEARTBEAT_FILE="/tmp/heartbeat.json"
REMOTE_PATH="/share/logs/prod/heartbeat.json"

# collect health info
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
HOSTNAME=$(hostname)
UPTIME=$(uptime -s 2>/dev/null || uptime | sed 's/.*up /up /' | sed 's/,.*//')
DISK_FREE=$(df -h /share | tail -1 | awk '{print $4}')
MEM_FREE=$(free -h 2>/dev/null | awk '/^Mem:/{print $4}' || echo "N/A")

# check container services
CADDY_STATUS=$(podman inspect -f '{{.State.Status}}' caddy 2>/dev/null || echo "not found")
SHINY_STATUS=$(podman inspect -f '{{.State.Status}}' shiny 2>/dev/null || echo "not found")

# write heartbeat json
cat > "$HEARTBEAT_FILE" <<EOF
{
  "timestamp":    "${TIMESTAMP}",
  "hostname":     "${HOSTNAME}",
  "uptime_since": "${UPTIME}",
  "disk_free":    "${DISK_FREE}",
  "mem_free":     "${MEM_FREE}",
  "services": {
    "caddy": "${CADDY_STATUS}",
    "shiny": "${SHINY_STATUS}"
  }
}
EOF

# push heartbeat to external server
rclone copyto "$HEARTBEAT_FILE" "${REMOTE}:${REMOTE_PATH}" --quiet
