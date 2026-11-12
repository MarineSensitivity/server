# Rendered by render.sh from this template + /share/ecotaxa/.env -> /share/ecotaxa/front_config/config.cfg
# Based on upstream ecotaxa_front/docker/all_in_one/front_config/config.cfg.
#DEBUG = False
SECRET_KEY = '${SECRET_KEY}'

# the back-end, by compose service name (no https inside the stack)
BACKEND_URL = "http://ecotaxaback:8000"
TAXOSERVER_URL = "https://ecotaxoserver.obs-vlfr.fr"
ECOPART_URL = "https://ecopart.obs-vlfr.fr"

APP_GUI_MESSAGE_FILE = "config/messages.json"
APP_GUI_MESSAGE_COOKIE_NAME = "ecotaxa_userinfo"
MAILSERVICE_SECRET_KEY = "${MAILSERVICE_SECRET_KEY}"
MAILSERVICE_SALT = "${MAILSERVICE_SALT}"
BG_SCALE = '_jpg95'
LOGO_SPECIAL='_noel'
