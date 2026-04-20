#!/usr/bin/env python3
"""
Generate a single-band uint32 cell-id COG in standard -180..180° longitude
from a multi-band source raster whose band 1 holds cell_ids as float32/NaN
in 0-360° longitude convention.

Steps
-----
1. Read band 1 of the source raster.
2. Cast NaN → 0 and float32 → uint32 (0 = nodata sentinel).
3. Split at longitude 180° and rearrange pixels so the output raster spans
   -180..180° at the same pixel resolution (roughly 0.05°). Columns with no
   source data stay 0 / transparent.
4. Write as a tiled COG (LZW, 512 px blocks). No overviews — interpolating
   overviews would corrupt integer cell_ids, and nearest-neighbor on the
   native resolution is fast enough for z ≤ 4 over a 7200×2006 target.

Run inside the titiler container (rasterio + numpy + rio-cogeo ship with the
base image):

    docker compose run --rm titiler \\
      python /opt/msens/scripts/make_cellid_cog.py \\
        /share/data/derived/r_bio-oracle_planarea.tif \\
        /share/data/derived/r_cellid.tif
"""
from __future__ import annotations

import argparse
import sys
import tempfile
from pathlib import Path

import numpy as np
import rasterio
from rasterio.shutil import copy as rio_copy
from rasterio.transform import from_origin


def main(src_path: str, dst_path: str) -> None:
  src_path = str(src_path)
  dst_path = str(dst_path)
  print(f"src: {src_path}")
  print(f"dst: {dst_path}")

  with rasterio.open(src_path) as src:
    print(f"  bands={src.count} dtype[0]={src.dtypes[0]} "
          f"nodata[0]={src.nodatavals[0]}")
    print(f"  bounds_native={src.bounds}")
    print(f"  shape=({src.height}, {src.width})")

    pix_x = src.transform.a
    pix_y = -src.transform.e
    left  = src.transform.c
    top   = src.transform.f
    right = left + src.width * pix_x

    if not (left > 180 or right > 180):
      print("  [warn] source does not appear to be in 0-360° convention; "
            "running the wrap step anyway")

    band = src.read(1)  # float32 or whatever the source is

  # 2) cast NaN → 0 and → uint32
  print("== casting NaN → 0, to uint32 ...")
  u32 = np.where(np.isnan(band), 0, band).astype(np.uint32)

  # 3) split at lng=180° and place into -180..180° raster
  col_180 = int(round((180.0 - left) / pix_x))
  print(f"== splitting at lng=180° (column {col_180} of {u32.shape[1]})")
  east = u32[:, :col_180]   # source cols covering [left, 180]
  west = u32[:, col_180:]   # source cols covering [180, right] → [-180, right-360]

  out_width  = int(round(360.0 / pix_x))
  out_height = u32.shape[0]
  out = np.zeros((out_height, out_width), dtype=np.uint32)

  # east chunk: in output cols [(left+180)/pix_x, (left+180)/pix_x + east_width]
  east_start = int(round((left + 180.0) / pix_x))
  east_end   = east_start + east.shape[1]
  if east_end > out_width:
    east = east[:, : out_width - east_start]
    east_end = out_width
  out[:, east_start:east_end] = east
  print(f"  east placed at cols [{east_start}, {east_end}]")

  # west chunk: in output cols [0, west_width]
  west_end = min(west.shape[1], out_width)
  out[:, :west_end] = west[:, :west_end]
  print(f"  west placed at cols [0, {west_end}]")

  # 4) write a tiled GTiff, then copy as COG
  out_transform = from_origin(-180.0, top, pix_x, pix_y)
  profile = {
    "driver":      "GTiff",
    "height":      out_height,
    "width":       out_width,
    "count":       1,
    "dtype":       "uint32",
    "crs":         "EPSG:4326",
    "transform":   out_transform,
    "nodata":      0,
    "compress":    "LZW",
    "tiled":       True,
    "blockxsize":  512,
    "blockysize":  512,
  }

  dst_path_p = Path(dst_path)
  dst_path_p.parent.mkdir(parents=True, exist_ok=True)

  with tempfile.NamedTemporaryFile(suffix=".tif", delete=False) as tf:
    tmp_path = tf.name
  try:
    print(f"== writing staged GTiff → {tmp_path}")
    with rasterio.open(tmp_path, "w", **profile) as dst:
      dst.write(out, 1)

    print(f"== copying as COG → {dst_path}")
    rio_copy(
      tmp_path, dst_path,
      driver="COG",
      compress="LZW",
      blocksize=512,
      overview_count=0,
      bigtiff="IF_SAFER",
    )
  finally:
    Path(tmp_path).unlink(missing_ok=True)

  # summary
  with rasterio.open(dst_path) as chk:
    print("== result:")
    print(f"  driver={chk.driver} dtype={chk.dtypes[0]} nodata={chk.nodatavals[0]}")
    print(f"  bounds={chk.bounds}")
    print(f"  shape=({chk.height}, {chk.width})")
    print(f"  overviews (band 1): {chk.overviews(1)}")
    nonzero = int(np.count_nonzero(chk.read(1, out_shape=(512, 512))))
    print(f"  nonzero px in 512x512 decimated read: {nonzero}")


if __name__ == "__main__":
  ap = argparse.ArgumentParser(description=__doc__)
  ap.add_argument("src", nargs="?", default="/share/data/derived/r_bio-oracle_planarea.tif")
  ap.add_argument("dst", nargs="?", default="/share/data/derived/r_cellid.tif")
  args = ap.parse_args()
  try:
    main(args.src, args.dst)
  except Exception as e:
    print(f"[error] {e.__class__.__name__}: {e}", file=sys.stderr)
    sys.exit(1)
