#!/usr/bin/env bash
# Local routing test of the storage.marinesensitivity.org vhost -- the REAL text cut out of the
# Caddyfile, run by a throwaway caddy on a free port, no Docker, no DNS.
#
# Since 2026-11-13 (R2 migration) the vhost is a 301 to the same key on storage.oceanmetrics.io,
# the Cloudflare Worker over R2 that lists folders itself: every path, query intact, no body, Range
# requests included (a 301 cannot be a 206). The pre-2026-11-13 behaviour (index pages proxied,
# objects 302'd to S3 with CORS) is in git history with its own version of this test.
#
#   caddy/test/storage_host_local.sh
#   STORAGE_HOST_CADDYFILE=/path/to/other.Caddyfile caddy/test/storage_host_local.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src="${STORAGE_HOST_CADDYFILE:-$here/../Caddyfile}"
need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need caddy; need curl; need python3; need awk

tmp=$(mktemp -d); pid=""
cleanup() { [ -n "$pid" ] && kill "$pid" >/dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
base="http://127.0.0.1:$port"
mkdir -p "$tmp/share/logs/caddy"

cfg="$tmp/Caddyfile"
{
  printf '{\n\tadmin off\n\tauto_https off\n}\n'
  awk '/^\(access_log\) \{/{p=1} p{print} p&&/^\}/{exit}' "$src"
  awk '/^storage\.marinesensitivity\.org \{/{p=1} p{print} p&&/^\}/{exit}' "$src"
} | sed -e "s#^storage\.marinesensitivity\.org {#$base {#" -e "s#/share/#$tmp/share/#g" > "$cfg"
grep -q "^$base {" "$cfg" || { echo "could not cut the storage vhost out of $src" >&2; exit 1; }
caddy validate --config "$cfg" --adapter caddyfile >/dev/null 2>&1 || { caddy validate --config "$cfg" --adapter caddyfile; exit 1; }
caddy run --config "$cfg" --adapter caddyfile >"$tmp/caddy.out" 2>&1 & pid=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "$base/" && break; sleep 0.1; done

fail=0
is() { if [ "$2" = "$3" ]; then echo "  ok   $1 ($3)"; else echo "  FAIL $1: expected '$2', got '$3'"; fail=1; fi; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
loc()  { curl -s -o /dev/null -w '%{redirect_url}' "$@"; }
OM=https://storage.oceanmetrics.io

is "folder URL -> 301"                      301 "$(code "$base/marine-atlas/")"
is "folder Location is the OM host"         "$OM/marine-atlas/" "$(loc "$base/marine-atlas/")"
is "index.html -> 301"                      "$OM/marine-atlas/index.html" "$(loc "$base/marine-atlas/index.html")"
is "data object -> 301"                     301 "$(code "$base/marine-atlas/latest.txt")"
is "data object Location"                   "$OM/marine-atlas/latest.txt" "$(loc "$base/marine-atlas/latest.txt")"
is "query string survives"                  "$OM/marine-atlas/latest.txt?a=1&b=two" "$(loc "$base/marine-atlas/latest.txt?a=1&b=two")"
is "Range request is redirected, not 206"   301 "$(code -H 'Range: bytes=0-4' "$base/marine-atlas/v8/tables/zone.parquet")"
is "redirect carries no body bytes"         0   "$(curl -s "$base/marine-atlas/latest.txt" | wc -c | tr -d ' ')"
is "gazetteer -> 301"                       "$OM/gazetteer/x/y.parquet" "$(loc "$base/gazetteer/x/y.parquet")"
is "indicators -> 301"                      "$OM/indicators/indicators.json" "$(loc "$base/indicators/indicators.json")"
is "/ -> the OM host root"                  "$OM/" "$(loc "$base/")"
is "robots.txt -> 301 (the OM host has its own)" 301 "$(code "$base/robots.txt")"
is "/backups/x -> 301 (the OM host answers 404 there)" "$OM/backups/x" "$(loc "$base/backups/x")"
is "OPTIONS -> 301 too (no CORS surface left here)" 301 "$(code -X OPTIONS "$base/marine-atlas/latest.txt")"
is "a 302 never appears"                    0   "$(for p in / /marine-atlas/ /marine-atlas/latest.txt; do code "$base$p"; echo; done | grep -c '^302$')"

[ "$fail" = 0 ] && echo "storage host: all assertions passed" || { echo "storage host: FAILED"; exit 1; }
