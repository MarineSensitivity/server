"""custom titiler factory serving sql-driven cell tiles from a fixed cell-id cog."""
from __future__ import annotations

import base64
import binascii
import logging
import os
import threading
from dataclasses import dataclass, field
from functools import lru_cache
from typing import Optional
from urllib.parse import urlencode

import duckdb
import numpy as np
import sqlglot
import sqlglot.expressions as exp
from fastapi import APIRouter, HTTPException, Query, Request
from rio_tiler.colormap import apply_cmap
from rio_tiler.colormap import cmap as default_cmap
from rio_tiler.constants import WGS84_CRS
from rio_tiler.errors import TileOutsideBounds
from rio_tiler.io import Reader
from rio_tiler.utils import render as utils_render
from starlette.responses import Response

log = logging.getLogger("msens.factory")

COG_PATH    = os.environ.get("MSENS_CELLID_COG", "/share/data/derived/r_bio-oracle_planarea.tif")
DUCKDB_PATH = os.environ.get("MSENS_DUCKDB",    "/share/data/big/latest/sdm.duckdb")
MAX_ROWS    = int(os.environ.get("MSENS_MAX_ROWS", "1000000"))
LRU_SIZE    = int(os.environ.get("MSENS_LRU_SIZE", "128"))

# disallowed statement / expression types
_FORBIDDEN_STATEMENTS = (
  exp.Insert, exp.Update, exp.Delete, exp.Drop, exp.Alter, exp.Create,
  exp.Command,  # catches ATTACH, PRAGMA, COPY, SET, CALL, LOAD, INSTALL, ...
  exp.Transaction, exp.Commit, exp.Rollback,
)
_FORBIDDEN_FN_PREFIXES = ("read_", "write_", "httpfs", "load_", "install_")


class SqlValidationError(ValueError):
  """raised when user-supplied SQL fails validation."""


# ---- sql handling -----------------------------------------------------------

def _decode_sql(b64: str) -> str:
  pad = "=" * ((4 - len(b64) % 4) % 4)
  try:
    raw = base64.urlsafe_b64decode(b64 + pad)
    return raw.decode("utf-8")
  except (binascii.Error, UnicodeDecodeError) as e:
    raise SqlValidationError(f"bad base64url encoding: {e}") from e


def _validate_sql(sql: str) -> str:
  """parse + restrict; return canonical duckdb-dialect sql."""
  try:
    parsed = sqlglot.parse(sql, dialect="duckdb")
  except sqlglot.errors.ParseError as e:
    raise SqlValidationError(f"parse error: {e}") from e

  if len(parsed) != 1 or parsed[0] is None:
    raise SqlValidationError("must be exactly one statement")

  stmt = parsed[0]
  if not isinstance(stmt, exp.Select):
    raise SqlValidationError(f"must be SELECT, got {type(stmt).__name__}")

  for node in stmt.walk():
    if isinstance(node, _FORBIDDEN_STATEMENTS):
      raise SqlValidationError(f"forbidden statement: {type(node).__name__}")
    if isinstance(node, exp.Anonymous):
      name = (node.name or "").lower()
      if any(name.startswith(p) for p in _FORBIDDEN_FN_PREFIXES):
        raise SqlValidationError(f"forbidden function: {name}")

  return stmt.sql(dialect="duckdb")


def _decode_and_validate(sql_b64: str) -> str:
  try:
    return _validate_sql(_decode_sql(sql_b64))
  except SqlValidationError as e:
    raise HTTPException(status_code=400, detail=f"invalid sql: {e}") from e


# ---- duckdb -----------------------------------------------------------------

# one read-only connection per thread; lru cache on query results
_tls = threading.local()


def _get_conn() -> duckdb.DuckDBPyConnection:
  if not hasattr(_tls, "conn"):
    _tls.conn = duckdb.connect(DUCKDB_PATH, read_only=True)
  return _tls.conn


@lru_cache(maxsize=LRU_SIZE)
def _load_value_map(canonical_sql: str) -> np.ndarray:
  """run validated sql; return dense np.float64 indexed by cell_id, NaN elsewhere."""
  wrapped = (
    "SELECT CAST(cell_id AS INTEGER) AS cell_id, "
    "CAST(value AS DOUBLE) AS value "
    f"FROM ({canonical_sql}) _msens_t "
    f"LIMIT {MAX_ROWS + 1}"
  )
  result = _get_conn().execute(wrapped).fetchnumpy()
  cell_ids = result["cell_id"]
  values   = result["value"]

  if len(cell_ids) > MAX_ROWS:
    raise HTTPException(status_code=400, detail=f"row cap {MAX_ROWS} exceeded")
  if len(cell_ids) == 0:
    raise HTTPException(status_code=404, detail="sql returned no rows")

  # strip nulls (numpy arrays from duckdb use NaN for null doubles, -MAXINT for null ints)
  valid = np.isfinite(values.astype(np.float64)) & (cell_ids > 0)
  cell_ids = cell_ids[valid].astype(np.int64)
  values   = values[valid].astype(np.float64)

  if len(cell_ids) == 0:
    raise HTTPException(status_code=404, detail="sql returned no positive cell_ids with finite values")

  max_id = int(cell_ids.max())
  vmap = np.full(max_id + 1, np.nan, dtype=np.float64)
  vmap[cell_ids] = values
  return vmap


# ---- tile rendering ---------------------------------------------------------

def _parse_rescale(s: Optional[str]) -> Optional[tuple[float, float]]:
  if not s:
    return None
  parts = s.split(",")
  if len(parts) != 2:
    raise HTTPException(status_code=400, detail="rescale must be 'min,max'")
  try:
    return (float(parts[0]), float(parts[1]))
  except ValueError:
    raise HTTPException(status_code=400, detail="rescale values must be numeric")


def _get_colormap(name: str):
  try:
    return default_cmap.get(name)
  except (KeyError, Exception) as e:
    raise HTTPException(status_code=400, detail=f"unknown colormap '{name}': {e}") from e


def _empty_tile_png() -> bytes:
  rgba = np.zeros((4, 256, 256), dtype=np.uint8)
  mask = np.zeros((256, 256), dtype=np.uint8)
  return utils_render(rgba, mask=mask, img_format="PNG")


def _render_tile(
    z: int, x: int, y: int, vmap: np.ndarray,
    colormap_name: str, rescale: tuple[float, float]) -> bytes:

  try:
    with Reader(COG_PATH) as src:
      img = src.tile(x, y, z, tilesize=256, resampling_method="nearest")
  except TileOutsideBounds:
    return _empty_tile_png()

  # img.data shape (bands, 256, 256); band 0 holds integer cell ids
  cellid   = img.data[0].astype(np.int64)
  cog_mask = img.mask  # 2D, uint8; 255 where valid

  flat = cellid.ravel()
  in_range = (flat > 0) & (flat < len(vmap))
  out = np.full(flat.shape, np.nan, dtype=np.float64)
  out[in_range] = vmap[flat[in_range]]
  values = out.reshape(cellid.shape)

  rmin, rmax = rescale
  if rmax <= rmin:
    rmax = rmin + 1.0
  scaled    = np.clip((values - rmin) / (rmax - rmin), 0.0, 1.0) * 255.0
  scaled_u8 = np.nan_to_num(scaled, nan=0).astype(np.uint8)

  # apply colormap explicitly: (1,H,W) uint8 → (4,H,W) RGBA uint8 + (H,W) alpha
  data_3d = scaled_u8[np.newaxis, ...]
  rgba, alpha_from_cmap = apply_cmap(data_3d, _get_colormap(colormap_name))

  # combine cog validity + value finiteness + colormap alpha
  valid_2d     = ((cog_mask > 0) & np.isfinite(values)).astype(np.uint8) * 255
  final_mask   = np.bitwise_and(alpha_from_cmap, valid_2d)

  return utils_render(rgba, mask=final_mask, img_format="PNG")


# ---- factory ----------------------------------------------------------------

@dataclass
class MsensCellsFactory:
  """sql-driven cell tiles backed by a fixed cell-id COG."""
  router: APIRouter = field(default_factory=APIRouter)

  def __post_init__(self):
    self._register_routes()

  def _register_routes(self):
    router = self.router

    @router.get("/bounds")
    def bounds():
      """geographic bounds of the cell-id cog."""
      with Reader(COG_PATH) as src:
        return {"bounds": list(src.get_geographic_bounds(WGS84_CRS)), "crs": "EPSG:4326"}

    @router.get("/statistics")
    def statistics(
        sql:   str = Query(..., description="base64url-encoded SELECT cell_id, value ..."),
        mtime: Optional[str] = Query(None, description="optional cache-bust tag — DuckDB mtime")):  # noqa: ARG001
      """min/max/percentiles of the sql result — used by clients to set rescale."""
      canonical = _decode_and_validate(sql)
      vmap = _load_value_map(canonical)
      vals = vmap[np.isfinite(vmap)]
      return {
        "n":    int(len(vals)),
        "min":  float(vals.min()),
        "max":  float(vals.max()),
        "mean": float(vals.mean()),
        "std":  float(vals.std()),
        "p2":   float(np.percentile(vals,  2)),
        "p50":  float(np.percentile(vals, 50)),
        "p98":  float(np.percentile(vals, 98)),
      }

    @router.get("/tilejson.json")
    def tilejson(
        request: Request,
        sql:      str = Query(..., description="base64url-encoded SELECT cell_id, value ..."),
        colormap: str = Query("spectral_r"),
        rescale:  Optional[str] = Query(None, description="'min,max'"),
        mtime:    Optional[str] = Query(None, description="optional cache-bust tag — DuckDB mtime"),
        minzoom:  int = Query(0),
        maxzoom:  int = Query(12)):
      """tilejson document pointing at the /tiles endpoint."""
      # validate early
      _decode_and_validate(sql)
      with Reader(COG_PATH) as src:
        bb = list(src.get_geographic_bounds(WGS84_CRS))

      params = {"sql": sql, "colormap": colormap}
      if rescale: params["rescale"] = rescale
      if mtime:   params["mtime"]   = mtime
      qs = urlencode(params)
      base = str(request.base_url).rstrip("/")
      return {
        "tilejson": "2.2.0",
        "name":     "msens-cells",
        "bounds":   bb,
        "center":   [(bb[0]+bb[2])/2, (bb[1]+bb[3])/2, minzoom],
        "minzoom":  minzoom,
        "maxzoom":  maxzoom,
        "tiles":    [f"{base}/msens/tiles/{{z}}/{{x}}/{{y}}.png?{qs}"],
      }

    @router.get("/tiles/{z}/{x}/{y}.png", response_class=Response)
    def tile(
        z: int, x: int, y: int,
        sql:      str = Query(...),
        colormap: str = Query("spectral_r"),
        rescale:  Optional[str] = Query(None),
        mtime:    Optional[str] = Query(None)):  # noqa: ARG001  (mtime is a cache key, consumed by varnish)
      canonical = _decode_and_validate(sql)
      vmap = _load_value_map(canonical)

      r = _parse_rescale(rescale)
      if r is None:
        finite = vmap[np.isfinite(vmap)]
        if len(finite) == 0:
          raise HTTPException(status_code=404, detail="empty value map")
        r = (float(finite.min()), float(finite.max()))

      png = _render_tile(z, x, y, vmap, colormap, r)
      return Response(
        png,
        media_type="image/png",
        headers={"Cache-Control": "public, max-age=604800"})
