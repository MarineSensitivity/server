#!/usr/bin/env bash
# Functional test of caddy/preview_routes.caddy — RUN ON THE SERVER (release
# notebook DEPLOY_CADDY does, after the restart; or by hand: caddy/test/run.sh).
#
# Starts a throwaway HTTP-only caddy from the SAME image with the SAME routes
# file, but a TEST HS256 jwtauth (caddy-jwt's README key; the token below is
# valid until 2285, iss https://api.example.com, aud https://api.example.io,
# username ggicci) so the routes can be exercised without Cloudflare. It joins
# the compose network, so rstudio:3839 (the preview Shiny Server instance) is
# reachable and the app really answers. Every assertion is one a broken routing
# would fail: 401 without a token; /v8/scores/ renders v8 (ms-ver) with
# ms-preview=1 and the test identity in the badge; ?ver=v7 on that path is
# OVERRIDDEN; the sockjs path proxies; the pre-path spelling redirects and is
# never proxied; docs and landing serve.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
net=${COMPOSE_NET:-server_default}
img=${CADDY_IMAGE:-server-caddy}
curl_img=${CURL_IMAGE:-curlimages/curl:8.14.1}
name=caddy-routes-test-$$
ver=${TEST_VER:-v8}     # any version the preview instance can render (public or restricted)
TOKEN=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjk5NTU4OTI2NzAsImp0aSI6IjgyMjk0YTYzLTk2NjAtNGM2Mi1hOGE4LTVhNjI2NWVmY2Q0ZSIsInN1YiI6IjM0MDYzMjc5NjM1MTY5MzIiLCJpc3MiOiJodHRwczovL2FwaS5leGFtcGxlLmNvbSIsImF1ZCI6WyJodHRwczovL2FwaS5leGFtcGxlLmlvIl0sInVzZXJuYW1lIjoiZ2dpY2NpIn0.O8kvRO9y6xQO3AymqdFE7DDqLRBQhkntf78O9kF71F8

cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --name "$name" --network "$net" \
  -v "$repo/caddy/preview_routes.caddy:/etc/caddy/preview_routes.caddy:ro" \
  -v "$here/preview_routes.test.Caddyfile:/etc/caddy/Caddyfile:ro" \
  -v "$repo/caddy/preview:/share/github/MarineSensitivity/server/caddy/preview:ro" \
  -v /share/docs_preview:/share/docs_preview:ro \
  "$img" caddy run --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
sleep 3

fails=0
say() { printf '  %-58s %s\n' "$1" "$2"; }
ok()  { say "$1" "ok"; }
bad() { say "$1" "FAIL: $2"; fails=$((fails+1)); }

# curl through the throwaway caddy: prints "<code> <redirect_url>" and stores the body
body=$(mktemp); chmod 666 "$body"; trap 'cleanup; rm -f "$body"' EXIT   # curl runs as uid 100 in its image
req() { # req <path> [curl args...] -> sets CODE LOC and $body
  local path=$1; shift
  local out
  out=$(docker run --rm --network "$net" -v "$body:/body" "$curl_img" \
        -s -m 90 -o /body -w '%{http_code} %{redirect_url}' "$@" "http://$name:8080$path")
  CODE=${out%% *}; LOC=${out#* }
}
auth=(-H "Cf-Access-Jwt-Assertion: $TOKEN")
meta() { grep -o "<meta name=\"$1\" content=\"[^\"]*\"" "$body" | sed 's/.*content="//; s/"$//' | head -1; }

echo "preview routes test via $name ($img on $net), version $ver"

req "/$ver/scores/";                            [ "$CODE" = 401 ] && ok "no token -> 401" || bad "no token" "$CODE"
req "/";                                        [ "$CODE" = 401 ] && ok "landing without token -> 401" || bad "landing no token" "$CODE"

req "/$ver/scores/" "${auth[@]}"
if [ "$CODE" = 200 ] && [ "$(meta ms-ver)" = "$ver" ] && [ "$(meta ms-preview)" = 1 ]; then ok "/$ver/scores/ -> app, ms-ver=$ver, ms-preview=1"; else bad "/$ver/scores/" "code=$CODE ms-ver=$(meta ms-ver) ms-preview=$(meta ms-preview)"; fi
grep -q "ggicci" "$body" && ok "X-MS-User from the verified claim reaches the badge" || bad "X-MS-User" "identity not in page"

req "/$ver/scores/?ver=v7&probe=1" "${auth[@]}"
[ "$CODE" = 200 ] && [ "$(meta ms-ver)" = "$ver" ] && ok "a client's ?ver=v7 is INERT on /$ver/ (ms-ver=$ver)" || bad "ver override" "code=$CODE ms-ver=$(meta ms-ver)"

req "/$ver/species/" "${auth[@]}"
[ "$CODE" = 200 ] && [ "$(meta ms-ver)" = "$ver" ] && ok "/$ver/species/ -> app, ms-ver=$ver" || bad "/$ver/species/" "code=$CODE ms-ver=$(meta ms-ver)"

req "/$ver/scores/__sockjs__/info" "${auth[@]}"
[ "$CODE" = 200 ] && grep -q websocket "$body" && ok "sockjs info proxies under the version prefix" || bad "sockjs" "code=$CODE"

req "/$ver/scores/shared/shiny.min.js" "${auth[@]}"
[ "$CODE" = 200 ] && ok "static assets proxy under the version prefix" || bad "assets" "code=$CODE"

# REGRESSION (2026-08-27): shiny-server serves its own client bundle from a
# handler that 404s if the request carries ANY query string, so forcing ?ver=
# on subresources broke the app -- sidebar rendered, map stuck on "Loading
# map...", because preShinyInit was never defined. `shared/` above does NOT
# catch this: it tolerates a query. These two do.
for a in __assets__/shiny-server-client.min.js __assets__/sockjs.min.js; do
  req "/$ver/scores/$a" "${auth[@]}"
  [ "$CODE" = 200 ] && ok "shiny-server client bundle: $a" || bad "$a" "code=$CODE (query forced onto a subresource?)"
done

req "/$ver/scores" "${auth[@]}"
[ "$CODE" = 308 ] && [ "${LOC%\?*}" = "http://$name:8080/$ver/scores/" ] && ok "/$ver/scores -> 308 /$ver/scores/" || bad "noslash redirect" "code=$CODE loc=$LOC"

req "/scores/?ver=$ver" "${auth[@]}"
[ "$CODE" = 302 ] && [ "$LOC" = "http://$name:8080/$ver/scores/" ] && ok "/scores/?ver=$ver -> 302 /$ver/scores/ (never proxied)" || bad "query->path redirect" "code=$CODE loc=$LOC"

req "/species?ver=$ver" "${auth[@]}"
[ "$CODE" = 302 ] && [ "$LOC" = "http://$name:8080/$ver/species/" ] && ok "/species?ver=$ver -> 302 /$ver/species/" || bad "query->path redirect (noslash)" "code=$CODE loc=$LOC"

req "/scores/" "${auth[@]}"
[ "$CODE" = 302 ] && [ "$LOC" = "http://$name:8080/" ] && ok "/scores/ without ver -> 302 / (never proxied)" || bad "unversioned app path" "code=$CODE loc=$LOC"

req "/" "${auth[@]}"
[ "$CODE" = 200 ] && grep -q PREVIEW "$body" && ok "landing page serves" || bad "landing" "code=$CODE"

req "/docs/" "${auth[@]}"
[ "$CODE" = 200 ] && ok "/docs/ serves the gh-pages-preview clone" || bad "docs" "code=$CODE"

docker run --rm --network "$net" "$curl_img" -s -m 30 -o /dev/null -D - "${auth[@]}" "http://$name:8080/" | grep -qi "x-robots-tag: noindex" && ok "X-Robots-Tag noindex" || bad "X-Robots-Tag" "missing"

if [ "$fails" -eq 0 ]; then echo "PREVIEW_ROUTES_OK"; else echo "PREVIEW_ROUTES_FAILED ($fails)"; exit 1; fi
