"""Unit tests for per-request helpers in app/tiles.py."""

from __future__ import annotations

import base64

import pytest
from fastapi import Response

from app.prune import inject_prune
from app.tiles import (
    build_cells,
    compute_etag,
    compute_stats_etag,
    decode_sql,
    set_cache_headers,
    strip_bbox_placeholder,
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


# --- strip_bbox_placeholder (backward compat) ----------------------------

def test_strip_bbox_placeholder_removes_token():
    sql = "SELECT cell_id, n AS value FROM idx_h3 WHERE res = 5 {{bbox}}"
    assert strip_bbox_placeholder(sql) == \
        "SELECT cell_id, n AS value FROM idx_h3 WHERE res = 5 "


def test_strip_bbox_placeholder_noop_when_absent():
    sql = "SELECT cell_id, value, n FROM idx_h3 WHERE res = 5"
    assert strip_bbox_placeholder(sql) == sql


# --- inject_prune (AST rewrite: add hex_prune IN(...) to spatial scans) ---

PTABLES = {"occ_h3": "hex_prune", "idx_h3": "hex_prune"}
COVER = (100, 200, 300)


def test_inject_prune_idx_h3_adds_predicate():
    sql = "SELECT cell_id, n AS value, n FROM idx_h3 WHERE res = 5"
    out, injected = inject_prune(sql, PTABLES, COVER)
    assert injected
    assert "hex_prune IN (100, 200, 300)" in out.replace('"', "")
    assert "idx_h3" in out


def test_inject_prune_targets_only_spatial_tables():
    # the recursive-CTE `taxon` table and `idx_h3_taxon` have no hex_prune -> skip;
    # only occ_h3 gets the predicate
    sql = (
        "WITH RECURSIVE taxon_tree AS ("
        "  SELECT taxonID, parentNameUsageID FROM taxon WHERE taxonID IN (1) "
        "  UNION ALL "
        "  SELECT t.taxonID, t.parentNameUsageID FROM taxon t "
        "  JOIN taxon_tree tt ON t.parentNameUsageID = tt.taxonID), "
        "src AS ("
        "  SELECT cell_id, SUM(records) AS ni FROM occ_h3 "
        "  WHERE res = 7 AND aphiaid IN (SELECT taxonID FROM taxon_tree) GROUP BY 1) "
        "SELECT cell_id, ni AS value, ni AS n FROM src"
    )
    out, injected = inject_prune(sql, PTABLES, COVER)
    assert injected
    flat = out.replace('"', "")
    assert flat.count("hex_prune IN") == 1     # only the occ_h3 scan
    assert "taxon.hex_prune" not in flat


def test_inject_prune_noop_without_cover_or_tables():
    sql = "SELECT cell_id, n AS value FROM idx_h3 WHERE res = 5"
    assert inject_prune(sql, PTABLES, ()) == (sql, False)
    assert inject_prune(sql, {}, COVER) == (sql, False)


def test_inject_prune_noop_when_no_spatial_table():
    sql = "SELECT cell_id, value, n FROM idx_h3_taxon WHERE rank = 'class'"
    out, injected = inject_prune(sql, PTABLES, COVER)
    assert not injected
    assert out == sql


# --- covering_cells (needs the duckdb h3 extension) ----------------------

def _h3_available():
    import duckdb
    try:
        duckdb.connect().execute("INSTALL h3 FROM community; LOAD h3;")
        return True
    except Exception:
        return False


@pytest.mark.skipif(not _h3_available(), reason="duckdb h3 extension unavailable")
def test_covering_cells_returns_positive_bigints_and_is_cached():
    from app.prune import covering_cells
    cov = covering_cells(3, -50.0, -40.0, -30.0, -20.0)
    assert len(cov) > 0
    assert all(isinstance(c, int) and 0 < c < 2**63 for c in cov)
    # a bigger bbox covers at least as many res-3 cells
    assert len(covering_cells(3, -55.0, -35.0, -35.0, -15.0)) >= len(cov)
    # deterministic (lru-cached)
    assert covering_cells(3, -50.0, -40.0, -30.0, -20.0) == cov


@pytest.mark.skipif(not _h3_available(), reason="duckdb h3 extension unavailable")
def test_covering_cells_skips_antimeridian():
    from app.prune import covering_cells
    # buffered box crossing +/-180 -> empty (caller falls back to a whole scan)
    assert covering_cells(3, 179.5, 179.9, 0.0, 1.0) == ()


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
