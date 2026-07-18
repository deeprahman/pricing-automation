#!/usr/bin/env bash
#
# rebuild_schema_db_safe.sh
# -----------------------------------------------------------------------------
# Purpose:
#   Safely rebuild the schema database (SCHEMA_DB) using the existing
#   container init script: /docker-entrypoint-initdb.d/00-run-schemas.sh
#
# What this script does:
#   1) Preflight checks and confirmation guard (--yes required).
#   2) Backup phase (before any destructive action):
#      - Full custom backup (schema + data): pg_dump -F c
#      - Data-only custom backup:            pg_dump -F c --data-only
#      - Backup integrity check:             pg_restore -l
#      - Baseline table counts for public schema.
#   3) Controlled downtime (stops workers and fastapi).
#   4) Rebuild + strict restore:
#      - Rebuild SCHEMA_DB with 00-run-schemas.sh
#      - Truncate rebuilt public tables to remove bootstrap defaults
#      - Restore the pre-backup data-only dump in strict mode.
#   5) Validation and rollback safety:
#      - Compare table counts before vs after restore
#      - Run verify_schema_bootstrap.sh
#      - On failure after rebuild starts: auto-rollback from full backup,
#        keep services stopped for manual verification.
#
# Notes:
#   - Reads .env only for manifest context (does not use it for DB auth).
#   - Runtime DB auth is taken from container environment variables.
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PG_CONTAINER="${PG_CONTAINER:-n8n-postgres}"
SCHEMA_DB="${SCHEMA_DB:-}"
BACKUP_DIR=""
CONFIRMED=false
KEEP_SERVICES_STOPPED=false

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
DEFAULT_BACKUP_DIR="${ROOT_DIR}/backups/db-rebuild-${TIMESTAMP}"

WAS_WORKERS_RUNNING=false
WAS_FASTAPI_RUNNING=false
SERVICES_STOPPED=false
REBUILD_STARTED=false
ROLLBACK_ATTEMPTED=false
ROLLBACK_SUCCEEDED=false
START_TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

TMP_DIR_CONTAINER=""
FULL_BACKUP_CONTAINER=""
DATA_BACKUP_CONTAINER=""
MANIFEST_PATH=""
ROLLBACK_LOG=""
ENV_CONTEXT_PATH=""
ENV_CONTEXT_SUMMARY=""

print_help() {
  cat <<'EOF'
Usage: rebuild_schema_db_safe.sh [options]

Safely rebuilds SCHEMA_DB using /docker-entrypoint-initdb.d/00-run-schemas.sh,
then restores pre-existing data exactly.

Options:
  --container NAME            Postgres container name (default: n8n-postgres)
  --schema-db NAME            Schema database name (default: container SCHEMA_DB)
  --backup-dir PATH           Backup output directory
                              (default: ./backups/db-rebuild-<timestamp>)
  --yes                       Required confirmation for destructive rebuild
  --keep-services-stopped     Do not restart services automatically on success
  -h, --help                  Show this help

Environment:
  PG_CONTAINER                Same as --container
  SCHEMA_DB                   Same as --schema-db
EOF
}

log() {
  printf "[%s] %s\n" "$(date +"%Y-%m-%d %H:%M:%S")" "$*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

compose_service_running() {
  local service="$1"
  local running
  running="$(docker compose ps --status running --services 2>/dev/null | tr -d '\r' || true)"
  if echo "${running}" | grep -qx "${service}"; then
    return 0
  fi
  return 1
}

collect_table_counts() {
  # Capture deterministic per-table row counts for the public schema.
  # Used as a simple integrity check before/after restore.
  local out_file="$1"
  docker exec -e TARGET_DB="${SCHEMA_DB}" "${PG_CONTAINER}" bash -lc '
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$TARGET_DB" -At <<'"'"'SQL'"'"'
CREATE TEMP TABLE __table_counts (
  table_name TEXT NOT NULL,
  row_count BIGINT NOT NULL
);

DO $$
DECLARE
  r RECORD;
  c BIGINT;
BEGIN
  FOR r IN
    SELECT schemaname, tablename
    FROM pg_tables
    WHERE schemaname = '"'"'public'"'"'
    ORDER BY tablename
  LOOP
    EXECUTE format('"'"'SELECT count(*) FROM %I.%I'"'"', r.schemaname, r.tablename) INTO c;
    INSERT INTO __table_counts (table_name, row_count)
    VALUES (format('"'"'%I.%I'"'"', r.schemaname, r.tablename), c);
  END LOOP;
END $$;

COPY (
  SELECT table_name, row_count
  FROM __table_counts
  ORDER BY table_name
) TO STDOUT WITH (FORMAT csv, DELIMITER E'"'"'\t'"'"', HEADER FALSE);
SQL
' > "${out_file}"
}

truncate_public_tables() {
  # Clear rebuilt tables so restore loads only pre-existing data.
  # RESTART IDENTITY resets sequences; CASCADE handles dependencies.
  docker exec -e TARGET_DB="${SCHEMA_DB}" "${PG_CONTAINER}" bash -lc '
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$TARGET_DB" <<'"'"'SQL'"'"'
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT schemaname, tablename
    FROM pg_tables
    WHERE schemaname = '"'"'public'"'"'
  LOOP
    EXECUTE format('"'"'TRUNCATE TABLE %I.%I RESTART IDENTITY CASCADE'"'"', r.schemaname, r.tablename);
  END LOOP;
END $$;
SQL
'
}

perform_rollback() {
  # Automatic recovery path used only after rebuild starts.
  # Restores the full backup to return DB to pre-run state.
  if [[ "${ROLLBACK_ATTEMPTED}" == "true" ]]; then
    return 0
  fi
  ROLLBACK_ATTEMPTED=true

  if [[ -z "${FULL_BACKUP_CONTAINER}" ]]; then
    log "Rollback skipped: full backup path is unknown."
    return 1
  fi

  if ! docker exec "${PG_CONTAINER}" test -f "${FULL_BACKUP_CONTAINER}"; then
    log "Rollback skipped: missing backup inside container: ${FULL_BACKUP_CONTAINER}"
    return 1
  fi

  log "Attempting automatic rollback from full backup..."
  {
    echo "===== rollback started at $(date -u +"%Y-%m-%dT%H:%M:%SZ") ====="
    docker exec -e TARGET_DB="${SCHEMA_DB}" "${PG_CONTAINER}" bash -lc '
pg_restore \
  --clean \
  --if-exists \
  --exit-on-error \
  --single-transaction \
  --no-owner \
  --no-privileges \
  -U "$POSTGRES_USER" \
  -d "$TARGET_DB" \
  "'"${FULL_BACKUP_CONTAINER}"'"
'
    echo "===== rollback completed at $(date -u +"%Y-%m-%dT%H:%M:%SZ") ====="
  } >> "${ROLLBACK_LOG}" 2>&1 && ROLLBACK_SUCCEEDED=true

  if [[ "${ROLLBACK_SUCCEEDED}" == "true" ]]; then
    log "Automatic rollback succeeded."
    return 0
  fi

  log "Automatic rollback failed. Check: ${ROLLBACK_LOG}"
  return 1
}

on_err() {
  local line_no="$1"
  local cmd="$2"
  echo "ERROR: command failed at line ${line_no}: ${cmd}" >&2

  if [[ "${REBUILD_STARTED}" == "true" ]]; then
    perform_rollback || true
    cat >&2 <<EOF
Failure occurred after rebuild started.
Services are intentionally left stopped for manual verification.
Backup directory: ${BACKUP_DIR}
Rollback log: ${ROLLBACK_LOG}
EOF
  fi
}
trap 'on_err "${LINENO}" "${BASH_COMMAND}"' ERR

while [[ $# -gt 0 ]]; do
  case "$1" in
    --container)
      PG_CONTAINER="$2"
      shift 2
      ;;
    --container=*)
      PG_CONTAINER="${1#*=}"
      shift
      ;;
    --schema-db)
      SCHEMA_DB="$2"
      shift 2
      ;;
    --schema-db=*)
      SCHEMA_DB="${1#*=}"
      shift
      ;;
    --backup-dir)
      BACKUP_DIR="$2"
      shift 2
      ;;
    --backup-dir=*)
      BACKUP_DIR="${1#*=}"
      shift
      ;;
    --yes)
      CONFIRMED=true
      shift
      ;;
    --keep-services-stopped)
      KEEP_SERVICES_STOPPED=true
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

if [[ "${CONFIRMED}" != "true" ]]; then
  cat >&2 <<'EOF'
Refusing to run without --yes.
This script performs destructive rebuild of SCHEMA_DB.
EOF
  print_help >&2
  exit 2
fi

if ! command -v docker >/dev/null 2>&1; then
  die "docker is not installed or not in PATH."
fi

if ! docker compose version >/dev/null 2>&1; then
  die "docker compose is unavailable."
fi

cd "${ROOT_DIR}"

if [[ -f "${ROOT_DIR}/.env" ]]; then
  # Documentation context only (manifest traceability); no credential loading.
  ENV_CONTEXT_PATH="${ROOT_DIR}/.env"
  ENV_CONTEXT_SUMMARY="$(grep -E '^(POSTGRES_DB|SCHEMA_DB|ADMIN_PWS_DB)=' "${ENV_CONTEXT_PATH}" || true)"
fi

if ! docker inspect "${PG_CONTAINER}" >/dev/null 2>&1; then
  die "Postgres container not found: ${PG_CONTAINER}"
fi

if [[ "$(docker inspect -f '{{.State.Running}}' "${PG_CONTAINER}")" != "true" ]]; then
  die "Postgres container is not running: ${PG_CONTAINER}"
fi

if [[ -z "${SCHEMA_DB}" ]]; then
  SCHEMA_DB="$(docker exec "${PG_CONTAINER}" bash -lc 'printf "%s" "${SCHEMA_DB:-auto_pws}"')"
fi

if [[ -z "${SCHEMA_DB}" ]]; then
  die "Could not determine schema database. Pass --schema-db."
fi

if ! docker exec -e TARGET_DB="${SCHEMA_DB}" "${PG_CONTAINER}" bash -lc 'pg_isready -U "$POSTGRES_USER" -d "$TARGET_DB" >/dev/null'; then
  die "Postgres is not ready for database '${SCHEMA_DB}'."
fi

if ! docker exec "${PG_CONTAINER}" test -x /docker-entrypoint-initdb.d/00-run-schemas.sh; then
  die "Missing executable init script: /docker-entrypoint-initdb.d/00-run-schemas.sh"
fi

if [[ -z "${BACKUP_DIR}" ]]; then
  BACKUP_DIR="${DEFAULT_BACKUP_DIR}"
elif [[ "${BACKUP_DIR}" != /* ]]; then
  BACKUP_DIR="${ROOT_DIR}/${BACKUP_DIR}"
fi

mkdir -p "${BACKUP_DIR}"

MANIFEST_PATH="${BACKUP_DIR}/manifest.txt"
ROLLBACK_LOG="${BACKUP_DIR}/rollback.log"
: > "${ROLLBACK_LOG}"

TMP_DIR_CONTAINER="/tmp/rebuild-schema-safe-${TIMESTAMP}-$$"
FULL_BACKUP_CONTAINER="${TMP_DIR_CONTAINER}/schema_full.backup"
DATA_BACKUP_CONTAINER="${TMP_DIR_CONTAINER}/schema_data_only.backup"

log "Recording current service state..."
if compose_service_running workers; then
  WAS_WORKERS_RUNNING=true
fi
if compose_service_running fastapi; then
  WAS_FASTAPI_RUNNING=true
fi

cat > "${MANIFEST_PATH}" <<EOF
start_utc=${START_TS}
container=${PG_CONTAINER}
schema_db=${SCHEMA_DB}
backup_dir=${BACKUP_DIR}
workers_running_before=${WAS_WORKERS_RUNNING}
fastapi_running_before=${WAS_FASTAPI_RUNNING}
EOF

if [[ -n "${ENV_CONTEXT_PATH}" ]]; then
  {
    echo "env_context_path=${ENV_CONTEXT_PATH}"
    echo "env_context_values_begin"
    printf "%s\n" "${ENV_CONTEXT_SUMMARY}"
    echo "env_context_values_end"
  } >> "${MANIFEST_PATH}"
fi

log "Creating backup directory in container: ${TMP_DIR_CONTAINER}"
docker exec "${PG_CONTAINER}" bash -lc "mkdir -p '${TMP_DIR_CONTAINER}'"

# --- Backup phase: create restorable artifacts before destructive steps ---
log "Creating full backup..."
docker exec -e TARGET_DB="${SCHEMA_DB}" "${PG_CONTAINER}" bash -lc '
pg_dump -U "$POSTGRES_USER" -d "$TARGET_DB" -F c -f "'"${FULL_BACKUP_CONTAINER}"'"
'

log "Creating data-only backup..."
docker exec -e TARGET_DB="${SCHEMA_DB}" "${PG_CONTAINER}" bash -lc '
pg_dump -U "$POSTGRES_USER" -d "$TARGET_DB" -F c --data-only -f "'"${DATA_BACKUP_CONTAINER}"'"
'

log "Verifying backup files are readable..."
docker exec "${PG_CONTAINER}" bash -lc '
pg_restore -l "'"${FULL_BACKUP_CONTAINER}"'" >/dev/null
pg_restore -l "'"${DATA_BACKUP_CONTAINER}"'" >/dev/null
'

log "Copying backup files to host..."
docker cp "${PG_CONTAINER}:${FULL_BACKUP_CONTAINER}" "${BACKUP_DIR}/schema_full.backup"
docker cp "${PG_CONTAINER}:${DATA_BACKUP_CONTAINER}" "${BACKUP_DIR}/schema_data_only.backup"

log "Capturing pre-restore row counts..."
collect_table_counts "${BACKUP_DIR}/counts.before.tsv"

# --- Downtime + rebuild phase ---
log "Stopping app writer services (workers, fastapi)..."
docker compose stop workers fastapi
SERVICES_STOPPED=true

log "Rebuilding schema DB via init script..."
REBUILD_STARTED=true
docker exec -e SCHEMA_DB="${SCHEMA_DB}" "${PG_CONTAINER}" bash -lc '/docker-entrypoint-initdb.d/00-run-schemas.sh'

log "Truncating all public tables in rebuilt schema DB..."
truncate_public_tables

# --- Restore phase (strict exact data restore) ---
log "Restoring data-only backup in strict mode..."
docker exec -e TARGET_DB="${SCHEMA_DB}" "${PG_CONTAINER}" bash -lc '
pg_restore \
  --data-only \
  --single-transaction \
  --exit-on-error \
  --disable-triggers \
  --no-owner \
  --no-privileges \
  -U "$POSTGRES_USER" \
  -d "$TARGET_DB" \
  "'"${DATA_BACKUP_CONTAINER}"'"
'

log "Capturing post-restore row counts..."
collect_table_counts "${BACKUP_DIR}/counts.after.tsv"

log "Comparing row counts..."
if ! diff -u "${BACKUP_DIR}/counts.before.tsv" "${BACKUP_DIR}/counts.after.tsv" > "${BACKUP_DIR}/counts.diff"; then
  echo "Row count mismatch detected. See: ${BACKUP_DIR}/counts.diff" >&2
  exit 1
fi

log "Running schema bootstrap verification..."
bash "${ROOT_DIR}/scripts/verify_schema_bootstrap.sh" --container "${PG_CONTAINER}" --db "${SCHEMA_DB}"

END_TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
{
  echo "end_utc=${END_TS}"
  echo "rollback_attempted=${ROLLBACK_ATTEMPTED}"
  echo "rollback_succeeded=${ROLLBACK_SUCCEEDED}"
} >> "${MANIFEST_PATH}"

if [[ "${KEEP_SERVICES_STOPPED}" == "true" ]]; then
  log "Keeping services stopped as requested."
else
  services_to_start=()
  if [[ "${WAS_WORKERS_RUNNING}" == "true" ]]; then
    services_to_start+=("workers")
  fi
  if [[ "${WAS_FASTAPI_RUNNING}" == "true" ]]; then
    services_to_start+=("fastapi")
  fi

  if (( ${#services_to_start[@]} > 0 )); then
    log "Restarting services that were previously running: ${services_to_start[*]}"
    docker compose start "${services_to_start[@]}"
  else
    log "No services were running before rebuild; skipping restart."
  fi
fi

log "Safe schema rebuild completed successfully."
cat <<EOF
Summary:
  Backup directory: ${BACKUP_DIR}
  Full backup:      ${BACKUP_DIR}/schema_full.backup
  Data backup:      ${BACKUP_DIR}/schema_data_only.backup
  Row counts:       ${BACKUP_DIR}/counts.before.tsv, ${BACKUP_DIR}/counts.after.tsv
  Manifest:         ${MANIFEST_PATH}
EOF

log "Cleaning temporary backup files from container..."
docker exec "${PG_CONTAINER}" bash -lc "rm -rf '${TMP_DIR_CONTAINER}'" >/dev/null 2>&1 || true
