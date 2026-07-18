FROM postgres:16

RUN set -eux; \
    for attempt in 1 2 3 4 5; do \
        apt-get update \
        && apt-get install -y --no-install-recommends postgresql-16-cron \
        && break; \
        if [ "$attempt" -eq 5 ]; then \
            exit 1; \
        fi; \
        rm -rf /var/lib/apt/lists/*; \
        sleep 5; \
    done; \
    rm -rf /var/lib/apt/lists/*
