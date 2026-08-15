# PREVIEW-instance wrapper for the species app -- see ../../shiny-server.conf.
#
# Same code as the public /species (the apps_v8 checkout Shiny Server serves at
# :3838), run as a SECOND process on :3839 with one env var set, so it may
# render restricted (under-review) releases: the app resolves ?ver= through
# msens::atlas_allow_access(), which reads MS_PREVIEW. shinyAppDir()'s onStart
# sets the working directory to the real app dir and serves its www/, so the
# app's relative data/, cache/ and www/ paths resolve exactly as they do publicly.
#
# Reachable only through Caddy's signed-in preview.marinesensitivity.org vhost.
# `touch restart.txt` HERE (not in the app checkout) reloads this instance;
# release_marine-atlas.qmd's DEPLOY_APPS does both.
Sys.setenv(MS_PREVIEW = "1")
shiny::shinyAppDir("/srv/shiny-server/species")
