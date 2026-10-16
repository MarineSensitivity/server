#!/usr/bin/env bash
# Local test of the ATLAS CUTOVER (B2) redirects -- for a laptop with homebrew caddy but
# WITHOUT the jwtauth plugin, Docker or Go (same constraints as atlas_routes_local.sh).
#
# It runs the REAL files, not copies of their rules:
#   * public host: the real `app.marinesensitivity.org` vhost lifted out of caddy/Caddyfile
#     (so its `import atlas_cutover_public.caddy` / `import app_version_routes.caddy` and
#     the order between them are what production runs), with PREVIEW_RESTRICTED_VERSIONS
#     set to v7b|v7c|v8|v9 and only the access-log line (a /share path) removed;
#   * preview host: the real caddy/preview_routes.caddy behind a basic_auth stand-in for
#     jwtauth -- basic_auth occupies the same `authentication` slot, which is what the
#     directive-sort proof needs (see atlas_routes_local.sh).
# Then atlas_cutover_matrix.py sends every URL shape, public and preview, with and without
# a query, and asserts status, Location (exact), where the chain ends and that it takes
# <= 2 hops. The Shiny upstream does not exist here: a request that would reach it answers
# 502, which the matrix reads as "not redirected".
#
# NOT proven here (stays with caddy/test/run.sh on the server, and CHECK_PREVIEW): the real
# jwtauth/Cloudflare gate, and the live Shiny worker.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
caddydir=$(cd "$here/.." && pwd)
need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need caddy; need python3; need lsof

work=$(mktemp -d)
pids=""
cleanup() {
  for p in $pids; do kill "$p" >/dev/null 2>&1 || true; wait "$p" 2>/dev/null || true; done
  rm -rf "$work"
}
trap cleanup EXIT

freeport() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
pub_port=$(freeport); prev_port=$(freeport)
while [ "$prev_port" = "$pub_port" ]; do prev_port=$(freeport); done

export PREVIEW_RESTRICTED_VERSIONS='v7b|v7c|v8|v9'
export ATLAS_PREVIEW_ROOT="$here/fixtures/atlas_preview"

# --- public: the real vhosts that proxy the public Shiny Server, each lifted out of the
# Caddyfile into a temp dir that symlinks the real snippets: app.marinesensitivity.org plus
# shiny.marinesensitivity.org and shiny.oceanmetrics.io (the same :3838 server, so scores and
# species were reachable there too and must redirect as well) ---------------------------------
ln -s "$caddydir/atlas_cutover_public.caddy" "$work/atlas_cutover_public.caddy"
ln -s "$caddydir/app_version_routes.caddy"   "$work/app_version_routes.caddy"
lift() { # lift <vhost address> <port> -> a standalone Caddyfile "$work/<address>.Caddyfile"
  awk -v site="$1" -v port="$2" '
    $0 == site " {" {print ":" port " {"; inside=1; next}
    inside && /^\}$/ {print; exit}
    inside && /^\timport access_log / {next}
    inside {print}
  ' "$caddydir/Caddyfile" > "$work/$1.part"
  [ -s "$work/$1.part" ] || { echo "could not lift the $1 vhost out of the Caddyfile" >&2; exit 1; }
  { printf '{\n\tauto_https off\n\tadmin off\n}\n'; cat "$work/$1.part"; } > "$work/$1.Caddyfile"
}
shiny_port=$(freeport); oceanshiny_port=$(freeport)
lift app.marinesensitivity.org   "$pub_port"
lift shiny.marinesensitivity.org "$shiny_port"
lift shiny.oceanmetrics.io       "$oceanshiny_port"
cp "$work/app.marinesensitivity.org.Caddyfile" "$work/public.Caddyfile"

# --- preview: the real routes behind a basic_auth stand-in for jwtauth ----------------
pw=cutover-test-pw
hash=$(caddy hash-password --plaintext "$pw")
cat > "$work/preview.Caddyfile" <<EOF
{
	auto_https off
	admin off
}
:$prev_port {
	basic_auth {
		reviewer $hash
	}
	import $caddydir/preview_routes.caddy
}
EOF

echo "validating the adapted configs ..."
for site in app.marinesensitivity.org shiny.marinesensitivity.org shiny.oceanmetrics.io; do
  caddy validate --config "$work/$site.Caddyfile" --adapter caddyfile >/dev/null 2>"$work/err" || { cat "$work/err"; exit 1; }
done
caddy validate --config "$work/preview.Caddyfile" --adapter caddyfile >/dev/null 2>"$work/err" || { cat "$work/err"; exit 1; }
# the real, whole Caddyfile (minus the plugin vhosts) must still adapt too
bash "$here/caddyfile_adapt_local.sh" | tail -1 | grep -q ADAPT_OK || { echo "caddyfile_adapt_local.sh failed"; exit 1; }
echo "adapt/validate OK"

fails=0
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails+1)); }

# --- no redirect on the preview host may answer BEFORE authentication ------------------
# Walk the compiled route tree in execution order (matchers ignored: the worst case, the
# request satisfies everything) and require that no `static_response` -- what redir and
# respond compile to -- appears before the `authentication` handler. `headers` before it
# is fine (the X-Robots-Tag line; it answers nothing).
caddy adapt --config "$work/preview.Caddyfile" --adapter caddyfile > "$work/preview.json" 2>/dev/null
if python3 - "$work/preview.json" <<'PYEOF'
import json, sys

def flatten(routes):
    for r in routes:
        for h in r.get("handle", []):
            if h.get("handler") == "subroute":
                yield from flatten(h.get("routes", []))
            else:
                yield h.get("handler")

routes = json.load(open(sys.argv[1]))["apps"]["http"]["servers"]["srv0"]["routes"]
seq = list(flatten(routes))
if "authentication" not in seq:
    sys.exit("no authentication handler in the compiled preview routes: %s" % seq)
before = seq[:seq.index("authentication")]
bare = [h for h in before if h not in ("headers", "vars")]
if bare:
    sys.exit("handler(s) %s run BEFORE authentication -- a redirect/respond can answer an unauthenticated request" % bare)
print("authentication runs before every redirect/respond of preview_routes.caddy (%d handlers walked)" % len(seq))
PYEOF
then echo "  ok   directive sort"; else bad "directive sort: a preview redirect can answer before authentication"; fi

start() { # start <config> <port> <logname>
  caddy run --config "$1" --adapter caddyfile > "$work/$3.log" 2>&1 &
  pids="$pids $!"
  for _ in $(seq 1 40); do lsof -i ":$2" -sTCP:LISTEN >/dev/null 2>&1 && return 0; sleep 0.25; done
  echo "caddy never bound :$2:"; cat "$work/$3.log"; exit 1
}
start "$work/app.marinesensitivity.org.Caddyfile"   "$pub_port"         public
start "$work/shiny.marinesensitivity.org.Caddyfile" "$shiny_port"       shiny
start "$work/shiny.oceanmetrics.io.Caddyfile"       "$oceanshiny_port"  oceanshiny
start "$work/preview.Caddyfile" "$prev_port" preview

echo "redirect matrix (app :$pub_port, shiny.ms :$shiny_port, shiny.om :$oceanshiny_port, preview :$prev_port)"
python3 "$here/atlas_cutover_matrix.py" "$pub_port" "$prev_port" "reviewer:$pw" "$shiny_port" "$oceanshiny_port" || fails=$((fails+1))

if [ "$fails" -eq 0 ]; then echo "ATLAS_CUTOVER_LOCAL_OK"; else echo "ATLAS_CUTOVER_LOCAL_FAILED ($fails)"; exit 1; fi
