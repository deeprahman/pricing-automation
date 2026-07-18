#!/bin/sh

# Wait for PostgreSQL to be available
until pg_isready -h ${DB_POSTGRESDB_HOST} -p ${DB_POSTGRESDB_PORT} -U ${POSTGRES_USER} -d ${POSTGRES_DB}; do
  echo "Waiting for PostgreSQL to be ready..."
  sleep 2
done

# Hash the password using bcrypt
hashed_password=$(node -e "const bcrypt = require('bcrypt'); bcrypt.hash('${N8N_USER_PASSWORD}', 10).then(console.log)")

# Create user in the database
echo "Creating user in the database..."
psql -h ${DB_POSTGRESDB_HOST} -U ${POSTGRES_USER} -d ${POSTGRES_DB} <<EOF
  INSERT INTO public."user" (email, password, first_name, last_name, created_at, updated_at)
  VALUES ('${N8N_USER_EMAIL}', '${hashed_password}', 'Admin', 'User', NOW(), NOW());
EOF

# Indicate that the user has been created
touch /home/node/.n8n/.user_created
