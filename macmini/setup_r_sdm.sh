#!/usr/bin/env bash
# mac mini modeling machine: the R library the OBIS-method (mpaeu_sdm / obissdm) fits and the
# msens notebooks need. run as bbest AFTER setup_r.sh; idempotent (pak skips what is installed).
#   ~/Github/MarineSensitivity/server/macmini/setup_r_sdm.sh
# obissdm itself is installed from the local clone (~/Github/iobis/mpaeu_msdm, branch
# msens-patches) by workflows/scripts/og/install_obissdm.sh, so the fitted code is the patched code.
set -euo pipefail
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH

Rscript - <<'RS'
options(repos = c(CRAN = "https://cloud.r-project.org"))
# mpaeu_sdm/requirements.R, minus what the patched pipeline never loads
# (polars, gbifdb, minioclient, rstudioapi) ----
pkgs_sdm <- c(
  "furrr", "future", "progressr", "storr", "arrow", "dplyr", "terra", "stars", "cli", "fs", "purrr",
  "hypervolume", "ggplot2", "patchwork", "sf", "ecospat", "ks", "ade4", "spatstat", "ragg",
  "stringr", "raster", "predicts", "worrms", "rgbif", "yaml", "glue", "virtualspecies",
  "lubridate", "geohashTools", "rfishbase", "robis", "readr", "DBI", "duckdb", "blockCV",
  "rnaturalearth", "isotree", "reticulate", "sp", "ecodist", "spThin", "modEvA", "precrec",
  "rlang", "maxnet", "glmnet", "dismo", "randomForest", "mgcv", "lightgbm", "leaflet", "sys",
  "jsonlite", "sfarrow", "tidyr", "bioc::Rarr",
  "sjevelazco/flexsdm", "meeliskull/prg/R_package/prg", "iobis/obistools", "bio-oracle/biooracler")
# msens + the notebooks ----
pkgs_msens <- c(
  "exactextractr", "gt", "DT", "knitr", "rmarkdown", "testthat", "roxygen2", "tibble", "forcats",
  "scales", "htmltools", "digest", "jsonvalidate", "rstac", "mapgl", "tidyterra", "concaveman", "geosphere")
pak::pkg_install(c(pkgs_sdm, pkgs_msens), upgrade = FALSE, ask = FALSE)

# msens' own imports + suggests, from its DESCRIPTION (honours its `Remotes:` pin of bbest/mapgl) ----
dir_msens <- file.path(Sys.getenv("HOME"), "Github/MarineSensitivity/msens")
if (dir.exists(dir_msens)) pak::local_install_deps(dir_msens, dependencies = TRUE, upgrade = FALSE, ask = FALSE)

# xgboost: obissdm 1.2.0 calls the 1.x/2.x interface (sdm_modules.R: xgboost(data =, label =,
# params =)); 3.x renamed those arguments, so pin the last 1.7 from the cran archive ----
XGB <- "1.7.11.1"
if (!requireNamespace("xgboost", quietly = TRUE) || as.character(packageVersion("xgboost")) != XGB)
  pak::pkg_install(paste0("xgboost@", XGB), ask = FALSE)
stopifnot(as.character(packageVersion("xgboost")) == XGB)

# record what is installed (the pin a rebuilt machine is checked against) ----
ip <- as.data.frame(installed.packages()[, c("Package", "Version")], row.names = FALSE)
out <- file.path(Sys.getenv("HOME"), "Github/MarineSensitivity/server/macmini/r_packages.csv")
write.csv(ip[order(ip$Package), ], out, row.names = FALSE, quote = FALSE)
cat(nrow(ip), "packages ->", out, "\n")
RS
