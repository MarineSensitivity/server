FROM python:3.13-slim

# system deps: curl for healthcheck; everything else (duckdb wheels, fastapi)
# is pure pip.
RUN apt-get update && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# bake the duckdb community `h3` + `spatial` extensions into the image so the
# read-only service does not need community-extension network access at boot
# (db.py LOADs them on every connection). installs into /root/.duckdb, the
# same extension dir the runtime (root) uses.
RUN python -c "import duckdb; c=duckdb.connect(); \
c.execute('INSTALL httpfs'); \
c.execute('INSTALL h3 FROM community'); \
c.execute('INSTALL spatial')"

COPY app /app/app

ENV H3T_HOST=0.0.0.0 H3T_PORT=8889
EXPOSE 8889

HEALTHCHECK --interval=10s --timeout=3s --start-period=15s --retries=5 \
  CMD curl -fsS http://localhost:${H3T_PORT}/h3t/health || exit 1

# uvicorn workers=1 — DuckDB connections are per-process and we want one
# shared read connection per registered DB. Concurrency comes from the
# async event loop + run_in_threadpool, not multiple worker processes.
CMD ["sh", "-c", "uvicorn app.main:app --host ${H3T_HOST} --port ${H3T_PORT} --workers 1 --proxy-headers"]
