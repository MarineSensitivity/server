#!/usr/bin/env bash
# Whole-file sanity for caddy/Caddyfile. The production image has two plugins
# (pmtiles_proxy, jwtauth) that homebrew caddy lacks, so the full file cannot be
# adapted locally: this strips what needs them -- the global options block, the
# `preview` vhost, the `pmtiles` vhost, the erddap import -- substitutes the env
# placeholders and runs `caddy adapt` on the rest. It also checks `caddy fmt`
# would not change the file and that every vhost carries an access log.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src="${ADAPT_CADDYFILE:-$here/../Caddyfile}"
command -v caddy >/dev/null || { echo "missing: caddy" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# drop: the leading global block, the preview + pmtiles vhosts (top-level blocks
# start in column 0 and end at a lone "}"), and the erddap import line
awk '
  NR==1 && /^#/ {next}
  !seen_first && /^\{$/ {skip=1}
  skip {if ($0=="}") {skip=0; seen_first=1}; next}
  /^(preview|pmtiles)\.marinesensitivity\.org \{/ {skip=1; next}
  /^import .*Caddyfile\.erddap/ {next}
  {print}
' "$src" \
  | sed -e 's/{\$PREVIEW_RESTRICTED_VERSIONS:__none__}/v8|v9/' \
        -e "s#/share/#$tmp/share/#g" \
  > "$tmp/Caddyfile"
mkdir -p "$tmp/share/logs/caddy"
cp "$here/../app_version_routes.caddy" "$tmp/"   # relative import, plain directives only
caddy adapt --config "$tmp/Caddyfile" --adapter caddyfile --validate >"$tmp/out.json" 2>"$tmp/err" \
  || { cat "$tmp/err"; echo "ADAPT_FAILED"; exit 1; }
echo "  ok   adapts + validates ($(grep -o '"host"' "$tmp/out.json" | wc -l | tr -d ' ') host matchers; preview/pmtiles/erddap stripped)"

# every vhost imports access_log (stripped ones are checked on the real file)
n_sites=$(grep -cE '^[A-Za-z0-9].* \{$' "$src")   # snippets start with "(" and are not counted
n_logs=$(grep -cE '^\s+import access_log [a-z0-9-]+$' "$src")
[ "$n_sites" = "$n_logs" ] || { echo "  FAIL $n_sites vhosts but $n_logs access_log imports"; echo "ADAPT_FAILED"; exit 1; }
echo "  ok   every vhost imports access_log ($n_logs of $n_sites)"
dup=$(grep -E '^\s+import access_log ' "$src" | sort | uniq -d | head -1)
[ -z "$dup" ] || { echo "  FAIL duplicate log name: $dup"; echo "ADAPT_FAILED"; exit 1; }

# fmt must be a no-op (tabs, as the file is written)
if caddy fmt --diff "$src" | grep -qE '^[-+]'; then caddy fmt --diff "$src" | grep -E '^[-+]'; echo "ADAPT_FAILED"; exit 1; fi
echo "  ok   caddy fmt --diff is empty"
echo "ADAPT_OK"
