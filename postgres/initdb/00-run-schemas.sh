#!/usr/bin/env bash
set -Eeuo pipefail

SCHEMA_DIR="/schemas"
SCHEMA_DB="${SCHEMA_DB:-auto_pws}"

if [[ "${SCHEMA_DB}" == "${POSTGRES_DB}" ]]; then
  echo "SCHEMA_DB must be different from POSTGRES_DB. Current value: ${SCHEMA_DB}" >&2
  exit 1
fi

echo "Recreating schema database: ${SCHEMA_DB}"
psql \
  -v ON_ERROR_STOP=1 \
  --username "${POSTGRES_USER}" \
  --dbname "postgres" \
  --set=schema_db="${SCHEMA_DB}" \
  --set=db_owner="${POSTGRES_USER}" <<'SQL'
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = :'schema_db'
  AND pid <> pg_backend_pid();

SELECT format('DROP DATABASE IF EXISTS %I', :'schema_db')
\gexec

SELECT format('CREATE DATABASE %I OWNER %I', :'schema_db', :'db_owner')
\gexec
SQL

# Deterministic order by dependency (do not rely on locale/glob sorting).
SCHEMA_FILES=(
  "property_platform_sql.sql"
  "property_platform_listing_metadata_migration.sql"
  "pricelabs_pms_metadata_backfill.sql"

  "booking_registers.sql"
  "booking_registers_entry_id_migration.sql"
  "booking_registers_stay_metrics_migration.sql"
  "booking_registers_previous_tracking_migration.sql"
  "booking_registers_stay_tracking_migration.sql"
  "booking_registers_needs_scan_migration.sql"
  "scanners_for_booking_registers.sql"
  "booking_registers_extension_scanner_needs_scan_migration.sql"
  "booking_registers_needs_scan_manual_override_migration.sql"

  "message_processing.sql"
  "message_thread_primary_classes_position_migration.sql"
  "message_classes_defaults.sql"
  "app_log.sql"
  "llm_model_usage.sql"
  "secrets.sql"
  "secure_task_scheduler.sql"
  "secure_task_scheduler_dependencies.sql"
  "secure_task_scheduler_metadata.sql"
  "secure_task_scheduler_runtime_variables.sql"

  "pricing-engine.sql"
  "pricing_engine_set_operation_migration.sql"
  "pricing_rules_listing_scope_migration.sql"
  "pricing_engine_stay_adjustment_migration.sql"
  "pricing_engine_conflict_guard_migration_patched.sql"
  "pricing_engine_condition_tree_migration_patched.sql"
  "pricing_engine_booking_class_position_migration_patched.sql"
  "pricing_engine_rule_guard_migration.sql"
  "pricing_engine_target_rate_type_and_season_window_migration.sql"

  "special_operation_assigner_tables.sql"
  "special_operation_assigner_status_processing_migration.sql"
  "nightlyrates_listing_rate_type_migration.sql"
  "nightlyrates_listing_remove_metadata_rate_type_migration.sql"
  "maintenance.sql"
)

for file in "${SCHEMA_FILES[@]}"; do
  full_path="${SCHEMA_DIR}/${file}"
  if [[ ! -f "${full_path}" ]]; then
    echo "Missing schema file: ${full_path}" >&2
    exit 1
  fi

  echo "Running schema: ${file}"
  psql \
    -v ON_ERROR_STOP=1 \
    --username "${POSTGRES_USER}" \
    --dbname "${SCHEMA_DB}" \
    --file "${full_path}"
done
