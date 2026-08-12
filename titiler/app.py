"""custom titiler app: stock endpoints, plus the msens cells factory ON REQUEST.

The `/msens` factory renders a tile by running a DuckDB query per request. Every
layer the apps draw is now a precomputed COG served by titiler's stock `/cog`
endpoints, so nothing reaches it in normal operation:

  - scores app: COG-first, and every metric on every release (v1-v8) has one, so
    its SQL fallback cannot fire.
  - species app: falls back to the factory only for a taxon with no merged COG,
    and merged coverage is 17,108/17,108.

Verified equivalent before switching off: 100 of 105 tiles byte-identical across
25 metric x subregion combinations, the remaining five differing by 3-6 pixels
out of 262,144 (float32 COG storage vs double in the database, not a data
difference).

KEPT, NOT DELETED. On-the-fly SQL tiling is genuinely useful for exploratory
work — an ad-hoc query, a surface nobody has published yet — so the code stays
and the route is one env var away:

    MSENS_FACTORY=1        mount /msens
    (unset, the default)   stock titiler only

Deliberately NOT behind the Varnish cache: a query-driven tile is not
cache-friendly the way an immutable COG is, and caching an exploratory endpoint
mostly serves stale answers to someone iterating on a query.
"""
import os

from titiler.application.main import app

if os.environ.get("MSENS_FACTORY", "").strip() not in ("", "0", "false", "False"):
    from factory import MsensCellsFactory

    msens = MsensCellsFactory()
    app.include_router(msens.router, prefix="/msens", tags=["Marine Sensitivity"])
