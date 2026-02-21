#!/usr/bin/env bash
# update-images.sh — pull latest container images from GHCR and restart
# designed to run unattended via cron (daily)
#
# podman auto-update does NOT work with podman-compose pods, so this script
# manually pulls, stops, and recreates containers when a newer image exists.

set -euo pipefail

LOG="/var/log/msens/update-images.log"
COMPOSE_DIR="/share/github/MarineSensitivity/server/prod"
IMAGE="ghcr.io/marinesensitivity/shiny:latest"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$LOG"; }

log "checking for image updates..."

# capture current image digest
OLD_DIGEST=$(sudo podman image inspect "$IMAGE" --format '{{.Digest}}' 2>/dev/null || echo "none")

# pull latest
if ! sudo podman pull "$IMAGE" >> "$LOG" 2>&1; then
  log "ERROR: failed to pull $IMAGE"
  exit 1
fi

# compare digests
NEW_DIGEST=$(sudo podman image inspect "$IMAGE" --format '{{.Digest}}')

if [ "$OLD_DIGEST" = "$NEW_DIGEST" ]; then
  log "image unchanged (${NEW_DIGEST:0:20}...); no restart needed"
  exit 0
fi

log "new image detected: ${OLD_DIGEST:0:20}... -> ${NEW_DIGEST:0:20}..."
log "restarting containers..."

cd "$COMPOSE_DIR"
sudo python3.8 -m podman_compose down  >> "$LOG" 2>&1
sudo python3.8 -m podman_compose up -d >> "$LOG" 2>&1

# re-apply SELinux context in case new volumes appeared
sudo chcon -R -t container_file_t /share >> "$LOG" 2>&1 || true

log "update complete. running containers:"
sudo podman ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" >> "$LOG" 2>&1

log "done."
