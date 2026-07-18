#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PG_CONTAINER="${PG_CONTAINER:-n8n-postgres}"
BACKUP_ROOT="${BACKUP_ROOT:-${ROOT_DIR}/backups/pg_incremental}"
STATE_DIR="${STATE_DIR:-${BACKUP_ROOT}/state}"
RUNS_DIR="${RUNS_DIR:-${BACKUP_ROOT}/runs}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"

# Mode/args
MODE=""
RESTORE_FROM=""
DB_FILTER=""

usage() {
  cat <<'USAGE'
Usage:
  postgres_incremental_backup.sh backup [options]
  postgres_incremental_backup.sh restore [options]

Modes:
  backup   Export incremental table data from PostgreSQL in Docker.
  restore  Restore one run, or replay all runs in order.

Options:
  --container NAME     Postgres container name (default: n8n-postgres or $PG_CONTAINER)
  --backup-root PATH   Backup root path (default: ./backups/pg_incremental)
  --state-dir PATH     State directory path (default: <backup-root>/state)
  --db NAME            Backup/restore only one database

Restore-only:
  --from PATH          Run directory OR backup root containing runs/. If omitted,
                       all runs under runs/ are replayed in ascending order.

Examples:
  ./scripts/postgres_incremental_backup.sh backup
  ./scripts/postgres_incremental_backup.sh backup --db auto_pws
  ./scripts/postgres_incremental_backup.sh restore --from ./backups/pg_incremental/runs/20260514-011500
  ./scripts/postgres_incremental_backup.sh restore --from ./backups/pg_incremental

Notes:
  - Incremental logic requires a cursor per table:
    1) preferred: updated_at / modified_at / last_updated / created_at (timestamp/date)
    2) fallback: single-column numeric primary key
  - Tables without a supported cursor are skipped and logged.
USAGE
}

log() {
  printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

parse_args() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  MODE="$1"
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --container)
        PG_CONTAINER="$2"
        shift 2
        ;;
      --backup-root)
        BACKUP_ROOT="$2"
        shift 2
        ;;
      --state-dir)
        STATE_DIR="$2"
        shift 2
        ;;
      --from)
        RESTORE_FROM="$2"
        shift 2
        ;;
      --db)
        DB_FILTER="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done

  RUNS_DIR="${BACKUP_ROOT}/runs"
}

check_prereqs() {
  command -v docker >/dev/null 2>&1 || die "docker is required"
  command -v awk >/dev/null 2>&1 || die "awk is required"
  command -v sort >/dev/null 2>&1 || die "sort is required"
  docker ps --format '{{.Names}}' | grep -Fxq "${PG_CONTAINER}" || die "Container not running: ${PG_CONTAINER}"

  docker exec "${PG_CONTAINER}" bash -lc 'command -v psql >/dev/null 2>&1' >/dev/null || die "psql not found in container"
  docker exec "${PG_CONTAINER}" bash -lc 'command -v pg_dump >/dev/null 2>&1' >/dev/null || die "pg_dump not found in container"

  mkdir -p "${BACKUP_ROOT}" "${STATE_DIR}" "${RUNS_DIR}"
  touch "${STATE_DIR}/checkpoints.tsv"
}

psql_query_at() {
  local db="$1"
  local sql="$2"
  docker exec -i -e TARGET_DB="${db}" "${PG_CONTAINER}" bash -lc \
    'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$TARGET_DB" -At' <<<"${sql}"
}

psql_exec() {
  local db="$1"
  local sql="$2"
  docker exec -i -e TARGET_DB="${db}" "${PG_CONTAINER}" bash -lc \
    'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$TARGET_DB"' <<<"${sql}" >/dev/null
}

dump_schema() {
  local db="$1"
  local out_file="$2"
  docker exec -i -e TARGET_DB="${db}" "${PG_CONTAINER}" bash -lc \
    'pg_dump -U "$POSTGRES_USER" -d "$TARGET_DB" --schema-only --no-owner --no-privileges' >"${out_file}"
}

state_file() {
  echo "${STATE_DIR}/checkpoints.tsv"
}

get_state() {
  local db="$1"
  local schema="$2"
  local table="$3"
  awk -F $'\t' -v d="$db" -v s="$schema" -v t="$table" '
    $1==d && $2==s && $3==t {print $4"\t"$5"\t"$6; found=1}
    END {if (!found) exit 1}
  ' "$(state_file)"
}

set_state() {
  local db="$1"
  local schema="$2"
  local table="$3"
  local kind="$4"
  local col="$5"
  local val="$6"

  local sf
  sf="$(state_file)"
  local tmp
  tmp="$(mktemp)"

  awk -F $'\t' -v OFS=$'\t' -v d="$db" -v s="$schema" -v t="$table" -v k="$kind" -v c="$col" -v v="$val" '
    !($1==d && $2==s && $3==t) {print}
  ' "${sf}" > "${tmp}"

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$db" "$schema" "$table" "$kind" "$col" "$val" >> "${tmp}"
  mv "${tmp}" "${sf}"
}

list_databases() {
  local sql
  sql="
SELECT datname
FROM pg_database
WHERE datallowconn
  AND NOT datistemplate
ORDER BY datname;
"
  psql_query_at "postgres" "${sql}"
}

list_tables() {
  local db="$1"
  local sql
  sql="
SELECT table_schema || E'\\t' || table_name
FROM information_schema.tables
WHERE table_type = 'BASE TABLE'
  AND table_schema NOT IN ('pg_catalog', 'information_schema')
ORDER BY table_schema, table_name;
"
  psql_query_at "${db}" "${sql}"
}

detect_cursor() {
  local db="$1"
  local schema="$2"
  local table="$3"

  local sql_ts
  # Avoid shell-dependent escaping issues by using SQL literals directly.
  sql_ts=$(cat <<SQL
SELECT c.column_name || E'\t' || c.data_type
FROM information_schema.columns c
WHERE c.table_schema = '$(printf '%s' "${schema}" | sed "s/'/''/g")'
  AND c.table_name = '$(printf '%s' "${table}" | sed "s/'/''/g")'
  AND c.column_name IN ('updated_at','modified_at','last_updated','created_at')
  AND c.data_type IN ('timestamp without time zone','timestamp with time zone','date')
ORDER BY CASE c.column_name
  WHEN 'updated_at' THEN 1
  WHEN 'modified_at' THEN 2
  WHEN 'last_updated' THEN 3
  WHEN 'created_at' THEN 4
  ELSE 10 END
LIMIT 1;
SQL
)

  local ts_line=""
  ts_line="$(psql_query_at "${db}" "${sql_ts}" || true)"
  if [[ -n "${ts_line}" ]]; then
    local ts_col="${ts_line%%$'\t'*}"
    echo -e "ts\t${ts_col}"
    return 0
  fi

  local sql_pk
  sql_pk=$(cat <<SQL
WITH pk AS (
  SELECT kcu.column_name, c.data_type
  FROM information_schema.table_constraints tc
  JOIN information_schema.key_column_usage kcu
    ON tc.constraint_name = kcu.constraint_name
   AND tc.table_schema = kcu.table_schema
   AND tc.table_name = kcu.table_name
  JOIN information_schema.columns c
    ON c.table_schema = kcu.table_schema
   AND c.table_name = kcu.table_name
   AND c.column_name = kcu.column_name
  WHERE tc.constraint_type = 'PRIMARY KEY'
    AND tc.table_schema = '$(printf '%s' "${schema}" | sed "s/'/''/g")'
    AND tc.table_name = '$(printf '%s' "${table}" | sed "s/'/''/g")'
), cnt AS (
  SELECT count(*) AS n FROM pk
)
SELECT pk.column_name || E'\t' || pk.data_type
FROM pk, cnt
WHERE cnt.n = 1
  AND pk.data_type IN ('smallint','integer','bigint','numeric')
LIMIT 1;
SQL
)

  local pk_line=""
  pk_line="$(psql_query_at "${db}" "${sql_pk}" || true)"
  if [[ -n "${pk_line}" ]]; then
    local pk_col="${pk_line%%$'\t'*}"
    echo -e "pk\t${pk_col}"
    return 0
  fi

  return 1
}

current_max_value() {
  local db="$1"
  local schema="$2"
  local table="$3"
  local col="$4"

  local sql
  sql=$(cat <<SQL
SELECT max("${col}")::text
FROM "${schema}"."${table}";
SQL
)
  psql_query_at "${db}" "${sql}" || true
}

export_incremental_csv() {
  local db="$1"
  local schema="$2"
  local table="$3"
  local col="$4"
  local last_val="$5"
  local high_val="$6"
  local out_file="$7"

  local where_clause=""
  if [[ -n "${last_val}" ]]; then
    where_clause="\"${col}\" > '$(printf '%s' "${last_val}" | sed "s/'/''/g")' AND "
  fi
  where_clause+="\"${col}\" <= '$(printf '%s' "${high_val}" | sed "s/'/''/g")'"

  local sql
  sql=$(cat <<SQL
COPY (
  SELECT *
  FROM "${schema}"."${table}"
  WHERE ${where_clause}
  ORDER BY "${col}" ASC
) TO STDOUT WITH (FORMAT csv, HEADER true);
SQL
)

  docker exec -i -e TARGET_DB="${db}" "${PG_CONTAINER}" bash -lc \
    'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$TARGET_DB"' <<<"${sql}" >"${out_file}"
}

run_backup() {
  local run_dir="${RUNS_DIR}/${RUN_ID}"
  mkdir -p "${run_dir}"

  local manifest="${run_dir}/manifest.tsv"
  printf 'database\tschema\ttable\tcursor_kind\tcursor_column\tfrom_value\tto_value\trows\tfile\n' > "${manifest}"

  local dbs
  dbs="$(list_databases)"

  if [[ -n "${DB_FILTER}" ]]; then
    if ! printf '%s\n' "${dbs}" | grep -Fxq "${DB_FILTER}"; then
      die "Database not found or not allowed: ${DB_FILTER}"
    fi
    dbs="${DB_FILTER}"
  fi

  if [[ -z "${dbs}" ]]; then
    die "No databases found"
  fi

  log "Starting incremental backup run: ${RUN_ID}"

  while IFS= read -r db; do
    [[ -z "${db}" ]] && continue
    log "Processing database: ${db}"

    local db_dir="${run_dir}/${db}"
    mkdir -p "${db_dir}/data"

    dump_schema "${db}" "${db_dir}/schema.sql"

    local tables
    tables="$(list_tables "${db}")"

    while IFS=$'\t' read -r schema table; do
      [[ -z "${schema}" || -z "${table}" ]] && continue

      local cursor_kind=""
      local cursor_col=""
      local from_val=""

      if state_line="$(get_state "${db}" "${schema}" "${table}" 2>/dev/null)"; then
        cursor_kind="${state_line%%$'\t'*}"
        state_line="${state_line#*$'\t'}"
        cursor_col="${state_line%%$'\t'*}"
        from_val="${state_line#*$'\t'}"
      else
        if cursor_line="$(detect_cursor "${db}" "${schema}" "${table}" 2>/dev/null)"; then
          cursor_kind="${cursor_line%%$'\t'*}"
          cursor_col="${cursor_line#*$'\t'}"
          from_val=""
        else
          log "Skipping ${db}.${schema}.${table}: no incremental cursor column found"
          printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${db}" "${schema}" "${table}" "skip" "" "" "" "0" "" >> "${manifest}"
          continue
        fi
      fi

      local max_val
      max_val="$(current_max_value "${db}" "${schema}" "${table}" "${cursor_col}")"

      if [[ -z "${max_val}" ]]; then
        log "No rows in ${db}.${schema}.${table}; checkpoint unchanged"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "${db}" "${schema}" "${table}" "${cursor_kind}" "${cursor_col}" "${from_val}" "" "0" "" >> "${manifest}"
        continue
      fi

      local data_file="${db_dir}/data/${schema}.${table}.csv"
      export_incremental_csv "${db}" "${schema}" "${table}" "${cursor_col}" "${from_val}" "${max_val}" "${data_file}"

      local lines
      lines="$(wc -l < "${data_file}")"
      local rows=0
      if [[ "${lines}" -gt 1 ]]; then
        rows=$((lines - 1))
      fi

      if [[ "${rows}" -eq 0 ]]; then
        rm -f "${data_file}"
      fi

      set_state "${db}" "${schema}" "${table}" "${cursor_kind}" "${cursor_col}" "${max_val}"

      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${db}" "${schema}" "${table}" "${cursor_kind}" "${cursor_col}" "${from_val}" "${max_val}" "${rows}" "${data_file#${run_dir}/}" >> "${manifest}"

      log "Backed up ${db}.${schema}.${table}: ${rows} rows"
    done <<< "${tables}"
  done <<< "${dbs}"

  log "Backup completed: ${run_dir}"
  log "State file: $(state_file)"
}

ensure_db_exists() {
  local db="$1"
  local exists
  exists="$(psql_query_at "postgres" "SELECT 1 FROM pg_database WHERE datname = '$(printf '%s' "${db}" | sed "s/'/''/g")';" || true)"
  if [[ -n "${exists}" ]]; then
    return 0
  fi

  log "Creating database: ${db}"
  psql_exec "postgres" "CREATE DATABASE \"${db}\";"
}

restore_schema_if_missing() {
  local db="$1"
  local schema_file="$2"

  # Apply schema idempotently by ignoring "already exists" and "does not exist" issues.
  docker exec -i -e TARGET_DB="${db}" "${PG_CONTAINER}" bash -lc \
    'psql -v ON_ERROR_STOP=0 -U "$POSTGRES_USER" -d "$TARGET_DB"' < "${schema_file}" >/dev/null || true
}

restore_csv_file() {
  local db="$1"
  local schema="$2"
  local table="$3"
  local csv_file="$4"

  docker exec -i -e TARGET_DB="${db}" "${PG_CONTAINER}" bash -lc \
    'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$TARGET_DB" -c '\''COPY "'"${schema}"'"."'"${table}"'" FROM STDIN WITH (FORMAT csv, HEADER true);'\''' \
    < "${csv_file}" >/dev/null
}

reset_sequences() {
  local db="$1"
  local sql
  sql=$(cat <<'SQL'
DO $$
DECLARE
  r RECORD;
  max_val BIGINT;
BEGIN
  FOR r IN
    SELECT
      n.nspname AS schema_name,
      c.relname AS table_name,
      a.attname AS column_name,
      s.relname AS sequence_name,
      sn.nspname AS sequence_schema
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
    JOIN pg_attrdef ad ON ad.adrelid = c.oid AND ad.adnum = a.attnum
    JOIN pg_depend d ON d.refobjid = c.oid AND d.refobjsubid = a.attnum
    JOIN pg_class s ON s.oid = d.objid AND s.relkind = 'S'
    JOIN pg_namespace sn ON sn.oid = s.relnamespace
    WHERE c.relkind = 'r'
      AND n.nspname NOT IN ('pg_catalog', 'information_schema')
      AND pg_get_expr(ad.adbin, ad.adrelid) LIKE 'nextval(%'
  LOOP
    EXECUTE format('SELECT COALESCE(MAX(%I), 0) FROM %I.%I', r.column_name, r.schema_name, r.table_name) INTO max_val;
    EXECUTE format('SELECT setval(%L, %s, true)', r.sequence_schema || '.' || r.sequence_name, max_val);
  END LOOP;
END $$;
SQL
)
  psql_exec "${db}" "${sql}"
}

collect_runs_for_restore() {
  local from_path="$1"

  if [[ -z "${from_path}" ]]; then
    from_path="${RUNS_DIR}"
  fi

  if [[ -d "${from_path}/runs" ]]; then
    from_path="${from_path}/runs"
  fi

  if [[ -d "${from_path}" && -f "${from_path}/manifest.tsv" ]]; then
    printf '%s\n' "${from_path}"
    return 0
  fi

  if [[ -d "${from_path}" ]]; then
    find "${from_path}" -mindepth 1 -maxdepth 1 -type d | sort
    return 0
  fi

  die "Invalid restore source path: ${from_path}"
}

run_restore() {
  local runs
  runs="$(collect_runs_for_restore "${RESTORE_FROM}")"

  if [[ -z "${runs}" ]]; then
    die "No backup runs found to restore"
  fi

  log "Starting restore"

  while IFS= read -r run_dir; do
    [[ -z "${run_dir}" ]] && continue
    [[ -f "${run_dir}/manifest.tsv" ]] || { log "Skipping ${run_dir}: manifest.tsv not found"; continue; }

    log "Restoring run: ${run_dir}"
    declare -A prepared_db=()

    # Restore databases detected in this run.
    while IFS=$'\t' read -r db schema table kind cursor from_val to_val rows rel_file; do
      if [[ "${db}" == "database" ]]; then
        continue
      fi

      if [[ -n "${DB_FILTER}" && "${db}" != "${DB_FILTER}" ]]; then
        continue
      fi

      if [[ -z "${prepared_db[${db}]:-}" ]]; then
        ensure_db_exists "${db}"
        local schema_file="${run_dir}/${db}/schema.sql"
        if [[ -f "${schema_file}" ]]; then
          restore_schema_if_missing "${db}" "${schema_file}"
        fi
        prepared_db["${db}"]=1
      fi

      if [[ "${kind}" == "skip" || "${rows}" == "0" || -z "${rel_file}" ]]; then
        continue
      fi

      local csv_file="${run_dir}/${rel_file}"
      if [[ ! -f "${csv_file}" ]]; then
        die "Missing CSV file referenced in manifest: ${csv_file}"
      fi

      restore_csv_file "${db}" "${schema}" "${table}" "${csv_file}"
      log "Restored ${rows} rows into ${db}.${schema}.${table}"
    done < "${run_dir}/manifest.tsv"

    # Reset sequences for all databases present in this run.
    for db_dir in "${run_dir}"/*; do
      [[ -d "${db_dir}" ]] || continue
      local db_name
      db_name="$(basename "${db_dir}")"

      if [[ -n "${DB_FILTER}" && "${db_name}" != "${DB_FILTER}" ]]; then
        continue
      fi

      reset_sequences "${db_name}" || log "Sequence reset warning in ${db_name}"
    done
  done <<< "${runs}"

  log "Restore completed"
}

main() {
  parse_args "$@"
  check_prereqs

  case "${MODE}" in
    backup)
      run_backup
      ;;
    restore)
      run_restore
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
