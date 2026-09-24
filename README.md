# server

The server software is for setting up web services outside those of Github (e.g. serving website, docs and R package) using Docker (see the [docker-compose.yml](https://github.com/MarineSensitivity/server/blob/main/docker-compose.yml); with reverse proxying from subdomains to ports by [Caddy](https://caddyserver.com)):

## Notebooks

These web pages (\*.html) are typically rendered from Quarto markdown (\*.qmd) in [github.com/MarineSensitivity/server](https://github.com/MarineSensitivity/server):

<!-- Jekyll rendering -->
{% for file in site.static_files %}
  {% if file.extname == '.html' %}
* [{{ file.basename }}]({{ site.baseurl }}{{ file.path }})
  {% endif %}
{% endfor %}

## Quick Start

```bash
# setup folders
mkdir -p /share/github

# clone the repository
cd /share/github
git clone https://github.com/MarineSensitivity/server

# set environment variables: echo echo
cd /share/github/server
echo 'PASSWORD=*******' > .env

# docker launch as daemon
docker compose up -d

# docker launch as daemon, rebuilding any changed containers
docker compose up -d --build
```


## Services

- [**rstudio**](https://rstudio.marinesensitivity.org)\
  _integrated development environment (IDE) to code and debug directly on the server_
  <img width="600" src="https://github.com/MarineSensitivity/server/assets/2837257/cfd04553-15a7-4cd9-9206-32bec377750a">\
  [More info..](https://posit.co/products/open-source/rstudio-server/)

- **shiny**\
  _interactive applications_\
  e.g., [**shiny**.marinesensitivity.org/**map**](https://shiny.marinesensitivity.org/map)\
  <img width="600" alt="Screenshot 2023-10-26 at 12 35 53 PM" src="https://github.com/MarineSensitivity/server/assets/2837257/36052617-275d-4d32-a1b5-f2db3a17c13a">\
  [More info..](https://shiny.posit.co/)
  
- [**pgadmin**](https://pgadmin.marinesensitivity.org)\
  _PostGreSQL database administration interface_\
  <img width="600" alt="Screenshot 2023-10-26 at 12 42 46 PM" src="https://github.com/MarineSensitivity/server/assets/2837257/4439a844-65c9-4ea2-9685-8ba6d4b2cd29">\
  [More info..](https://www.pgadmin.org/)

- [**api**](https://api.marinesensitivity.org)\
  _custom API: using R plumber_\
  <img width="600" alt="Screenshot 2023-10-26 at 1 02 05 PM" src="https://github.com/MarineSensitivity/server/assets/2837257/3ff49d8c-8569-4111-9e63-2998960ea192">\
  [More info..](https://www.rplumber.io/)
  
- [**swagger**](https://swagger.marinesensitivity.org)\
  _generic database API: using PostGREST_\
  <img width="600" alt="Screenshot 2023-10-26 at 1 02 05 PM" src="https://github.com/MarineSensitivity/server/assets/2837257/787cc7b6-b1cd-4c1a-b896-4f17777b1d7d">\
  [More info..](https://postgrest.org/en/stable/)

- [**tile**](https://tile.marinesensitivity.org)\
  _spatial database API: using pg_tileserv for serving vector tiles_\
  <img width="667" alt="Screenshot 2023-10-26 at 1 46 00 PM" src="https://github.com/MarineSensitivity/server/assets/2837257/73398fe2-4b09-4ec9-8b14-2ef25165ecf4">\
  [More info..](https://postgrest.org/en/stable/)


## Keeping apps warm, and the resource budget

`warm` (a tiny sidecar, `warm/warm.sh`) re-requests the pages people actually open — the promoted
release and every `restricted` one, from the registry, not a hardcoded list — every 20 minutes and
immediately after `DEPLOY_APPS`. It hits `rstudio:3838` / `:3839` directly, so no Cloudflare round
trip, no Access token, no egress. Paired with `app_idle_timeout 3600`
(`rstudio/shiny-server.conf`), that turns a visitor's first page from ~13–17 s into ~1 s.

**Budget (measured 2026-08-27, 4 cores / 16 GB):** load ~0.4, ~7.6 GB available. `rstudio` 3.8 GB
(4 warm R workers at ~550 MB each, plus RStudio Server), `titiler` 1.2 GB, `titiler-v8` 0.9 GB,
`h3t` 0.7 GB, everything else < 250 MB. Warming costs ~4 page renders per 20 min — under 1 % of one
core — and its memory is the four pinned workers, not the sidecar (~5 MB).

**If it ever gets tight**, in order: warm fewer versions (drop the restricted ones, or set
`WARM_INTERVAL` higher and let `app_idle_timeout` expire them), lower `app_idle_timeout`, then look
at the species bundle — 222 MB per worker versus scores' 9.6 MB, the one outlier worth fixing at
source. A pipeline render inside `rstudio` is the other big transient consumer; it is what the
headroom is for.

**The report API is deliberately NOT warmed.** `plumber` is a long-running process, so it has no
cold start; each report is a fresh quarto render (~21–24 s) whose cost is the render itself, and
repeats are already free (~1.2 s) from the content-hash cache in `/share/public/reports`. Since a
report's key includes its title and areas, pre-rendering would almost never be hit. What the report
path does need is a *liveness* check — see the heartbeat note below.

## Preview host (restricted pre-releases)

`preview.marinesensitivity.org` serves **restricted** releases — pre-releases under review — to
invited reviewers only. Everything else stays public and unchanged.

- **URLs:** the version is the path on BOTH app hosts (`app…/v7/scores/`,
  `preview…/v8/scores/`), from one shared route file, `caddy/app_version_routes.caddy`. `?ver=`
  301s to it.
- **Who gets in:** Cloudflare Access (email one-time PIN), one application + reviewer policy **per
  version** — which the path scheme is what makes possible, since Access scopes by path.
  Reviewer lists live in `.env` as `PREVIEW_REVIEWERS_<VER>` (`PREVIEW_ADMINS` is the catch-all);
  today admins = ben@oceanmetrics.io and `PREVIEW_REVIEWERS_V8` = ben@oceanmetrics.io,
  timothy.white@boem.gov. Apply with `cloudflare/access.sh` — idempotent, reads the published
  registry, `--dry-run` shows what it would do.
- **How it is enforced:** Cloudflare in front (only this hostname is proxied), `jwtauth` in
  `caddy/Caddyfile` verifying the Access JWT at the origin, routes in
  `caddy/preview_routes.caddy` (tested by `caddy/test/run.sh`), and a SECOND Shiny Server instance
  on `:3839` (`rstudio/shiny-server.conf` + `rstudio/shiny_apps_preview/`) whose wrapper sets
  `MS_PREVIEW=1` — the public instance has no code path that renders a restricted release.
- **Setup + operations runbook:** [`cloudflare/README.md`](cloudflare/README.md).

### The atlas app (restricted releases)

`atlas` (the static Svelte app, `github.com/MarineSensitivity/atlas`) publishes its public releases
to GitHub Pages' `gh-pages` branch, which cannot be gated — so a **restricted** atlas release is
served here instead, at `preview…/{ver}/atlas/`, the same `dist/` and the same commit, just a
different door. It needs no app process (unlike scores/species): it is a static build, served by
`caddy/atlas_preview_routes.caddy` straight off disk.

- **What the block does:** `/{ver}/atlas` 308s to `/{ver}/atlas/` (query intact); `/{ver}/atlas/`
  and everything under it serve `/share/atlas_preview` (`index.html`/`report.html` `no-cache`, no
  SPA fallback — an unknown path is a real 404); `/{ver}/atlas/session.json` is **synthesized** by
  Caddy (never a file on disk) as EXACTLY `{"preview":true,"ver":"<from the URL path>"}`,
  `Cache-Control: no-store` — this is the app's one door into preview mode
  (`atlas/src/lib/release/session.ts`). There is **no `"user"` field** — a ruled deviation from the
  atlas-9 subplan's sample block, found by the Opus gate review of the first commit (e6fdef5):
  interpolating a raw Access claim into hand-built JSON is one stray `"` in a claim value away from
  smuggling an extra key (e.g. a `data` key, which a preview session's `dataBase()` would then
  honor as the data origin) — dropped rather than re-argued as safe, since the app never reads it
  anyway. Path traversal is refused, case-insensitively and including a bare trailing dot
  (`SESSION.JSON`, `Session.Json`, `session.json.` all 404 — a second, case-insensitive matcher
  refuses anything that isn't the exact lowercase spelling, so a case-insensitive filesystem can't
  leak the real file the way `file_server`'s own case-sensitive-regex-but-case-insensitive-lookup
  gap would otherwise allow). Every route that can answer unauthenticated is wrapped in `handle` so
  it sorts AFTER `authentication` in Caddy's compiled route list — a bare `redir`/`respond` sorts
  ahead of it, which is exactly how the no-slash redirect answered before jwtauth in the first
  commit (Opus finding 2). **Pre-existing, elsewhere, NOT touched by this change:** the redirects in
  `caddy/app_version_routes.caddy` and the query→path rules in `caddy/preview_routes.caddy` have
  this same bare-redirect-ahead-of-`authentication` shape. Harmless (a 308 to another URL under the
  same gate leaks no content) and another session's files — flagged here, not fixed here. The same
  general check (below) should be run on the server against the REAL `preview.marinesensitivity.org`
  Caddyfile — `docker compose exec caddy caddy adapt --config /etc/caddy/Caddyfile --adapter
  caddyfile`, then confirm the vhost's FIRST compiled route is `authentication` — which would flag
  those same two pre-existing redirects too; that is a finding for the server's owner to act on, not
  something this branch changes.
  Tested locally (routing only, no Access) by `caddy/test/atlas_routes_local.sh`, including a
  `basic_auth` stand-in (this laptop has no jwtauth plugin) that walks the whole COMPILED route tree
  (not specific matcher names — a fix-round-1 version of this check missed a bare, unmatchered
  `redir` or `header` added later, since it only looked for the `van`/`vatlas` matchers) and asserts
  the very first handler encountered, whatever it is, is `authentication`; the auth half is in
  `caddy/test/run.sh`, run on the server by `DEPLOY_CADDY`. **Not asserted anywhere, on purpose:** a
  v8 token refused on `/v9/atlas/`. This origin's jwtauth has one flat `audience_whitelist` covering
  every Access application's AUD (the same shape the Shiny routes already rely on), so per-version
  entitlement is enforced by **Cloudflare Access at the edge**, not by this origin check — a token
  valid for any restricted version reaches the origin able to request any other version's
  `/{ver}/atlas/` too. Hardening option, left to the server's owner: a per-version AUD and one
  `handle` per version, mirroring the per-version Access applications `cloudflare/access.sh` already
  creates.
- **Parity with scores/species, added 2026-09-24 (rebase onto main + gap-fill, still `atlas-preview`):**
  three checks the release session asked for, against the same convention `app_version_routes.caddy`
  already uses for `/scores/`/`/species/`.
  1. **Version conveyance.** Scores/species are reverse-proxied, so Caddy sets `X-MS-Version` on the
     upstream request; atlas is a static `file_server` with no upstream to set a header on, so its
     equivalent is the synthesized `session.json` body (`ver` from the URL PATH only, never `?ver=` or
     a header — see the "no `user` field" note above). Same guarantee (server-derived, un-forgeable by
     the client), different mechanism because the serving model differs.
  2. **`?ver=` deep links now 301 to the path form**, mirroring `@vquery_slash`/`@vquery_noslash`:
     an UNVERSIONED `/atlas/?ver=v9` (or `/atlas?ver=v9`) 301s to `/v9/atlas/` — it never itself
     renders content, and it cannot create the "?ver= overrides an already-versioned path" hole,
     because its matcher requires NO version segment (a request that already has one, e.g.
     `/v9/atlas/session.json?ver=v8`, keeps hitting the existing "?ver= is INERT" path untouched).
     Like the scores/species version it mirrors, only `ver` is used to build the destination; the
     rest of the query is dropped, not carried — a discrepancy in the existing scores/species
     convention (its own comment says query is carried; the code drops it) that this change matches
     for consistency rather than silently fixes elsewhere. **Gotcha hit while building this:**
     `redir <to> <code>` inside a `handle` block, with no explicit matcher, treats a `<to>` value that
     starts with a literal `/` as an (ambiguous) inline path matcher instead — confirmed via `caddy
     adapt` compiling the placeholder text itself into a `match.path`, with "301" ending up as the
     Location header. Fixed with an explicit `redir * /{query.ver}{path} 301` (the bare `*` forces the
     next token to be read as `to`).
  3. **A restricted version cannot reach the atlas via `app.marinesensitivity.org` (the public app
     host) either.** `@restricted_app` in `caddy/Caddyfile` (the same matcher that already sends
     `/{ver}/scores|species` for a `PREVIEW_RESTRICTED_VERSIONS` version to the review host) now
     covers `atlas` too. Before this, `/v9/atlas/` on that host fell through to
     `reverse_proxy rstudio:3838`, which has no idea what `/atlas` is — so the failure mode was
     already "cannot reach it" (a bogus 404/502), just not a deliberate one; this makes it the SAME
     redirect-to-review-host behavior scores/species get, and keeps a restricted version's atlas
     content from ever being requested from the un-gated host, deliberately rather than by accident.
     `docker-compose.yml`'s `PREVIEW_RESTRICTED_VERSIONS` comment updated to match. This matcher has
     no automated test on either side (scores/species were never covered either — a pre-existing
     gap, not one this change introduces); proven by hand locally (`caddy adapt` + `caddy run` against
     the isolated matcher, `PREVIEW_RESTRICTED_VERSIONS=v8|v9`): `/v9/atlas/?mdl_key=x` → 302 to
     `https://preview.marinesensitivity.org/v9/atlas/?mdl_key=x` (query intact); `/v7/atlas/` (not
     restricted) → falls through unmatched; `/v9/atlascanary` (word-boundary check) does not match.
  **Locally proven, with the real image, end-to-end:** built `caddy/Dockerfile`'s image
  (`docker compose build caddy` — a real `xcaddy` build, jwtauth plugin included) and ran the FULL
  production `Caddyfile` through `caddy validate` (needs a stub for the sibling `oceanmetrics/erddap`
  import and a writable `/share/logs`, neither of which exist on a laptop — worked around with a
  throwaway stub dir, not committed) — `Valid configuration`, before AND after every edit above. Then
  ran `caddy/test/run.sh` itself (unmodified logic; only its two hardcoded `/share/...` bind-mount
  SOURCES were redirected to a scratch dir, since `/share` does not exist locally and this laptop has
  no `sudo`) against `server_default` with a bare `python -m http.server` standing in for `rstudio`.
  Result: all 13 atlas assertions green, INCLUDING the ones that need real auth (no-token 401/302,
  `session.json`'s exact body behind a valid test token, traversal refusal, query-intact redirects) —
  this is the first time this branch's auth half has run against anything, laptop or server. The 8
  scores/species assertions that failed are 100% attributable to the stub returning 404 for every
  path (not a real Shiny app) — pre-existing routing this branch does not touch. **Still genuinely
  needs the live server:** the real `atlas-preview` sidecar's clone (`ms-app-sha` on the actual built
  app, not a fixture), the real `rstudio:3839` Shiny process for scores/species, and Cloudflare's own
  JWKS in place of the test HS256 key (i.e., that Access itself, not just this origin's `jwtauth`
  verification of a *valid* token, is configured correctly end to end).
- **Hand-off to deploy** (this is a branch for another session to review and deploy under its own
  flag; do these IN ORDER):
  1. **Host state first.** `sudo mkdir -p /share/atlas_preview && sudo chown 1000:1000
     /share/atlas_preview` — **before** the first `docker compose up` that includes this change.
     Docker auto-creates a missing bind-mount source as `root:root`, and if that happens first the
     `atlas-preview` sidecar can never write its clone (same failure mode, same fix, as
     `/share/docs_preview`).
  2. **This is not a `caddy reload`.** The new bind mount (`atlas_preview_routes.caddy`, the
     read-only `/share/atlas_preview` mount) and the new `atlas-preview` service both need the
     containers recreated: `docker compose up -d caddy atlas-preview` (a reload alone would keep
     running the OLD caddy container, which never sees the new mount).
  3. **`DEPLOY_CADDY=1`'s green bar means three things passed, in order:** `docker compose config -q`
     (the compose file itself parses), then `caddy validate --config /etc/caddy/Caddyfile` run
     **inside the recreated container** (`docker compose exec caddy caddy validate --config
     /etc/caddy/Caddyfile`) — validating the file on disk proves nothing if the running container is
     still the pre-recreate one — then `caddy/test/run.sh`. A red result at any step must stop the
     chunk before it restarts anything live.
  4. **Confirm the clone actually happened:** `test -d /share/atlas_preview/.git` (or `ls
     /share/atlas_preview`) after step 2 — a wrong owner (step 1 skipped) or a `gh-pages` branch
     that doesn't exist yet both leave this empty, and `/{ver}/atlas/` then 404s on everything with
     no obvious error anywhere else.
  5. **Confirm `CF_ZONE_ID` is set** (server `.env`) so `cloudflare/access.sh`'s cache-bypass rule
     for `preview.marinesensitivity.org` exists. Without it, `session.json`'s freshness depends on
     `Cache-Control: no-store` alone reaching every layer between the browser and this origin — the
     header is correct either way, but the zone rule is the belt to its suspenders. `access.sh
     --dry-run` (no credentials needed) shows whether it would create one.
  6. **Re-run `caddy/test/atlas_routes_local.sh` on the Linux server** (same script, `bash
     caddy/test/atlas_routes_local.sh`) to confirm Opus finding 3's case-variant leak was a macOS/APFS
     filesystem property, not the routing itself — the fix (the case-insensitive refusal matcher) is
     filesystem-independent and should read identically green on both, but the ORIGINAL bug (before
     that matcher existed) would not have reproduced on a case-sensitive Linux filesystem, and that
     asymmetry is worth confirming once rather than assuming.
  `DEPLOY_ACCESS=1` is **not** needed for this change (see Access, above).
- **Access:** covered by the existing per-version application (`preview.../{ver}`,
  `cloudflare/access.sh`) with no changes — Cloudflare Access applications are scoped by hostname +
  **path prefix**, and `/{ver}/atlas/` is a subpath of that same `/{ver}` prefix already gating
  `/{ver}/scores/` and `/{ver}/species/`. A v9 reviewer's existing access covers `/v9/atlas/` the
  moment this ships; nothing to run in `access.sh`.
- **`CHECK_PREVIEW` (in the `workflows` repo's `release_marine-atlas.qmd`, not this repo — a patch for
  that session, not made here):** add the same per-version probe already run for `/{ver}/scores/` to
  `/{ver}/atlas/` and `/{ver}/atlas/session.json`: a version's own service token → 200 + `session.json`'s
  `ver` matches;
  no token → 401/302; and (now that `@restricted_app` covers atlas — see above) the PUBLIC
  `app.marinesensitivity.org/{ver}/atlas/` for a restricted version → 302 to the preview host, query
  intact. Same reasoning as the existing scores/species probes: this is the assertion that would have
  caught a version dropped from `PREVIEW_RESTRICTED_VERSIONS`, or the atlas import silently missing
  from `preview_routes.caddy`, before a reviewer does.
- **Rollback:** revert this commit and `DEPLOY_CADDY=1` again — the atlas routes disappear and
  `/{ver}/atlas/` stops resolving; `atlas-preview`'s clone under `/share/atlas_preview` is harmless
  to leave in place (nothing serves it once the routes are gone). The public `atlas` app and its
  `gh-pages` branch are untouched either way.

## Connect

```bash
# ssh
pem='~/My Drive/private/msens_key_pair.pem'
ssh -i $pem ubuntu@msens1.marinesensitivity.org

# ssh with tunneling to postgis database
pem='~/My Drive/private/msens_key_pair.pem'
ssh -i $pem -L 5432:localhost:5432 ubuntu@msens1.marinesensitivity.org

# $PASSWORD
cat '/Users/bbest/My Drive/private/msens_server_env-password.txt'
```

## Restart

```bash
cd ~/server
git pull

# restart with any new configs
sudo docker restart

# update software
sudo docker compose up -d

# check disk space and remove big unused files interactively
sudo ncdu

# remove unused docker images, containers, and networks
docker system prune

# build new plumber api container
docker compose up --build plumber
```

## Reference

- [Server Setup](https://github.com/MarineSensitivity/server/wiki/Server-Setup) on AWS as EC2 instance at allocated IP address `100.25.173.0`


## 2024-06-17

- [CRAN as Ubuntu Binaries - r2u](https://eddelbuettel.github.io/r2u/#github-actions)

```bash
sudo apt upgrade
```

## Memory ceilings + host swap (2026-09-24 outage)

A Shiny Server app worker (uid 996 `shiny`, inside the `rstudio` container) reached 7.8 GB
resident on the 16 GB host, which had no swap and no per-container limit. The kernel reclaimed
page cache for an hour (CPU flat at 32 %, sshd/apps/STAC/API unreachable; EC2 status checks
green) before the OOM killer fired; an EC2 reboot ended it. Two layers now:

- **`docker-compose.yml` `rstudio: mem_limit: 9g` / `memswap_limit: 9g`** — a runaway worker is
  OOM-killed inside the container (that Shiny session errors, everything else keeps serving).
  Apply with `docker compose up -d --no-deps rstudio` (a recreate: the container's R library
  resets to the image + the msens reconcile at start). `docker inspect rstudio --format
  '{{.HostConfig.Memory}}'` must print `9663676416`.
- **`host/swap.sh`** — idempotent 4 GiB `/swapfile` + `vm.swappiness=10`, persisted in fstab and
  `/etc/sysctl.d/60-msens-swap.conf`. Run once as root; re-run after any host rebuild.

Which app it was is not provable after the fact (Shiny Server OSS wrote no per-app log); the
container log for that window shows only `ships` (`/srv/shiny-server/ships ->
/share/github/ecoquants/ricei/app_company`, not an MST app) erroring in `mapgl::mapboxgl`.
