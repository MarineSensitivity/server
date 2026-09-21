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
need caddy; need curl; need lsof; need python3

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

# --- Opus gate review of e6fdef5, finding 2: prove authentication sorts
# BEFORE every atlas route in the COMPILED route list, not just by reading the
# Caddyfile source (Caddy's directive sort reorders top-level directives by
# category, not by the order they are written — see the header comment on
# the no-slash redirect in atlas_preview_routes.caddy). This laptop has no
# jwtauth plugin, so `basic_auth` stands in: it occupies the exact same
# "authentication" handler slot jwtauth does, so the same proof carries over.
sortcad=$(mktemp); sortjson=$(mktemp)
# caddy-jwt's own README hash, reused here only as "some bcrypt hash caddy
# will accept" -- this config is adapted, never run.
cat > "$sortcad" <<CADDYEOF
{
	auto_https off
	admin off
}
:19999 {
	basic_auth {
		testuser \$2a\$14\$APmV/j/x/sUpbJQJy/7Gk.hy.l9d3.E5fEog9qJQaRXGks4AVHAye
	}
	import $snippet
}
CADDYEOF
if caddy adapt --config "$sortcad" --adapter caddyfile > "$sortjson" 2>/tmp/atlas_routes_local.sort.err; then
  if python3 - "$sortjson" <<'PYEOF'
import json, sys
routes = json.load(open(sys.argv[1]))["apps"]["http"]["servers"]["srv0"]["routes"]
auth_idx = next((i for i, r in enumerate(routes)
                  if "authentication" in [h.get("handler") for h in r.get("handle", [])]), None)
atlas_idxs = [i for i, r in enumerate(routes)
              for m in (r.get("match") or [])
              if (m.get("path_regexp") or {}).get("name") in ("van", "vatlas")]
if auth_idx is None:
    sys.exit("no authentication route found")
if not atlas_idxs:
    sys.exit("no atlas route found (van/vatlas matcher missing)")
early = [i for i in atlas_idxs if i <= auth_idx]
if early:
    sys.exit(f"authentication at index {auth_idx}, but atlas route(s) at {early} sort BEFORE or WITH it")
print(f"authentication at {auth_idx}; atlas routes at {sorted(atlas_idxs)} (all after)")
PYEOF
  then
    sort_ok=1
  else
    sort_ok=0
  fi
else
  sort_ok=0; echo "caddy adapt (sort check) failed:" >&2; cat /tmp/atlas_routes_local.sort.err >&2
fi
rm -f "$sortcad" "$sortjson"

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

if [ "$sort_ok" = 1 ]; then
  ok "directive sort: authentication (basic_auth stand-in) runs before every atlas route"
else
  bad "directive sort" "an atlas route can run before authentication (see stderr above)"
fi

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
keys_exact() { python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
sys.exit(0 if isinstance(d, dict) and sorted(d.keys()) == sorted(sys.argv[2].split()) else 1)
" "$body" "$1"; } # keys_exact "<space separated expected keys>" -> exit 0 iff $body's JSON has EXACTLY those keys
# a refusal must be a REAL response, never a curl failure (CODE=000/empty)
# masquerading as "not 200" -- see run.sh's same guard (Opus gate review,
# finding 4).
refused() { [ -n "$1" ] && [ "$1" != "000" ] && [ "$1" != 200 ]; }

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

# --- session.json: EXACTLY {preview, ver} -- no "user" (Opus gate review,
# finding 1: a raw claim interpolated into hand-built JSON could smuggle a
# "data" key, which a preview session's dataBase() would honor as the data
# origin). keys_exact fails the assertion outright if any THIRD key appears.
req "/v9/atlas/session.json"
sc=$(hdr "/v9/atlas/session.json" | grep -i '^cache-control:' | sed 's/.*: //' || true) # ditto
if [ "$CODE" = 200 ] && [ "$(jf preview)" = true ] && [ "$(jf ver)" = v9 ] && [ "$sc" = no-store ] \
   && keys_exact "preview ver" && ! grep -q FIXTURE_SESSION_FILE "$body"; then
  ok "/v9/atlas/session.json -> EXACTLY {preview:true,ver:v9}, no-store, NOT the fixture file"
else
  bad "/v9/atlas/session.json" "code=$CODE preview=$(jf preview) ver=$(jf ver) cache-control=$sc fixture-leaked=$(grep -c FIXTURE_SESSION_FILE "$body")"
fi

req "/v7b/atlas/session.json"
[ "$CODE" = 200 ] && [ "$(jf ver)" = v7b ] && ok "/v7b/atlas/session.json -> ver=v7b" || bad "v7b session.json" "code=$CODE ver=$(jf ver)"

req "/v9/atlas/session.json?ver=v8"
[ "$CODE" = 200 ] && [ "$(jf ver)" = v9 ] && ok "?ver=v8 query is INERT on /v9/atlas/session.json (ver=v9)" || bad "query override" "code=$CODE ver=$(jf ver)"

req "/v9/atlas/../../etc/passwd"
refused "$CODE" && ! grep -qi 'root:' "$body" && ok "literal .. traversal refused (code=$CODE, no passwd content)" || bad "traversal (literal ..)" "code=$CODE"

req "/v9/atlas/%2e%2e/%2e%2e/etc/passwd"
refused "$CODE" && ! grep -qi 'root:' "$body" && ok "encoded %2e%2e traversal refused (code=$CODE, no passwd content)" || bad "traversal (encoded)" "code=$CODE"

req "/v9/atlas/%252e%252e/%252e%252e/etc/passwd"
refused "$CODE" && ! grep -qi 'root:' "$body" && ok "double-encoded %252e%252e refused, no double-decode (code=$CODE)" || bad "traversal (double-encoded)" "code=$CODE"

req "/v9/atlas/..%2f..%2fetc/passwd"
refused "$CODE" && ! grep -qi 'root:' "$body" && ok "..%2f (encoded slash) traversal refused (code=$CODE)" || bad "traversal (..%2f)" "code=$CODE"

req "/vX/atlas/"
refused "$CODE" && ! grep -q FIXTURE "$body" && ok "/vX/atlas/ (no digits) not served by this block (code=$CODE)" || bad "/vX/atlas/" "code=$CODE"

req "/v9x9/atlas/"
refused "$CODE" && ! grep -q FIXTURE "$body" && ok "/v9x9/atlas/ (trailing digit) not served by this block (code=$CODE)" || bad "/v9x9/atlas/" "code=$CODE"

req "/V9/atlas/"
refused "$CODE" && ! grep -q FIXTURE "$body" && ok "/V9/atlas/ (uppercase V) not served by this block (code=$CODE)" || bad "/V9/atlas/" "code=$CODE"

req "/v9/atlas/nope.html"
[ "$CODE" = 404 ] && ok "/v9/atlas/nope.html -> 404 (no SPA fallback)" || bad "nope.html" "code=$CODE"

# --- Opus gate review, finding 3: case variants of session.json. On this
# macOS/APFS filesystem (case-insensitive, case-preserving) these spellings
# would resolve to the real fixture file via file_server if the exact,
# case-sensitive matcher were the only guard -- @atlas_session_anycase must
# refuse them outright, never falling through.
for variant in SESSION.JSON Session.Json session.JSON session.json.; do
  req "/v9/atlas/$variant"
  refused "$CODE" && ! grep -q FIXTURE_SESSION_FILE "$body" \
    && ok "/v9/atlas/$variant -> refused (code=$CODE), never the fixture file" \
    || bad "case/dot variant: $variant" "code=$CODE fixture-leaked=$(grep -c FIXTURE_SESSION_FILE "$body")"
done

# --- reviewer probes: spellings that Caddy's own path matcher NORMALIZES
# (decodes once, cleans dot-segments) to the exact canonical path before
# testing -- these must still reach the SYNTHESIZED body, not 404 and not
# the fixture file, proving the exact matcher's normalization is doing the
# same job for a legitimate reviewer's odd-but-equivalent URL as it does for
# an attacker's traversal attempt above.
for probe in "//session.json" "%73ession.json" "./session.json" "a/../session.json"; do
  req "/v9/atlas/$probe"
  [ "$CODE" = 200 ] && [ "$(jf ver)" = v9 ] && [ "$(jf preview)" = true ] && ! grep -q FIXTURE_SESSION_FILE "$body" \
    && ok "/v9/atlas/$probe -> normalizes to session.json, ver=v9" \
    || bad "reviewer probe: $probe" "code=$CODE ver=$(jf ver)"
done

req "/v9/atlas/session.json/"
! grep -q FIXTURE_SESSION_FILE "$body" && ok "/v9/atlas/session.json/ (trailing slash) -> not the fixture (code=$CODE)" || bad "session.json/" "code=$CODE fixture-leaked=$(grep -c FIXTURE_SESSION_FILE "$body")"

if [ "$fails" -eq 0 ]; then echo "ATLAS_ROUTES_LOCAL_OK"; else echo "ATLAS_ROUTES_LOCAL_FAILED ($fails)"; exit 1; fi
