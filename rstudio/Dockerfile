# https://github.com/rocker-org/rocker-versioned2/blob/master/dockerfiles/geospatial_4.6.1.Dockerfile
# Pinned to an exact R patch release (never `latest`) so a rebuild is reproducible.
FROM rocker/geospatial:4.6.1

# https://github.com/rocker-org/rocker-versioned2/tree/master/scripts
RUN /rocker_scripts/install_shiny_server.sh
RUN /rocker_scripts/install_python.sh

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
#   bbest/mapgl@1e52f60 — the head of walkerke/mapgl PR #211,
#     "fix(h3t): render H3 hexagons crossing the antimeridian". This is a FORK,
#     not walkerke/mapgl, because that fix is NOT yet merged upstream; the h3t
#     hexagon layers in the species app render wrongly without it. When PR #211
#     lands, switch this back to a released walkerke/mapgl version and drop the
#     fork. See https://github.com/walkerke/mapgl/pull/211
#   crazycapivara/h3-r@6b658e8 (3.7.2), yogevherz/plotme@ff9ea91 (0.1.0) — not on CRAN.
#
# msens is intentionally NOT pinned: release_marine-atlas.qmd reinstalls it from
# the server checkout on every deploy, so a pin here would be misleading.
RUN installGithub.r \
  MarineSensitivity/msens qfes/rdeck \
  bbest/mapgl@1e52f603c3a41cfd36c2049b13f8f6281c4580ba \
  crazycapivara/h3-r@6b658e832f6907581d9d5c5296d611c4e4cf372a \
  yogevherz/plotme@ff9ea913949b4274cac244c5ecb6061c92ad2556 \
  && rm -rf /tmp/downloaded_packages   # clean R package cache

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
