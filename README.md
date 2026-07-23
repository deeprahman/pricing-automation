# Pricing Automation Workers Stack

This repo runs Postgres, a dedicated Python `workers` service, and FastAPI
behind Nginx. The admin UI is served under `/pwsadmin/home`.

## What This Does
A highly optimized, AI-powered pricing orchestrator that solves multi-PMS and multi-tool pricing complexity:

1. **Unified Pricing Analysis & Configuration**
   - Integrates with multiple Property Management Systems (PMS) and dynamic pricing tools simultaneously
   - Analyzes various data types (demand signals, seasonality, market trends, occupancy) to identify property-specific pricing opportunities
   - Allows granular pricing configuration at multiple levels: individual property, property group, seasonal, OTA, and PMS level

2. **Fill Pricing Gaps**
   - Handles pricing scenarios that your dynamic pricing tools cannot cover
   - Automatically applies custom pricing rules based on your configuration

3. **Intelligent Demand-Based Pricing**
   - Identifies demand patterns on specific properties
   - Automatically adjusts pricing across all connected systems based on detected demand and your rules

4. **Cross-Platform Price Synchronization**
   - Synchronizes pricing across Property Management Systems (PMS), dynamic pricing tools, and OTAs (Online Travel Agencies)
   - Ensures consistent pricing across all booking channels and integrations
   - Maintains real-time sync with OTA APIs where available

## Use Case
Suppose you manage many listings across multiple OTAs, PMSs, and dynamic pricing tools. Dynamic pricing tools generally do their job correctly, but there are situations they cannot address on their own because they lack access to booking patterns and guest behavior data. Those situations — where only a human with access to guest and booking data can correctly interpret the opportunity — often require manual overrides or custom nightly rates to optimize revenue.

When your portfolio contains many listings, manually identifying and updating rates becomes time consuming. This project automates that process: it analyzes booking patterns and guest data, identifies opportunities that dynamic pricing tools cannot act on, and applies overrides or updated rates across your connected systems so you don't have to do it manually for each listing.

## Compatibility
This solution is compatible with:
- **Multiple PMS (Property Management Systems)**: Support for various property management platforms
- **Multiple DPT (Dynamic Pricing Tools)**: Integration with different dynamic pricing providers
- **Multiple LLM Service Providers**: Flexible AI/LLM backend support (e.g., OpenAI, Ollama, and others)

## Requirements
- Docker and Docker Compose

## Key Paths
- `docker-compose.yml` (production baseline)
- `docker-compose.local.yml` (local override for host Postgres access)
- `.env` / `.env.example`
- `nginx/templates/default.conf.template` (active Nginx config)
- `nginx/ssl/` (TLS certs)
- `fastapi/` (landing page service)
- `workers/pws_workers/` (managed Python worker project)
- `workers/worker_manager.md` (worker runtime and debug usage)

## Local Docker Compose overrides
- `docker-compose.yml` defines the full stack (workers, Postgres, FastAPI, nginx).
- `docker-compose.local.yml` is intentionally minimal; it runs on top of the base compose file, publishes Postgres plus the workers debugpy port to `127.0.0.1` for local tooling, and switches live mes[...]
- Always invoke Docker Compose with both files when you need local host access:

  ```bash
  docker compose -f docker-compose.yml -f docker-compose.local.yml --env-file .env.local up -d --build
  ```

  The second file layers the port override (`127.0.0.1:${POSTGRES_HOST_PORT:-5432}:5432`) on top of the service configuration and does not replace the rest of the stack.

## Local Setup (auto.pricingautomation.lo)
1. Create a local env file:
   ```bash
   cp .env.example .env.local
   ```
2. Edit `.env.local` and set at least:
   ```
   DOMAIN=auto.pricingautomation.lo
   BASE_DOMAIN=pricingautomation.lo
   SSL_CERT=/etc/nginx/ssl/auto.pricingautomation.lo.crt
   SSL_KEY=/etc/nginx/ssl/auto.pricingautomation.lo.key
   ```
3. Generate secrets and update `.env.local`:
   ```bash
   openssl rand -hex 32    # N8N_ENCRYPTION_KEY
   openssl rand -base64 24 # POSTGRES_PASSWORD
   ```
4. Create a self-signed cert if needed:
   ```bash
   mkdir -p nginx/ssl
   openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
     -keyout nginx/ssl/auto.pricingautomation.lo.key \
     -out nginx/ssl/auto.pricingautomation.lo.crt \
     -subj "/CN=auto.pricingautomation.lo"
   ```
5. Map the domain locally (hosts file):
   ```
   127.0.0.1 auto.pricingautomation.lo pricingautomation.lo
   ```
6. Start the stack:
   ```bash
   docker compose \
     -f docker-compose.yml \
     -f docker-compose.local.yml \
     --env-file .env.local up -d --build
   ```
   Local runs expect an Ollama server reachable from the `workers` container at `http://host.docker.internal:11550` by default. Override `OLLAMA_API_URL` or `OLLAMA_MODEL` in `.env.local` if your loca[...]
7. Visit:
   - Admin UI: `https://auto.pricingautomation.lo/pwsadmin/home`
8. Connect to local Postgres from host tools (including Python):
   ```bash
   psql "host=127.0.0.1 port=${POSTGRES_HOST_PORT:-5432} dbname=${POSTGRES_DB} user=${POSTGRES_USER} password=${POSTGRES_PASSWORD}"
   ```
   ```python
   # pip install psycopg[binary]
   import os
   import psycopg

   conn = psycopg.connect(
       host="127.0.0.1",
       port=int(os.getenv("POSTGRES_HOST_PORT", "5432")),
       dbname=os.getenv("POSTGRES_DB", "n8n"),
       user=os.getenv("POSTGRES_USER", "n8n"),
       password=os.getenv("POSTGRES_PASSWORD"),
   )
   with conn, conn.cursor() as cur:
       cur.execute("SELECT now();")
       print(cur.fetchone()[0])
   ```

## Production Setup (auto.pricingautomation.com)
1. Create `.env.prod` and set:
   ```
   DOMAIN=auto.pricingautomation.com
   BASE_DOMAIN=pricingautomation.com
   SSL_CERT=/etc/nginx/ssl/fullchain.pem
   SSL_KEY=/etc/nginx/ssl/privkey.pem
   ```
2. Obtain certs (example using certbot on the host):
   ```bash
   sudo certbot certonly --standalone \
     -d auto.pricingautomation.com \
     --email you@example.com \
     --agree-tos \
     --no-eff-email

   sudo cp /etc/letsencrypt/live/auto.pricingautomation.com/fullchain.pem nginx/ssl/
   sudo cp /etc/letsencrypt/live/auto.pricingautomation.com/privkey.pem nginx/ssl/
   sudo chown -R $USER:$USER nginx/ssl
   ```
3. Start the stack:
   ```bash
   docker compose -f docker-compose.yml --env-file .env.prod up -d --build
   ```

## Environment Variables
- `DOMAIN`: subdomain (used by Nginx and n8n)
- `BASE_DOMAIN`: root domain for redirect
- `SSL_CERT`, `SSL_KEY`: TLS cert paths inside the Nginx container
- `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`
- `SCHEMA_DB`: database recreated and loaded from SQL files in `./schemas` (default: `auto_pws`)
- `POSTGRES_HOST_PORT`: host port for local Postgres access (`docker-compose.local.yml`, default `5432`)
- `N8N_ENCRYPTION_KEY`
- `N8N_USER_EMAIL`, `N8N_USER_PASSWORD`
- `TZ`
- `PWS_MESSAGE_CLASSIFIER_PROVIDER`: live classifier provider for workers (`openai` by default, `ollama` in `docker-compose.local.yml`)
- `OLLAMA_API_URL`: local Ollama endpoint used when provider is `ollama` (default local override: `http://host.docker.internal:11550`)
- `OLLAMA_MODEL`: Ollama model name for local live classification (default local override: `llama3.2:3b`)

## Schema Database Separation
- n8n app data stays in `POSTGRES_DB` (default: `n8n`).
- `postgres/initdb/00-run-schemas.sh` recreates `SCHEMA_DB` (default: `auto_pws`) and then installs SQL files from `./schemas`.
- `SCHEMA_DB` must be different from `POSTGRES_DB`.
- Running the schema bootstrap destroys all existing data in `SCHEMA_DB`.
- Postgres init scripts in `/docker-entrypoint-initdb.d` run only when `PGDATA` is empty.
- Bootstrap applies production schema SQL only plus reference defaults shipped as schema files, such as `message_classes_defaults.sql` (no `*_test.sql`, no demo seed SQL).
- Compose volumes are project-scoped by default (`<project>_postgres_data`, `<project>_n8n_data`).
- SQL layout:
  - Schema files: `schemas/*.sql`
  - Seed/demo files: `schemas/seeds/*.sql`
  - SQL test files: `schemas/tests/**/*.sql`

## Schema Bootstrap Recovery (Clean First Run)
Use this when schema files were skipped due to an existing Postgres volume:

```bash
docker compose down -v --remove-orphans
docker compose up -d --build
```

Expected first-init log lines:

```bash
docker compose logs --no-color postgres | rg "Recreating schema database|Running schema: message_processing.sql"
```

Run schema smoke verification:

```bash
./scripts/verify_schema_bootstrap.sh
```

## Optional Seed/Demo SQL and Test SQL
Seed/demo SQL is now manual by design. Run only when needed for local experimentation:

```bash
docker compose exec -T postgres psql -U "${POSTGRES_USER}" -d "${SCHEMA_DB:-auto_pws}" -f /schemas/seeds/property_platform_sql.seed_data.sql
docker compose exec -T postgres psql -U "${POSTGRES_USER}" -d "${SCHEMA_DB:-auto_pws}" -f /schemas/seeds/scanner_for_extension.seed_data.sql

# Optional demo/usage query packs (not required for seed data)
docker compose exec -T postgres psql -U "${POSTGRES_USER}" -d "${SCHEMA_DB:-auto_pws}" -f /schemas/seeds/property_platform_sql.demo_queries.sql
docker compose exec -T postgres psql -U "${POSTGRES_USER}" -d "${SCHEMA_DB:-auto_pws}" -f /schemas/seeds/scanner_for_extension.usage_examples.sql
```

Run scheduler tests separately from bootstrap:

```bash
./scripts/run_secure_task_scheduler_tests.sh --test-only
```



## Nginx Templating
Nginx reads `nginx/templates/default.conf.template` and renders it at startup
using the environment variables above. Edit the template for routing changes.

## Useful Commands
```bash
docker compose logs -f nginx
docker compose restart nginx
docker compose down
```


## Task Scheduler Helper & External Service Handler
1. Ensure Postgres is running (e.g., `docker compose -f docker-compose.yml -f docker-compose.local.yml up -d` or another Postgres instance reachable at `127.0.0.1:5432`).
2. From the repo root, start the helper worker:

   ```bash
   python tests/task-scheduler-helper/task_scheduler_helper_worker.py --once
   ```

   Omit `--once` for continuous processing, and use `--dsn <dsn>`/`--no-auto-dsn` if you need custom credentials. The helper reads `tests/task-scheduler-helper/tsh_in/enqueue_task.json`, runs `reset_s[...]
3. In a second terminal, run the external service handler:

   ```bash
   python tests/external-service-handler-worker/external_service_handler.py --dsn postgresql://n8n:kUGkqDwExXgdwmPyMEO3XVsUEYnaNCYt@127.0.0.1:5432/auto_pws
   ```

   Or rely on auto DSN (`--auto-dsn`) if you have the Postgres env vars already set.
4. With both processes running, add tasks to `tests/task-scheduler-helper/tsh_in/enqueue_task.json`. Each entry should specify `worker`, `queue`, `action`, and (optionally) `return_handler`; the [...]

The worker scripts write runtime logs to `tests/logs/<worker>.err.log` during direct runs; when using `tests/run-worker-stack.ps1`, check the worker log files under the selected log directory. For hel[...] 

For stepping through one worker in VS Code while the rest of the local worker stack runs normally, use:

```powershell
pwsh -NoProfile -File tests/run-worker-stack.ps1 -DebugWorker message-classifier
```

That leaves the named worker stopped so you can launch it manually from VS Code with the `Python: Current File (auto DSN)` debug profile. See `tests/README.md` for the worker-stack details.

## Manually activate the User account for PWS Dashboard

# 1) Check schema
```
docker exec -i n8n-postgres psql -U n8n -d admin_pws -c "\d+ users"
```
# 2) See first account
```
docker exec -i n8n-postgres psql -U n8n -d admin_pws -c "SELECT id,email,username,is_active,is_admin FROM users ORDER BY id ASC LIMIT 1;"
```
# 3) Activate first account
```
docker exec -i n8n-postgres psql -U n8n -d admin_pws -c "UPDATE users SET is_active = TRUE, updated_at = NOW() WHERE id = (SELECT id FROM users ORDER BY id ASC LIMIT 1) RETURNING id,email,username,is_[...]"
```
