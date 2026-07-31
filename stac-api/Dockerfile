# stac-fastapi-duckdb, pinned, with one upstream bug patched.
#
# THE PATCH. The backend builds its spatial filter as
#     ST_Intersects(geometry, ST_GeomFromText('POLYGON(...)'))
# but `geometry` in stac-geoparquet is a WKB **BLOB**, and DuckDB spatial has no
# ST_Intersects(BLOB, GEOMETRY) — only (GEOMETRY, GEOMETRY) and (BOX_2D, BOX_2D).
# So every bbox/intersects search 500s:
#     Binder Error: No function matches ... 'ST_Intersects(BLOB, GEOMETRY)'
# That is not specific to our data — it applies to any stac-geoparquet source,
# including the Planetary Computer exports the project's own helper downloads.
# Wrapping the column in ST_GeomFromWKB() is the minimal correct fix. Worth
# sending upstream; until then it lives here, asserted so a silent no-op fails
# the BUILD rather than resurfacing as 500s at request time.
#
# Built from a git clone rather than a git build-context so the patch can be
# applied between checkout and install.
FROM python:3.10-slim

RUN apt-get update && apt-get -y upgrade && \
    apt-get install -y --no-install-recommends build-essential git && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

ENV CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
WORKDIR /app

# pin by commit — a moving default branch is not something to serve from
ARG STAC_DUCKDB_REF=359aa2a0f1a94b77e592f3bd33c4d28537d31949
RUN git clone https://github.com/Healy-Hyperspatial/stac-fastapi-duckdb.git . && \
    git checkout ${STAC_DUCKDB_REF}

RUN sed -i 's/ST_Intersects(geometry,/ST_Intersects(ST_GeomFromWKB(geometry),/g' \
      stac_fastapi/duckdb/database_logic.py && \
    test "$(grep -c 'ST_Intersects(ST_GeomFromWKB(geometry),' stac_fastapi/duckdb/database_logic.py)" -ge 2 && \
    test "$(grep -c 'ST_Intersects(geometry,' stac_fastapi/duckdb/database_logic.py)" -eq 0

RUN pip install --no-cache-dir -e .[dev,server]

# PATCH 2 — spec-conformant paging fields. stac_fastapi_core (6.2.1) builds its
# ItemCollection with `numReturned=` / `numMatched=`, but the very TypedDict it
# constructs, stac_fastapi.types.stac.ItemCollection, declares `numberReturned` /
# `numberMatched` — the names STAC API and OGC API Features require. A TypedDict
# does not validate kwargs at runtime, so the wrong names pass through silently
# and every response carries them:
#     {"numReturned": 10, "numMatched": 16818}
# Paging still works (clients follow rel="next"), but a strict client reading
# numberMatched sees nothing — it cannot tell 16,818 items from 10.
#
# Applied AFTER pip install because it lives in the installed DEPENDENCY, not in
# the cloned backend. Asserted both ways — new names present, old ones entirely
# gone — so a rename upstream fails the BUILD instead of quietly reverting this.
# Worth sending upstream alongside the ST_Intersects patch.
RUN CORE="$(python -c 'import stac_fastapi.core.core as m; print(m.__file__)')" && \
    sed -i 's/numReturned=/numberReturned=/g; s/numMatched=/numberMatched=/g' "$CORE" && \
    test "$(grep -c 'numberReturned=' "$CORE")" -ge 2 && \
    test "$(grep -c 'numberMatched='  "$CORE")" -ge 2 && \
    test "$(grep -c 'numReturned='    "$CORE")" -eq 0 && \
    test "$(grep -c 'numMatched='     "$CORE")" -eq 0

EXPOSE 8084
CMD ["python", "-m", "stac_fastapi.duckdb.app"]
