# https://www.rplumber.io/articles/hosting.html#docker:~:text=FROM%20rstudio/plumber
# https://github.com/rstudio/plumber/blob/main/Dockerfile
# https://github.com/rocker-org/rocker-versioned2/blob/master/dockerfiles/geospatial_4.4.1.Dockerfile
FROM rocker/geospatial:4.4.1

# install system dependencies
#   plumber deps; `rm` call removes `apt` cache; libpq RPostgres dep
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
  curl git-core libssl-dev libcurl4-gnutls-dev libsodium-dev libxml2-dev \
  libpq-dev \
  && rm -rf /var/lib/apt/lists/*

# install R packages on CRAN; `rm` call removes install2.r's cache
RUN install2.r --error \
 dbplyr dplyr digest DT fs glue here httr2 jsonlite librarian markdown \
 plumber pool purrr rmarkdown RPostgres plotly readr shiny stringr tibble tidyr \
 yaml \
 && rm -rf /tmp/downloaded_packages

# install R packages on Github
# RUN installGithub.r \
#  r-lib/gargle \
#  && rm -rf /tmp/downloaded_packages/

EXPOSE 8000

CMD Rscript /share/github/MarineSensitivity/api/run-api.R

