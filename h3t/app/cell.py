"""Species in one H3 cell: the list behind a cell's indicators.

For the obis-hex Cell pane (oceanmetrics/obis-hex#5): which species make up a
cell's `n` (records) and `sp` (species), with records and first / last year per
species. Reads the same `occ_h3` rows as every release layer and the subtree
endpoint, with the same layer filters, so the list sums to the cell's `n` and
counts to its `sp`:

- all taxa: no filter
- `aphiaid`: the WoRMS subtree (`subtree.taxon_tree_cte`), as /h3t/subtree
- `eov`: the store's `eov` table (`occ_h3.aphiaid = eov.taxonID`), as
  obisindicators `obis_eov_bake()` / the release's eov layers
- `rank` + `taxon`: the occ_h3 rank column, as `.h3t_idx_taxon_sql()` / the
  release's taxon layers
- `decade`: `date_year` in [decade, decade + 9], as the decade layers

Species are grouped by the `species` name (how `sp` counts them); the AphiaID
shown is the WoRMS species-rank taxon of that name (accepted first), else the
AphiaID with the most records in the group (e.g. a subspecies).

A cell at res r is read from the occ_h3 tier t >= r. Its tier-t descendants are
the ids in [lo, hi] that share its bits down to digit r (H3 indexes put the
resolution digits in order, high to low), so a range on the stored `hex_prune`
(res-3 parent) skips every other row group; the exact `h3_cell_to_parent`
filter then keeps only the cell's rows.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from . import subtree
from .subtree import PRUNE_RES, SubtreeError, taxon_tree_cte, tier_for

# the ranks the release has taxon layers for (occ_h3 columns)
RANKS: tuple[str, ...] = ("phylum", "class", "order", "family")

COLUMNS: tuple[str, ...] = (
    "species", "aphiaid", "phylum", "class", "order", "family",
    "records", "year_min", "year_max")

_HEX = re.compile(r"[0-9a-f]{15,16}")
_RES_SHIFT = 52
_RES_MASK = 0xF << _RES_SHIFT


def _digit_shift(r: int) -> int:
    """Bit offset of resolution digit r (1..15)."""
    return (15 - r) * 3


def parse_cell(h3: str) -> tuple[int, int]:
    """H3 cell index (hex string) → (cell id, res). Raises SubtreeError.

    Checks the cell mode, base cell and unused digits; the res must be in the
    store's range [1, 7].
    """
    s = (h3 or "").strip().lower()
    if not _HEX.fullmatch(s):
        raise SubtreeError("h3 must be an H3 cell index in hex, e.g. 84ad369ffffffff")
    i = int(s, 16)
    res = (i >> _RES_SHIFT) & 0xF
    if i >> 63 or (i >> 59) & 0xF != 1 or (i >> 56) & 0x7 or (i >> 45) & 0x7F > 121:
        raise SubtreeError("h3 is not an H3 cell index")
    if any((i >> _digit_shift(r)) & 7 != 7 for r in range(res + 1, 16)):
        raise SubtreeError("h3 is not an H3 cell index")
    if not 1 <= res <= subtree.TIERS[-1]:
        raise SubtreeError(f"h3 resolution must be in [1, {subtree.TIERS[-1]}]")
    return i, res


def cell_to_parent(i: int, p: int) -> int:
    """The res-p ancestor of cell `i` (p <= its res), by bit arithmetic."""
    out = (i & ~_RES_MASK) | (p << _RES_SHIFT)
    for r in range(p + 1, 16):
        out |= 7 << _digit_shift(r)
    return out


def descendant_range(i: int, res: int, t: int) -> tuple[int, int]:
    """(lo, hi): every res-t descendant of the res-`res` cell `i` lies in it,
    and no other valid res-t cell does (t >= res)."""
    if t < res:
        raise ValueError("t must be >= res")
    base = (i & ~_RES_MASK) | (t << _RES_SHIFT)
    lo = hi = base
    for r in range(res + 1, t + 1):
        sh = _digit_shift(r)
        lo &= ~(7 << sh)              # digit 0
        hi = (hi & ~(7 << sh)) | (6 << sh)  # digit 6
    return lo, hi


@dataclass(frozen=True)
class CellQuery:
    cell: int
    res: int
    aphiaid: int | None = None
    eov: str | None = None
    rank: str | None = None
    taxon: str | None = None
    decade: int | None = None

    def __post_init__(self) -> None:
        layers = sum(x is not None for x in (self.aphiaid, self.eov, self.rank))
        if layers > 1:
            raise SubtreeError("give at most one of aphiaid, eov, rank + taxon")
        if (self.rank is None) != (self.taxon is None):
            raise SubtreeError("rank and taxon go together")
        if self.rank is not None and self.rank not in RANKS:
            raise SubtreeError(f"rank must be one of {', '.join(RANKS)}")
        if self.decade is not None and self.decade % 10 != 0:
            raise SubtreeError("decade must be a year ending in 0, e.g. 1990")


def cell_species_sql(q: CellQuery) -> tuple[str, list]:
    """(SQL, params): one row per species in the cell, most records first."""
    t = tier_for(q.res)
    if q.res >= PRUNE_RES:
        plo = phi = cell_to_parent(q.cell, PRUNE_RES)
    else:
        plo, phi = descendant_range(q.cell, q.res, PRUNE_RES)
    cell = int(q.cell)
    at = "cell_id" if q.res == t else f"h3_cell_to_parent(cell_id, {int(q.res)})"

    where = [f"res = {t}", f"hex_prune BETWEEN {plo} AND {phi}", f"{at} = {cell}"]
    params: list = []
    head = "WITH"
    if q.aphiaid is not None:
        head = f"WITH RECURSIVE {taxon_tree_cte(q.aphiaid)},"
        where.append("aphiaid IN (SELECT taxonID FROM taxon_tree)")
    elif q.eov is not None:
        where.append("aphiaid IN (SELECT taxonID FROM eov WHERE eov = ?)")
        params.append(q.eov)
    elif q.rank is not None:
        where.append(f'"{q.rank}" = ?')  # rank is whitelisted (RANKS)
        params.append(q.taxon)
    if q.decade is not None:
        d = int(q.decade)
        where.append(f"date_year BETWEEN {d} AND {d + 9}")
    where_sql = "\n      AND ".join(where)

    sql = f"""
{head}
    occ AS (
      SELECT species, aphiaid, phylum, class, "order", family, date_year, records
      FROM occ_h3
      WHERE {where_sql}),
    agg AS (
      SELECT species,
        arg_max(aphiaid, records)  AS aphiaid_top,
        ANY_VALUE(phylum)          AS phylum,
        ANY_VALUE(class)           AS class,
        ANY_VALUE("order")         AS "order",
        ANY_VALUE(family)          AS family,
        SUM(records)::BIGINT       AS records,
        MIN(date_year)             AS year_min,
        MAX(date_year)             AS year_max
      FROM occ GROUP BY species),
    ids AS (
      SELECT scientificName AS species,
        FIRST(taxonID ORDER BY (taxonomicStatus = 'accepted') DESC NULLS LAST, taxonID) AS taxonID
      FROM taxon
      WHERE lower(taxonRank) = 'species'
        AND scientificName IN (SELECT species FROM agg)
      GROUP BY 1)
    SELECT a.species, COALESCE(i.taxonID, a.aphiaid_top) AS aphiaid,
      a.phylum, a.class, a."order", a.family, a.records, a.year_min, a.year_max
    FROM agg a LEFT JOIN ids i USING (species)
    ORDER BY a.records DESC, a.species"""
    return sql, params
