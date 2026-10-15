"""Integration: /h3t/cell species lists vs the store's precomputed indicators.

Runs only where the full OBIS store exists (as test_subtree_store.py: set
H3T_TEST_STORE, or /share/data/obis on msens, ~/data/obis on the mini). For the
busiest cells of a layer, the species list must sum to the cell's `n` and count
to its `sp` in the table the release is exported from: idx_h3 (all taxa),
idx_h3_taxon (a class), idx_h3_eov (an EOV), and the subtree SQL (an AphiaID).
"""

from __future__ import annotations

import time

import pytest

from app import cell, subtree
from tests.test_subtree_store import STORE

pytestmark = pytest.mark.skipif(STORE is None, reason="full OBIS store not found")

MAMMALIA = 1837
TOP = 5


@pytest.fixture(scope="module")
def sub():
    if not subtree.init(STORE, threads=2, memory_limit="1GB", rollup=False):
        pytest.skip("store has no taxon table")
    return subtree


def _top(sub, sql: str) -> list[tuple[int, int, int]]:
    """(cell_id, n, sp) of the busiest cells."""
    return [tuple(r) for r in sub.run_rows(sub.cursor(), sql)[1]]


def _check(sub, cells, res: int, **kw):
    assert cells
    for cid, n, sp in cells:
        t0 = time.perf_counter()
        sql, params = cell.cell_species_sql(cell.CellQuery(cid, res, **kw))
        _, rows = sub.run_rows(sub.cursor(), sql, params)
        ms = (time.perf_counter() - t0) * 1000
        got = (sum(r[6] for r in rows), len(rows))
        print(f"res {res} {format(cid, 'x')} {kw or 'all'}: {got[1]} species, {got[0]} records, {ms:.0f} ms")
        assert got == (n, sp), (format(cid, "x"), res, kw)


@pytest.mark.parametrize("res", [1, 2, 3, 4, 5, 6, 7])
def test_all_taxa(sub, res):
    _check(sub, _top(sub, f"""
      SELECT cell_id, n, sp FROM idx_h3 WHERE res = {res} ORDER BY n DESC LIMIT {TOP}"""), res)


@pytest.mark.parametrize("res", [3, 5, 7])
def test_class(sub, res):
    _check(sub, _top(sub, f"""
      SELECT cell_id, n, sp FROM idx_h3_taxon
      WHERE rank = 'class' AND taxon = 'Mammalia' AND res = {res} ORDER BY n DESC LIMIT {TOP}"""),
           res, rank="class", taxon="Mammalia")


@pytest.mark.parametrize("res", [3, 5])
def test_eov(sub, res):
    if not subtree.has_table("idx_h3_eov"):
        pytest.skip("store has no idx_h3_eov")
    eov = sub.run_rows(sub.cursor(), "SELECT MIN(eov) FROM idx_h3_eov")[1][0][0]
    _check(sub, _top(sub, f"""
      SELECT cell_id, n, sp FROM idx_h3_eov
      WHERE eov = '{eov}' AND res = {res} ORDER BY n DESC LIMIT {TOP}"""), res, eov=eov)


@pytest.mark.parametrize("res", [3, 5])
def test_aphiaid(sub, res):
    _check(sub, _top(sub, f"""
      SELECT cell_id, n, sp FROM ({sub.subtree_sql(MAMMALIA, res)}) ORDER BY n DESC LIMIT {TOP}"""),
           res, aphiaid=MAMMALIA)
