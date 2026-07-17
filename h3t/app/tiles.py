"""Per-request helpers: base64 SQL decode, {{res}} substitution, h3j payload
assembly, ETag, cache headers."""

from __future__ import annotations

import base64
import hashlib
import re
from typing import Any, Iterable

from fastapi import Response


_RES_PLACEHOLDER = re.compile(r"\{\{\s*res\s*\}\}")
_BBOX_PLACEHOLDER = re.compile(r"\{\{\s*bbox\s*\}\}")


def decode_sql(q: str | None) -> str | None:
    """Base64-decode a SQL query. Returns None on missing/invalid input."""
    if not q:
        return None
    try:
        return base64.b64decode(q, validate=True).decode("utf-8")
    except (ValueError, UnicodeDecodeError):
        return None


def substitute_res(sql: str, res_h3: int) -> str:
    """Replace `{{res}}` placeholders with an integer H3 resolution.

    Lets clients bake `hex_h3res{{res}}` into a single base64 query that
    covers every zoom level — the server fills in the actual resolution.
    """
    return _RES_PLACEHOLDER.sub(str(int(res_h3)), sql)


def substitute_bbox(sql: str, bbox=None, buffer_deg: float = 0.0) -> str:
    """Replace `{{bbox}}` with a stored-lat/lng predicate that prunes the scan
    to the tile, or with empty when there is no bbox (e.g. the stats route).

    Clients (obisindicators::obis_h3t_sql) bake `{{bbox}}` into the WHERE of the
    `occ_h3` / `idx_h3` scan. Those tables carry precomputed `lat`/`lng` columns
    and are physically clustered by `(res, lat, lng)`, so a `lat/lng BETWEEN`
    predicate lets DuckDB prune row groups to the tile instead of aggregating
    the whole globe per tile.

    `bbox` is an `h3t_query.TileBBox`. `buffer_deg` must be large enough that
    this inner (base-cell) filter is a SUPERSET of the outer (display-cell
    centroid) filter applied by `wrap_tile_sql` — otherwise a cell straddling
    the tile edge could be dropped or under-counted. The tile route passes a
    larger buffer here than the outer wrap for exactly that reason.

    Queries that contain no `{{bbox}}` token (the precomputed per-taxon path, or
    any pre-existing client) pass through unchanged — the substitution is a
    no-op, so this is fully backward compatible.
    """
    if bbox is None:
        return _BBOX_PLACEHOLDER.sub("", sql)
    lm = bbox.lon_min - buffer_deg
    lM = bbox.lon_max + buffer_deg
    am = bbox.lat_min - buffer_deg
    aM = bbox.lat_max + buffer_deg
    # lat kept as a top-level AND so its zonemap prunes even though the lng OR
    # (antimeridian ±360) can't prune; tiles are thin in lat, so lat pruning
    # alone gives the row-group reduction.
    pred = (
        f"AND lat BETWEEN {am:.10f} AND {aM:.10f} "
        f"AND (lng BETWEEN {lm:.10f} AND {lM:.10f} "
        f"OR lng + 360 BETWEEN {lm:.10f} AND {lM:.10f} "
        f"OR lng - 360 BETWEEN {lm:.10f} AND {lM:.10f})"
    )
    # function replacement avoids re.sub interpreting backslashes/group refs
    return _BBOX_PLACEHOLDER.sub(lambda _m: pred, sql)


def compute_etag(
    db_name: str,
    q: str,
    z: int,
    x: int,
    y: int,
    res_h3: int,
    release: str,
    db_mtime: str,
) -> str:
    """Stable SHA-256 over a delimited string of cache-relevant inputs.

    The R service hashes the same logical tuple via digest::digest() on an
    R list, which uses R's internal serialization. We adopt a stable
    string-based scheme that both services can match (R update is part of
    the cutover); see plan §5.
    """
    payload = f"{db_name}|{q}|{z}|{x}|{y}|{res_h3}|{release}|{db_mtime}"
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def compute_stats_etag(db_name: str, q: str, release: str, db_mtime: str) -> str:
    payload = f"stats|{db_name}|{q}|{release}|{db_mtime}"
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def set_cache_headers(
    response: Response,
    etag: str,
    release: str = "",
    db_mtime: str = "",
    max_age: int = 600,
) -> None:
    response.headers["Cache-Control"] = f"public, max-age={int(max_age)}"
    response.headers["ETag"] = f'W/"{etag}"'
    # Vary on Accept-Encoding so Varnish caches gzip and non-gzip variants
    # separately when it does the compression upstream.
    response.headers["Vary"] = "Accept-Encoding"
    if release:
        response.headers["X-Calcofi-Release"] = release
    if db_mtime:
        response.headers["X-Calcofi-Db-Mtime"] = db_mtime


def build_cells(
    columns: list[str], rows: Iterable[tuple[Any, ...]]
) -> list[dict[str, Any]]:
    """Convert wrapped-query rows into the h3j `cells` payload.

    Expects columns ['h3id', 'value', 'n']. Drops 'n' entries that are None
    so the JSON omits the field rather than emitting `null` (matches the
    R behavior of skipping NA n values).
    """
    try:
        i_h3id = columns.index("h3id")
        i_value = columns.index("value")
        i_n = columns.index("n")
    except ValueError as e:
        raise RuntimeError(
            f"wrapped query did not project expected columns; got {columns}"
        ) from e

    out: list[dict[str, Any]] = []
    for r in rows:
        cell: dict[str, Any] = {"h3id": r[i_h3id], "value": r[i_value]}
        n = r[i_n]
        if n is not None:
            cell["n"] = int(n)
        out.append(cell)
    return out
