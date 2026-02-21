#!/usr/bin/env bash
# render all .mmd diagrams to high-res PNG using mermaid-cli (mmdc)
#
# brand icons (github, docker) are not bundled with mmdc's Font Awesome.
# this script substitutes {{ICON_GITHUB}} and {{ICON_DOCKER}} placeholders
# in .mmd files with base64 data-URI <img> tags before rendering.
#
# install mmdc:
#   brew install mermaid-cli
#   # or: npm install -g @mermaid-js/mermaid-cli
#
# usage:
#   cd diagrams && ./render.sh              # render all
#   cd diagrams && ./render.sh sync-simple  # render one

set -euo pipefail
cd "$(dirname "$0")"

if ! command -v mmdc &>/dev/null; then
  echo "error: mmdc not found. install with: brew install mermaid-cli" >&2
  exit 1
fi

# build base64 data-URI img tags from local SVGs
make_icon() {
  local svg_file="$1" size="${2:-20}"
  local b64
  b64=$(base64 < "$svg_file" | tr -d '\n')
  echo "<img src='data:image/svg+xml;base64,${b64}' width='${size}' height='${size}' />"
}

ICON_GITHUB=$(make_icon github.svg 20)
ICON_DOCKER=$(make_icon docker.svg 20)

render_one() {
  local name="$1"
  local tmp_file
  tmp_file=$(mktemp "${TMPDIR:-/tmp}/${name}.XXXX.mmd")

  # substitute icon placeholders
  sed \
    -e "s|{{ICON_GITHUB}}|${ICON_GITHUB}|g" \
    -e "s|{{ICON_DOCKER}}|${ICON_DOCKER}|g" \
    "${name}.mmd" > "$tmp_file"

  echo "rendering ${name}.mmd -> ${name}.png"
  mmdc -i "$tmp_file" -o "${name}.png" \
    -w 2400 -H 1600 \
    -b transparent \
    -s 3

  rm -f "$tmp_file"
}

if [[ $# -gt 0 ]]; then
  render_one "$1"
else
  for f in *.mmd; do
    render_one "${f%.mmd}"
  done
fi

echo "done."
