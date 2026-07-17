"""Environment-driven configuration."""

from __future__ import annotations

import os
from pathlib import Path


def _parse_db_registry(s: str) -> dict[str, Path]:
    """Parse `H3T_DBS="name1:/path/a.duckdb,name2:/path/b.duckdb"`.

    Whitespace around names and paths is stripped. Names must be unique;
    a duplicate raises ValueError.
    """
    out: dict[str, Path] = {}
    for entry in s.split(","):
        entry = entry.strip()
        if not entry:
            continue
        if ":" not in entry:
            raise ValueError(f"H3T_DBS entry missing 'name:path' separator: {entry!r}")
        name, _, path = entry.partition(":")
        name = name.strip()
        path = path.strip()
        if not name or not path:
            raise ValueError(f"H3T_DBS entry has empty name or path: {entry!r}")
        if name in out:
            raise ValueError(f"H3T_DBS has duplicate db name: {name!r}")
        out[name] = Path(path)
    if not out:
        raise ValueError("H3T_DBS set but parsed to empty registry")
    return out


def load_db_paths() -> tuple[dict[str, Path], str]:
    """Return (registry, default_db_name).

    Registry mode: `H3T_DBS` env var, optionally with `H3T_DEFAULT_DB`.
    Legacy mode: `DUCKDB_PATH` env var → registry `{"default": DUCKDB_PATH}`.
    """
    dbs_env = os.getenv("H3T_DBS", "").strip()
    if dbs_env:
        registry = _parse_db_registry(dbs_env)
        default_name = os.getenv("H3T_DEFAULT_DB", "").strip()
        if default_name:
            if default_name not in registry:
                raise ValueError(
                    f"H3T_DEFAULT_DB={default_name!r} not in H3T_DBS registry "
                    f"(available: {sorted(registry)})"
                )
        else:
            default_name = next(iter(registry))
        return registry, default_name

    legacy = os.getenv("DUCKDB_PATH", "").strip()
    if not legacy:
        raise SystemExit(
            "config: either H3T_DBS or DUCKDB_PATH must be set "
            "(H3T_DBS='name:path,...' takes precedence)"
        )
    return {"default": Path(legacy)}, "default"


# request-time limits
MAX_ROWS_PER_TILE: int = int(os.getenv("H3T_MAX_ROWS", "50000"))
STMT_TIMEOUT_MS: int   = int(os.getenv("H3T_STMT_TIMEOUT_MS", "3000"))

# automatic per-tile spatial pruning: the coarse H3 resolution of the stored
# `hex_prune` column (must match obisindicators::H3T_PRUNE_RES that built the
# store). The server derives each tile's covering res-PRUNE_RES cells from
# z/x/y and injects `hex_prune IN (...)`; injection is skipped for tiles coarser
# than this (the coarse rows aren't keyed on a res-PRUNE_RES parent) or when the
# covering set exceeds MAX_COVER_CELLS (huge low-zoom tiles fall back to a whole
# scan — correctness always held by the outer centroid filter in wrap_tile_sql).
PRUNE_RES: int       = int(os.getenv("H3T_PRUNE_RES", "3"))
MAX_COVER_CELLS: int = int(os.getenv("H3T_MAX_COVER_CELLS", "2048"))

# per-connection DuckDB resource caps — bound CPU/RAM on the serving side so a
# heavy tile query can't peg every core or exhaust host RAM. Unset = DuckDB
# defaults (all cores, ~80% RAM).
DUCKDB_THREADS: str | None      = os.getenv("H3T_THREADS", "").strip() or None
DUCKDB_MEMORY_LIMIT: str | None = os.getenv("H3T_MEMORY_LIMIT", "").strip() or None

# CORS
CORS_ORIGIN: str = os.getenv("H3T_CORS_ORIGIN", "*")

# optional app-level gzip (off by default; Varnish handles it in prod)
APP_GZIP: bool = os.getenv("H3T_APP_GZIP", "false").lower() == "true"

# bind
HOST: str = os.getenv("H3T_HOST", "0.0.0.0")
PORT: int = int(os.getenv("H3T_PORT", "8889"))
