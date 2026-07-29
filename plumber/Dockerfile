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
#   DBI backs the /h3 endpoint (OBIS H3 summaries), replacing the retired
#   postgres stack. duckdb is installed separately below (needs >= 1.5).
RUN install2.r --error \
 DBI dbplyr dplyr digest DT fs ggiraph ggplot2 glue gt here httr2 jsonlite \
 librarian markdown plumber pool purrr quarto rmarkdown rnaturalearth \
 rnaturalearthdata \
 RPostgres plotly readr scales shiny stringr terra tibble tidyr yaml \
 && rm -rf /tmp/downloaded_packages

# duckdb >= 1.5 for the /h3 endpoint AND to read the obis_h3 store (and for
# msens below, which requires >= 1.5.0). The base image's pinned RSPM snapshot
# ships duckdb 1.1.1 — too old — so install the latest jammy binary explicitly.
RUN R -e 'install.packages("duckdb", repos = "https://packagemanager.posit.co/cran/__linux__/jammy/latest")' \
 && R -e 'stopifnot(packageVersion("duckdb") >= "1.5.0")'

# pre-install the DuckDB h3 + spatial extensions so /h3 needs no network at
# request time (non-fatal: the endpoint's runtime INSTALL is an idempotent
# fallback).
RUN R -e 'library(duckdb); con <- dbConnect(duckdb()); \
  DBI::dbExecute(con, "INSTALL h3 FROM community; INSTALL spatial;"); \
  DBI::dbDisconnect(con, shutdown = TRUE)' || true

# TinyTeX for PDF rendering of /report (idempotent if already installed)
# Kept above the msens layer so bumping msens doesn't re-run the slow
# TinyTeX install.
RUN R -e 'if (!nzchar(Sys.which("lualatex"))) tinytex::install_tinytex()'

# install msens from GitHub (provides cells_in_polygon, scores_for_cells,
# species_for_cells, plot_flower, tbl_species, ggmap_areas used by report.qmd).
#
# PINNED BY COMMIT, and version-asserted. Left unpinned, this layer cached
# indefinitely: the running container sat on **msens 0.5.0** while the package
# moved on to 0.12.0, which broke the v8 API twice over, silently —
#   * no serve.duckdb fallback in sdm_db_path() (0.9.1), so /report?ver=v8 died
#     with `Cannot open database "/share/data/big/v8/sdm.duckdb"`;
#   * no cell_model support (0.9.0), so drawn areas would scan the
#     mdl_id-partitioned model_cell instead of the cell-oriented surface.
# Bumping MSENS_REF invalidates the layer, so a rebuild can never quietly serve
# a stale msens, and the version assertion fails the BUILD rather than caching a
# bad layer as successful. Keep MSENS_MIN at the version whose API report.qmd
# actually needs (0.12.1 = cells_in_polygon(poly, con) grid dispatch, S4-safe).
ARG MSENS_REF=1446d10891b0f4e374ee85d882e0b0995b776ab1
ARG MSENS_MIN=0.13.0
RUN R -e 'remotes::install_github(paste0("MarineSensitivity/msens@", Sys.getenv("MSENS_REF")), upgrade = FALSE); \
          library(msens); \
          stopifnot(packageVersion("msens") >= Sys.getenv("MSENS_MIN"))' \
 && rm -rf /tmp/downloaded_packages/

EXPOSE 8888

CMD Rscript /share/github/MarineSensitivity/api/run-api.R

