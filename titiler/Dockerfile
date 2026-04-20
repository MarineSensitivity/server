FROM ghcr.io/developmentseed/titiler:latest

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
