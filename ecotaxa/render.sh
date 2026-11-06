#!/usr/bin/env sh
# Render the EcoTaxa configs from the templates here and the secrets in /share/ecotaxa/.env.
# Rendered files are chmod 600 and live OUTSIDE the repo (/share/ecotaxa). Re-run after editing
# either side, then: docker compose -p ecotaxa restart ecotaxaback ecotaxafront
set -eu
here=$(cd "$(dirname "$0")" && pwd)
dst=${ECOTAXA_DIR:-/share/ecotaxa}
env_file="$dst/.env"
[ -r "$env_file" ] || { echo "missing $env_file" >&2; exit 1; }
set -a; . "$env_file"; set +a
vars='$POSTGRES_PASSWORD $SECRET_KEY $SECURITY_PASSWORD_SALT $MAILSERVICE_SECRET_KEY $MAILSERVICE_SALT $APPMANAGER_EMAIL $APPMANAGER_NAME $INSTANCE_ID'
mkdir -p "$dst/front_config" "$dst/pgdata" "$dst/vault" "$dst/ftp_area" "$dst/file_srv" "$dst/models" "$dst/temp_jobs" "$dst/eco_users_files"
umask 077
envsubst "$vars" < "$here/back_config.ini.tpl" > "$dst/back_config.ini"
envsubst "$vars" < "$here/front_config/config.cfg.tpl" > "$dst/front_config/config.cfg"
umask 022
for f in hometop.html homebottom.html appmanagermsg.html; do cp "$here/front_config/$f" "$dst/front_config/$f"; done
echo "rendered to $dst (back_config.ini, front_config/)"
