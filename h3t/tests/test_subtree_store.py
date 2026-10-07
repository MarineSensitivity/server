"""Integration: subtree indicators vs the precomputed idx_h3_taxon layer.

Runs only where the full OBIS store (with its `taxon` table) exists: set
H3T_TEST_STORE, or it looks in /share/data/obis (msens) and ~/data/obis (mini).

Parity: the per-class layer idx_h3_taxon groups occ_h3 by its `class` column
(OBIS's classification), the subtree endpoint by the WoRMS parent walk. For
Mammalia both select exactly the same records, so every cell must agree to
floating-point precision at every resolution. For Aves the WoRMS tree also picks
up 10 taxa whose occ_h3.class is NULL, so the subtree is a superset: every
reference cell is present with n >= the reference, and cells with equal n agree.
"""

from __future__ import annotations

import math
import os
from pathlib import Path

import pytest

from app import subtree

_CANDIDATES = [
    os.getenv("H3T_TEST_STORE", ""),
    "/share/data/obis/obis_h3.duckdb",
    str(Path.home() / "data/obis/obis_h3.duckdb"),
]
STORE = next((Path(p) for p in _CANDIDATES if p and Path(p).exists()), None)

pytestmark = pytest.mark.skipif(STORE is None, reason="full OBIS store not found")

MAMMALIA, AVES = 1837, 1836
COLS = ("n", "sp", "shannon", "simpson", "es")


@pytest.fixture(scope="module")
def sub():
    if not subtree.init(STORE, threads=2, memory_limit="2GB", rollup=False):
        pytest.skip("store has no taxon table")
    return subtree


def _compare(sub, aphiaid: int, cls: str, res: int):
    sql = f"""
      WITH s AS ({sub.subtree_sql(aphiaid, res)}),
      r AS (SELECT cell_id, n, sp, shannon, simpson, es FROM idx_h3_taxon
            WHERE rank = 'class' AND taxon = '{cls}' AND res = {res})
      SELECT r.cell_id IS NOT NULL AS in_ref, s.cell_id IS NOT NULL AS in_sub,
             s.n, r.n, s.sp, r.sp, s.shannon, r.shannon, s.simpson, r.simpson, s.es, r.es
      FROM s FULL JOIN r USING (cell_id)"""
    _, rows = sub.run_rows(sub.cursor(), sql)
    return rows


def _close(a, b):
    # ES(50) at n ~ 1e5-1e6 sums lgamma differences of ~1e6-sized numbers, so
    # the parallel SUM order alone moves it by ~1e-8 absolute; 1e-7 relative is
    # float noise, not a formula difference (n and sp must match exactly)
    if a is None or b is None:
        return a is None and b is None
    return math.isclose(a, b, rel_tol=1e-7, abs_tol=1e-9)


@pytest.mark.parametrize("res", [1, 2, 3, 4, 5, 6, 7])
def test_parity_mammalia(sub, res):
    rows = _compare(sub, MAMMALIA, "Mammalia", res)
    assert rows
    bad = [r for r in rows
           if not (r[0] and r[1] and r[2] == r[3] and r[4] == r[5]
                   and _close(r[6], r[7]) and _close(r[8], r[9]) and _close(r[10], r[11]))]
    assert not bad, f"{len(bad)} of {len(rows)} cells differ, e.g. {bad[:3]}"


@pytest.mark.parametrize("res", [3, 5])
def test_superset_aves(sub, res):
    rows = _compare(sub, AVES, "Aves", res)
    assert rows
    assert all(r[1] for r in rows), "a reference cell is missing from the subtree"
    assert all(r[3] is None or r[2] >= r[3] for r in rows)
    same_n = [r for r in rows if r[0] and r[2] == r[3]]
    assert len(same_n) > 0.95 * len(rows)
    bad = [r for r in same_n
           if not (r[4] == r[5] and _close(r[6], r[7]) and _close(r[8], r[9])
                   and _close(r[10], r[11]))]
    assert not bad, bad[:3]
