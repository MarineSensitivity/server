#!/usr/bin/env bash
# host/pmtiles_native.sh — take the per-model PMTiles of v8/v9 out of /share/data/derived.
#
# WHY: the BOEM internal mirror (prod/sync-pull.sh, key msens-sync@boem) runs
#   rclone sync ext_dev:/share/data/derived /share/data/derived --include "*.pmtiles"
# every hour. On 2026-08-27 17:05 UTC v9's 6,776 per-model PMTiles appeared here (hardlinks to
# v8's, so free on this disk — but rclone copies them as a second 6.7 GB), the mirror's disk
# filled, and every hour since it re-read the 3,950 files it could not store: ~5.8 GB/hour,
# ~150 GB/day of EC2 egress, $55.60 in August and $397.70 in September. That host's copy of the
# script has never reached its `git pull` (0 occurrences in its own log since February), so no
# fix can be delivered to it as code. What it DOES obey is the source listing: `rclone sync`
# deletes a destination file whose source is gone. Removing these two trees from derived/ makes
# its next run delete its ~10 GB of copies, free its disk and transfer nothing.
#
# The files stay served at the same URLs (file.marinesensitivity.org/pmtiles/{v8,v9}/…, which
# every published v8/v9 native_asset row points at): caddy/Caddyfile roots those two paths at
# $DST. Hardlinks, so nothing is copied and nothing is at risk until `retire`.
#
#   host/pmtiles_native.sh link     # BEFORE caddy restarts onto the new roots (idempotent)
#   host/pmtiles_native.sh retire   # AFTER: prove the URLs, remove the old trees, prove again
#   host/pmtiles_native.sh status
#
# `retire` refuses to remove anything unless the new tree holds every file of the old one and
# the public URL answers; if the URL stops answering after the removal it puts the tree back.
set -euo pipefail
SRC="${PMTILES_SRC:-/share/data/derived/pmtiles}"
DST="${PMTILES_DST:-/share/data/pmtiles_native}"
URL="${PMTILES_URL:-https://file.marinesensitivity.org/pmtiles}"
VERS="${PMTILES_VERS:-v8 v9}"
say() { echo "[pmtiles_native] $*"; }
n_files() { [ -d "$1" ] && find "$1" -type f -name '*.pmtiles' | wc -l | tr -d ' ' || echo 0; }

# one real file per version, to ask the public URL for
probe() {  # probe <ver> -> http status of a ranged GET on its first file
  local f rel
  f=$(find "$DST/$1" -type f -name '*.pmtiles' | sort | head -1)
  [ -n "$f" ] || { echo 000; return; }
  rel=${f#"$DST"/}
  # an unreachable host must read as "000", not end the script under set -e with no message
  # (the retries cover caddy's first seconds after a restart; a 404 is an answer and is not retried)
  curl -s -o /dev/null -m 30 --retry 5 --retry-delay 2 --retry-connrefused -r 0-15 \
    -w '%{http_code}' "$URL/$rel" || true
}

case "${1:-status}" in
  link)
    mkdir -p "$DST"
    for v in $VERS; do
      if [ ! -d "$SRC/$v" ]; then say "$v: nothing at $SRC/$v (already retired?)"; continue; fi
      # an incomplete tree from an interrupted run is only links: drop it and link afresh
      if [ "$(n_files "$SRC/$v")" != "$(n_files "$DST/$v")" ]; then
        rm -rf "${DST:?}/$v"
        cp -al "$SRC/$v" "$DST/$v"
      fi
      say "$v: $(n_files "$SRC/$v") files in derived, $(n_files "$DST/$v") linked at $DST/$v"
      [ "$(n_files "$SRC/$v")" = "$(n_files "$DST/$v")" ] || { say "$v: COUNT MISMATCH"; exit 1; }
    done
    ;;
  retire)
    grep -q "pmtiles_native" "$(dirname "$0")/../caddy/Caddyfile" \
      || { say "this checkout's Caddyfile does not root /pmtiles/{v8,v9} at $DST — refusing"; exit 1; }
    for v in $VERS; do
      if [ ! -d "$SRC/$v" ]; then say "$v: already out of derived"; continue; fi
      [ "$(n_files "$SRC/$v")" = "$(n_files "$DST/$v")" ] \
        || { say "$v: $DST/$v is not a complete copy — run 'link' first"; exit 1; }
      code=$(probe "$v"); [ "$code" = 206 ] || [ "$code" = 200 ] \
        || { say "$v: $URL answers $code before the removal — refusing"; exit 1; }
      rm -rf "${SRC:?}/$v"
      code=$(probe "$v")
      if [ "$code" != 206 ] && [ "$code" != 200 ]; then
        say "$v: $URL answers $code with the old tree gone — caddy is NOT serving $DST; restoring"
        cp -al "$DST/$v" "$SRC/$v"
        exit 1
      fi
      say "$v: removed from derived; $URL/$v/ still answers $code from $DST"
    done
    say "PMTILES_NATIVE_OK $(find "$SRC" -type f -name '*.pmtiles' | wc -l | tr -d ' ') pmtiles left under $SRC"
    ;;
  status)
    for v in $VERS; do
      say "$v: derived=$(n_files "$SRC/$v") native=$(n_files "$DST/$v") url=$(probe "$v" 2>/dev/null || echo n/a)"
    done
    ;;
  *) echo "usage: $0 link|retire|status" >&2; exit 2 ;;
esac
