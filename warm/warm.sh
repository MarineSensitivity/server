#!/bin/sh
# warm.sh — keep the app workers that people actually open already built.
#
# `app_idle_timeout` (rstudio/shiny-server.conf) keeps a worker alive once
# someone has started it; it cannot help the FIRST visitor after a deploy, a
# container restart, or a quiet night — and that visitor pays the full cold
# start (measured: ~13 s scores, ~17 s species, of which ~8 s is attaching
# packages and the rest is building that version's bundle). This loop pays it
# instead, on a schedule, so a reviewer never does.
#
# WHICH versions: the registry decides, not this file. The promoted release
# (latest.txt) is what the public apps open by default, and every `restricted`
# release is what reviewers are being asked to look at. Everything else stays
# cold on purpose — warming all nine would hold nine bundles per worker.
#
# WHERE: the container ports directly (rstudio:3838 public, :3839 preview), not
# the public hostnames. Warming is an internal concern: no Cloudflare round
# trip, no Access token, no egress, and it still works if DNS or the edge is
# having a bad day. The preview instance resolves `?ver=` itself (MS_PREVIEW=1),
# which is exactly what Caddy's X-MS-Version does for a real visitor.
#
# A page GET is enough: it starts the worker and evaluates ui(req), which builds
# that version's bundle. No websocket, so no session, so nothing is logged as
# usage and no analytics beacon fires.
set -u
REG=${VERSIONS_URL:-https://s3.us-east-1.amazonaws.com/oceanmetrics.io-public/marine-atlas/versions.json}
LATEST=${LATEST_URL:-https://s3.us-east-1.amazonaws.com/oceanmetrics.io-public/marine-atlas/latest.txt}
PUBLIC=${PUBLIC_BASE:-http://rstudio:3838}
PREVIEW=${PREVIEW_BASE:-http://rstudio:3839}
EVERY=${WARM_INTERVAL:-1200}          # < app_idle_timeout, so a worker never lapses
say() { echo "[warm $(date -u +%H:%M:%S)] $*"; }

hit() {  # hit <base> <app> <ver>
  code=$(curl -s -o /dev/null -m 300 -w '%{http_code} %{time_total}' "$1/$2/?ver=$3" 2>/dev/null)
  say "$2 $3 -> ${code:-unreachable}s"
}

while true; do
  promoted=$(curl -sf --max-time 30 "$LATEST" 2>/dev/null | tr -d '[:space:]')
  restricted=$(curl -sf --max-time 30 "$REG" 2>/dev/null | jq -r '
    .versions[]
    | (.access // (if .status == "prerelease" then "restricted" else "public" end)) as $a
    | select($a == "restricted") | .ver' 2>/dev/null)

  if [ -n "$promoted" ]; then
    for app in scores species; do hit "$PUBLIC" "$app" "$promoted"; done
  else
    say "latest.txt unreadable — skipping the public apps this round"
  fi

  if [ -n "$restricted" ]; then
    for v in $restricted; do
      for app in scores species; do hit "$PREVIEW" "$app" "$v"; done
    done
  else
    say "no restricted release to warm"
  fi

  sleep "$EVERY"
done
