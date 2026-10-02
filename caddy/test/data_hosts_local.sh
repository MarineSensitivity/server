#!/usr/bin/env bash
# Local test of the crawler policy on the DATA hosts of caddy/Caddyfile -- the
# REAL text of the vhosts and snippets, cut out with awk, site addresses swapped
# for local ports, /share for a fixture dir, upstreams for a closed port (a 502
# from the proxy counts as "passed through"). Needs only homebrew caddy + curl.
#
# What it proves (2026-10-02 egress review), on titiler-v8 (a plain proxy host)
# and file (a host of sibling `handle` blocks, the case a bare `respond` misses):
#   - AI/SEO scraper User-Agents get 403, a browser UA and Claude-User do not;
#   - robots.txt says Disallow: / (and stays reachable for the bots);
#   - file still lets a bot read /stac/ and /branding/;
#   - every request is written to the vhost's access log.
#
# Seeded fault: DATA_HOSTS_CADDYFILE=<the pre-change Caddyfile> must FAIL.
#   git show HEAD:caddy/Caddyfile > /path/to/old.Caddyfile   # HEAD, before this change is committed
#   DATA_HOSTS_CADDYFILE=/path/to/old.Caddyfile caddy/test/data_hosts_local.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src="${DATA_HOSTS_CADDYFILE:-$here/../Caddyfile}"
need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need caddy; need curl; need python3; need awk

tmp=$(mktemp -d); pid=""
cleanup() { [ -n "$pid" ] && kill "$pid" >/dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT
freeport() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
p_ti=$(freeport); p_fi=$(freeport); p_dead=$(freeport)
ti="http://127.0.0.1:$p_ti"; fi="http://127.0.0.1:$p_fi"
r="$tmp/share"
mkdir -p "$r/logs/caddy" "$r/data/derived/stac" "$r/data/derived/v7" "$r/github/MarineSensitivity/server/branding" "$r/public"
printf '{"type":"Catalog"}' > "$r/data/derived/stac/catalog.json"
printf 'TIF'  > "$r/data/derived/v7/f.tif"
printf '<svg/>' > "$r/github/MarineSensitivity/server/branding/mark.svg"

# ---- the vhosts + the snippets they import, cut from the real Caddyfile --------------
cfg="$tmp/Caddyfile"
cut_block() { awk -v pat="$1" '$0==pat {p=1} p{print} p&&/^\}/{exit}' "$src"; }   # $1 = the exact opening line
{
  printf '{\n\tadmin off\n\tauto_https off\n}\n'
  for s in cors access_log robots_none no_ai_bots; do cut_block "($s) {"; done
  cut_block 'titiler-v8.marinesensitivity.org {'
  cut_block 'file.marinesensitivity.org {'
} | sed -e "s#^titiler-v8\.marinesensitivity\.org {#$ti {#" \
        -e "s#^file\.marinesensitivity\.org {#$fi {#" \
        -e "s#reverse_proxy titiler-v8:8000#reverse_proxy 127.0.0.1:$p_dead#" \
        -e "s#/share/#$r/#g" > "$cfg"
grep -q "^$ti {" "$cfg" && grep -q "^$fi {" "$cfg" || { echo "could not cut the vhosts out of $src" >&2; exit 1; }
caddy validate --config "$cfg" --adapter caddyfile >/dev/null 2>&1 || { caddy validate --config "$cfg" --adapter caddyfile; exit 1; }
caddy run --config "$cfg" --adapter caddyfile >"$tmp/caddy.out" 2>&1 & pid=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "$ti/robots.txt" && break; sleep 0.1; done

# ---- assertions ------------------------------------------------------------------------
fail=0
is() {  # is <label> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  ok   $1 ($3)"; else echo "  FAIL $1: expected '$2', got '$3'"; fail=1; fi
}
isnt() {  # isnt <label> <unwanted> <actual>
  if [ "$2" != "$3" ]; then echo "  ok   $1 ($3)"; else echo "  FAIL $1: got '$3'"; fail=1; fi
}
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
BOT='Mozilla/5.0 AppleWebKit/537.36 (compatible; GPTBot/1.2)'
BROWSER='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
CLAUDE_USER='Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; Claude-User/1.0; +Claude-User@anthropic.com)'

for h in "titiler-v8:$ti" "file:$fi"; do
  n=${h%%:*}; b=${h#*:}
  is    "$n: GPTBot -> 403"                 403 "$(code -A "$BOT" "$b/tiles/1/2/3.png")"
  is    "$n: lower-case gptbot -> 403"      403 "$(code -A 'gptbot/1.0' "$b/x")"
  is    "$n: ClaudeBot -> 403"              403 "$(code -A 'ClaudeBot/1.0' "$b/x")"
  is    "$n: AhrefsBot -> 403"              403 "$(code -A 'Mozilla/5.0 (compatible; AhrefsBot/7.0)' "$b/x")"
  isnt  "$n: browser UA is not 403"         403 "$(code -A "$BROWSER" "$b/x")"
  isnt  "$n: Claude-User is not 403"        403 "$(code -A "$CLAUDE_USER" "$b/x")"
  isnt  "$n: ChatGPT-User is not 403"       403 "$(code -A 'Mozilla/5.0 (compatible; ChatGPT-User/1.0)' "$b/x")"
  isnt  "$n: no User-Agent is not 403"      403 "$(code -H 'User-Agent:' "$b/x")"
  is    "$n: robots.txt 200"                200 "$(code -A "$BROWSER" "$b/robots.txt")"
  is    "$n: robots.txt says Disallow: /"   1   "$(curl -s -A "$BROWSER" "$b/robots.txt" | grep -c '^Disallow: /$')"
  is    "$n: robots.txt readable by a bot"  200 "$(code -A "$BOT" "$b/robots.txt")"
done
is   "titiler-v8: browser reaches the (dead) upstream -> 502" 502 "$(code -A "$BROWSER" "$ti/anything")"
is   "titiler-v8: robots.txt is exactly the two lines" "User-agent: *|Disallow: /" "$(curl -s "$ti/robots.txt" | paste -sd'|' -)"
# the file host: bots are refused on the data trees, welcome on the small browsable ones
is   "file: bot on /derived/ data -> 403"      403 "$(code -A "$BOT" "$fi/derived/v7/f.tif")"
is   "file: bot on /pmtiles/ data -> 403"      403 "$(code -A "$BOT" "$fi/pmtiles/v9/rng/a.pmtiles")"
is   "file: bot on / (public tree) -> 403"     403 "$(code -A "$BOT" "$fi/cog/c.tif")"
is   "file: bot on /stac/ is not blocked"      200 "$(code -A "$BOT" "$fi/stac/")"
is   "file: bot on /stac/catalog.json"         200 "$(code -A "$BOT" "$fi/stac/catalog.json")"
is   "file: bot on /branding/ is not blocked"  200 "$(code -A "$BOT" "$fi/branding/")"
is   "file: browser still gets the data file"  TIF "$(curl -s -A "$BROWSER" "$fi/derived/v7/f.tif")"
sleep 0.5
is   "titiler-v8: requests are logged"         1 "$( [ -s "$r/logs/caddy/titiler-v8.log" ] && echo 1 || echo 0)"
is   "file: requests are logged"               1 "$( [ -s "$r/logs/caddy/file.log" ] && echo 1 || echo 0)"
is   "log is JSON with the status"             1 "$(grep -c '"status":403' "$r/logs/caddy/titiler-v8.log" | sed 's/^[1-9][0-9]*$/1/')"

[ "$fail" = 0 ] && echo "DATA_HOSTS_OK" || { echo "DATA_HOSTS_FAILED"; exit 1; }
