# Rendered by render.sh from this template + /share/ecotaxa/.env -> /share/ecotaxa/back_config.ini
# Based on upstream ecotaxa_front/docker/all_in_one/back_config.ini.
[default]

[conf]
DB_USER = postgres
DB_PASSWORD = ${POSTGRES_PASSWORD}
DB_HOST = pgdb
DB_PORT = 5432
DB_DATABASE = ecotaxa
# read-only connection (mandatory in back >= 3.4): same DB and user on this demo
RO_DB_USER = postgres
RO_DB_PASSWORD = ${POSTGRES_PASSWORD}
RO_DB_HOST = pgdb
RO_DB_PORT = 5432
RO_DB_DATABASE = ecotaxa

APPMANAGER_EMAIL = ${APPMANAGER_EMAIL}
APPMANAGER_NAME = ${APPMANAGER_NAME}

THUMBSIZELIMIT = 400

VAULT_DIR = /vault
JOBS_DIR = /temp_jobs
SERVERLOADAREA = /file_srv
FTPEXPORTAREA = /ftp_area
MODELSAREA = /models

# taxonomy server (upstream all_in_one defaults; the instance id/secret are the public demo ones)
TAXOSERVER_URL = https://ecotaxoserver.obs-vlfr.fr
TAXOSERVER_INSTANCE_ID = 9
TAXOSERVER_SHARED_SECRET = ZiAgKGDHiQ4WAj6Gi1RN41WHrMkPut8B3AzgXqLWZ

# password encryption parameters; SECRET_KEY must equal the front's config.cfg SECRET_KEY
SECRET_KEY = ${SECRET_KEY}
SECURITY_PASSWORD_HASH = sha512_crypt
SECURITY_PASSWORD_SALT = ${SECURITY_PASSWORD_SALT}
MAILSERVICE_SECRET_KEY = ${MAILSERVICE_SECRET_KEY}
MAILSERVICE_SALT = ${MAILSERVICE_SALT}
# no outgoing mail is configured on this demo (dummy account, as upstream)
SENDER_ACCOUNT = noreply@senderaccount.mail,passwdaccount,ssl0.ovh.net,465,993
INSTANCE_ID = ${INSTANCE_ID}
USER_EMAIL_VERIFICATION = off
ACCOUNT_VALIDATION = off
DIR_MAIL_TEMPLATES = /account_validation_mails
SERVERURL = https://ecotaxa.oceanmetrics.io

USERSFILESAREA = /eco_users_files
# max upload file size in bytes (2 GB, same as Caddy/nginx)
MAX_UPLOAD_SIZE = 2147483648
TIMETOLIVE = 60
ALL_IN_ONE = on
