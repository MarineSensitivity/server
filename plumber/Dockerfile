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

# install Quarto CLI (needed by the quarto R package to render /report)
RUN curl -L https://quarto.org/download/latest/quarto-linux-amd64.deb \
      -o /tmp/quarto.deb \
  && apt-get update -qq \
  && apt-get install -y --no-install-recommends /tmp/quarto.deb \
  && rm /tmp/quarto.deb \
  && rm -rf /var/lib/apt/lists/*

# install R packages on CRAN; `rm` call removes install2.r's cache
RUN install2.r --error \
 dbplyr dplyr digest DT fs ggiraph ggplot2 glue gt here httr2 jsonlite \
 librarian markdown plumber pool purrr quarto rmarkdown rnaturalearth \
 RPostgres plotly readr scales shiny stringr terra tibble tidyr yaml \
 && rm -rf /tmp/downloaded_packages

# TinyTeX for PDF rendering of /report (idempotent if already installed)
# Kept above the msens layer so bumping msens doesn't re-run the slow
# TinyTeX install.
RUN R -e 'if (!nzchar(Sys.which("lualatex"))) tinytex::install_tinytex()'

# install msens from GitHub (provides cells_in_polygon, scores_for_cells,
# species_for_cells, plot_flower, tbl_species, ggmap_areas used by report.qmd).
# The post-install `library(msens)` check fails the build loudly if the
# install silently fails — otherwise a bad layer gets cached as successful
# and the running container silently has no msens.
RUN R -e 'remotes::install_github("MarineSensitivity/msens", upgrade = FALSE); library(msens)' \
 && rm -rf /tmp/downloaded_packages/

EXPOSE 8000

CMD Rscript /share/github/MarineSensitivity/api/run-api.R

