FROM python:3.11-slim

WORKDIR /workspace

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PYTHONPATH=/workspace:/workspace/workers

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY workers/requirements.txt /tmp/workers-requirements.txt
RUN pip install --no-cache-dir -r /tmp/workers-requirements.txt

COPY workers /workspace/workers
COPY schemas /workspace/schemas
COPY data/dummy_messages /workspace/data/dummy_messages

RUN chmod +x /workspace/workers/docker-entrypoint.sh \
    && mkdir -p /workspace/output/worker-logs

ENTRYPOINT ["/workspace/workers/docker-entrypoint.sh"]
