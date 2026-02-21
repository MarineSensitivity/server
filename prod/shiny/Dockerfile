# production Shiny image for BOEM internal server
# based on rocker/geospatial:4.5.2 (R 4.5.2, PPM snapshot ~Jan 2026)
# installs Shiny Server + R packages for mapgl and mapsp apps
# app code is NOT baked in — mounted via volume at runtime

FROM rocker/geospatial:4.5.2

# install shiny server
RUN /rocker_scripts/install_shiny_server.sh

# install system dependencies
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
  curl libssl-dev libcurl4-gnutls-dev libsodium-dev libxml2-dev \
  && rm -rf /var/lib/apt/lists/*

# install CRAN packages (union of mapgl + mapsp app dependencies)
RUN install2.r --error \
  bsicons bslib DBI dplyr duckdb DT fs ggiraph ggplot2 glue here \
  htmltools librarian mapgl plotly purrr RColorBrewer readr scales sf \
  shiny stringr terra tibble tidyr viridisLite \
  && rm -rf /tmp/downloaded_packages

# override PPM snapshot for packages that need the very latest CRAN version
RUN Rscript -e "install.packages(c('mapgl', 'dplyr'), repos='https://cran.r-project.org')"

# install GitHub packages
RUN installGithub.r \
  etiennebacher/conductor yogevherz/plotme \
  && rm -rf /tmp/downloaded_packages

EXPOSE 3838

CMD ["/usr/bin/shiny-server"]
