#!/usr/bin/env bash
# Local routing test of the file.marinesensitivity.org vhost — the REAL text of
# caddy/Caddyfile, not a copy: the block is cut out of it, its site address is
# swapped for a local port and /share for a fixture tree built here. Needs only
# homebrew caddy + curl (no plugins: this vhost uses none).
#
# What it proves (2026-10-02 egress review; 2026-10-07 asset-store prune):
#   - /pmtiles/v8/ and /pmtiles/v9/ answer 410 Gone and never fall through to
#     derived/pmtiles (a decoy with the old name sits there and must not be served);
#   - no data tree answers with a directory listing; exact files still do;
#   - /stac/ and /branding/ stay browsable; robots.txt exists; requests are logged.
#
# Seeded fault: FILE_HOST_CADDYFILE=<an older Caddyfile> must FAIL.
#   git show 2b55524:caddy/Caddyfile > /tmp/old.Caddyfile
#   FILE_HOST_CADDYFILE=/tmp/old.Caddyfile caddy/test/file_host_local.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src="${FILE_HOST_CADDYFILE:-$here/../Caddyfile}"
need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need caddy; need curl; need python3; need awk

tmp=$(mktemp -d); pid=""
cleanup() { [ -n "$pid" ] && kill "$pid" >/dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
base="http://127.0.0.1:$port"

# ---- fixtures ------------------------------------------------------------------
r="$tmp/share"
mkdir -p "$r/data/derived/pmtiles/v8/rng" "$r/data/derived/pmtiles/v9/rng" \
         "$r/data/derived/v4/pmtiles" "$r/data/derived/stac" "$r/data/derived/v7" "$r/public/cog" \
         "$r/github/MarineSensitivity/server/branding" "$r/logs/caddy"
printf 'ZONES'   > "$r/data/derived/pmtiles/ply.pmtiles"
printf 'DECOY8'  > "$r/data/derived/pmtiles/v8/rng/a.pmtiles"      # the OLD place: must not be served
printf 'DECOY9'  > "$r/data/derived/pmtiles/v9/rng/a.pmtiles"
printf 'V4'      > "$r/data/derived/v4/pmtiles/x.pmtiles"
printf '{"type":"Catalog"}' > "$r/data/derived/stac/catalog.json"
printf 'TIF'     > "$r/data/derived/v7/f.tif"
printf 'COG'     > "$r/public/cog/c.tif"
printf '<svg/>'  > "$r/github/MarineSensitivity/server/branding/mark.svg"

# ---- the vhost, cut from the real Caddyfile ---------------------------------------
cfg="$tmp/Caddyfile"
{
  printf '{\n\tadmin off\n\tauto_https off\n}\n'
  awk '/^\(cors\) \{/{p=1} p{print} p&&/^\}/{exit}' "$src"
  awk '/^\(access_log\) \{/{p=1} p{print} p&&/^\}/{exit}' "$src"   # snippets the vhost imports (absent in older Caddyfiles)
  awk '/^\(no_ai_bots\) \{/{p=1} p{print} p&&/^\}/{exit}' "$src"
  awk '/^file\.marinesensitivity\.org \{/{p=1} p{print} p&&/^\}/{exit}' "$src"
} | sed -e "s#^file\.marinesensitivity\.org {#$base {#" -e "s#/share/#$r/#g" > "$cfg"
grep -q "^$base {" "$cfg" || { echo "could not cut the file vhost out of $src" >&2; exit 1; }
caddy validate --config "$cfg" --adapter caddyfile >/dev/null 2>&1 || { caddy validate --config "$cfg" --adapter caddyfile; exit 1; }
caddy run --config "$cfg" --adapter caddyfile >"$tmp/caddy.out" 2>&1 & pid=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "$base/robots.txt" && break; sleep 0.1; done

# ---- assertions --------------------------------------------------------------------
fail=0
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
is() {  # is <label> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  ok   $1 ($3)"; else echo "  FAIL $1: expected $2, got $3"; fail=1; fi
}
is "v8 per-model tile is gone (410), not the decoy" 410 "$(code "$base/pmtiles/v8/rng/a.pmtiles")"
is "v9 per-model tile is gone (410), not the decoy" 410 "$(code "$base/pmtiles/v9/rng/a.pmtiles")"
is "the decoy body is never served"    0   "$(curl -s "$base/pmtiles/v8/rng/a.pmtiles" | grep -c DECOY)"
is "zone tiles at /pmtiles/"           "ZONES" "$(curl -s "$base/pmtiles/ply.pmtiles")"
is "range request (PMTiles protocol)"  206 "$(code -r 0-2 "$base/pmtiles/ply.pmtiles")"
is "legacy /pmtiles/v4/"               "V4"    "$(curl -s "$base/pmtiles/v4/x.pmtiles")"
is "derived file by exact URL"         "TIF"   "$(curl -s "$base/derived/v7/f.tif")"
is "public file by exact URL"          "COG"   "$(curl -s "$base/cog/c.tif")"
for d in /pmtiles/ /pmtiles/v4/ /derived/ /derived/v7/ / /cog/; do
  is "no directory listing at $d" 404 "$(code "$base$d")"
done
is "/stac/ stays browsable"            200 "$(code "$base/stac/")"
is "/stac/ lists the catalog"          1   "$(curl -s "$base/stac/" | grep -c 'catalog.json' | head -1 | sed 's/^[1-9][0-9]*$/1/')"
is "/branding/ stays browsable"        200 "$(code "$base/branding/")"
is "robots.txt"                        200 "$(code "$base/robots.txt")"
is "robots.txt keeps crawlers off data" 1  "$(curl -s "$base/robots.txt" | grep -c '^Disallow: /$')"
is "CORS for a browser origin"         1   "$(curl -s -D - -o /dev/null -H 'Origin: https://marinesensitivity.org' "$base/pmtiles/ply.pmtiles" | grep -ci '^access-control-allow-origin: \*')"
sleep 0.5
is "requests are logged"               1   "$( [ -s "$r/logs/caddy/file.log" ] && echo 1 || echo 0)"

[ "$fail" = 0 ] && echo "FILE_HOST_OK" || { echo "FILE_HOST_FAILED"; exit 1; }
