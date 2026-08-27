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


