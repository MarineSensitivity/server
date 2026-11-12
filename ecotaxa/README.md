# EcoTaxa demo node (msens1)

A self-hosted [EcoTaxa](https://github.com/ecotaxa) instance stood up on 2026-11-06 as a proof of concept for
the US EcoTaxa call (NOAA/IOOS). Everything here is the upstream `ecotaxa_front/docker/all_in_one` route,
adapted to live beside the production stack on msens1.

- **URL:** https://ecotaxa.oceanmetrics.io (`*.oceanmetrics.io` is a wildcard A to msens1). The plan first
  named ecotaxa.marinebon.app, but `marinebon.app` has no wildcard (Google Cloud DNS has only the apex and
  `shiny`, checked 2026-11-06); Ben chose the oceanmetrics.io name the same day.
- **Versions:** `ecotaxa/ecotaxa_front:v3.4.1`, `ecotaxa/ecotaxa_back:v3.4.0` (both released 2026-11-03;
  `latest` is months older), `pgvector/pgvector:pg14`, `nginx:1.21.6`. No GPU back (no GPU on msens1):
  the RandomForest classifier in the back is CPU and works; deep-feature extraction does not.
- **Where things are:** this folder holds the compose file, nginx.conf, config *templates* and the
  install/render scripts (no secrets). `/share/ecotaxa/` holds the secrets (`.env`, chmod 600), the
  rendered `back_config.ini` and `front_config/config.cfg`, and all data: `pgdata/` (Postgres), `vault/`
  (images), `file_srv/` (server-side import area), `ftp_area/`, `models/`, `temp_jobs/`, `eco_users_files/`.
- **Admin login:** `ECOTAXA_ADMIN_EMAIL` / `ECOTAXA_ADMIN_PASSWORD` in `/share/ecotaxa/.env` (user id 1).
  Self-registration is **open** (upstream has no switch short of `ACCOUNT_VALIDATION = on`, which needs a
  working mail account).
- **Networking:** no host ports. The `ecotaxa-nginx` container joins the host Caddy's `server_default`
  network and the Caddyfile block `ecotaxa.oceanmetrics.io` reverse-proxies
  `ecotaxa-nginx:80` with a 2 GB body limit (zip imports). Postgres is only reachable on the stack's own
  `econet` network.
- **Memory caps:** nginx 256 MB, front 1 GB, back 2.5 GB (2 gunicorn workers), Postgres 1.5 GB.

## Set up (what was run)

```sh
# secrets
install -m 600 env.example /share/ecotaxa/.env   # then edit every value
# create DB, build schema, set the admin login, start everything
sh ~/server/ecotaxa/install.sh
# Caddy: add the vhost block to caddy/Caddyfile (edit IN PLACE: it is a single-file bind mount), then
docker exec caddy caddy validate --config /etc/caddy/Caddyfile && docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Then, as admin through the API (`POST /api/login` for a token):

1. `GET /api/taxa/pull_from_central` -- a fresh `db build` has an EMPTY taxonomy; this pulls the whole
   tree from ecotaxoserver.obs-vlfr.fr (12,522 rows, ~95 s). Without it every import fails on categories.
2. `POST /api/projects/create` (`instrument` must be one of the ids in the `instrument` table, e.g.
   `Zooscan`; `generic` is not one) then `POST /api/file_import/{project_id}` with
   `source_path` relative to `/file_srv` (`import_test.zip`, upstream `ecotaxa_back/QA/py/data`).
   The job stops in state `A` when the TSV names an unknown annotator; `POST /api/jobs/{id}/answer`
   with `{"users": {"<name>": <user_id>}, "taxa": {}}` resumes it.

Gotchas met: back >= 3.4 requires `RO_DB_*` keys (upstream's all_in_one config omits them); `.env`
values with spaces must be quoted (the scripts `source` it).

## Operate

```sh
dc="docker compose -p ecotaxa --env-file /share/ecotaxa/.env -f ~/server/ecotaxa/docker-compose.yml"
$dc ps; $dc logs --tail 50 ecotaxaback
sh ~/server/ecotaxa/render.sh && $dc restart ecotaxaback ecotaxafront   # after a config/.env change
docker exec ecotaxa-pgdb psql -U postgres -d ecotaxa
```

## Tear down

```sh
docker compose -p ecotaxa --env-file /share/ecotaxa/.env -f ~/server/ecotaxa/docker-compose.yml down
# remove the `ecotaxa.oceanmetrics.io { ... }` block from caddy/Caddyfile (in place), then
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
sudo rm -rf /share/ecotaxa          # data + secrets (pgdata is owned by the postgres uid)
docker rmi ecotaxa/ecotaxa_front:v3.4.1 ecotaxa/ecotaxa_back:v3.4.0 pgvector/pgvector:pg14 nginx:1.21.6
```

Never `docker compose up/restart` the production stack for this; only `caddy reload`.
