#!/usr/bin/env bash
# Snapshot the public DNS answers for every hostname this server fronts, plus
# the zone's apex/mail records, so the nameserver move to Cloudflare (Phase 1 of
# workflows/.claude/plans/2026-08-15 pre-release review gate …) can be PROVED
# lossless: run before, run after propagation, diff the two files.
#
#   ./dns_snapshot.sh > dns_before.txt      # at Squarespace
#   (move NS, wait)                          #
#   ./dns_snapshot.sh > dns_after.txt       # at Cloudflare
#   diff dns_before.txt dns_after.txt       # ONLY `preview` may differ (proxied)
#
# The hostname list is derived from caddy/Caddyfile's site labels, so it cannot
# drift from what is actually served — but it is NOT the source of truth for the
# zone: mail (MX/SPF/DKIM/DMARC), verification TXTs and anything not routed by
# Caddy live only in the Squarespace panel. Copy those from the panel; this
# script only checks the ones it can name (apex, www, MX, TXT, and every Caddy
# vhost).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
caddyfile=${1:-"$here/../caddy/Caddyfile"}
zone=marinesensitivity.org
resolver=${RESOLVER:-1.1.1.1}

q() { # q <name> <type>
  local ans
  ans=$(dig +short @"$resolver" "$1" "$2" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')
  printf '%-40s %-5s %s\n' "$1" "$2" "${ans:-<none>}"
}

echo "# dns snapshot of $zone via $resolver — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
q "$zone" A;   q "$zone" AAAA;  q "$zone" NS;  q "$zone" MX;  q "$zone" TXT;  q "$zone" CAA
q "www.$zone" A;  q "www.$zone" CNAME
# the wildcard: every otherwise-unnamed subdomain lands on this server today
q "*.$zone" A;    q "*.$zone" CNAME
q "_dmarc.$zone" TXT
# every site label in the Caddyfile that belongs to this zone
grep -oE '^[a-z0-9.-]+\.'"$zone"'[[:space:]]*\{' "$caddyfile" | sed 's/[[:space:]]*{//' | sort -u \
  | while read -r h; do q "$h" A; q "$h" CNAME; done
