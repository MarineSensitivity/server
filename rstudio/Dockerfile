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

RUN install2.r --error \
  bslib dbplyr DiagrammeR dplyr DT fs glue gt here htmltools htmlwidgets httpuv \
  httr2 jsonlite leaflet librarian mapedit mapview plotly plumber purrr readr \
  Rcpp RColorBrewer reticulate rhandsontable RPostgres rvest sf shinydashboard \
  shiny shinyjs shinyWidgets stringr terra tibble tidyr tidyselect units \
  urltools viridis yaml \
  && rm -rf /tmp/downloaded_packages   # clean R package cache

RUN installGithub.r \
  MarineSensitivity/msens qfes/rdeck \
  && rm -rf /tmp/downloaded_packages   # clean R package cache

# for each directory in apps, chgrp to shiny and chmod g+rx
RUN chgrp -R shiny /share/github/MarineSensitivity/apps \
  && chmod -R g+rx /share/github/MarineSensitivity/apps

EXPOSE 3838

CMD ["/init"]
