#!/usr/bin/env sh
# First-time install (mirrors upstream all_in_one/install_all_in_one.sh, without the image
# purge): create the database, build the schema, set the admin login from .env.
# Idempotent enough to re-run on a half-finished install.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
dst=${ECOTAXA_DIR:-/share/ecotaxa}
set -a; . "$dst/.env"; set +a
dc="docker compose -p ecotaxa --env-file $dst/.env -f $here/docker-compose.yml"
sh "$here/render.sh"
$dc up -d pgdb
echo "waiting for postgres..."
for i in $(seq 1 30); do docker exec ecotaxa-pgdb pg_isready -U postgres -q && break; sleep 2; done
docker exec ecotaxa-pgdb psql -U postgres -tAc "select 1 from pg_database where datname='ecotaxa'" | grep -q 1 || \
  docker exec ecotaxa-pgdb psql -U postgres -c "create DATABASE ecotaxa WITH OWNER=postgres ENCODING='UTF8' TEMPLATE=template0 LC_CTYPE='C' LC_COLLATE='C' CONNECTION LIMIT=-1;"
$dc up -d ecotaxaback
sleep 5
docker exec ecotaxa-back sh -c "PYTHONPATH=. python cmds/manage.py db build"
# upstream sets email+password of user 1 by SQL (the back accepts a plaintext password in the DB
# and flags it as weak; change it once in the UI to get it hashed)
printf "UPDATE users SET email=:'e', password=:'p', name='Administrator' WHERE id=1;\n" | \
  docker exec -i ecotaxa-pgdb psql -U postgres -d ecotaxa -v e="$ECOTAXA_ADMIN_EMAIL" -v p="$ECOTAXA_ADMIN_PASSWORD"
$dc up -d
echo "install done: https://ecotaxa.marinebon.app  (admin = $ECOTAXA_ADMIN_EMAIL)"
