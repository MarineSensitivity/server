#!/usr/bin/env bash
# Local routing test of the storage.marinesensitivity.org vhost -- the REAL text
# of caddy/Caddyfile, cut out with awk, its site address swapped for a local
# port. Needs homebrew caddy + curl (no plugins). The proxy target is the real
# public bucket (the objects used below exist and are public), so this needs
# network access.
#
# What it proves (2026-10-02 egress review): only the small pages (folder URLs,
# */index.html, */README.md) are proxied through the VM; every other object is a
# 302 to the bucket's own HTTPS endpoint -- Range requests included -- so no
# data bytes transit the server; backups/ stays unreachable.
#
# 2026-10-08: the 302 (and a preflight OPTIONS) must carry CORS headers, or every
# cross-origin fetch / range request from the apps through this host fails with
# status 0. OPTIONS is answered here with a 204; the page proxies are unchanged.
#
# Seeded fault: STORAGE_HOST_CADDYFILE=<the pre-change Caddyfile> must FAIL.
#   git show HEAD:caddy/Caddyfile > /path/to/old.Caddyfile   # HEAD, before this change is committed
#   STORAGE_HOST_CADDYFILE=/path/to/old.Caddyfile caddy/test/storage_host_local.sh
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

# ---- the vhost (+ the snippets it imports, if this Caddyfile has them) ----------------
cfg="$tmp/Caddyfile"
{
  printf '{\n\tadmin off\n\tauto_https off\n}\n'
  awk '/^\(access_log\) \{/{p=1} p{print} p&&/^\}/{exit}' "$src"
  awk '/^\(s3_cors\) \{/{p=1} p{print} p&&/^\}/{exit}' "$src"
  awk '/^storage\.marinesensitivity\.org, storage\.oceanmetrics\.io \{/{p=1} p{print} p&&/^\}/{exit}' "$src"
} | sed -e "s#^storage\.marinesensitivity\.org, storage\.oceanmetrics\.io {#$base {#" -e "s#/share/#$tmp/share/#g" > "$cfg"
grep -q "^$base {" "$cfg" || { echo "could not cut the storage vhost out of $src" >&2; exit 1; }
caddy validate --config "$cfg" --adapter caddyfile >/dev/null 2>&1 || { caddy validate --config "$cfg" --adapter caddyfile; exit 1; }
caddy run --config "$cfg" --adapter caddyfile >"$tmp/caddy.out" 2>&1 & pid=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "$base/robots.txt" && break; sleep 0.1; done

# ---- assertions ---------------------------------------------------------------------
fail=0
is() {  # is <label> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  ok   $1 ($3)"; else echo "  FAIL $1: expected '$2', got '$3'"; fail=1; fi
}
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
loc()  { curl -s -o /dev/null -w '%{redirect_url}' "$@"; }
S3=https://s3.us-east-1.amazonaws.com/oceanmetrics.io-public

is "folder URL is proxied (index page)"     200 "$(code "$base/marine-atlas/")"
is "folder URL is text/html"                "text/html" "$(curl -s -o /dev/null -w '%{content_type}' "$base/marine-atlas/" | cut -d';' -f1)"
is "folder URL really is the index page"    1   "$(curl -s "$base/marine-atlas/" | grep -ci '<html' | sed 's/^[1-9][0-9]*$/1/')"
is "*/index.html is proxied"                200 "$(code "$base/marine-atlas/index.html")"
is "data object -> 302"                     302 "$(code "$base/marine-atlas/latest.txt")"
is "data object Location is the bucket"     "$S3/marine-atlas/latest.txt" "$(loc "$base/marine-atlas/latest.txt")"
is "versions.json -> 302"                   "$S3/marine-atlas/versions.json" "$(loc "$base/marine-atlas/versions.json")"
is "Range request is redirected, not 206"   302 "$(code -H 'Range: bytes=0-4' "$base/marine-atlas/latest.txt")"
is "Range request Location unchanged"       "$S3/marine-atlas/latest.txt" "$(loc -H 'Range: bytes=0-4' "$base/marine-atlas/latest.txt")"
is "redirect carries no body bytes"         0   "$(curl -s -H 'Range: bytes=0-4' "$base/marine-atlas/latest.txt" | wc -c | tr -d ' ')"
is "query string survives the redirect"     "$S3/marine-atlas/latest.txt?a=1&b=two" "$(loc "$base/marine-atlas/latest.txt?a=1&b=two")"
is "gazetteer data object -> 302"           "$S3/gazetteer/x/y.parquet" "$(loc "$base/gazetteer/x/y.parquet")"
is "deep parquet object -> 302 (not proxied)" 302 "$(code "$base/marine-atlas/v8/tables/zone.parquet")"
is "/ -> /marine-atlas/"                    "$base/marine-atlas/" "$(loc "$base/")"
is "/ is a 302"                             302 "$(code "$base/")"
is "robots.txt"                             200 "$(code "$base/robots.txt")"
is "robots.txt keeps crawlers off objects"  1   "$(curl -s "$base/robots.txt" | grep -c '^Disallow: /\*\.parquet\$')"
is "/backups/anything is 404"               404 "$(code "$base/backups/anything")"
is "/backups/ is 404"                       404 "$(code "$base/backups/")"
is "404 keeps its text body"                1   "$(curl -s "$base/backups/x" | grep -c '^Not found\.')"
is "/backups/ never redirects to the bucket" "" "$(loc "$base/backups/x")"
# CORS (2026-10-08): the redirect carries the headers; OPTIONS is a 204 preflight answer
ORI='Origin: http://localhost:5179'
hdr() { curl -s -D - -o /dev/null "$@" | tr -d '\r' | tr 'A-Z' 'a-z'; }   # lower-cased response headers
has() { grep -c -E "$1" <<<"$2" | sed 's/^[1-9][0-9]*$/1/'; }
h=$(hdr -H "$ORI" "$base/gazetteer/places/places.pmtiles")
is "302 for a data object has ACAO *"        1 "$(has '^access-control-allow-origin: \*$' "$h")"
is "302 exposes Content-Range"               1 "$(has '^access-control-expose-headers:.*content-range' "$h")"
is "302 allows GET, HEAD"                    1 "$(has '^access-control-allow-methods: get, head$' "$h")"
is "302 is cacheable for a day"              1 "$(has '^cache-control: public, max-age=86400$' "$h")"
is "302 for a data object is still a 302"    302 "$(code -H "$ORI" "$base/gazetteer/places/places.pmtiles")"
h=$(hdr -H "$ORI" -H 'Range: bytes=-65536' "$base/gazetteer/places/places.pmtiles")
is "suffix-range 302 has ACAO *"             1 "$(has '^access-control-allow-origin: \*$' "$h")"
h=$(hdr -X OPTIONS -H "$ORI" -H 'Access-Control-Request-Method: GET' -H 'Access-Control-Request-Headers: range,if-none-match' "$base/gazetteer/places/places.pmtiles")
is "OPTIONS preflight -> 204"                204 "$(code -X OPTIONS -H "$ORI" -H 'Access-Control-Request-Method: GET' "$base/gazetteer/places/places.pmtiles")"
is "OPTIONS has ACAO *"                      1 "$(has '^access-control-allow-origin: \*$' "$h")"
is "OPTIONS allows the Range header"         1 "$(has '^access-control-allow-headers:.*range' "$h")"
is "OPTIONS allows If-Match, If-None-Match"  1 "$(has '^access-control-allow-headers:.*if-match.*if-none-match' "$h")"
is "OPTIONS has Max-Age"                     1 "$(has '^access-control-max-age: 3600$' "$h")"
is "OPTIONS is not redirected"               "" "$(loc -X OPTIONS -H "$ORI" "$base/gazetteer/places/places.pmtiles")"
is "OPTIONS on marine-atlas -> 204"          204 "$(code -X OPTIONS -H "$ORI" "$base/marine-atlas/latest.txt")"
is "OPTIONS on /backups/ stays 404"          404 "$(code -X OPTIONS -H "$ORI" "$base/backups/x")"
# the folder / page proxies are unchanged: still proxied (200), not the redirect's headers
is "folder proxy still 200 with Origin"      200 "$(code -H "$ORI" "$base/marine-atlas/")"
h=$(hdr -H "$ORI" "$base/marine-atlas/index.html")
is "page proxy has no day-long Cache-Control" 0 "$(grep -c -E '^cache-control: public, max-age=86400$' <<<"$h" || true)"
is "page proxy ACAO not duplicated (S3's own)" 1 "$(grep -c -E '^access-control-allow-origin:' <<<"$h" || true)"
sleep 0.5
is "requests are logged"                    1   "$( [ -s "$tmp/share/logs/caddy/storage.log" ] && echo 1 || echo 0)"

[ "$fail" = 0 ] && echo "STORAGE_HOST_OK" || { echo "STORAGE_HOST_FAILED"; exit 1; }
