#!/usr/bin/env bash
set -Eeuo pipefail

ADMIN_PWS_DB="${ADMIN_PWS_DB:-admin_pws}"

if [[ "${ADMIN_PWS_DB}" == "${POSTGRES_DB}" ]]; then
  echo "ADMIN_PWS_DB must be different from POSTGRES_DB. Current value: ${ADMIN_PWS_DB}" >&2
  exit 1
fi

echo "Ensuring admin database exists: ${ADMIN_PWS_DB}"
psql \
  -v ON_ERROR_STOP=1 \
  --username "${POSTGRES_USER}" \
  --dbname "postgres" \
  --set=admin_db="${ADMIN_PWS_DB}" \
  --set=db_owner="${POSTGRES_USER}" <<'SQL'
SELECT format('CREATE DATABASE %I OWNER %I', :'admin_db', :'db_owner')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'admin_db')
\gexec
SQL

