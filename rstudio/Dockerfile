# https://github.com/rocker-org/rocker-versioned2/blob/master/dockerfiles/geospatial_4.6.1.Dockerfile
# Pinned to an exact R patch release (never `latest`) so a rebuild is reproducible.
FROM rocker/geospatial:4.6.1

# https://github.com/rocker-org/rocker-versioned2/tree/master/scripts
RUN /rocker_scripts/install_shiny_server.sh
RUN /rocker_scripts/install_python.sh

# shiny-server runs apps as `shiny` (run_as shiny), and some files on the /share
# bind mount are group-`staff` with no world read — e.g.
# /share/data/derived/r_bio-oracle_planarea.tif is `-rw-r----- ubuntu staff`,
# which BOTH v7 apps read at startup. The previous image had shiny in staff; the
# stock 4.6.1 image does not, so recreating the container broke v7 with
# "Permission denied (GDAL error 4)". Declare the membership so it survives any
# rebuild. `staff` is gid 50 in the container and matches the host group.
RUN usermod -aG staff shiny

# install system dependencies
#   plumber deps; `rm` call removes `apt` cache; libpq RPostgres dep
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
  curl git-core libssl-dev libcurl4-gnutls-dev libsodium-dev libxml2-dev \
  libpq-dev \
  && rm -rf /var/lib/apt/lists/*       # clean apt cache

# NOTE: `mapgl` is deliberately NOT listed here — the apps need the bbest/mapgl
# FORK (see installGithub.r below), and a CRAN copy installed first would only be
# overwritten.
RUN install2.r --error \
  arrow bslib DBI dbplyr DiagrammeR dplyr DT duckdb exactextractr fs ggiraph glue gt here htmltools \
  htmlwidgets httpuv httr2 janitor jsonlite leaflet librarian logger mapedit mapview \
  plotly plumber purrr quarto readr Rcpp RColorBrewer reticulate rhandsontable \
  RPostgres rvest sf shinydashboard shiny shinyjs shinyWidgets stringr targets terra \
  tibble tidyr tidyselect units urltools viridis yaml \
  && rm -rf /tmp/downloaded_packages   # clean R package cache

# Packages the RUNNING container had but this image did NOT. Auditing
# installed.packages() in the live container against a throwaway container from
# this image found 50 such packages — installed ad-hoc at runtime and never
# declared. That drift meant recreating the container would have silently broken
# BOTH the v7 and v8 Shiny apps (mapgl, ggiraph, conductor, bsicons, plotme,
# duckdbfs, logger, targets, quarto...). Declared here so a rebuild reproduces the
# working environment.
#
# Listed explicitly — including transitive deps (globals/listenv/parallelly from
# future, the gdtools/font* family from ggiraph, crul/httpcode/jqr/protolite from
# geojsonio) — so the image matches the audited container exactly rather than
# relying on resolution to happen to pull them.
#
# If you ever install a package at runtime, add it here in the SAME change.
#
# (`otel` and `snowflakeauth` could not be resolved against the old 4.4.1 snapshot
# and briefly had to be dropped; on 4.6.1 they resolve, so full parity is restored.)
RUN install2.r --error \
  base64url bsicons checkmate cmocean cols4all conductor crul duckdbfs dygraphs \
  fontBitstreamVera fontLiberation fontquiver Formula future gdtools geojson geojsonio \
  globals httpcode insight jose jqr leafgl leaflegend listenv litedown maptiles \
  marginaleffects otel pak parallelly protolite Rnanoflann rnaturalearth rnaturalearthdata \
  S7 secretbase snakecase snowflakeauth spacesXYZ stringdist \
  && rm -rf /tmp/downloaded_packages   # clean R package cache

# GitHub-only packages, pinned to exact commits so a rebuild is reproducible
# (a bare `user/repo` tracks a moving default branch).
#
#   crazycapivara/h3-r@6b658e8 (3.7.2), yogevherz/plotme@ff9ea91 (0.1.0) — not on CRAN.
#
# msens IS pinned, and asserted — it used to be deliberately unpinned on the
# reasoning that "release_marine-atlas.qmd reinstalls it from the server checkout
# on every deploy". That is true, and it is exactly the problem: any container
# recreate BETWEEN deploys silently rolls msens back to whatever this image
# happens to carry, with no error anywhere. That bit three times on 2026-07-28 —
# each recreate reverted msens and took a user-facing feature down with it:
#
#   * 0.11.0 -> 0.10.0 twice, so `msens::drawn_features_sf()` vanished and BOTH
#     scores apps answered "Draw a polygon on the map first." for every polygon
#     drawn (the app's tryCatch turns the missing function into a NULL).
#
# The deploy still reinstalls from the checkout on top; this pin only guarantees
# the FLOOR, so a recreate can never drop below the version the apps need.
# Bump MSENS_REF + MSENS_MIN together when an app starts needing something newer.
#
# `mapgl` is deliberately NOT in this RUN — see the next one for why.
ARG MSENS_REF=96a0833493809fcb4f758f2fd396e223e9225374
ARG MSENS_MIN=0.12.2
RUN installGithub.r \
  MarineSensitivity/msens@$MSENS_REF qfes/rdeck \
  crazycapivara/h3-r@6b658e832f6907581d9d5c5296d611c4e4cf372a \
  yogevherz/plotme@ff9ea913949b4274cac244c5ecb6061c92ad2556 \
  && R -e 'stopifnot(packageVersion("msens") >= Sys.getenv("MSENS_MIN")); \
           stopifnot("drawn_features_sf" %in% getNamespaceExports("msens"))' \
  && rm -rf /tmp/downloaded_packages   # clean R package cache

# mapgl LAST, in its OWN layer, so nothing above can walk it back.
#
#   bbest/mapgl@484e869f — branch `fix/h3t-antimeridian`, i.e. walkerke/mapgl
#     `main` merged in (0 commits behind) PLUS "fix(h3t): render H3 hexagons
#     crossing the antimeridian" (1e52f60). This is a FORK BRANCH, not the fork's
#     default branch: bbest/mapgl `main` is a plain sync of upstream and does NOT
#     carry the fix. Without it the h3t hexagon layers (h3-db globe, species app)
#     render a gap down the antimeridian. When PR #211 lands, switch this back to a
#     released walkerke/mapgl version and drop the fork.
#     See https://github.com/walkerke/mapgl/pull/211
#
# WHY ITS OWN LAYER, AFTER msens: msens's DESCRIPTION carries a `Remotes:` line for
# mapgl, which remotes resolves whenever msens is installed from GitHub. While that
# line read `walkerke/mapgl`, installing msens pulled UPSTREAM mapgl over this pin —
# and it is not only this build that installs msens: twelve Shiny apps
# `librarian::shelf(MarineSensitivity/msens)` at startup, as the `shiny` user, so a
# running container silently reverted to upstream mapgl a day after the image was
# built (observed 2026-07-26). msens `Remotes:` now names this same commit, so the
# two agree; keeping mapgl in a later layer means a future drift there cannot
# silently undo the pin at build time. Bump BOTH together.
RUN installGithub.r \
  bbest/mapgl@484e869f93af01bf396cbba7f074f0a3c53eba6d \
  && rm -rf /tmp/downloaded_packages   # clean R package cache

# DuckDB extensions, baked into the PERSISTENT duckdb home each user actually reads.
#
# Left to itself, duckdb stores extensions in a per-session temp dir
# ("/tmp/Rtmp*/duckdb/extensions"), wiped when the R session ends and re-downloaded
# next time. When that download fails, the v8 species app dies at startup with
#   Extension Autoloading Error: ... 'httpfs' ... not found
# because its `dataset` query goes through the S3-backed serve.duckdb views.
#
# The previous attempt at this set ENV DUCKDB_EXTENSION_DIRECTORY=/opt/duckdb/extensions
# and installed into it. That NEVER worked, in two independent ways:
#   1. duckdb R 1.5.x IGNORES that env var — it picks ~/.duckdb when that directory
#      exists and a temp dir otherwise, so the build installed to the temp dir and
#      /opt/duckdb/extensions shipped EMPTY (verified: `find /opt/duckdb -type f`
#      returned 0 files in the running container).
#   2. shiny-server starts an app with `su -l shiny`, a LOGIN shell, which resets
#      the environment — so a container-level ENV could not have reached the app
#      even if the directory had been populated.
# The bake looked correct and bought nothing; every app start silently re-downloaded.
#
# duckdb's own message names the supported mechanism ("Run duckdb(shared_home = TRUE)
# (or create ~/.duckdb)"). ~/.duckdb is the one that needs no app-code change, so
# create it per user and install into it. `aws` is included because the dotted public
# bucket needs it for globbing. `shiny` runs the apps; `root` is what
# `docker exec rstudio Rscript ...` (release_marine-atlas.qmd) runs as.
RUN mkdir -p /home/shiny/.duckdb && chown -R shiny:shiny /home/shiny/.duckdb \
  && su -s /bin/sh shiny -c 'cd /home/shiny && HOME=/home/shiny Rscript -e "con <- DBI::dbConnect(duckdb::duckdb()); for (e in c(\"httpfs\", \"aws\")) DBI::dbExecute(con, sprintf(\"INSTALL %s\", e)); DBI::dbDisconnect(con, shutdown = TRUE)"' \
  && mkdir -p /root/.duckdb \
  && Rscript -e 'con <- DBI::dbConnect(duckdb::duckdb()); \
       for (e in c("httpfs", "aws")) DBI::dbExecute(con, sprintf("INSTALL %s", e)); \
       DBI::dbDisconnect(con, shutdown = TRUE)' \
  && chmod -R a+rX /home/shiny/.duckdb /root/.duckdb

# NOTE: there is deliberately no `chgrp -R shiny /share/github/...` step here.
# `/share` is a RUNTIME bind mount (see docker-compose.yml) and does not exist
# during the build, so such a step can only ever fail with
# "chgrp: cannot access '/share/...': No such file or directory" — which is
# exactly why this image had gone unrebuilt while the Dockerfile drifted ahead
# of it.
#
# App-directory permissions are HOST state, not image state. The checkouts are
# already world-readable (drwxr-xr-x, owner ubuntu), and shiny-server's `run_as
# shiny` user can read them — verified inside the container with
# `su -s /bin/sh shiny -c 'test -r .../app.R'`. If that ever changes, fix it on
# the host, not here.

EXPOSE 3838

CMD ["/init"]
