"""WoRMS subtree indicators: per-cell OBIS biodiversity for any AphiaID.

The one query the browser app cannot precompute: the indicators (n, sp,
shannon, simpson, es) per H3 cell over every occurrence whose taxon is the
AphiaID or any descendant at any rank. Ported from obisindicators:

- subtree resolution: `.h3t_taxon_tree_cte()` (R/taxon.R) — a recursive CTE
  down `taxon.parentNameUsageID`. The seed also includes the AphiaID's accepted
  name (`acceptedNameUsageID`), so a synonym resolves to the accepted subtree.
- indicator math: `.h3t_indicators_sql()` (R/h3t.R), the single formula
  builder behind idx_h3 / idx_h3_taxon / idx_h3_eov. Keep the two in step.
- tiering: `obis_h3t_sql()` reads the coarsest occ_h3 tier (3/5/7) at least as
  fine as the requested resolution and rolls cells up with h3_cell_to_parent.

The queries run on a dedicated DuckDB instance (in-memory, with the store
ATTACHed read-only) so its `threads` / `memory_limit` caps are independent of
the tile connection's.
"""

from __future__ import annotations

import os
import threading
from dataclasses import dataclass
from pathlib import Path

import duckdb

# H3 resolution tiers stored in occ_h3 (obisindicators H3T_RES_TIERS)
TIERS: tuple[int, ...] = (3, 5, 7)
# coarse parent materialized as occ_h3.hex_prune (obisindicators H3T_PRUNE_RES)
PRUNE_RES: int = 3
# largest covering set injected as `hex_prune IN (...)`; beyond it the exact
# centre filter alone applies (still correct, just a wider scan)
MAX_PRUNE_CELLS: int = 4096


class SubtreeError(ValueError):
    """Bad request parameters (→ HTTP 400)."""


@dataclass(frozen=True)
class BBox:
    w: float
    s: float
    e: float
    n: float

    @property
    def crosses_antimeridian(self) -> bool:
        return self.w > self.e


def parse_bbox(s: str | None) -> BBox | None:
    """Parse `w,s,e,n` in decimal degrees; `w > e` means it crosses 180°."""
    if s is None or not s.strip():
        return None
    parts = s.split(",")
    if len(parts) != 4:
        raise SubtreeError("bbox must be 'w,s,e,n' (4 comma-separated numbers)")
    try:
        w, so, e, n = (float(p) for p in parts)
    except ValueError as err:
        raise SubtreeError("bbox values must be numbers") from err
    if not (-180 <= w <= 180 and -180 <= e <= 180):
        raise SubtreeError("bbox longitudes must be in [-180, 180]")
    if not (-90 <= so <= 90 and -90 <= n <= 90) or so >= n:
        raise SubtreeError("bbox latitudes must be in [-90, 90] with s < n")
    return BBox(w, so, e, n)


def tier_for(res: int) -> int:
    """Coarsest occ_h3 tier at least as fine as `res`."""
    for t in TIERS:
        if res <= t:
            return t
    raise SubtreeError(f"res must be <= {TIERS[-1]}")


def taxon_tree_cte(aphiaid: int, name: str = "taxon_tree") -> str:
    """`<name> AS (...)` yielding every taxonID in the subtree of `aphiaid`.

    Port of obisindicators `.h3t_taxon_tree_cte()`, with the seed widened to the
    AphiaID's accepted name. Use after `WITH RECURSIVE`.
    """
    a = int(aphiaid)  # injection guard: only an int reaches the SQL
    return (
        f"{name} AS (\n"
        f"  SELECT taxonID, parentNameUsageID FROM taxon\n"
        f"  WHERE taxonID = {a}\n"
        f"     OR taxonID = (SELECT acceptedNameUsageID FROM taxon WHERE taxonID = {a})\n"
        f"  UNION\n"
        f"  SELECT t.taxonID, t.parentNameUsageID\n"
        f"  FROM taxon t JOIN {name} tt ON t.parentNameUsageID = tt.taxonID\n"
        f"  WHERE t.parentNameUsageID IS NOT NULL)")


def indicators_sql(
    src: str,
    keys: tuple[str, ...] = (),
    select: str | None = None,
    esn: int = 50,
) -> str:
    """Port of obisindicators `.h3t_indicators_sql()` (R/h3t.R).

    `src` is a SELECT yielding `keys`, `cell_id`, `species`, `ni` (records of the
    species in the cell), one row per (keys, cell_id, species). Output: `select`
    (default keys + cell_id), then n, sp, shannon, simpson, es. ES(esn) is NULL
    for a cell with n < esn.
    """
    esn = int(esn)
    k  = ", ".join([*keys, "cell_id"])
    sk = ", ".join(f"s.{c}" for c in [*keys, "cell_id"])
    if select is None:
        select = k
    return f"""
    WITH src AS (
      {src}),
    tot AS (
      SELECT {k}, SUM(ni) AS n FROM src GROUP BY {k}),
    per AS (
      SELECT {sk}, s.ni, t.n,
        CASE
          WHEN t.n - s.ni >= {esn} THEN 1 - exp(
                 lgamma(t.n - s.ni + 1) + lgamma(t.n - {esn} + 1)
               - lgamma(t.n - s.ni - {esn} + 1) - lgamma(t.n + 1))
          WHEN t.n >= {esn} THEN 1
          ELSE NULL END AS esi
      FROM src s JOIN tot t USING ({k}))
    SELECT {select},
      ANY_VALUE(n)                                       AS n,
      COUNT(*)                                           AS sp,
      -SUM((ni::DOUBLE / n) * ln(ni::DOUBLE / n))        AS shannon,
      SUM((ni::DOUBLE / n) * (ni::DOUBLE / n))           AS simpson,
      SUM(esi)                                           AS es
    FROM per GROUP BY {k}"""


def _bbox_centre_where(bbox: BBox, cell_expr: str) -> str:
    lat = f"h3_cell_to_lat({cell_expr})"
    lng = f"h3_cell_to_lng({cell_expr})"
    lat_c = f"{lat} BETWEEN {bbox.s!r} AND {bbox.n!r}"
    if bbox.crosses_antimeridian:
        lng_c = f"({lng} >= {bbox.w!r} OR {lng} <= {bbox.e!r})"
    else:
        lng_c = f"{lng} BETWEEN {bbox.w!r} AND {bbox.e!r}"
    return f"{lat_c} AND {lng_c}"


def subtree_sql(
    aphiaid: int,
    res: int,
    decade: int | None = None,
    bbox: BBox | None = None,
    prune_cells: tuple[int, ...] | None = None,
    esn: int = 50,
    limit: int | None = None,
) -> str:
    """Per-cell indicators at `res` for the AphiaID subtree.

    `decade` keeps records with `date_year` in [decade, decade + 9] (records
    without a year drop out, as in the parquet export's decade layers). `bbox`
    keeps output cells whose centre lies in it — whole cells only, so each
    returned cell's indicators are complete. `prune_cells` (res-3 covering cells
    of the bbox) adds `hex_prune IN (...)` so DuckDB skips row groups; it must be
    a superset of the bbox cells' res-3 parents. `limit` caps the row count (the
    caller asks for one more than the cap to detect overflow).
    """
    res = int(res)
    if not 1 <= res <= TIERS[-1]:
        raise SubtreeError(f"res must be in [1, {TIERS[-1]}]")
    tier = tier_for(res)
    cell = f"CAST(h3_cell_to_parent(cell_id, {res}) AS BIGINT)" if res != tier else "cell_id"

    where = [f"res = {tier}", "aphiaid IN (SELECT taxonID FROM taxon_tree)"]
    if decade is not None:
        d = int(decade)
        if d % 10 != 0:
            raise SubtreeError("decade must be a year ending in 0, e.g. 1990")
        where.append(f"date_year BETWEEN {d} AND {d + 9}")
    if prune_cells:
        where.append("hex_prune IN (" + ",".join(str(int(c)) for c in prune_cells) + ")")
    if bbox is not None:
        where.append(_bbox_centre_where(bbox, cell))
    where_sql = "\n        AND ".join(where)

    src = (
        f"SELECT {cell} AS cell_id, species, SUM(records) AS ni\n"
        f"      FROM occ_h3\n"
        f"      WHERE {where_sql}\n"
        f"      GROUP BY 1, 2")
    ind = indicators_sql(src, esn=esn)
    lim = f"\nLIMIT {int(limit)}" if limit is not None else ""
    return (
        f"WITH RECURSIVE {taxon_tree_cte(aphiaid)}\n"
        f"SELECT h3_h3_to_string(cell_id) AS h3, cell_id, n::BIGINT AS n, sp, shannon, simpson, es\n"
        f"FROM ({ind}) _i\n"
        f"ORDER BY cell_id{lim}")


# --- taxon lookup -----------------------------------------------------------

def taxon_search_sql(limit: int = 20) -> str:
    """Prefix search on scientificName (parameter `?` = the prefix).

    Accepted names first, then by subtree record count, then name. `records`
    comes from the `taxon_n` rollup (see ROLLUP_SQL), NULL if absent.
    """
    return f"""
    SELECT t.taxonID AS id, t.scientificName, t.taxonRank AS rank,
           t.taxonomicStatus AS status, t.acceptedNameUsageID AS accepted_id,
           r.records
    FROM taxon t LEFT JOIN memory.main.taxon_n r USING (taxonID)
    WHERE starts_with(lower(t.scientificName), lower(?))
    ORDER BY (t.taxonomicStatus = 'accepted') DESC NULLS LAST,
             r.records DESC NULLS LAST, t.scientificName
    LIMIT {int(limit)}"""


TAXON_ONE_SQL = """
    SELECT t.taxonID AS id, t.scientificName, t.taxonRank AS rank,
           t.taxonomicStatus AS status, t.acceptedNameUsageID AS accepted_id,
           t.parentNameUsageID AS parent_id,
           (SELECT COUNT(*) FROM taxon c WHERE c.parentNameUsageID = t.taxonID)
             AS children,
           (SELECT COUNT(*) FROM taxon c WHERE c.parentNameUsageID = t.taxonID
              AND c.taxonomicStatus = 'accepted') AS children_accepted,
           r.records
    FROM taxon t LEFT JOIN memory.main.taxon_n r USING (taxonID)
    WHERE t.taxonID = ?"""

# records per taxon summed over its whole subtree (same parent walk as
# taxon_tree_cte): start from each occ_h3 aphiaid's records at the coarsest tier
# and walk up parentNameUsageID. depth guard against any cycle in the snapshot.
ROLLUP_SQL = """
CREATE OR REPLACE TABLE memory.main.taxon_n AS
WITH RECURSIVE occ AS (
  SELECT aphiaid AS taxonID, SUM(records) AS records
  FROM occ_h3 WHERE res = 3 GROUP BY 1),
up AS (
  SELECT o.taxonID AS taxonID, o.records, t.parentNameUsageID AS parent, 0 AS depth
  FROM occ o JOIN taxon t USING (taxonID)
  UNION ALL
  SELECT t.taxonID, up.records, t.parentNameUsageID, up.depth + 1
  FROM up JOIN taxon t ON t.taxonID = up.parent
  WHERE up.parent IS NOT NULL AND up.parent <> up.taxonID AND up.depth < 64)
SELECT taxonID, SUM(records)::BIGINT AS records FROM up GROUP BY 1"""


# --- dedicated connection ---------------------------------------------------

_con: duckdb.DuckDBPyConnection | None = None
_lock = threading.Lock()
_has_taxon: bool = False


def init(
    path: Path,
    threads: int = 2,
    memory_limit: str = "2GB",
    temp_directory: str | None = None,
    rollup: bool = True,
) -> bool:
    """Open the subtree instance: in-memory DuckDB, store ATTACHed read-only.

    Returns False (and leaves the endpoint disabled) if the store has no
    `taxon` table. `rollup` builds the per-taxon subtree record counts used by
    the taxon search (a few seconds at startup, a few MB of RAM).
    """
    global _con, _has_taxon
    tmp = temp_directory or os.path.join(os.getenv("TMPDIR", "/tmp"), "h3t_subtree")
    con = duckdb.connect(config={
        "threads":        int(threads),
        "memory_limit":   memory_limit,
        "temp_directory": tmp,
    })
    con.execute("INSTALL h3 FROM community; LOAD h3;")
    con.execute(f"ATTACH '{Path(path).as_posix()}' AS store (READ_ONLY)")
    con.execute("USE store")
    tabs = {r[0].lower() for r in con.execute(
        "SELECT table_name FROM information_schema.tables "
        "WHERE table_catalog = 'store'").fetchall()}
    _has_taxon = {"taxon", "occ_h3"} <= tabs
    if _has_taxon:
        if rollup:
            con.execute(ROLLUP_SQL)
        else:
            con.execute("CREATE OR REPLACE TABLE memory.main.taxon_n "
                        "(taxonID BIGINT, records BIGINT)")
    _con = con
    return _has_taxon


def enabled() -> bool:
    return _con is not None and _has_taxon


def cursor() -> duckdb.DuckDBPyConnection:
    if _con is None:
        raise RuntimeError("subtree connection not initialized")
    cur = _con.cursor()
    cur.execute("USE store")  # the default catalog is per cursor
    return cur


def run_rows(cur: duckdb.DuckDBPyConnection, sql: str, params: list | None = None):
    """(columns, rows); closes the cursor."""
    try:
        cur.execute(sql, params or [])
        cols = [d[0] for d in cur.description] if cur.description else []
        return cols, cur.fetchall()
    finally:
        cur.close()


def run_copy_parquet(cur: duckdb.DuckDBPyConnection, sql: str, out: str) -> int:
    """COPY (sql) TO `out` as parquet; returns the row count. Closes the cursor."""
    o = out.replace("'", "''")
    try:
        row = cur.execute(
            f"COPY ({sql}) TO '{o}' (FORMAT parquet, COMPRESSION zstd)").fetchone()
        return int(row[0]) if row else 0
    finally:
        cur.close()
