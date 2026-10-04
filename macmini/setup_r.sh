#!/usr/bin/env bash
# mac mini modeling machine: R + quarto. run as bbest AFTER passwordless sudo exists
# (the rig and quarto installers call sudo themselves; homebrew must not run as root).
#   ssh macmini 'bash -s' < macmini/setup_r.sh
set -euo pipefail

export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
R_VERSION=${R_VERSION:-4.6.1}   # same as the laptop, so packages install as cran arm64 binaries

sudo -n true 2>/dev/null || { echo "needs passwordless sudo (see setup_root.sh header)" >&2; exit 1; }

# rig (r installation manager) + quarto ----
# rig is not in homebrew's own cask list: it comes from the r-lib/rig tap
# (r-lib = the R tooling organisation that publishes it), and homebrew refuses a cask from a
# third-party tap until it is trusted: trust that one cask, not the whole tap
command -v rig    >/dev/null || { brew tap r-lib/rig; brew trust --cask r-lib/rig/rig; brew install --cask r-lib/rig/rig; }
command -v quarto >/dev/null || brew install --cask quarto

# r, pinned ----
rig list 2>/dev/null | grep -q "$R_VERSION" || rig add "$R_VERSION"
rig default "${R_VERSION%.*}"   # rig names an install by its minor version (4.6), not 4.6.1

# base tooling; project libraries are restored per project from its renv.lock ----
Rscript -e 'if (!requireNamespace("pak", quietly = TRUE)) install.packages("pak", repos = "https://cloud.r-project.org")'
Rscript -e 'pak::pkg_install(c("renv", "devtools", "librarian", "quarto", "targets", "terra", "sf", "arrow", "duckdb", "DBI", "dplyr", "glue", "here"))'

# report ----
R --version | head -1
quarto --version
Rscript -e 'cat("terra gdal:", terra::gdal(), "\n")'
