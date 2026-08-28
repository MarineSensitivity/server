# The preview host — operations, and how it was set up

**Live since 2026-08-27.** `preview.marinesensitivity.org` serves restricted (under-review)
releases to invited reviewers; **v8 is restricted today**. Steps 1–8 below are the one-time setup,
kept as the record and for rebuilding elsewhere — they are **done**. For day-to-day work jump to
[Managing reviewers](#managing-reviewers) and [What a reviewer does](#what-a-reviewer-does).

Current state: zone `marinesensitivity.org` on Cloudflare (only `preview` proxied), Zero Trust team
`marinesensitivity`, One-time PIN login, three Access applications (catch-all, `preview…/v8`,
`preview…/docs/v8`), reviewers **ben@oceanmetrics.io** (admin, everywhere) and
**timothy.white@boem.gov** (v8).

Plan and rationale: `workflows/.claude/plans/2026-08-15 pre-release review gate — preview host + Cloudflare Access.md`.

**Time:** ~1 h of work plus DNS propagation (minutes to a few hours; Cloudflare emails you).
**Cost:** $0 — Cloudflare Free zone + Zero Trust free tier (≤ 50 users).
**Blast radius:** the nameserver move touches the whole `marinesensitivity.org` zone. Only
`preview` becomes proxied; every other hostname keeps resolving to the same IP with the same
behavior. `dns_before.txt` in this directory is the "before" snapshot to diff against.

Steps 1–5 are **yours** (an account, a DNS change — nobody can script those for you). Step 6
onward is scripted.

---

## 1. Cloudflare account + Zero Trust organization

1. Sign up at <https://dash.cloudflare.com/sign-up> (use `ben@oceanmetrics.io`; enable 2FA).
2. In the dashboard, open **Zero Trust**. It asks for a **team name** — this becomes your login
   domain `https://<team>.cloudflareaccess.com`, is shown to reviewers, and is annoying to change
   later. Suggested: **`marinesensitivity`**.
3. Choose the **Free** plan when prompted (up to 50 users; no card required for the free tier).

Write down the **Account ID**: dashboard → any zone → right sidebar, or Zero Trust → Settings.

## 2. Add the zone (do NOT change nameservers yet)

1. Dashboard → **Add a site** → `marinesensitivity.org` → **Free** plan.
2. Cloudflare scans the existing DNS. **Its scan is a convenience, not proof.** Open the
   Squarespace DNS panel side by side and check every record, especially ones no Caddy vhost
   names (mail/MX, SPF/DKIM/DMARC TXT, verification TXTs). `dns_before.txt` lists what public DNS
   answered on 2026-08-15 for the apex, `www`, the wildcard, and every Caddy vhost.
3. **Proxy status** (the orange/grey cloud) — this is the important part:
   - `preview` → **Proxied (orange)**. If no `preview` record exists, create one:
     type `A`, name `preview`, content `100.25.173.0`, **Proxied**.
     (A wildcard `*` A record already covers `preview`; create the explicit record anyway so the
     proxy setting is unambiguous, and leave the wildcard **DNS only**.)
   - **Everything else → DNS only (grey)**: apex + `www` (GitHub Pages), `app`, `api`, `file`,
     `storage`, `rstudio`, `shiny`, `tile*`, `titiler*`, `h3t*`, `pmtiles`, `stac-api`, `pgadmin`,
     the wildcard, and all mail records. Grey = Cloudflare answers DNS and nothing else, so those
     hosts behave exactly as they do today.
4. **SSL/TLS** → **Overview** → encryption mode **Full (strict)**. The origin holds a real
   Let's Encrypt certificate, so strict is correct and anything weaker is worse than useless.

## 3. Move the nameservers (Squarespace → Cloudflare)

1. `./dns_snapshot.sh > /tmp/dns_before2.txt` and diff against `dns_before.txt` — confirms nothing
   changed since the snapshot was taken.
2. In Squarespace → Domains → `marinesensitivity.org` → **Nameservers**: replace the four
   `*.squarespacedns.com` / NS1 servers with the two Cloudflare gave you. **Squarespace keeps its
   records** — that is the rollback.
3. Wait for Cloudflare's "zone is active" email.
4. `./dns_snapshot.sh > /tmp/dns_after.txt && diff dns_before.txt /tmp/dns_after.txt`
   Expected difference: **only `preview`**, which now answers Cloudflare's anycast IPs instead of
   `100.25.173.0`. Anything else differing is a record that did not carry over — fix it in
   Cloudflare DNS before continuing.
5. Sanity-check the public surface (all must be unchanged):
   ```sh
   curl -sI https://app.marinesensitivity.org/scores/ | head -3
   curl -sI https://marinesensitivity.org/docs/v8/    | head -3
   curl -sI https://file.marinesensitivity.org/       | head -3
   ```

## 4. Add the **One-time PIN** login method

New Zero Trust organizations default to the *Cloudflare* identity provider (sign in with a
Cloudflare account) — which Tim does not have and should not need. OTP is no longer added
automatically, so add it:

**Zero Trust → Integrations → Identity providers → Add new → One-time PIN.**

> If DOI/BOEM mail filtering (Mimecast, Barracuda, Proofpoint…) is strict, ask IT to allowlist
> **`noreply@notify.cloudflare.com`**. A blocked PIN email looks identical to a working one from
> the login page's point of view — it always says "a code has been emailed to you".

## 5. Create the API token

Dashboard → **My Profile → API Tokens → Create Token → Create Custom Token**. Permissions:

| Scope   | Permission                                            | Level |
|---------|-------------------------------------------------------|-------|
| Account | Access: Apps and Policies                             | Edit  |
| Account | Access: Service Tokens                                | Edit  |
| Account | Access: Organizations, Identity Providers, and Groups | Read  |
| Zone    | Cache Rules (zone `marinesensitivity.org`)            | Edit  |

Account resources: your account. Zone resources: `marinesensitivity.org`. Copy the token once.

## 6. Fill in the server `.env`

On the server, `/share/github/MarineSensitivity/server/.env` (untracked; never commit these):

```sh
CF_API_TOKEN=<the token from step 5>
CF_ACCOUNT_ID=<account id>
CF_ZONE_ID=<zone id: dashboard -> marinesensitivity.org -> right sidebar>

# who may sign in. PREVIEW_ADMINS is the catch-all (landing page + anything not
# separately gated); PREVIEW_REVIEWERS_<VER> is that release's reviewer list.
PREVIEW_ADMINS=ben@oceanmetrics.io
PREVIEW_REVIEWERS_V8=ben@oceanmetrics.io,timothy.white@boem.gov
```

## 7. Create the Access applications

```sh
cd /share/github/MarineSensitivity/server
set -a; . ./.env; set +a
cloudflare/access.sh --dry-run     # read what it will do
cloudflare/access.sh               # apply
```

It reads the published `versions.json` and creates, per **restricted** release, an application for
`preview.…/{ver}` and one for `preview.…/docs/{ver}` with that release's reviewer policy, plus a
catch-all application for the host with the admin policy, service tokens for the automated checks,
and a cache-bypass rule. It is idempotent — re-run it whenever a reviewer list or a release's
`access` changes. (`DEPLOY_ACCESS=1` in `release_marine-atlas.qmd` runs exactly this.)

It prints two lines to paste into `.env`:

```sh
CF_ACCESS_TEAM=marinesensitivity
CF_ACCESS_AUD="<aud> <aud> …"    # QUOTED: space-separated, one per application
```

…and any new service-token secrets (shown once; also appended to
`/share/private/preview_access.env`). Then deploy the routing so Caddy picks up the team + AUDs:

```sh
cd ~/Github/MarineSensitivity/workflows       # (or on the server checkout)
DEPLOY_CADDY=1 quarto render release_marine-atlas.qmd
```

## 8. Verify

Automated (from the workflows repo, with the check token in the environment):

```sh
set -a; . /share/github/MarineSensitivity/server/.env; . /share/private/preview_access.env; set +a
CHECK_PREVIEW=1 quarto render release_marine-atlas.qmd
```

It asserts: the public host never renders a restricted version; the preview host is closed without
a token and open with one (`ms-preview=1`, the right `ms-ver`); origin-direct is 401; the pre-path
spelling `/scores/?ver=` redirects rather than serving; restricted docs are off GitHub Pages.

By hand, the thing that actually matters:

1. Open <https://preview.marinesensitivity.org/> in a private window → Cloudflare login →
   "Send me a code" → the landing page lists the restricted releases.
2. Open `/v8/scores/` (once v8 is restricted; before that the catch-all admits admins) → the app
   with a **PREVIEW** badge naming you.
3. Ask Tim to do the same. His PIN arriving at a `.gov` mailbox is the real acceptance test.

## 9. Flipping a version to restricted (v8 was done this way on 2026-08-27)

Order matters: **publish the registry before the readers act on it.**

```sh
# 1. workflows/data/versions.csv: v8 access -> restricted, then publish versions.json
cd ~/Github/MarineSensitivity/workflows && quarto render build_version_manifest.qmd
# 2. Access applications for the now-restricted v8 (+ its reviewer list)
ssh msens 'cd /share/github/MarineSensitivity/server && set -a && . ./.env && set +a && cloudflare/access.sh'
# 3. paste the new CF_ACCESS_AUD into .env, then reload routing + apps
DEPLOY_CADDY=1 DEPLOY_APPS=1 quarto render release_marine-atlas.qmd
# 4. docs CI: v8's book leaves gh-pages for gh-pages-preview
gh workflow run quarto-publish.yaml --repo MarineSensitivity/docs
# 5. prove it
CHECK_PREVIEW=1 quarto render release_marine-atlas.qmd
```

## Managing reviewers

Reviewer lists live in the server `.env` — **one line per version**, so access is per release:

```sh
PREVIEW_ADMINS=ben@oceanmetrics.io                                  # catch-all: landing page + any ungated version
PREVIEW_REVIEWERS_V8=ben@oceanmetrics.io,timothy.white@boem.gov     # v8 only (V9 for v9, V4B for v4b …)
```

Add or remove someone, then apply:

```sh
ssh msens 'cd /share/github/MarineSensitivity/server && set -a && . ./.env && set +a && cloudflare/access.sh'
```

That is the whole operation for an **existing** restricted version: `access.sh` updates the policy
in place, no new AUDs, nothing else to deploy. New reviewers get in on their next sign-in.

**Making a NEW version restricted** (say v9) additionally mints applications, so:

```sh
# 1. registry FIRST — every reader derives access fail-closed from it
#    workflows/data/versions.csv: v9 -> restricted, then
cd ~/Github/MarineSensitivity/workflows && quarto render build_version_manifest.qmd
# 2. add PREVIEW_REVIEWERS_V9=… to .env, and add v9 to PREVIEW_RESTRICTED_VERSIONS (a regex
#    alternation, e.g. "v8|v9": the PUBLIC app host 302s these versions to the review host —
#    DEPLOY_CADDY refuses to restart Caddy if it disagrees with versions.json), then create its applications
ssh msens 'cd /share/github/MarineSensitivity/server && set -a && . ./.env && set +a && cloudflare/access.sh'
# 3. paste the printed CF_ACCESS_AUD="…" line into .env (it lists EVERY application's AUD), then
DEPLOY_APPS=1 quarto render release_marine-atlas.qmd     # apps first: DEPLOY_CADDY's routes test asserts them
DEPLOY_CADDY=1 quarto render release_marine-atlas.qmd
# 4. docs: the CI moves a restricted version's book to gh-pages-preview
gh workflow run quarto-publish.yaml --repo MarineSensitivity/docs
# 5. prove it
CHECK_PREVIEW=1 quarto render release_marine-atlas.qmd
```

To open a release to a whole agency instead of naming people, replace the email list with a domain
rule in the dashboard (Zero Trust → Access → Policies → *preview v9 reviewers* → Include → *Emails
ending in* `@boem.gov`) — but `access.sh` rewrites that policy from `.env` on its next run, so if
you go that way, record it here and drop that version from the script's email handling.

## What a reviewer does

Send them the version link — nothing else is needed, no account, no password:

- apps: `https://preview.marinesensitivity.org/v8/scores/` · `…/v8/species/`
- docs: `https://preview.marinesensitivity.org/docs/v8/`
- or the landing page `https://preview.marinesensitivity.org/`, which lists the restricted releases

They enter their email, Cloudflare emails a one-time PIN, and the session lasts 24 h. The app shows
a **PREVIEW** badge with their address, and the version they are reading is the one in the path — a
v8 reviewer cannot reach v9 (proven by `CHECK_PREVIEW`'s per-version probe tokens).

## Rollback

| Situation | Action |
|---|---|
| Access misbehaves | Set `preview` to **DNS only** in Cloudflare DNS. Every preview URL then 401s at the origin (nothing leaks). |
| Cloudflare wholesale | Point the nameservers back to Squarespace; its records were never deleted. |
| A release should be public again | Flip `access` in `versions.csv`, re-run `build_version_manifest.qmd`, the docs CI, and `access.sh`. |

## Gotchas (each cost someone a day somewhere)

- **Only `preview` is proxied.** An accidentally-orange `app`/`file`/`storage` record puts
  Cloudflare in front of tile and Parquet traffic — caching and egress you did not plan.
- **Certificate renewal through the proxy.** Caddy renews via HTTP-01, which Cloudflare proxies, so
  it keeps working; if it ever fails, the symptom is a Cloudflare **526** and the fix is a
  Cloudflare Origin Certificate (or DNS-01). The origin cert must stay valid — that is what
  Full (strict) checks.
- **Cloudflare Free times out at 100 s (error 524).** Measured on this server: a *cold* preview
  Shiny worker answers its first page in **14–19 s**, warm in **~1.4 s**. Comfortable, but a much
  heavier release could approach it.
- **Access application paths ignore query strings** — which is exactly why the version is the
  path (`/v9/scores/`). Do not "simplify" the routes back to `?ver=`.
- **Path precedence:** the most specific application wins, and a path with no application of its
  own inherits the parent's. So the catch-all admits admins everywhere a version-specific
  application does not exist — including a release you forgot to gate.
- **The `aud` list must be complete.** Each application signs with its own AUD; a missing entry in
  `CF_ACCESS_AUD` means Access lets the reviewer through and then Caddy 401s them. Always paste the
  whole line `access.sh` prints.
- **Session length is 24 h** (application setting). Reviewers re-authenticate daily; raise it in
  the dashboard if that is annoying.
- **A blocked user still sees "a code has been emailed to you"** — by design. If someone says the
  PIN never arrives, check the policy first, then their spam filter.
- **Never force a query onto app requests.** shiny-server serves its client bundle from
  `<app>/__assets__/…` via a handler that 404s if the request carries ANY query string. The version
  therefore travels as the `X-MS-Version` header (`caddy/preview_routes.caddy`), not as `?ver=`;
  when it was forced, both apps drew their sidebar and hung on "Loading map…".
- **A service token's JWT has `common_name`, not `email`** — `jwtauth` must accept both
  (`user_claims email common_name sub`) or Access admits the automated checks and the origin 401s
  them. And Cloudflare rewrites `server:` on proxied responses, so a 401 that looks like
  Cloudflare's may well be the origin's: read the body.
- **Deploy apps before routes** for a coordinated change — `DEPLOY_CADDY` runs
  `caddy/test/run.sh`, which asserts the app really renders the path's version, so routing-first
  fails the test and stops the run before the apps update.
