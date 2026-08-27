#!/usr/bin/env bash
# Rebuild the rstudio image against the CURRENT msens main, recorded and
# cache-correct: resolve main -> a commit SHA, pass it as MSENS_REF.
#
#   ./build.sh                 # latest msens main
#   ./build.sh <sha|branch>    # a specific one (reproduce an old image)
#
# Then recreate: docker compose up -d rstudio   (the container also reconciles
# msens with the /share checkout at start, so this is belt AND braces).
set -euo pipefail
cd "$(dirname "$0")/.."
ref=${1:-}
if [ -z "$ref" ]; then
  ref=$(git ls-remote https://github.com/MarineSensitivity/msens.git main | cut -f1)
  [ -n "$ref" ] || { echo "could not resolve msens main" >&2; exit 1; }
  echo "msens main -> $ref"
fi
MSENS_REF="$ref" docker compose build rstudio
echo "built rstudio with MSENS_REF=$ref"
echo "recreate with: docker compose up -d rstudio"
