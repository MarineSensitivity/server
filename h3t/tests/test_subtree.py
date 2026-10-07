"""Subtree + taxon endpoints against a tiny real DuckDB store.

Fixture store: genus Gadus (10) with species G. morhua (11) and G. chalcogrammus
(12), a synonym (13) of G. morhua whose parent lies outside the tree (99), and
an unrelated genus Thunnus (20) with T. thynnus (21). Two res-7 cells, rolled up
into the occ_h3 tiers 3/5/7 the way obisindicators builds them. Expected
indicators are computed here in Python, independent of the SQL.
"""

from __future__ import annotations

import math
from pathlib import Path

import duckdb
import pytest
from fastapi.testclient import TestClient

from app import subtree

# (lat, lng) of the two cells: one in the N Atlantic, one off California
CELLS = {"a": (45.0, -40.0), "b": (34.0, -120.0)}

# (cell, aphiaid, species, date_year, records)
OCC = [
    ("a", 11, "Gadus morhua",         1995, 60),
    ("a", 12, "Gadus chalcogrammus",  1995, 40),
    ("a", 21, "Thunnus thynnus",      2005, 500),
    ("b", 12, "Gadus chalcogrammus",  2003, 30),
    ("b", 13, "Gadus callarias",      1998, 5),   # synonym of 11, parent outside
    ("b", 21, "Thunnus thynnus",      2003, 7),
]

TAXON = [
    # taxonID, parent, accepted, name, rank, status
    (1,  None, 1,  "Animalia",              "Kingdom", "accepted"),
    (99, 1,    99, "Elsewhere",             "Genus",   "accepted"),
    (10, 1,    10, "Gadus",                 "Genus",   "accepted"),
    (11, 10,   11, "Gadus morhua",          "Species", "accepted"),
    (12, 10,   12, "Gadus chalcogrammus",   "Species", "accepted"),
    (13, 99,   11, "Gadus callarias",       "Species", "unaccepted"),
    (20, 1,    20, "Thunnus",               "Genus",   "accepted"),
    (21, 20,   21, "Thunnus thynnus",       "Species", "accepted"),
]


@pytest.fixture(scope="module")
def store(tmp_path_factory) -> Path:
    path = tmp_path_factory.mktemp("store") / "mini.duckdb"
    con = duckdb.connect(str(path))
    con.execute("INSTALL h3 FROM community; LOAD h3;")
    con.execute("""CREATE TABLE taxon (taxonID BIGINT, parentNameUsageID BIGINT,
      acceptedNameUsageID BIGINT, scientificName VARCHAR, taxonRank VARCHAR,
      taxonomicStatus VARCHAR)""")
    con.executemany("INSERT INTO taxon VALUES (?, ?, ?, ?, ?, ?)", TAXON)
    con.execute("""CREATE TABLE base (cell_id BIGINT, aphiaid BIGINT, species VARCHAR,
      date_year SMALLINT, records BIGINT)""")
    for c, a, sp, yr, n in OCC:
        lat, lng = CELLS[c]
        con.execute(
            "INSERT INTO base SELECT CAST(h3_latlng_to_cell(?, ?, 7) AS BIGINT), ?, ?, ?, ?",
            [lat, lng, a, sp, yr, n])
    con.execute("""CREATE TABLE occ_h3 AS
      SELECT r::UTINYINT AS res,
             CAST(h3_cell_to_parent(cell_id, r) AS BIGINT) AS cell_id,
             aphiaid, NULL::VARCHAR AS phylum, NULL::VARCHAR AS class,
             NULL::VARCHAR AS "order", NULL::VARCHAR AS family, NULL::VARCHAR AS genus,
             species, date_year, SUM(records)::BIGINT AS records,
             CAST(h3_cell_to_parent(cell_id, 3) AS BIGINT) AS hex_prune
      FROM base, (SELECT UNNEST([3, 5, 7]) AS r)
      GROUP BY ALL""")
    con.execute("DROP TABLE base")
    con.close()
    return path


@pytest.fixture(scope="module")
def sub(store):
    assert subtree.init(store, threads=1, memory_limit="256MB", rollup=True)
    return subtree


def _expected(records: list[int], esn: int = 50) -> dict:
    n = sum(records)
    p = [r / n for r in records]

    def lchoose(a, b):
        return math.lgamma(a + 1) - math.lgamma(b + 1) - math.lgamma(a - b + 1)

    if n < esn:
        es = None
    else:
        es = sum(1 - (math.exp(lchoose(n - ni, esn) - lchoose(n, esn)) if n - ni >= esn else 0)
                 for ni in records)
    return {"n": n, "sp": len(records),
            "shannon": -sum(x * math.log(x) for x in p),
            "simpson": sum(x * x for x in p), "es": es}


def _rows(sub, sql):
    cols, rows = sub.run_rows(sub.cursor(), sql)
    return [dict(zip(cols, r)) for r in rows]


def _close(a, b):
    if a is None or b is None:
        return a is None and b is None
    return math.isclose(a, b, rel_tol=1e-9, abs_tol=1e-12)


# --- SQL builder ------------------------------------------------------------

def test_tier_for():
    assert [subtree.tier_for(r) for r in range(1, 8)] == [3, 3, 3, 5, 5, 7, 7]


def test_parse_bbox():
    assert subtree.parse_bbox(None) is None
    b = subtree.parse_bbox("-130,30,-110,40")
    assert (b.w, b.s, b.e, b.n) == (-130, 30, -110, 40) and not b.crosses_antimeridian
    assert subtree.parse_bbox("170,-10,-170,10").crosses_antimeridian
    for bad in ["1,2,3", "a,b,c,d", "-200,0,0,10", "0,10,10,5"]:
        with pytest.raises(subtree.SubtreeError):
            subtree.parse_bbox(bad)


def test_aphiaid_is_int_only():
    with pytest.raises(ValueError):
        subtree.taxon_tree_cte("1; DROP TABLE taxon")  # type: ignore[arg-type]


def test_genus_subtree_with_synonym(sub):
    """Gadus = 11 + 12, plus synonym 13 (accepted 11) only via the seed widening
    when the seed itself is the synonym; 13's parent (99) is outside Gadus."""
    rows = _rows(sub, sub.subtree_sql(10, 7))
    by = {r["h3"]: r for r in rows}
    assert len(rows) == 2
    a = [r for r in rows if r["n"] == 100][0]
    exp = _expected([60, 40])
    for k in ("n", "sp", "shannon", "simpson", "es"):
        assert _close(a[k], exp[k]), (k, a[k], exp[k])
    b = [r for r in rows if r["n"] != 100][0]
    assert b["n"] == 30 and b["sp"] == 1 and b["es"] is None  # n < 50 → ES NULL
    assert all(isinstance(h, str) and len(h) == 15 for h in by)


def test_synonym_seed_resolves_to_accepted_subtree(sub):
    # seed = synonym 13 → also seeds its accepted 11 → G. morhua + G. callarias
    rows = _rows(sub, sub.subtree_sql(13, 3))
    assert sorted(r["n"] for r in rows) == [5, 60]


def test_kingdom_matches_all_taxa(sub):
    rows = _rows(sub, sub.subtree_sql(1, 5))
    a = [r for r in rows if r["n"] == 600][0]
    exp = _expected([60, 40, 500])
    for k in ("n", "sp", "shannon", "simpson", "es"):
        assert _close(a[k], exp[k]), k
    assert sorted(r["n"] for r in rows) == [42, 600]


def test_rollup_to_coarser_res_matches_finer(sub):
    """res 1 (from tier 3) sums the same records as res 7, per parent."""
    r1 = _rows(sub, sub.subtree_sql(10, 1))
    assert sorted(r["n"] for r in r1) == [30, 100]


def test_decade_filter(sub):
    rows = _rows(sub, sub.subtree_sql(1, 3, decade=2000))
    assert sorted(r["n"] for r in rows) == [37, 500]
    with pytest.raises(subtree.SubtreeError):
        sub.subtree_sql(1, 3, decade=2001)


def test_bbox_filter_on_cell_centre(sub):
    bb = subtree.parse_bbox("-130,30,-110,40")  # California only
    rows = _rows(sub, sub.subtree_sql(1, 7, bbox=bb))
    assert [r["n"] for r in rows] == [42]
    # antimeridian-crossing box that excludes both cells
    bb2 = subtree.parse_bbox("170,30,-170,50")
    assert _rows(sub, sub.subtree_sql(1, 7, bbox=bb2)) == []


def test_bbox_prune_cells_keep_result(sub):
    from app import prune
    bb = subtree.parse_bbox("-130,30,-110,40")
    cover = prune.covering_cells(3, bb.w, bb.e, bb.s, bb.n)
    assert cover
    rows = _rows(sub, sub.subtree_sql(1, 7, bbox=bb, prune_cells=cover))
    assert [r["n"] for r in rows] == [42]


def test_limit(sub):
    assert len(_rows(sub, sub.subtree_sql(1, 7, limit=1))) == 1


def test_rollup_counts(sub):
    cols, rows = sub.run_rows(sub.cursor(), sub.TAXON_ONE_SQL, [10])
    d = dict(zip(cols, rows[0]))
    assert d["records"] == 130 and d["children"] == 2 and d["rank"] == "Genus"
    cols, rows = sub.run_rows(sub.cursor(), sub.TAXON_ONE_SQL, [1])
    assert dict(zip(cols, rows[0]))["records"] == 642


# --- endpoints --------------------------------------------------------------

@pytest.fixture
def client(store, monkeypatch):
    from app import config as config_mod
    from app import db as db_mod
    from app.main import app

    monkeypatch.setattr(db_mod, "init_connections", lambda *a, **k: None)
    monkeypatch.setattr(db_mod, "_PATHS", {"obis": store})
    monkeypatch.setattr(db_mod, "_MTIMES", {"obis": "1700000000.000000"})
    monkeypatch.setattr(config_mod, "load_db_paths", lambda: ({"obis": store}, "obis"))
    monkeypatch.setattr(config_mod, "SUBTREE_MAX_CELLS", 1)
    with TestClient(app) as c:
        yield c


def test_subtree_parquet(client, tmp_path):
    r = client.get("/h3t/subtree?aphiaid=10&res=3&format=parquet",
                   headers={"Origin": "https://oceanmetrics.io"})
    assert r.status_code == 413  # 2 cells > cap of 1 (patched)
    r = client.get("/h3t/subtree?aphiaid=10&res=3&decade=2000",
                   headers={"Origin": "https://oceanmetrics.io"})
    assert r.status_code == 200, r.text
    assert r.headers["content-type"] == "application/vnd.apache.parquet"
    assert r.headers["cache-control"] == "public, max-age=86400"
    assert r.headers["access-control-allow-origin"] in ("*", "https://oceanmetrics.io")
    assert r.headers["x-rows"] == "1"
    f = tmp_path / "subtree.parquet"
    f.write_bytes(r.content)
    rows = duckdb.connect().execute(f"SELECT h3, cell_id, n, sp FROM '{f}'").fetchall()
    assert len(rows) == 1 and rows[0][2] == 30 and rows[0][3] == 1


def test_subtree_json(client):
    r = client.get("/h3t/subtree?aphiaid=11&res=5&decade=1990&format=json")
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["columns"] == ["h3", "cell_id", "n", "sp", "shannon", "simpson", "es"]
    assert [(c["n"], c["sp"], c["es"]) for c in body["cells"]] == [(60, 1, 1.0)]


def test_subtree_requires_bbox_at_fine_res(client):
    r = client.get("/h3t/subtree?aphiaid=10&res=6")
    assert r.status_code == 400 and "bbox" in r.json()["reason"]
    r = client.get("/h3t/subtree?aphiaid=10&res=7&bbox=-130,30,-110,40")
    assert r.status_code == 200 and r.headers["x-rows"] == "1"


def test_subtree_bad_params(client):
    assert client.get("/h3t/subtree?aphiaid=10&res=8").status_code == 400
    assert client.get("/h3t/subtree?aphiaid=10&res=3&decade=1995").status_code == 400
    assert client.get("/h3t/subtree?aphiaid=10&res=3&bbox=1,2").status_code == 400
    assert client.get("/h3t/subtree?aphiaid=x&res=3").status_code == 400
    assert client.get("/h3t/subtree?aphiaid=10&res=3&format=csv").status_code == 400


def test_taxon_search(client):
    r = client.get("/h3t/taxon?q=gad")
    assert r.status_code == 200
    taxa = r.json()["taxa"]
    # accepted first, then by subtree records: Gadus 130, G. morhua 60, G. chalc. 70
    assert [t["id"] for t in taxa] == [10, 12, 11, 13]
    assert taxa[0]["records"] == 130 and taxa[-1]["status"] == "unaccepted"
    assert r.headers["cache-control"] == "public, max-age=86400"


def test_taxon_one(client):
    r = client.get("/h3t/taxon/10")
    assert r.status_code == 200
    d = r.json()
    assert (d["scientificName"], d["rank"], d["children"], d["records"]) == ("Gadus", "Genus", 2, 130)
    assert client.get("/h3t/taxon/424242").status_code == 404
