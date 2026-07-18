#!/bin/sh
set -eu

cd /workspace

target_db="${WORKER_DB_NAME:-${SCHEMA_DB:-auto_pws}}"
log_dir="${WORKER_LOG_DIR:-output/worker-logs}"

set -- supervise --python-exe python --db-name "$target_db" --log-dir "$log_dir"

if [ -n "${WORKER_DEBUG_WORKER:-}" ]; then
  set -- "$@" --debug-worker "$WORKER_DEBUG_WORKER"
fi

if [ "${WORKER_DISABLE_MAINTENANCE:-0}" = "1" ]; then
  set -- "$@" --no-maintenance
fi

exec python workers/pws_workers/worker_manager.py "$@"