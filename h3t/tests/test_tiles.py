"""Unit tests for per-request helpers in app/tiles.py."""

from __future__ import annotations

import base64

import pytest
from fastapi import Response

from app.h3t_query import TileBBox
from app.tiles import (
    build_cells,
    compute_etag,
    compute_stats_etag,
    decode_sql,
    set_cache_headers,
    substitute_bbox,
    substitute_res,
)


# --- decode_sql ----------------------------------------------------------

def test_decode_roundtrips_utf8():
    s = "SELECT 1 AS cell_id, 2 AS value -- ünîcødé"
    enc = base64.b64encode(s.encode("utf-8")).decode("ascii")
    assert decode_sql(enc) == s


@pytest.mark.parametrize("bad", [None, "", "!!!", "not-base64"])
def test_decode_rejects_invalid(bad):
    assert decode_sql(bad) is None


# --- substitute_res ------------------------------------------------------

def test_substitute_res_replaces_all_occurrences():
    sql = "SELECT hex_h3res{{res}}, foo FROM t WHERE bar = hex_h3res{{ res }}"
    assert substitute_res(sql, 7) == \
        "SELECT hex_h3res7, foo FROM t WHERE bar = hex_h3res7"


def test_substitute_res_noop_when_absent():
    assert substitute_res("SELECT 1", 7) == "SELECT 1"


# --- substitute_bbox -----------------------------------------------------

def test_substitute_bbox_none_strips_token():
    # stats route (no bbox) collapses {{bbox}} to empty
    sql = "SELECT cell_id, n AS value FROM idx_h3 WHERE res = 5 {{bbox}}"
    out = substitute_bbox(sql, None)
    assert "{{bbox}}" not in out
    assert out == "SELECT cell_id, n AS value FROM idx_h3 WHERE res = 5 "


def test_substitute_bbox_injects_latlng_predicate():
    bbox = TileBBox(lon_min=-50.0, lon_max=-40.0, lat_min=-30.0, lat_max=-20.0)
    sql = "... WHERE res = 7 {{bbox}} GROUP BY 1"
    out = substitute_bbox(sql, bbox, buffer_deg=0.1)
    assert "{{bbox}}" not in out
    # lat is a top-level AND (prunable); lng handles the antimeridian ±360
    assert "AND lat BETWEEN -30.1000000000 AND -19.9000000000" in out
    assert "lng BETWEEN -50.1000000000 AND -39.9000000000" in out
    assert "lng + 360 BETWEEN" in out and "lng - 360 BETWEEN" in out


def test_substitute_bbox_noop_when_absent():
    # a query without the token (precomputed per-taxon path, or old clients)
    # passes through unchanged — backward compatible
    sql = "SELECT cell_id, value, n FROM idx_h3_taxon WHERE rank = 'class'"
    bbox = TileBBox(lon_min=0.0, lon_max=1.0, lat_min=0.0, lat_max=1.0)
    assert substitute_bbox(sql, bbox, buffer_deg=0.1) == sql
    assert substitute_bbox(sql, None) == sql


# --- etag ----------------------------------------------------------------

def test_etag_deterministic_and_input_sensitive():
    a = compute_etag("db1", "q", 1, 2, 3, 5, "v1", "mt")
    b = compute_etag("db1", "q", 1, 2, 3, 5, "v1", "mt")
    c = compute_etag("db2", "q", 1, 2, 3, 5, "v1", "mt")  # db differs
    d = compute_etag("db1", "q", 1, 2, 3, 6, "v1", "mt")  # res differs
    assert a == b
    assert a != c
    assert a != d
    assert len(a) == 64  # sha256 hex


def test_stats_etag_independent_of_xyz():
    s = compute_stats_etag("d", "q", "v", "m")
    assert len(s) == 64


# --- cache headers -------------------------------------------------------

def test_set_cache_headers_writes_expected():
    r = Response()
    set_cache_headers(r, "abc123", release="v1", db_mtime="1700000000")
    assert r.headers["ETag"] == 'W/"abc123"'
    assert r.headers["Cache-Control"] == "public, max-age=600"
    assert r.headers["Vary"] == "Accept-Encoding"
    assert r.headers["X-Calcofi-Release"] == "v1"
    assert r.headers["X-Calcofi-Db-Mtime"] == "1700000000"


# --- build_cells ---------------------------------------------------------

def test_build_cells_emits_n_when_present():
    cols = ["h3id", "value", "n"]
    rows = [("85283473fffffff", 1.5, 10), ("85283447fffffff", 2.0, 4)]
    cells = build_cells(cols, rows)
    assert cells == [
        {"h3id": "85283473fffffff", "value": 1.5, "n": 10},
        {"h3id": "85283447fffffff", "value": 2.0, "n": 4},
    ]


def test_build_cells_omits_null_n():
    cols = ["h3id", "value", "n"]
    rows = [("85283473fffffff", 1.5, None)]
    cells = build_cells(cols, rows)
    assert cells == [{"h3id": "85283473fffffff", "value": 1.5}]


def test_build_cells_raises_on_missing_columns():
    with pytest.raises(RuntimeError):
        build_cells(["h3id", "value"], [])
