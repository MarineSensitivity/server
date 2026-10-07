"""FastAPI app — h3t tile API.

Endpoints (mirror the R Plumber service):
  GET /h3t/{z}/{x}/{y}.h3t ?q=<b64>[&res_h3=N][&release=v][&db=name] → h3j tile
  GET /h3t/stats           ?q=<b64>[&res_h3=N][&release=v][&db=name] → value summary
  GET /h3t/meta                                          [&db=name]  → schema + release
  GET /h3t/health                                                    → liveness
  GET /h3t/subtree ?aphiaid=&res=[&decade=][&bbox=w,s,e,n][&format=parquet|json]
                                   → per-cell indicators for an AphiaID subtree
  GET /h3t/taxon   ?q=<prefix>[&limit=20]                → taxon name search
  GET /h3t/taxon/{aphiaid}                               → one taxon + children
"""

from __future__ import annotations

import asyncio
import hashlib
import logging
import os
import tempfile
import time
from contextlib import asynccontextmanager
from typing import AsyncIterator

from typing import Literal

from fastapi import FastAPI, HTTPException, Query, Request, Response
from fastapi.concurrency import run_in_threadpool
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from . import config, db, h3t_query, prune, subtree, tiles
from .sql_validate import validate as validate_sql

log = logging.getLogger("h3t")
# uvicorn configures only its own loggers; give ours a handler so the per-request
# query time / row count lines reach `docker compose logs h3t`
if not log.handlers:
    _h = logging.StreamHandler()
    _h.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
    log.addHandler(_h)
    log.setLevel(logging.INFO)
    log.propagate = False


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    registry, default_name = config.load_db_paths()
    db.init_connections(
        registry,
        threads=config.DUCKDB_THREADS,
        memory_limit=config.DUCKDB_MEMORY_LIMIT)
    app.state.default_db = default_name
    if config.SUBTREE_ENABLED:
        path = db.db_path(default_name)
        if path.exists():
            t0 = time.perf_counter()
            ok = subtree.init(
                path,
                threads=config.SUBTREE_THREADS,
                memory_limit=config.SUBTREE_MEMORY_LIMIT,
                rollup=config.SUBTREE_ROLLUP)
            log.info("subtree %s on %s (%.1fs)",
                     "ready" if ok else "disabled: no taxon/occ_h3 table",
                     path, time.perf_counter() - t0)
    log.info("h3t ready: dbs=%s default=%s", db.db_names(), default_name)
    yield


app = FastAPI(title="api-h3t", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=config.CORS_ORIGINS,
    allow_methods=["GET", "OPTIONS"],
    allow_headers=["Content-Type", "If-None-Match"],
    expose_headers=["ETag", "X-Calcofi-Release", "X-Calcofi-Db-Mtime", "X-Cache",
                    "X-Rows", "X-Query-Ms", "X-Aphiaid"],
    max_age=600,
)

if config.APP_GZIP:
    from fastapi.middleware.gzip import GZipMiddleware
    app.add_middleware(GZipMiddleware, minimum_size=1024)


# --- error responses (parity with R service shape) -----------------------

@app.exception_handler(HTTPException)
async def _http_exception(_req: Request, exc: HTTPException) -> JSONResponse:
    # match the R service shape: {"error": "bad_request", "reason": "..."}
    # for 4xx (except 422); upgrade 422 → 400 with reason.
    code = exc.status_code
    if code == 400:
        return JSONResponse(
            status_code=400,
            content={"error": "bad_request", "reason": str(exc.detail)},
        )
    if code == 500:
        return JSONResponse(
            status_code=500,
            content={"error": "query_failed", "reason": str(exc.detail)},
        )
    return JSONResponse(status_code=code, content={"reason": str(exc.detail)})


@app.exception_handler(RequestValidationError)
async def _validation_exception(
    _req: Request, exc: RequestValidationError
) -> JSONResponse:
    # Pydantic validation errors → 400 with a flattened reason, matching R.
    errs = exc.errors()
    reason = "; ".join(f"{'.'.join(str(p) for p in e['loc'])}: {e['msg']}" for e in errs)
    return JSONResponse(
        status_code=400,
        content={"error": "bad_request", "reason": reason},
    )


# --- helpers -------------------------------------------------------------

def _resolve_db(db_arg: str | None) -> str:
    return db_arg or app.state.default_db


def _validate_q(q: str | None, res_h3: int | None) -> dict:
    sql = tiles.decode_sql(q)
    if sql is None:
        raise HTTPException(400, "q is required and must be valid base64")
    if res_h3 is not None:
        sql = tiles.substitute_res(sql, res_h3)
    # backward-compat: strip any {{bbox}} token from cached URLs minted by the
    # earlier placeholder clients (the server now auto-injects hex_prune). Must
    # run before validate_sql, which parses + re-serializes via sqlglot.
    sql = tiles.strip_bbox_placeholder(sql)
    v = validate_sql(sql)
    if not v.get("ok"):
        raise HTTPException(400, v.get("reason") or "invalid SQL")
    return v


# --- endpoints -----------------------------------------------------------

@app.get("/h3t/health")
async def health() -> dict:
    return {
        "ok": True,
        "default_db": app.state.default_db,
        "dbs": {
            name: {"path": str(db.db_path(name)), "mtime": db.db_mtime(name)}
            for name in db.db_names()
        },
    }


@app.get("/h3t/{z}/{x}/{y}.h3t")
async def tile(
    z: int, x: int, y: int,
    response: Response,
    q: str = Query(..., description="base64-encoded user SELECT"),
    res_h3: int | None = Query(None, ge=1, le=10),
    release: str = "",
    db_name: str | None = Query(None, alias="db"),
) -> dict:
    try:
        bbox = h3t_query.tile_bbox(z, x, y)
    except ValueError as e:
        raise HTTPException(400, f"invalid z/x/y: {e}") from e

    qres = res_h3 if res_h3 is not None else h3t_query.zoom_to_res(z)
    if not 1 <= qres <= 10:
        raise HTTPException(400, "res_h3 must be in [1, 10]")

    name = _resolve_db(db_name)
    con = db.get_connection(name)
    db_mtime = db.db_mtime(name)

    v = _validate_q(q, qres)

    # automatic per-tile spatial prune: derive the tile's covering coarse H3
    # cells from z/x/y and inject `hex_prune IN (...)` into any scan of a table
    # that carries hex_prune. Skipped for tiles coarser than the prune res (those
    # rows aren't keyed on a res-PRUNE_RES parent) or when the covering set is too
    # large (huge low-zoom tiles). Correctness is always held by the outer
    # centroid filter below, so injection is a pure speed-up.
    inner = v["normalized"]
    ptables = db.prune_tables(name)
    if ptables and qres >= config.PRUNE_RES:
        cover = prune.covering_cells(
            config.PRUNE_RES, bbox.lon_min, bbox.lon_max, bbox.lat_min, bbox.lat_max)
        if cover and len(cover) <= config.MAX_COVER_CELLS:
            inner, _ = prune.inject_prune(inner, ptables, cover)

    wrapped = h3t_query.wrap_tile_sql(
        inner, bbox, has_n=bool(v.get("has_n")),
        max_rows=config.MAX_ROWS_PER_TILE,
        buffer_deg=h3t_query.h3_edge_length_deg(qres) * 1.5,
    )

    cur = con.cursor()
    try:
        cols, rows = await asyncio.wait_for(
            run_in_threadpool(db.execute_query, cur, wrapped),
            timeout=config.STMT_TIMEOUT_MS / 1000,
        )
    except asyncio.TimeoutError:
        # asyncio.wait_for only abandons the await — the DuckDB call keeps
        # running in the threadpool. interrupt() actually cancels it so it
        # stops consuming a serving thread. cur.close() is owned by the worker.
        try:
            cur.interrupt()
        except Exception:
            log.exception("failed to interrupt timed-out tile query")
        log.warning("tile query timeout (>%dms)", config.STMT_TIMEOUT_MS)
        raise HTTPException(504, "query timeout")
    except Exception as e:
        log.exception("tile query failed")
        raise HTTPException(500, str(e)) from e

    etag = tiles.compute_etag(name, q, z, x, y, qres, release, db_mtime)
    tiles.set_cache_headers(response, etag, release, db_mtime)
    return {"cells": tiles.build_cells(cols, rows)}


@app.get("/h3t/stats")
async def stats(
    response: Response,
    q: str = Query(...),
    release: str = "",
    res_h3: int = Query(5, ge=1, le=10),
    db_name: str | None = Query(None, alias="db"),
) -> dict:
    name = _resolve_db(db_name)
    con = db.get_connection(name)
    db_mtime = db.db_mtime(name)

    v = _validate_q(q, res_h3)
    wrapped = h3t_query.wrap_stats_sql(v["normalized"])

    cur = con.cursor()
    try:
        cols, row = await asyncio.wait_for(
            run_in_threadpool(db.execute_query_one, cur, wrapped),
            timeout=config.STMT_TIMEOUT_MS / 1000,
        )
    except asyncio.TimeoutError:
        # cancel the abandoned DuckDB query so it frees its serving thread
        # (see the tile route for the full rationale).
        try:
            cur.interrupt()
        except Exception:
            log.exception("failed to interrupt timed-out stats query")
        log.warning("stats query timeout (>%dms)", config.STMT_TIMEOUT_MS)
        raise HTTPException(504, "query timeout")
    except Exception as e:
        log.exception("stats query failed")
        raise HTTPException(500, str(e)) from e

    etag = tiles.compute_stats_etag(name, q, release, db_mtime)
    tiles.set_cache_headers(response, etag, release, db_mtime)

    body: dict = dict(zip(cols, row)) if row is not None else dict.fromkeys(cols)
    body["release"] = release
    body["db_mtime"] = db_mtime
    return body


@app.get("/h3t/meta")
async def meta(
    response: Response,
    db_name: str | None = Query(None, alias="db"),
) -> dict:
    name = _resolve_db(db_name)
    con = db.get_connection(name)
    tables = await run_in_threadpool(db.list_tables, con)
    response.headers["Cache-Control"] = "public, max-age=60"
    response.headers["Vary"] = "Accept-Encoding"
    return {
        "db": name,
        "db_mtime": db.db_mtime(name),
        "tables": tables,
        "h3_columns_per_row": [f"hex_h3res{r}" for r in range(1, 11)],
        "default_zoom_breaks": h3t_query.h3t_zoom_breaks,
        "available_dbs": db.db_names(),
        "default_db": app.state.default_db,
    }


# --- subtree + taxon (dedicated capped DuckDB instance; see app/subtree.py) ---

PARQUET_MEDIA_TYPE = "application/vnd.apache.parquet"
_subtree_sem = asyncio.Semaphore(config.SUBTREE_CONCURRENCY)


def _require_subtree() -> None:
    if not subtree.enabled():
        raise HTTPException(503, "subtree/taxon endpoints unavailable: the store has no taxon table")


def _subtree_cache_headers(response: Response, key: str) -> str:
    mtime = db.db_mtime(app.state.default_db)
    etag  = 'W/"' + hashlib.sha1(f"{key}|{mtime}".encode()).hexdigest()[:20] + '"'
    response.headers["ETag"]          = etag
    response.headers["Cache-Control"] = f"public, max-age={config.SUBTREE_MAX_AGE}"
    response.headers["Vary"]          = "Accept-Encoding"
    response.headers["X-Calcofi-Db-Mtime"] = mtime
    return etag


async def _run_subtree(fn, *args, what: str):
    """Run a blocking subtree-instance call under the concurrency cap + timeout."""
    cur = args[0]
    async with _subtree_sem:
        try:
            return await asyncio.wait_for(
                run_in_threadpool(fn, *args), timeout=config.SUBTREE_TIMEOUT_S)
        except asyncio.TimeoutError:
            try:
                cur.interrupt()
            except Exception:
                log.exception("failed to interrupt timed-out %s query", what)
            log.warning("%s query timeout (>%.0fs)", what, config.SUBTREE_TIMEOUT_S)
            raise HTTPException(504, f"query timeout (>{config.SUBTREE_TIMEOUT_S:.0f}s)")
        except HTTPException:
            raise
        except Exception as e:
            log.exception("%s query failed", what)
            raise HTTPException(500, str(e)) from e


@app.get("/h3t/subtree")
async def subtree_route(
    aphiaid: int = Query(..., ge=1, description="WoRMS AphiaID (root of the subtree)"),
    res: int = Query(..., ge=1, le=7, description="H3 resolution 1-7"),
    decade: int | None = Query(None, ge=1000, le=2990, description="first year of a decade, e.g. 1990"),
    bbox: str | None = Query(None, description="w,s,e,n in degrees; required for res >= 6"),
    format: Literal["parquet", "json"] = "parquet",
) -> Response:
    _require_subtree()
    try:
        bb = subtree.parse_bbox(bbox)
        if decade is not None and decade % 10 != 0:
            raise subtree.SubtreeError("decade must be a year ending in 0, e.g. 1990")
    except subtree.SubtreeError as e:
        raise HTTPException(400, str(e)) from e
    if res >= config.SUBTREE_BBOX_MIN_RES and bb is None:
        raise HTTPException(400, f"bbox (w,s,e,n) is required for res >= {config.SUBTREE_BBOX_MIN_RES}")

    # row-group prune on the stored res-3 parent: only valid when output cells
    # are at least as fine as the prune res (coarser cells span many parents)
    cover = None
    if bb is not None and res >= subtree.PRUNE_RES and not bb.crosses_antimeridian:
        c = prune.covering_cells(subtree.PRUNE_RES, bb.w, bb.e, bb.s, bb.n)
        if c and len(c) <= subtree.MAX_PRUNE_CELLS:
            cover = c

    cap = config.SUBTREE_MAX_CELLS
    sql = subtree.subtree_sql(aphiaid, res, decade=decade, bbox=bb,
                              prune_cells=cover, limit=cap + 1)
    t0 = time.perf_counter()
    if format == "parquet":
        fd, out = tempfile.mkstemp(prefix="h3t_subtree_", suffix=".parquet")
        os.close(fd)
        try:
            nrow = await _run_subtree(subtree.run_copy_parquet, subtree.cursor(), sql, out,
                                      what="subtree")
            if nrow <= cap:
                with open(out, "rb") as f:
                    body = f.read()
        finally:
            try:
                os.unlink(out)
            except OSError:
                pass
    else:
        cols, rows = await _run_subtree(subtree.run_rows, subtree.cursor(), sql,
                                        what="subtree")
        nrow = len(rows)
    ms = (time.perf_counter() - t0) * 1000
    log.info("subtree aphiaid=%d res=%d decade=%s bbox=%s format=%s rows=%d ms=%.0f",
             aphiaid, res, decade, bbox, format, nrow, ms)
    if nrow > cap:
        raise HTTPException(
            413, f"result exceeds {cap} cells; use a coarser res or a smaller bbox")

    if format == "parquet":
        response = Response(content=body, media_type=PARQUET_MEDIA_TYPE)
    else:
        response = JSONResponse({
            "aphiaid": aphiaid, "res": res, "decade": decade, "bbox": bbox,
            "columns": cols,
            "cells": [dict(zip(cols, r)) for r in rows]})
    _subtree_cache_headers(
        response, f"subtree|{aphiaid}|{res}|{decade}|{bbox}|{format}")
    response.headers["X-Rows"]     = str(nrow)
    response.headers["X-Query-Ms"] = f"{ms:.0f}"
    response.headers["X-Aphiaid"]  = str(aphiaid)
    return response


@app.get("/h3t/taxon")
async def taxon_search(
    response: Response,
    q: str = Query(..., min_length=1, max_length=100, description="scientificName prefix"),
    limit: int = Query(20, ge=1, le=100),
) -> dict:
    _require_subtree()
    t0 = time.perf_counter()
    cols, rows = await _run_subtree(
        subtree.run_rows, subtree.cursor(), subtree.taxon_search_sql(limit), [q.strip()],
        what="taxon")
    ms = (time.perf_counter() - t0) * 1000
    log.info("taxon q=%r rows=%d ms=%.0f", q, len(rows), ms)
    _subtree_cache_headers(response, f"taxon|{q.strip().lower()}|{limit}")
    response.headers["X-Rows"]     = str(len(rows))
    response.headers["X-Query-Ms"] = f"{ms:.0f}"
    return {"q": q, "taxa": [dict(zip(cols, r)) for r in rows]}


@app.get("/h3t/taxon/{aphiaid}")
async def taxon_one(response: Response, aphiaid: int) -> dict:
    _require_subtree()
    t0 = time.perf_counter()
    cols, rows = await _run_subtree(
        subtree.run_rows, subtree.cursor(), subtree.TAXON_ONE_SQL, [aphiaid],
        what="taxon")
    ms = (time.perf_counter() - t0) * 1000
    log.info("taxon id=%d rows=%d ms=%.0f", aphiaid, len(rows), ms)
    if not rows:
        raise HTTPException(404, f"AphiaID {aphiaid} not in the taxon table")
    _subtree_cache_headers(response, f"taxon_one|{aphiaid}")
    response.headers["X-Query-Ms"] = f"{ms:.0f}"
    return dict(zip(cols, rows[0]))
