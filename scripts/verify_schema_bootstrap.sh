#!/usr/bin/env bash
set -euo pipefail

PG_CONTAINER="${PG_CONTAINER:-n8n-postgres}"
TARGET_DB="${TARGET_DB:-}"

print_help() {
  cat <<'EOF'
Usage: verify_schema_bootstrap.sh [options]

Options:
  --container NAME  Postgres container name (default: n8n-postgres)
  --db NAME         Target schema database (default: container SCHEMA_DB or auto_pws)
  -h, --help        Show this help

Environment overrides:
  PG_CONTAINER      Same as --container
  TARGET_DB         Same as --db
EOF
}

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

if ! docker exec -e TARGET_DB="$TARGET_DB" "$PG_CONTAINER" bash -lc 'pg_isready -U "$POSTGRES_USER" -d "$TARGET_DB" >/dev/null'; then
  echo "Postgres is running but not ready for db '$TARGET_DB' (pg_isready failed)." >&2
  exit 1
fi

echo "Checking schema bootstrap sentinels on container: $PG_CONTAINER (db: $TARGET_DB)"

CHECK_RESULTS="$(cat <<'SQL' | docker exec -e TARGET_DB="$TARGET_DB" -i "$PG_CONTAINER" bash -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$TARGET_DB" -At -f -'
WITH checks AS (
    SELECT 'platforms'::text AS object_name, to_regclass('public.platforms') IS NOT NULL AS present
    UNION ALL SELECT 'booking_registers', to_regclass('public.booking_registers') IS NOT NULL
    UNION ALL SELECT 'booking_registers_metadata_column', EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'booking_registers'
          AND column_name = 'metadata'
    )
    UNION ALL SELECT 'booking_registers_ppl_id_column', EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'booking_registers'
          AND column_name = 'ppl_id'
    )
    UNION ALL SELECT 'message_classes', to_regclass('public.message_classes') IS NOT NULL
    UNION ALL SELECT 'app_logs', to_regclass('public.app_logs') IS NOT NULL
    UNION ALL SELECT 'llm_model_usage', to_regclass('public.llm_model_usage') IS NOT NULL
    UNION ALL SELECT 'task_queue', to_regclass('public.task_queue') IS NOT NULL
    UNION ALL SELECT 'task_dependencies', to_regclass('public.task_dependencies') IS NOT NULL
    UNION ALL SELECT 'worker_metadata', to_regclass('public.worker_metadata') IS NOT NULL
    UNION ALL SELECT 'runtime_variables', to_regclass('public.runtime_variables') IS NOT NULL
    UNION ALL SELECT 'pricing_rules', to_regclass('public.pricing_rules') IS NOT NULL
    UNION ALL SELECT 'class_operation_mapping', to_regclass('public.class_operation_mapping') IS NOT NULL
    UNION ALL SELECT 'booking_applied_rules', to_regclass('public.booking_applied_rules') IS NOT NULL
    UNION ALL SELECT 'nightlyrates_listing', to_regclass('public.nightlyrates_listing') IS NOT NULL
    UNION ALL SELECT 'scan_booking_registers_for_extension', to_regprocedure('scan_booking_registers_for_extension(date,date,integer,bigint)') IS NOT NULL
    UNION ALL SELECT 'scan_booking_registers_for_checkout', to_regprocedure('scan_booking_registers_for_checkout(date,integer,bigint)') IS NOT NULL
    UNION ALL SELECT 'create_booking_register_fn', to_regprocedure('create_booking_register(bigint,text,date,date,timestamp with time zone,bigint,integer,text,jsonb,jsonb)') IS NOT NULL
    UNION ALL SELECT 'update_booking_register_fn', to_regprocedure('update_booking_register(bigint,text,date,date,timestamp with time zone,bigint,integer,text,jsonb,jsonb)') IS NOT NULL
    UNION ALL SELECT 'get_booking_register_by_id_fn', to_regprocedure('get_booking_register_by_id(bigint)') IS NOT NULL
    UNION ALL SELECT 'find_booking_registers_fn', to_regprocedure('find_booking_registers(integer,text,text,integer,bigint)') IS NOT NULL
    UNION ALL SELECT 'delete_booking_register_fn', to_regprocedure('delete_booking_register(bigint)') IS NOT NULL
    UNION ALL SELECT 'secrets', to_regclass('public.secrets') IS NOT NULL
    UNION ALL SELECT 'set_secret_fn', to_regprocedure('set_secret(text,text)') IS NOT NULL
    UNION ALL SELECT 'get_secret_fn', to_regprocedure('get_secret(bigint)') IS NOT NULL
    UNION ALL SELECT 'update_secret_fn', to_regprocedure('update_secret(bigint,text,text)') IS NOT NULL
    UNION ALL SELECT 'delete_secret_fn', to_regprocedure('delete_secret(bigint)') IS NOT NULL
)
SELECT object_name || '|' || CASE WHEN present THEN '1' ELSE '0' END
FROM checks
ORDER BY object_name;
SQL
)"

declare -a missing=()

while IFS='|' read -r object_name present_flag; do
  [[ -z "$object_name" ]] && continue
  if [[ "$present_flag" == "1" ]]; then
    echo "  PASS: $object_name"
  else
    echo "  FAIL: $object_name"
    missing+=("$object_name")
  fi
done <<< "$CHECK_RESULTS"

if (( ${#missing[@]} > 0 )); then
  echo "Schema verification failed. Missing sentinels: ${missing[*]}" >&2
  exit 1
fi

UNCLASSIFIED_PRESENT="$(docker exec -e TARGET_DB="$TARGET_DB" "$PG_CONTAINER" bash -lc "psql -v ON_ERROR_STOP=1 -U \"\$POSTGRES_USER\" -d \"$TARGET_DB\" -At -c \"SELECT CASE WHEN EXISTS (SELECT 1 FROM message_classes WHERE name = 'unclassified' AND is_active = TRUE) THEN '1' ELSE '0' END;\"")"

if [[ "$UNCLASSIFIED_PRESENT" == "1" ]]; then
  echo "  PASS: message_classes_unclassified_default"
else
  echo "  FAIL: message_classes_unclassified_default"
  echo "Schema verification failed. Missing sentinels: message_classes_unclassified_default" >&2
  exit 1
fi

echo "Schema verification passed."
