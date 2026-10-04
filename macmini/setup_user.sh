#!/usr/bin/env bash
# mac mini modeling machine: everything that needs NO root. idempotent, rerun freely.
#   ssh macmini 'bash -s' < macmini/setup_user.sh       (or run from a checkout on the mini)
set -euo pipefail

export PATH=/opt/homebrew/bin:$PATH
BIG_VOL=${BIG_VOL:-/Volumes/msens_big}   # external 2 TB APFS volume
DIR_GH=${DIR_GH:-$HOME/Github}
here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")

# shell path: non-interactive ssh sessions read ~/.zshenv ----
grep -q '/opt/homebrew/bin' ~/.zshenv 2>/dev/null ||
  echo 'export PATH=/opt/homebrew/bin:/opt/homebrew/sbin:$HOME/.local/bin:$PATH' >> ~/.zshenv

# homebrew formulae ----
if [ -n "$here" ] && [ -f "$here/Brewfile" ]; then
  brew bundle --file="$here/Brewfile"
else
  curl -fsSL https://raw.githubusercontent.com/MarineSensitivity/server/main/macmini/Brewfile -o /tmp/Brewfile
  brew bundle --file=/tmp/Brewfile
fi

# big data lives on the external volume, reached as ~/_big (same path as the laptop) ----
if [ -d "$BIG_VOL" ]; then
  mkdir -p "$BIG_VOL/_big/msens/raw" "$BIG_VOL/_big/msens/derived" "$BIG_VOL/_big/sdm"
  [ -e ~/_big ] || ln -s "$BIG_VOL/_big" ~/_big
else
  echo "WARN: $BIG_VOL is not mounted; ~/_big not linked" >&2
fi

# python command-line tools ----
# `rio cogeo`, called by the obis pipeline to write cogs: rio-cogeo is a plugin with no
# executable of its own; the `rio` command belongs to rasterio
uv tool install rasterio --with rio-cogeo

# repos, same layout as the laptop (https: read-only until the mini has its own github key) ----
clone() { # clone <org> <repo>
  local d="$DIR_GH/$1/$2"
  [ -d "$d/.git" ] || { mkdir -p "$DIR_GH/$1"; git clone "https://github.com/$1/$2.git" "$d"; }
}
for r in workflows msens server; do clone MarineSensitivity "$r"; done
for r in mpaeu_sdm mpaeu_msdm mpaeu_esdm mpaeu_docs speciesgrids speedy; do clone iobis "$r"; done

# report ----
echo "--- versions"
for c in gdalinfo duckdb aws gh uv rclone; do printf '%s: ' "$c"; "$c" --version 2>&1 | head -1 || true; done
tmux -V || true   # tmux has no --version
ls -ld ~/_big 2>/dev/null || true
df -h "$BIG_VOL" 2>/dev/null | tail -1 || true
