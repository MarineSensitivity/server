#!/usr/bin/env bash
# Local routing test of caddy/atlas_preview_routes.caddy — for a laptop with
# homebrew caddy but WITHOUT the jwtauth plugin, no Docker daemon, no Go, so
# caddy/test/run.sh's approach (a real image, on the compose network, behind a
# test jwtauth) does not work here. This proves ROUTING ONLY, against a small
# fixture tree (caddy/test/fixtures/atlas_preview/), never the Cloudflare
# Access gate — caddy/test/run.sh is what proves that half, on the server.
#
# Starts homebrew caddy on a free high port, serving ONLY this one snippet
# (caddy/test/atlas_preview_routes.test.Caddyfile imports it directly, with a
# trailing 404 standing in for "the rest of the vhost didn't match either" —
# see that file's header) with ATLAS_PREVIEW_ROOT pointed at the fixture tree
# instead of /share/atlas_preview. Every assertion below is one that broken
# routing — not broken auth, which is out of scope here — would fail.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
snippet="$here/../atlas_preview_routes.caddy"
testfile="$here/atlas_preview_routes.test.Caddyfile"
fixtures="$here/fixtures/atlas_preview"

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need caddy; need curl; need lsof

# a free high port: ask the OS for one (bind :0), rather than guessing and
# hoping — this laptop runs plenty else.
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
export ATLAS_TEST_PORT=$port
export ATLAS_PREVIEW_ROOT=$fixtures
base="http://127.0.0.1:$port"

pid=""
cleanup() {
  [ -n "$pid" ] && kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" 2>/dev/null || true
}
trap cleanup EXIT

echo "validating $testfile (imports $snippet) ..."
caddy validate --config "$testfile" --adapter caddyfile
caddy adapt --config "$testfile" --adapter caddyfile > /dev/null
echo "adapt/validate OK"

caddy run --config "$testfile" --adapter caddyfile > /tmp/atlas_routes_local.caddy.log 2>&1 &
pid=$!
# confirm the port actually came up rather than a fixed sleep-and-hope
for _ in $(seq 1 20); do
  lsof -i ":$port" -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.25
done
lsof -i ":$port" -sTCP:LISTEN >/dev/null 2>&1 || { echo "caddy never bound :$port; log:"; cat /tmp/atlas_routes_local.caddy.log; exit 1; }

fails=0
say() { printf '  %-62s %s\n' "$1" "$2"; }
ok()  { say "$1" "ok"; }
bad() { say "$1" "FAIL: $2"; fails=$((fails+1)); }

body=$(mktemp)
trap 'cleanup; rm -f "$body"' EXIT

req() { # req <path> [curl args...] -> sets CODE LOC, body in $body
  local path=$1; shift
  local out
  out=$(curl -s -m 10 --path-as-is -o "$body" -w '%{http_code} %{redirect_url}' "$@" "$base$path")
  CODE=${out%% *}; LOC=${out#* }
}
jf() { grep -o "\"$1\"[[:space:]]*:[[:space:]]*[^,}]*" "$body" | head -1 | sed -E "s/.*:[[:space:]]*//; s/^\"//; s/\"$//"; } # jf <key> -> value from $body (bare string/bool/number)
hdr() { curl -s -m 10 --path-as-is -o /dev/null -D - "$@" "$base$1" | tr -d '\r'; } # hdr <path> [curl args...] -> headers

echo "atlas preview routes (local, routing-only) on $base"

req "/v9/atlas?lens=species&x=1"
[ "$CODE" = 308 ] && [ "$LOC" = "$base/v9/atlas/?lens=species&x=1" ] \
  && ok "/v9/atlas -> 308, Location keeps ?lens=species&x=1" \
  || bad "noslash redirect" "code=$CODE loc=$LOC"

req "/v9/atlas/"
cc=$(hdr "/v9/atlas/" | grep -i '^cache-control:' | sed 's/.*: //' || true) # a missing header must FAIL the assertion below, not kill the script (set -e)
if [ "$CODE" = 200 ] && grep -q FIXTURE_INDEX "$body" && [ "$cc" = "no-cache" ]; then
  ok "/v9/atlas/ -> 200 fixture index, Cache-Control: no-cache"
else
  bad "/v9/atlas/" "code=$CODE cache-control=$cc"
fi

req "/v9/atlas/assets/app.js"
[ "$CODE" = 200 ] && grep -q FIXTURE_APP_JS "$body" && ok "/v9/atlas/assets/app.js -> 200" || bad "assets/app.js" "code=$CODE"

req "/v9/atlas/session.json"
sc=$(hdr "/v9/atlas/session.json" | grep -i '^cache-control:' | sed 's/.*: //' || true) # ditto
if [ "$CODE" = 200 ] && [ "$(jf preview)" = true ] && [ "$(jf ver)" = v9 ] && [ "$sc" = no-store ] && ! grep -q FIXTURE_SESSION_FILE "$body"; then
  ok "/v9/atlas/session.json -> synthesized {preview:true,ver:v9}, no-store, NOT the fixture file"
else
  bad "/v9/atlas/session.json" "code=$CODE preview=$(jf preview) ver=$(jf ver) cache-control=$sc fixture-leaked=$(grep -c FIXTURE_SESSION_FILE "$body")"
fi

req "/v7b/atlas/session.json"
[ "$CODE" = 200 ] && [ "$(jf ver)" = v7b ] && ok "/v7b/atlas/session.json -> ver=v7b" || bad "v7b session.json" "code=$CODE ver=$(jf ver)"

req "/v9/atlas/session.json?ver=v8"
[ "$CODE" = 200 ] && [ "$(jf ver)" = v9 ] && ok "?ver=v8 query is INERT on /v9/atlas/session.json (ver=v9)" || bad "query override" "code=$CODE ver=$(jf ver)"

req "/v9/atlas/../../etc/passwd"
[ "$CODE" != 200 ] && ! grep -qi 'root:' "$body" && ok "literal .. traversal refused (code=$CODE, no passwd content)" || bad "traversal (literal ..)" "code=$CODE"

req "/v9/atlas/%2e%2e/%2e%2e/etc/passwd"
[ "$CODE" != 200 ] && ! grep -qi 'root:' "$body" && ok "encoded %2e%2e traversal refused (code=$CODE, no passwd content)" || bad "traversal (encoded)" "code=$CODE"

req "/vX/atlas/"
[ "$CODE" != 200 ] && ! grep -q FIXTURE "$body" && ok "/vX/atlas/ (no digits) not served by this block (code=$CODE)" || bad "/vX/atlas/" "code=$CODE"

req "/v9x9/atlas/"
[ "$CODE" != 200 ] && ! grep -q FIXTURE "$body" && ok "/v9x9/atlas/ (trailing digit) not served by this block (code=$CODE)" || bad "/v9x9/atlas/" "code=$CODE"

req "/v9/atlas/nope.html"
[ "$CODE" = 404 ] && ok "/v9/atlas/nope.html -> 404 (no SPA fallback)" || bad "nope.html" "code=$CODE"

if [ "$fails" -eq 0 ]; then echo "ATLAS_ROUTES_LOCAL_OK"; else echo "ATLAS_ROUTES_LOCAL_FAILED ($fails)"; exit 1; fi
