# https://github.com/rocker-org/rocker-versioned2/blob/master/dockerfiles/geospatial_4.4.1.Dockerfile
FROM rocker/geospatial:4.4.1

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
# `otel` and `snowflakeauth` are intentionally EXCLUDED: they exist in the live
# container only because a runtime install resolved against a NEWER CRAN snapshot
# than the one rocker/geospatial:4.4.1 pins, so a clean build cannot fetch them
# ("not available for this version of R"). They are OpenTelemetry / Snowflake auth
# shims pulled in as soft deps — nothing in these apps uses them.
RUN install2.r --error \
  base64url bsicons checkmate cmocean cols4all conductor crul duckdbfs dygraphs \
  fontBitstreamVera fontLiberation fontquiver Formula future gdtools geojson geojsonio \
  globals httpcode insight jose jqr leafgl leaflegend listenv litedown maptiles \
  marginaleffects pak parallelly protolite Rnanoflann rnaturalearth rnaturalearthdata \
  S7 secretbase snakecase spacesXYZ stringdist \
  && rm -rf /tmp/downloaded_packages   # clean R package cache

# bbest/mapgl is a FORK, not walkerke/mapgl: the apps depend on fork behaviour
# (>= 0.4.5.9000), and a stale mapgl previously crashed the v8 merged surface.
# h3 + plotme are likewise GitHub-only.
RUN installGithub.r \
  MarineSensitivity/msens qfes/rdeck \
  bbest/mapgl crazycapivara/h3-r yogevherz/plotme \
  && rm -rf /tmp/downloaded_packages   # clean R package cache

# for each directory in apps, chgrp to shiny and chmod g+rx
RUN chgrp -R shiny /share/github/MarineSensitivity/apps \
  && chmod -R g+rx /share/github/MarineSensitivity/apps

EXPOSE 3838

CMD ["/init"]
