#!/usr/bin/env bash
# access.sh — create/update the Cloudflare Access applications that gate
# preview.marinesensitivity.org, one per RESTRICTED release, from the published
# version registry. Idempotent: run it again after flipping a release's `access`
# and it converges (creates what is missing, updates what drifted, and reports
# what it left alone).
#
#   ./access.sh --dry-run     # print every API call it WOULD make; no credentials needed
#   ./access.sh               # apply
#   ./access.sh --rotate NAME # mint a NEW secret for an existing service token
#                             # (Cloudflare returns a token's secret exactly once,
#                             #  so this is the recovery when one is lost)
#
# WHY PER VERSION: Cloudflare Access scopes an application by hostname + PATH
# (never by query string), and the more specific path wins while unmatched
# subpaths inherit the parent. So the preview host serves each release under its
# own path -- /v9/scores/, /v9/species/, /docs/v9/ (server/caddy/preview_routes.caddy)
# -- and each restricted release gets its own application + reviewer policy.
# A v9 reviewer then cannot open v10, which one host-wide application could not
# express. Path precedence also means the catch-all application below covers
# everything that has no version-specific application of its own.
#
# WHAT IT CREATES (names are the idempotency key -- do not rename by hand):
#   policy  "preview admins"                allow, include: emails in PREVIEW_ADMINS
#   policy  "preview {ver} reviewers"       allow, include: emails in PREVIEW_REVIEWERS_{VER}
#                                           (falls back to PREVIEW_ADMINS)
#   policy  "preview service check"         non_identity, include: the shared check token
#   policy  "preview service probe {ver}"   non_identity, include: that version's probe token
#   app     "preview (catch-all)"           preview.marinesensitivity.org
#   app     "preview {ver} apps"            preview.marinesensitivity.org/{ver}
#   app     "preview {ver} docs"            preview.marinesensitivity.org/docs/{ver}
#   token   "msens-preview-check"           reaches EVERY app (the release notebook's CHECK_PREVIEW)
#   token   "msens-preview-probe-{ver}"     reaches ONLY that version (proves the isolation)
#   cache rule "bypass cache: {host}"       so no edge copy of an app asset outlives a deploy
#
# ENV (server .env; see README.md):
#   CF_API_TOKEN            required. Account: Access: Apps and Policies Write,
#                           Access: Organizations, Identity Providers, and Groups Read,
#                           Access: Service Tokens Write; Zone: Cache Rules Edit (for the
#                           cache rule; omit CF_ZONE_ID to skip it)
#   CF_ACCOUNT_ID           required
#   CF_ZONE_ID              optional; enables the cache-bypass rule
#   PREVIEW_HOST            default preview.marinesensitivity.org
#   PREVIEW_ADMINS          comma-separated emails; the catch-all policy
#   PREVIEW_REVIEWERS_V8    comma-separated emails allowed on v8 (per version; V4B for v4b)
#   VERSIONS_URL            default the published marine-atlas versions.json
#   SECRETS_OUT             where new service-token secrets are written (default
#                           /share/private/preview_access.env when that directory exists)
#   PREVIEW_ORG_NAME        what the LOGIN PAGE calls this organisation (default
#                           "BOEM Marine Sensitivity Toolkit"). A fresh Zero Trust org
#                           is named after its generated subdomain, so reviewers were
#                           greeted by "steep-bonus-bf70.cloudflareaccess.com".
#   PREVIEW_LOGIN_LOGO      absolute URL of a logo for the login page (optional)
#   PREVIEW_LOGIN_FOOTER    footer text. The default explains what Cloudflare's own
#                           wording cannot: a one-time PIN is sent ONLY to an invited
#                           address, and the page says "a code has been emailed" either
#                           way -- by design, so the allow-list cannot be probed.
set -euo pipefail

API=https://api.cloudflare.com/client/v4
host=${PREVIEW_HOST:-preview.marinesensitivity.org}
versions_url=${VERSIONS_URL:-https://s3.us-east-1.amazonaws.com/oceanmetrics.io-public/marine-atlas/versions.json}
dry=0; rotate=""
case "${1:-}" in
  --dry-run) dry=1 ;;
  --rotate)  rotate=${2:?--rotate needs a service-token name} ;;
  "")        ;;
  *)         echo "unknown argument: $1 (see the header of this script)" >&2; exit 2 ;;
esac

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need curl; need jq

if [ "$dry" = 0 ]; then
  : "${CF_API_TOKEN:?set CF_API_TOKEN (see README.md)}"
  : "${CF_ACCOUNT_ID:?set CF_ACCOUNT_ID (see README.md)}"
else
  # a dry run must work with no credentials at all -- that is the point
  CF_API_TOKEN=${CF_API_TOKEN:-dry}; CF_ACCOUNT_ID=${CF_ACCOUNT_ID:-DRY}
fi

# cf <METHOD> <PATH> [JSON] -> the `result` object, or exits with the API's errors.
# A Cloudflare 200 can still carry "success": false, so the payload is checked, not the status.
cf() {
  local method=$1 path=$2 data=${3:-}
  if [ "$dry" = 1 ]; then
    echo "    [dry-run] $method $path${data:+ $(echo "$data" | jq -c .)}" >&2
    echo '{"dry_run":true}'
    return 0
  fi
  local out
  if [ -n "$data" ]; then
    out=$(curl -sS -m 60 --request "$method" "$API$path" \
      -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" --data "$data")
  else
    out=$(curl -sS -m 60 --request "$method" "$API$path" -H "Authorization: Bearer $CF_API_TOKEN")
  fi
  if [ "$(echo "$out" | jq -r '.success // false')" != "true" ]; then
    echo "API $method $path failed:" >&2
    echo "$out" | jq -r '.errors // . | tostring' >&2
    exit 1
  fi
  echo "$out" | jq -c '.result'
}

# same, but a failed request returns non-zero instead of ending the run --
# for calls whose failure is a legitimate state (see the cache ruleset below)
cf_try() {
  local method=$1 path=$2 data=${3:-} out
  [ "$dry" = 1 ] && { echo "    [dry-run] $method $path" >&2; echo '{}'; return 0; }
  if [ -n "$data" ]; then
    out=$(curl -sS -m 60 --request "$method" "$API$path" \
      -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" --data "$data")
  else
    out=$(curl -sS -m 60 --request "$method" "$API$path" -H "Authorization: Bearer $CF_API_TOKEN")
  fi
  if [ "$(echo "$out" | jq -r '.success // false')" != "true" ]; then
    echo "$out" | jq -c '.errors' >&2
    return 1
  fi
  echo "$out" | jq -c '.result'
}

# ---- inputs ----------------------------------------------------------------
emails_json() {   # "a@b, c@d" -> [{"email":{"email":"a@b"}}, ...]
  echo "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' \
    | jq -R '{email: {email: .}}' | jq -s '.'
}
ver_env() {       # v4b -> PREVIEW_REVIEWERS_V4B
  echo "PREVIEW_REVIEWERS_$(echo "$1" | tr '[:lower:]' '[:upper:]')"
}

admins=${PREVIEW_ADMINS:-}
if [ -z "$admins" ]; then
  echo "PREVIEW_ADMINS is empty: the catch-all application would let nobody in." >&2
  echo "Set it in .env (comma-separated emails) and re-run." >&2
  [ "$dry" = 1 ] || exit 1
  admins="you@example.org"
fi

echo "registry: $versions_url"
vjson=$(curl -sSf -m 60 "$versions_url")
echo "$vjson" | jq -e '.versions | length > 0' > /dev/null   # payload, not exit status
restricted=$(echo "$vjson" | jq -r '.versions[]
  | (.access // (if .status == "prerelease" then "restricted" else "public" end)) as $a
  | select($a == "restricted") | .ver')
# RESTRICTED_OVERRIDE exists for --dry-run: see what Phase 2 will create before
# flipping a release. It must never override a real run.
if [ -n "${RESTRICTED_OVERRIDE:-}" ] && [ "$dry" = 1 ]; then restricted=$RESTRICTED_OVERRIDE; fi
echo "host: $host"
echo "restricted versions: ${restricted:-<none>}"
echo

# ---- helpers: idempotent upserts by NAME -----------------------------------
policies=$(cf GET "/accounts/$CF_ACCOUNT_ID/access/policies" || echo '[]')
apps=$(cf GET "/accounts/$CF_ACCOUNT_ID/access/apps" || echo '[]')
tokens=$(cf GET "/accounts/$CF_ACCOUNT_ID/access/service_tokens" || echo '[]')
by_name() { echo "$1" | jq -r --arg n "$2" '(if type == "array" then . else [] end) | map(select(.name == $n)) | .[0].id // empty'; }

upsert_policy() {  # <name> <decision> <include-json> -> policy id
  local name=$1 decision=$2 include=$3 id body
  id=$(by_name "$policies" "$name")
  body=$(jq -n --arg n "$name" --arg d "$decision" --argjson inc "$include" \
    '{name: $n, decision: $d, include: $inc}')
  if [ -n "$id" ]; then
    cf PUT "/accounts/$CF_ACCOUNT_ID/access/policies/$id" "$body" > /dev/null
    echo "  policy  $name (updated)" >&2
  else
    id=$(cf POST "/accounts/$CF_ACCOUNT_ID/access/policies" "$body" | jq -r '.id // "dry-policy"')
    echo "  policy  $name (created)" >&2
  fi
  echo "$id"
}

upsert_app() {     # <name> <domain> <policy-id...> -> "aud"
  local name=$1 domain=$2; shift 2
  local id body pol aud
  pol=$(printf '%s\n' "$@" | jq -R . | jq -s '.')
  id=$(by_name "$apps" "$name")
  body=$(jq -n --arg n "$name" --arg d "$domain" --argjson p "$pol" '{
    name: $n, type: "self_hosted", domain: $d, policies: $p,
    session_duration: "24h",
    # the landing page and the version paths are all a human navigates to; the
    # app launcher would list them to people who cannot open them
    app_launcher_visible: false,
    # every enabled IdP (one-time PIN + anything added later) may be used
    allowed_idps: [], auto_redirect_to_identity: false
  }')
  if [ -n "$id" ]; then
    aud=$(cf PUT "/accounts/$CF_ACCOUNT_ID/access/apps/$id" "$body" | jq -r '.aud // "dry-aud"')
    echo "  app     $name -> $domain (updated)" >&2
  else
    aud=$(cf POST "/accounts/$CF_ACCOUNT_ID/access/apps" "$body" | jq -r '.aud // "dry-aud"')
    echo "  app     $name -> $domain (created)" >&2
  fi
  echo "$aud"
}

# Where a new secret is persisted. Cloudflare returns a service-token secret
# exactly ONCE, at creation, so it is written the moment it exists -- never
# accumulated for a summary at the end, which is how a later failure in this
# script (a zone with no cache-rules ruleset yet) once swallowed one.
secrets_out=${SECRETS_OUT:-}
if [ -z "$secrets_out" ] && [ -d /share/private ]; then secrets_out=/share/private/preview_access.env; fi
record_secret() {  # <env-suffix> <client_id> <client_secret>
  local pfx=$1 cid=$2 sec=$3 line
  line="CF_ACCESS_CLIENT_ID${pfx:+_$pfx}=$cid
CF_ACCESS_CLIENT_SECRET${pfx:+_$pfx}=$sec"
  new_secrets="${new_secrets}${line}
"
  if [ -n "$secrets_out" ] && [ "$dry" = 0 ]; then
    (umask 077; printf '%s\n' "$line" >> "$secrets_out")
    echo "  secret  -> $secrets_out (owner-only)" >&2
  else
    echo "  secret  $line" >&2
  fi
}
tok_pfx() {        # msens-preview-probe-v8 -> PROBE_V8 ; msens-preview-check -> "" (the plain pair)
  local p; p=$(echo "$1" | sed 's/^msens-preview-//; s/-/_/g' | tr '[:lower:]' '[:upper:]')
  [ "$p" = "CHECK" ] && p=""
  echo "$p"
}

new_secrets=""
upsert_token() {   # <name> -> token id (secret recorded ONCE, on creation)
  local name=$1 id res
  id=$(by_name "$tokens" "$name")
  if [ -n "$id" ]; then
    echo "  token   $name (exists; secret unchanged)" >&2
    echo "$id"; return
  fi
  res=$(cf POST "/accounts/$CF_ACCOUNT_ID/access/service_tokens" \
        "$(jq -n --arg n "$name" '{name: $n, duration: "8760h"}')")
  id=$(echo "$res" | jq -r '.id // "dry-token"')
  echo "  token   $name (created)" >&2
  record_secret "$(tok_pfx "$name")" \
    "$(echo "$res" | jq -r '.client_id // "dry.access"')" \
    "$(echo "$res" | jq -r '.client_secret // "dry-secret"')"
  echo "$id"
}

# --rotate: Cloudflare shows a secret once; this mints a new one for an existing
# token (same client_id) and revokes the previous secret immediately.
if [ -n "$rotate" ]; then
  toks=$(cf GET "/accounts/$CF_ACCOUNT_ID/access/service_tokens")
  tid=$(echo "$toks" | jq -r --arg n "$rotate" 'map(select(.name == $n)) | .[0].id // empty')
  [ -n "$tid" ] || { echo "no service token named '$rotate'" >&2; exit 1; }
  res=$(cf POST "/accounts/$CF_ACCOUNT_ID/access/service_tokens/$tid/rotate" '{}')
  echo "rotated $rotate (previous secret revoked immediately)"
  record_secret "$(tok_pfx "$rotate")" \
    "$(echo "$res" | jq -r '.client_id')" "$(echo "$res" | jq -r '.client_secret')"
  exit 0
fi

# ---- policies + tokens ------------------------------------------------------
echo "policies, applications and service tokens:"
adm_pol=$(upsert_policy "preview admins" allow "$(emails_json "$admins")")
check_tok=$(upsert_token "msens-preview-check")
check_pol=$(upsert_policy "preview service check" non_identity \
  "$(jq -n --arg t "$check_tok" '[{service_token: {token_id: $t}}]')")

# catch-all: everything without a version-specific application (landing page,
# /docs/, and any release not separately gated) -- admins only
auds=$(upsert_app "preview (catch-all)" "$host" "$adm_pol" "$check_pol")

for v in $restricted; do
  rev=$(eval "echo \${$(ver_env "$v"):-}")
  if [ -z "$rev" ]; then
    echo "  note    $(ver_env "$v") unset -> $v reviewers = PREVIEW_ADMINS" >&2
    rev=$admins
  fi
  rpol=$(upsert_policy "preview $v reviewers" allow "$(emails_json "$rev")")
  ptok=$(upsert_token "msens-preview-probe-$v")
  ppol=$(upsert_policy "preview service probe $v" non_identity \
    "$(jq -n --arg t "$ptok" '[{service_token: {token_id: $t}}]')")
  a1=$(upsert_app "preview $v apps" "$host/$v"       "$rpol" "$check_pol" "$ppol")
  a2=$(upsert_app "preview $v docs" "$host/docs/$v"  "$rpol" "$check_pol" "$ppol")
  auds="$auds $a1 $a2"
done

# ---- cache: never let the edge hold an app asset across a deploy ------------
if [ -n "${CF_ZONE_ID:-}" ]; then
  echo
  echo "cache rule:"
  desc="bypass cache: $host"
  # A zone with no cache rules has NO entrypoint ruleset yet and answers 10003
  # ("could not find entrypoint ruleset"). That is a normal empty state, not an
  # error: treat it as "no existing rules" and let the PUT create the ruleset.
  cur=$(cf_try GET "/zones/$CF_ZONE_ID/rulesets/phases/http_request_cache_settings/entrypoint") \
    || { echo "  (no cache ruleset yet — creating it)"; cur='{}'; }
  # read-modify-write: a bare PUT would silently discard any other cache rule
  rules=$(echo "$cur" | jq -c --arg d "$desc" '((.rules // []) | map(select(.description != $d)))')
  rule=$(jq -n --arg e "(http.host eq \"$host\")" --arg d "$desc" \
    '{expression: $e, description: $d, action: "set_cache_settings", action_parameters: {cache: false}}')
  body=$(jq -n --argjson r "$rules" --argjson n "$rule" '{rules: ([$n] + $r)}')
  cf PUT "/zones/$CF_ZONE_ID/rulesets/phases/http_request_cache_settings/entrypoint" "$body" > /dev/null
  echo "  $desc (applied; $(echo "$rules" | jq 'length') other rule(s) preserved)"
else
  echo
  echo "cache rule: skipped (CF_ZONE_ID unset)"
fi

# ---- brand the login page ---------------------------------------------------
# Cloudflare will NEVER say "that address is not allowed": with one-time PIN it
# always claims a code was sent, so an outsider cannot enumerate who has access.
# That is the right default and it cannot be changed -- but the page around it
# can say who runs this and what to do when no code arrives, which is the part
# that was actually confusing.
echo
echo "login page:"
org_name=${PREVIEW_ORG_NAME:-"BOEM Marine Sensitivity Toolkit"}
footer=${PREVIEW_LOGIN_FOOTER:-"Access is by invitation. A one-time code is emailed only to addresses on the reviewer list for this release; the page says a code was sent either way, so the list cannot be probed. If no code arrives, ask Ben Best (ben@oceanmetrics.io) to add you."}
design=$(jq -n --arg h "$org_name" --arg f "$footer" --arg logo "${PREVIEW_LOGIN_LOGO:-}" \
  '{header_text: $h, footer_text: $f, background_color: "#1b2a33", text_color: "#ffffff"}
   + (if ($logo | length) > 0 then {logo_path: $logo} else {} end)')
if org_out=$(cf_try PUT "/accounts/$CF_ACCOUNT_ID/access/organizations" \
      "$(jq -n --arg n "$org_name" --argjson d "$design" '{name: $n, login_design: $d}')"); then
  echo "  named \"$org_name\", footer set${PREVIEW_LOGIN_LOGO:+, logo $PREVIEW_LOGIN_LOGO}"
else
  echo "  SKIPPED: the API token lacks 'Access: Organizations, Identity Providers, and Groups: Edit'."
  echo "  Add it (My Profile -> API Tokens -> edit this token) and re-run, or set it by hand in"
  echo "  Zero Trust -> Settings -> Custom Pages -> Access login page."
fi

# ---- what the server needs --------------------------------------------------
team=$(cf GET "/accounts/$CF_ACCOUNT_ID/access/organizations" 2>/dev/null \
       | jq -r '.auth_domain // empty' || true)
team=${team:-<team>.cloudflareaccess.com}
echo
echo "=============================================================================="
echo "Put these in the server .env (/share/github/MarineSensitivity/server/.env),"
echo "then deploy the routing:  cd workflows && DEPLOY_CADDY=1 quarto render release_marine-atlas.qmd"
echo
echo "CF_ACCESS_TEAM=${team%%.cloudflareaccess.com}"
# QUOTED: this value is space-separated, and an unquoted multi-word value makes
# `set -a; . ./.env` run the tail as commands and export only the first AUD.
# docker compose's own .env parser strips the quotes.
echo "CF_ACCESS_AUD=\"$(echo "$auds" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')\""
echo
echo "  (CF_ACCESS_AUD lists EVERY application's AUD: caddy-jwt's audience_whitelist"
echo "   is space-separated, and each Access application signs with its own AUD, so"
echo "   a missing one makes that path 401 at the origin after Access let it through.)"
if [ -n "$new_secrets" ]; then
  echo
  echo "NEW SERVICE TOKEN SECRETS were recorded above${secrets_out:+ and appended to $secrets_out}."
  echo "  CHECK_PREVIEW reads CF_ACCESS_CLIENT_ID / CF_ACCESS_CLIENT_SECRET (the shared"
  echo "  check token); the per-version probe pairs prove a v-N token cannot open v-M."
  echo "  A secret is shown ONCE by Cloudflare: recover a lost one with"
  echo "  ./access.sh --rotate <token-name>."
fi
echo "=============================================================================="
