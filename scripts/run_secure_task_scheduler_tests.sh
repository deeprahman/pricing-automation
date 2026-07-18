#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEMA_FILE="$ROOT_DIR/schemas/secure_task_scheduler.sql"
TEST_FILE="$ROOT_DIR/schemas/tests/secure_task_scheduler_test.sql"
PG_CONTAINER="${PG_CONTAINER:-n8n-postgres}"
TARGET_DB="${TARGET_DB:-}"
WITH_SCHEMA=false

print_help() {
  cat <<'EOF'
Usage: run_secure_task_scheduler_tests.sh [options]

Options:
  --with-schema     Apply schema before running tests (drops/recreates objects).
  --test-only       Run tests only (default).
  --container NAME  Postgres container name (default: n8n-postgres).
  --db NAME         Target database name (default: container SCHEMA_DB or auto_pws).
  -h, --help        Show this help.

Environment overrides:
  PG_CONTAINER       Same as --container.
  TARGET_DB          Same as --db.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-schema)
      WITH_SCHEMA=true
      shift
      ;;
    --test-only)
      WITH_SCHEMA=false
      shift
      ;;
    --container)
      PG_CONTAINER="$2"
      shift 2
      ;;
    --container=*)
      PG_CONTAINER="${1#*=}"
      shift
      ;;
    --db)
      TARGET_DB="$2"
      shift 2
      ;;
    --db=*)
      TARGET_DB="${1#*=}"
      shift
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      print_help >&2
      exit 2
      ;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is not installed or not in PATH." >&2
  exit 1
fi

if ! docker inspect "$PG_CONTAINER" >/dev/null 2>&1; then
  echo "Postgres container not found: $PG_CONTAINER" >&2
  exit 1
fi

if [[ "$(docker inspect -f '{{.State.Running}}' "$PG_CONTAINER")" != "true" ]]; then
  echo "Postgres container is not running: $PG_CONTAINER" >&2
  exit 1
fi

if [[ -z "$TARGET_DB" ]]; then
  TARGET_DB="$(docker exec "$PG_CONTAINER" bash -lc 'printf "%s" "${SCHEMA_DB:-auto_pws}"')"
fi

if [[ -z "$TARGET_DB" ]]; then
  echo "Could not determine target database. Set --db or TARGET_DB." >&2
  exit 1
fi

if [[ ! -f "$TEST_FILE" ]]; then
  echo "Missing test file: $TEST_FILE" >&2
  exit 1
fi

if [[ "$WITH_SCHEMA" == "true" && ! -f "$SCHEMA_FILE" ]]; then
  echo "Missing schema file: $SCHEMA_FILE" >&2
  exit 1
fi

if ! docker exec -e TARGET_DB="$TARGET_DB" "$PG_CONTAINER" bash -lc 'pg_isready -U "$POSTGRES_USER" -d "$TARGET_DB" >/dev/null'; then
  echo "Postgres is running but not ready (pg_isready failed)." >&2
  exit 1
fi

if [[ "$WITH_SCHEMA" == "true" ]]; then
  echo "WARNING: --with-schema will DROP and RECREATE scheduler objects." >&2
fi

echo "Running secure_task_scheduler tests on container: $PG_CONTAINER (db: $TARGET_DB)"

TMP_LOG="$(mktemp)"

if [[ "$WITH_SCHEMA" == "true" ]]; then
  cat "$SCHEMA_FILE" "$TEST_FILE" | docker exec -e TARGET_DB="$TARGET_DB" -i "$PG_CONTAINER" bash -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$TARGET_DB" -f -' >"$TMP_LOG" 2>&1 || {
    echo "TEST RESULT: FAIL" >&2
    cat "$TMP_LOG" >&2
    rm -f "$TMP_LOG"
    exit 1
  }
else
  cat "$TEST_FILE" | docker exec -e TARGET_DB="$TARGET_DB" -i "$PG_CONTAINER" bash -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$TARGET_DB" -f -' >"$TMP_LOG" 2>&1 || {
    echo "TEST RESULT: FAIL" >&2
    cat "$TMP_LOG" >&2
    rm -f "$TMP_LOG"
    exit 1
  }
fi

cat "$TMP_LOG"
rm -f "$TMP_LOG"

echo "TEST RESULT: PASS"
