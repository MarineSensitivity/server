# PINNED (2026-11-05): `:latest` moved to titiler 2.4.0, a /opt/venv image with no `pip` on PATH, and the
# v10 RELEASE_DEPLOY rebuild died at `pip install` (exit 127) while the live containers were still the
# 2.2.1 build. Bump deliberately, with the pip/venv line below adjusted to the new image.
FROM ghcr.io/developmentseed/titiler:2.2.1

# custom-factory deps
COPY requirements.txt /tmp/msens-requirements.txt
RUN pip install --no-cache-dir -r /tmp/msens-requirements.txt

# factory source
WORKDIR /opt/msens
COPY app.py factory.py ./
COPY scripts ./scripts

# default paths — overridable via docker-compose env
ENV MSENS_CELLID_COG=/share/data/derived/r_cellid.tif \
    MSENS_DUCKDB=/share/data/big/latest/sdm.duckdb \
    MSENS_MAX_ROWS=1000000 \
    MSENS_LRU_SIZE=128 \
    PYTHONPATH=/opt/msens

EXPOSE 8000

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000", "--app-dir", "/opt/msens"]
