"""/h3t/cell: the species in one cell, against a tiny real DuckDB store.

Fixture store: genus Gadus (10) with G. morhua (11) and G. chalcogrammus (12), a
synonym of G. morhua (13) whose parent lies outside the tree, genus Thunnus (20)
with T. thynnus (21), its subspecies (23) and an unaccepted homonym "Thunnus
thynnus" (24). OBIS records carry the accepted species name, so a record of
13 is "Gadus morhua" and a record of 23 is "Thunnus thynnus". Two res-7 cells,
rolled up into the occ_h3 tiers 3/5/7 the way obisindicators builds them.
Expected lists are computed here in Python; n and sp are also checked against
the subtree endpoint's indicator SQL (the same formula as the release layers).
"""

from __future__ import annotations

from pathlib import Path

import duckdb
import pytest
from fastapi.testclient import TestClient

from app import cell, subtree

CELLS = {"a": (45.0, -40.0), "b": (34.0, -120.0)}

GAD = ("Chordata", "Teleostei", "Gadiformes", "Gadidae")
SCO = ("Chordata", "Teleostei", "Scombriformes", "Scombridae")

# (cell, aphiaid, taxonomy, species, date_year, records)
OCC = [
    ("a", 11, GAD, "Gadus morhua",         1995, 60),
    ("a", 11, GAD, "Gadus morhua",         2001, 15),
    ("a", 12, GAD, "Gadus chalcogrammus",  1995, 40),
    ("a", 21, SCO, "Thunnus thynnus",      2005, 500),
    ("a", 23, SCO, "Thunnus thynnus",      None, 5),    # subspecies, no year
    ("b", 12, GAD, "Gadus chalcogrammus",  2003, 30),
    ("b", 13, GAD, "Gadus morhua",         1998, 5),    # synonym AphiaID
    ("b", 23, SCO, "Thunnus thynnus",      2003, 7),    # only the subspecies here
]

TAXON = [
    # taxonID, parent, accepted, name, rank, status
    (1,  None, 1,  "Animalia",                "Kingdom",    "accepted"),
    (99, 1,    99, "Elsewhere",               "Genus",      "accepted"),
    (10, 1,    10, "Gadus",                   "Genus",      "accepted"),
    (11, 10,   11, "Gadus morhua",            "Species",    "accepted"),
    (12, 10,   12, "Gadus chalcogrammus",     "Species",    "accepted"),
    (13, 99,   11, "Gadus callarias",         "Species",    "unaccepted"),
    (20, 1,    20, "Thunnus",                 "Genus",      "accepted"),
    (21, 20,   21, "Thunnus thynnus",         "Species",    "accepted"),
    (23, 21,   23, "Thunnus thynnus thynnus", "Subspecies", "accepted"),
    (24, 99,   21, "Thunnus thynnus",         "Species",    "unaccepted"),
]

# the store's eov table holds every taxonID of an EOV's subtree
EOV = [("cod", 10), ("cod", 11), ("cod", 12), ("cod", 13)]


@pytest.fixture(scope="module")
def store(tmp_path_factory) -> Path:
    path = tmp_path_factory.mktemp("store") / "obis_h3_global_v20990101.duckdb"
    con = duckdb.connect(str(path))
    con.execute("INSTALL h3 FROM community; LOAD h3;")
    con.execute("""CREATE TABLE taxon (taxonID BIGINT, parentNameUsageID BIGINT,
      acceptedNameUsageID BIGINT, scientificName VARCHAR, taxonRank VARCHAR,
      taxonomicStatus VARCHAR)""")
    con.executemany("INSERT INTO taxon VALUES (?, ?, ?, ?, ?, ?)", TAXON)
    con.execute("CREATE TABLE eov (eov VARCHAR, taxonID BIGINT)")
    con.executemany("INSERT INTO eov VALUES (?, ?)", EOV)
    con.execute("""CREATE TABLE base (cell_id BIGINT, aphiaid BIGINT, phylum VARCHAR,
      class VARCHAR, "order" VARCHAR, family VARCHAR, species VARCHAR,
      date_year SMALLINT, records BIGINT)""")
    for c, a, tx, sp, yr, n in OCC:
        lat, lng = CELLS[c]
        con.execute(
            "INSERT INTO base SELECT CAST(h3_latlng_to_cell(?, ?, 7) AS BIGINT), ?, ?, ?, ?, ?, ?, ?, ?",
            [lat, lng, a, *tx, sp, yr, n])
    con.execute("""CREATE TABLE occ_h3 AS
      SELECT r::UTINYINT AS res,
             CAST(h3_cell_to_parent(cell_id, r) AS BIGINT) AS cell_id,
             aphiaid, phylum, class, "order", family, NULL::VARCHAR AS genus,
             species, date_year, SUM(records)::BIGINT AS records,
             CAST(h3_cell_to_parent(cell_id, 3) AS BIGINT) AS hex_prune
      FROM base, (SELECT UNNEST([3, 5, 7]) AS r)
      GROUP BY ALL""")
    con.execute("DROP TABLE base")
    con.close()
    return path


@pytest.fixture(scope="module")
def sub(store):
    assert subtree.init(store, threads=1, memory_limit="256MB", rollup=False)
    return subtree


@pytest.fixture(scope="module")
def h3con():
    c = duckdb.connect()
    c.execute("INSTALL h3 FROM community; LOAD h3;")
    return c


def _cell(h3con, key: str, res: int) -> int:
    """The res-`res` cell holding the fixture's records: the parent of its res-7
    cell (H3 parents do not nest exactly, so for res < 7 this is not always the
    point's own res-`res` cell); beyond res 7, the point's cell."""
    lat, lng = CELLS[key]
    if res > 7:
        return h3con.execute("SELECT h3_latlng_to_cell(?, ?, ?)::UBIGINT",
                             [lat, lng, res]).fetchone()[0]
    return h3con.execute(
        "SELECT h3_cell_to_parent(h3_latlng_to_cell(?, ?, 7), ?)::UBIGINT",
        [lat, lng, res]).fetchone()[0]


def _species(sub, q: cell.CellQuery) -> list[dict]:
    sql, params = cell.cell_species_sql(q)
    cols, rows = sub.run_rows(sub.cursor(), sql, params)
    return [dict(zip(cols, r)) for r in rows]


def _expected(key: str, keep=lambda o: True) -> dict[str, tuple[int, int | None, int | None]]:
    """species → (records, year_min, year_max) for the cell, from OCC."""
    out: dict[str, list] = {}
    for o in OCC:
        if o[0] != key or not keep(o):
            continue
        rec = out.setdefault(o[3], [0, None, None])
        rec[0] += o[5]
        if o[4] is not None:
            rec[1] = o[4] if rec[1] is None else min(rec[1], o[4])
            rec[2] = o[4] if rec[2] is None else max(rec[2], o[4])
    return {k: tuple(v) for k, v in out.items()}


def _as_expected(rows: list[dict]) -> dict:
    return {r["species"]: (r["records"], r["year_min"], r["year_max"]) for r in rows}


# --- H3 bit arithmetic ------------------------------------------------------

def test_parse_cell(h3con):
    for r in range(1, 8):
        i = _cell(h3con, "a", r)
        assert cell.parse_cell(format(i, "x")) == (i, r)
        assert cell.parse_cell(format(i, "X")) == (i, r)
    for bad in ["", "xyz", "0" * 15, "zz2830828052d25", "84ad369ffffffff0" + "f",
                "84ad369fffffffe"]:  # digit past res not 7
        with pytest.raises(subtree.SubtreeError):
            cell.parse_cell(bad)
    # valid H3 cells outside the store's res range
    for r in (0, 8, 15):
        with pytest.raises(subtree.SubtreeError, match="resolution"):
            cell.parse_cell(format(_cell(h3con, "a", r), "x"))


def test_parent_matches_h3(h3con):
    for r in range(1, 8):
        i = _cell(h3con, "b", r)
        for p in range(0, r + 1):
            want = h3con.execute("SELECT h3_cell_to_parent(?::UBIGINT, ?)::UBIGINT", [i, p]).fetchone()[0]
            assert cell.cell_to_parent(i, p) == want, (r, p)


def test_descendant_range_is_exact(h3con):
    """The range holds all res-t children of the cell and no child of a neighbour,
    for hexagons and for a pentagon."""
    pent = h3con.execute("SELECT h3_get_pentagons(2)[1]::UBIGINT").fetchone()[0]
    for i, r in [(_cell(h3con, "a", 1), 1), (_cell(h3con, "a", 2), 2), (pent, 2),
                 (_cell(h3con, "b", 4), 4)]:
        for t in (r, 3, 5, 7):
            if t < r:
                continue
            lo, hi = cell.descendant_range(i, r, t)
            kids = [k for (k,) in h3con.execute(
                "SELECT UNNEST(h3_cell_to_children(?::UBIGINT, ?))::UBIGINT", [i, t]).fetchall()]
            assert all(lo <= k <= hi for k in kids), (r, t)
            ring = [k for (k,) in h3con.execute(
                "SELECT UNNEST(h3_grid_disk(?::UBIGINT, 1))::UBIGINT", [i]).fetchall() if k != i]
            for nb in ring:
                lo2, hi2 = cell.descendant_range(nb, r, t)
                assert hi2 < lo or lo2 > hi, (r, t, nb)


# --- the species list -------------------------------------------------------

def test_all_taxa_list(sub, h3con):
    rows = _species(sub, cell.CellQuery(_cell(h3con, "a", 7), 7))
    assert [r["species"] for r in rows] == ["Thunnus thynnus", "Gadus morhua", "Gadus chalcogrammus"]
    assert _as_expected(rows) == _expected("a")
    assert _as_expected(rows)["Thunnus thynnus"] == (505, 2005, 2005)   # the no-year record counts
    assert _as_expected(rows)["Gadus morhua"] == (75, 1995, 2001)
    assert rows[0]["family"] == "Scombridae" and rows[1]["order"] == "Gadiformes"


def test_aphiaid_is_the_species_taxon(sub, h3con):
    """The AphiaID is the accepted species-rank taxon of the name, not the
    recorded subspecies (23) or synonym (13), nor the unaccepted homonym (24)."""
    rows = _species(sub, cell.CellQuery(_cell(h3con, "b", 5), 5))
    assert {r["species"]: r["aphiaid"] for r in rows} == {
        "Gadus chalcogrammus": 12, "Thunnus thynnus": 21, "Gadus morhua": 11}


@pytest.mark.parametrize("res", range(1, 8))
def test_every_res_sums_to_the_indicators(sub, h3con, res):
    """All taxa (the kingdom's subtree): n and sp equal the indicator SQL's."""
    ind = {r[1]: r for r in sub.run_rows(sub.cursor(), sub.subtree_sql(1, res))[1]}
    for key in CELLS:
        i = _cell(h3con, key, res)
        rows = _species(sub, cell.CellQuery(i, res))
        assert _as_expected(rows) == _expected(key)
        assert (sum(r["records"] for r in rows), len(rows)) == (ind[i][2], ind[i][3])


@pytest.mark.parametrize("aphiaid", [10, 11, 13, 20, 21, 23])
def test_subtree_filter_matches_subtree_endpoint(sub, h3con, aphiaid):
    for res in (2, 5, 7):
        ind = {r[1]: r for r in sub.run_rows(sub.cursor(), sub.subtree_sql(aphiaid, res))[1]}
        for key in CELLS:
            i = _cell(h3con, key, res)
            rows = _species(sub, cell.CellQuery(i, res, aphiaid=aphiaid))
            got = (sum(r["records"] for r in rows), len(rows))
            want = (ind[i][2], ind[i][3]) if i in ind else (0, 0)
            assert got == want, (aphiaid, res, key)


def test_decade(sub, h3con):
    for res in (3, 7):
        ind = {r[1]: r for r in sub.run_rows(sub.cursor(), sub.subtree_sql(1, res, decade=1990))[1]}
        i = _cell(h3con, "a", res)
        rows = _species(sub, cell.CellQuery(i, res, decade=1990))
        assert _as_expected(rows) == {"Gadus morhua": (60, 1995, 1995),
                                      "Gadus chalcogrammus": (40, 1995, 1995)}
        assert (sum(r["records"] for r in rows), len(rows)) == (ind[i][2], ind[i][3])


def test_eov(sub, h3con):
    rows = _species(sub, cell.CellQuery(_cell(h3con, "b", 7), 7, eov="cod"))
    assert _as_expected(rows) == _expected("b", lambda o: o[1] in {10, 11, 12, 13})
    assert _species(sub, cell.CellQuery(_cell(h3con, "b", 7), 7, eov="birds")) == []


def test_rank_taxon(sub, h3con):
    rows = _species(sub, cell.CellQuery(_cell(h3con, "a", 4), 4, rank="family", taxon="Scombridae"))
    assert _as_expected(rows) == {"Thunnus thynnus": (505, 2005, 2005)}
    rows = _species(sub, cell.CellQuery(_cell(h3con, "a", 4), 4, rank="order", taxon="Gadiformes"))
    assert _as_expected(rows) == _expected("a", lambda o: o[2] == GAD)
    # a value is a parameter, never SQL
    assert _species(sub, cell.CellQuery(_cell(h3con, "a", 4), 4, rank="family",
                                        taxon="x' OR 1=1 --")) == []


def test_query_validation():
    for kw in [dict(aphiaid=1, eov="cod"), dict(eov="cod", rank="family", taxon="X"),
               dict(rank="family"), dict(taxon="X"), dict(rank="genus", taxon="X"),
               dict(rank='family" OR 1=1 --', taxon="X"), dict(decade=1995)]:
        with pytest.raises(subtree.SubtreeError):
            cell.CellQuery(1, 3, **kw)


# --- endpoint ---------------------------------------------------------------

@pytest.fixture
def client(store, monkeypatch):
    from app import config as config_mod
    from app import db as db_mod
    from app.main import app

    monkeypatch.setattr(db_mod, "init_connections", lambda *a, **k: None)
    monkeypatch.setattr(db_mod, "_PATHS", {"obis": store})
    monkeypatch.setattr(db_mod, "_MTIMES", {"obis": "1700000000.000000"})
    monkeypatch.setattr(config_mod, "load_db_paths", lambda: ({"obis": store}, "obis"))
    monkeypatch.setattr(config_mod, "SUBTREE_ROLLUP", False)
    with TestClient(app) as c:
        yield c


def test_cell_json(client, h3con):
    h = format(_cell(h3con, "a", 6), "x")
    r = client.get(f"/h3t/cell?h3={h}&decade=2000&release=v20990101",
                   headers={"Origin": "https://oceanmetrics.io"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["columns"] == list(cell.COLUMNS)
    assert (body["h3"], body["res"], body["decade"]) == (h, 6, 2000)
    assert body["store"] == "obis_h3_global_v20990101.duckdb"
    assert (body["n"], body["sp"]) == (515, 2)
    assert body["species"][0] == {
        "species": "Thunnus thynnus", "aphiaid": 21, "phylum": "Chordata",
        "class": "Teleostei", "order": "Scombriformes", "family": "Scombridae",
        "records": 500, "year_min": 2005, "year_max": 2005}
    assert r.headers["cache-control"] == "public, max-age=86400"
    assert r.headers["x-rows"] == "2" and "etag" in r.headers
    assert r.headers["access-control-allow-origin"] in ("*", "https://oceanmetrics.io")


def test_cell_filters(client, h3con):
    h = format(_cell(h3con, "b", 3), "x")
    assert client.get(f"/h3t/cell?h3={h}&aphiaid=10").json()["n"] == 30
    assert client.get(f"/h3t/cell?h3={h}&eov=cod").json()["n"] == 35
    body = client.get(f"/h3t/cell?h3={h}&rank=family&taxon=Scombridae").json()
    assert (body["n"], body["sp"], body["species"][0]["aphiaid"]) == (7, 1, 21)


def test_cell_bad_params(client, h3con):
    h = format(_cell(h3con, "a", 3), "x")
    assert client.get("/h3t/cell").status_code == 400
    assert client.get("/h3t/cell?h3=zzzzzzzzzzzzzzz").status_code == 400
    assert client.get(f"/h3t/cell?h3={format(_cell(h3con, 'a', 9), 'x')}").status_code == 400
    assert client.get(f"/h3t/cell?h3={h}&aphiaid=10&eov=cod").status_code == 400
    assert client.get(f"/h3t/cell?h3={h}&rank=genus&taxon=Gadus").status_code == 400
    assert client.get(f"/h3t/cell?h3={h}&rank=family").status_code == 400
    assert client.get(f"/h3t/cell?h3={h}&decade=1995").status_code == 400
    r = client.get(f"/h3t/cell?h3={h}&rank=genus&taxon=Gadus")
    assert "rank must be one of" in r.json()["reason"]


def test_cell_eov_needs_the_table(client, h3con, monkeypatch):
    monkeypatch.setattr(subtree, "_tables", frozenset({"taxon", "occ_h3"}))
    h = format(_cell(h3con, "a", 3), "x")
    assert client.get(f"/h3t/cell?h3={h}&eov=cod").status_code == 503
    assert client.get(f"/h3t/cell?h3={h}").status_code == 200
