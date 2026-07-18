# Worker Manager

`workers/pws_workers/worker_manager.py` manages the Python workers under `workers/pws_workers/` using the manifest in `workers/pws_workers/worker_manifest.json`.

## Managed workers

The current manifest includes:

- `external-services-worker`
- `messages-worker`

Update `workers/pws_workers/worker_manifest.json` when you add or remove managed workers.

## What it does

The manager can:

- start workers from the manifest
- supervise workers and restart them after DB outages
- stop workers
- restart workers
- reset the schema database in Docker
- apply SQL seed files or seed directories
- show worker stats
- show task stats
- run a background maintenance loop that periodically calls `promote_scheduled_tasks()` and `reset_stuck_tasks()`

## Basic usage

Show help:

```powershell
python workers/pws_workers/worker_manager.py --help
```

Start all managed workers:

```powershell
python workers/pws_workers/worker_manager.py start
```

Run the long-lived supervisor that keeps workers running and waits for Postgres to come back before restarting them:

```powershell
python workers/pws_workers/worker_manager.py supervise
```

Start only one worker:

```powershell
python workers/pws_workers/worker_manager.py start --worker messages-worker
```

Start workers and reset the schema first:

```powershell
python workers/pws_workers/worker_manager.py start --refresh-db
```

Start workers, reset the schema, and load seed SQL:

```powershell
python workers/pws_workers/worker_manager.py start --refresh-db --seed-path schemas/seeds/dummy-messages-seed
```

Stop all managed workers:

```powershell
python workers/pws_workers/worker_manager.py stop
```

Stop one worker only:

```powershell
python workers/pws_workers/worker_manager.py stop --worker messages-worker
```

Restart all managed workers:

```powershell
python workers/pws_workers/worker_manager.py restart
```

Restart one worker:

```powershell
python workers/pws_workers/worker_manager.py restart --worker external-services-worker
```

## VS Code debugging

Reserve one worker for manual launch under the debugger while the rest of the stack starts normally:

```powershell
python workers/pws_workers/worker_manager.py start --debug-worker messages-worker
```

The manager prints the exact launch command for the reserved worker.

## Docker workers service

The compose stack now includes a dedicated `workers` container that starts the manifest workers automatically.
The container now uses `supervise`, so if `n8n-postgres` is down temporarily and the worker processes exit, the manager waits for DB connectivity and starts them again after Postgres recovers.

Start the stack:

```powershell
docker compose -f docker-compose.yml -f docker-compose.local.yml --env-file .env.local up -d --build
```

Optional env vars for the `workers` service:

- `WORKER_DB_NAME` to override the schema DB name
- `WORKER_DEBUG_WORKER` to keep one manifest worker stopped for manual debugging
- `WORKER_DISABLE_MAINTENANCE=1` to skip the maintenance loop
- `WORKERS_DEBUG_PORT` to change the local debugpy port mapping (default `5678`)

When `WORKER_DEBUG_WORKER` is set, start the target script in the container with debugpy and then attach from VS Code using the `Python: Attach to Workers Container` launch configuration:

```powershell
docker compose exec workers python -m debugpy --listen 0.0.0.0:5678 --wait-for-client workers/pws_workers/messages-worker/messages_worker.py --auto-dsn --db-name auto_pws
```

## Database commands

Reset the schema only:

```powershell
python workers/pws_workers/worker_manager.py refresh-db
```

Apply a single SQL file:

```powershell
python workers/pws_workers/worker_manager.py seed --path schemas/seeds/message_processing.seed_data.sql
```

Apply all `.sql` files in a directory:

```powershell
python workers/pws_workers/worker_manager.py seed --path schemas/seeds/dummy-messages-seed
```

These commands use Docker and default to:

- container: `n8n-postgres`
- schema script: `/docker-entrypoint-initdb.d/00-run-schemas.sh`

Override them when needed:

```powershell
python workers/pws_workers/worker_manager.py refresh-db --container-name my-postgres --db-name auto_pws
```

## Stats

Show worker process and DB worker stats:

```powershell
python workers/pws_workers/worker_manager.py worker-stat
```

Show stats for one worker:

```powershell
python workers/pws_workers/worker_manager.py worker-stat --worker messages-worker
```

Show task scheduler stats:

```powershell
python workers/pws_workers/worker_manager.py task-stat
```

Show one task by id:

```powershell
python workers/pws_workers/worker_manager.py task-stat --task-id 42
```

Show JSON output:

```powershell
python workers/pws_workers/worker_manager.py worker-stat --json
python workers/pws_workers/worker_manager.py task-stat --json
```

## Manifest

Manifest path:

```text
workers/pws_workers/worker_manifest.json
```

Each worker entry defines:

- `name`
- `primary_queue`
- `subscribed_queues`
- `script_path`
- `args`
- `runtime_variables`
- `log_prefix`
- `startup_delay_seconds`
- `enabled`

The manager starts workers in manifest order.

`runtime_variables` controls runtime-variable expiry. The manager merges the manifest-level defaults with the worker-level overrides and passes the effective config to the worker process automatically.

Supported shape:

```json
{
  "runtime_variables": {
    "default_ttl_minutes": 15
  },
  "workers": [
    {
      "name": "messages-worker",
      "runtime_variables": {
        "default_ttl_minutes": 60,
        "by_action": {
          "fetch": {
            "by_scope": {
              "fetch-extsvc-request": 30
            }
          }
        }
      }
    }
  ]
}
```

TTL precedence inside a worker is:

- `action.by_scope[scope]`
- `action.default_ttl_minutes`
- `worker.by_scope[scope]`
- `worker.default_ttl_minutes`
- manifest default
- code fallback

`seed_schedule` supports recurring startup seeding for workers that should always keep one scheduler row active.
`seed_schedules` supports multiple recurring seeds for the same worker.

Rules:

- Use either `seed_schedule` or `seed_schedules` per worker entry, not both.
- `seed_schedule` is a single object.
- `seed_schedules` is a non-empty array of schedule objects.

Supported fields:

- `action` (required)
- `recurrence_pattern` (required): `hourly`, `daily`, `weekly`, `monthly`
- `limit` (optional, default `25`)
- `first_run_immediate` (optional, default `true`)
- `time_of_day` (optional): `HH:MM` or `HH:MM:SS` (24-hour)
- `timezone` (optional): IANA timezone such as `America/New_York`
- `payload` (optional): additional JSON object merged into seeded task payload

Rules:

- `time_of_day` and `timezone` are optional, but when one is set the other is required.
- Exact local-time scheduling is supported for `daily`, `weekly`, and `monthly`.
- `hourly` keeps boundary behavior and does not accept `time_of_day`/`timezone`.
- `payload` must be a JSON object and cannot override reserved keys `action` or `limit`.

Example with multiple recurring tasks:

```json
{
  "name": "bookings-worker",
  "seed_schedules": [
    {
      "action": "process_checkout",
      "limit": 100,
      "recurrence_pattern": "daily",
      "time_of_day": "10:00",
      "timezone": "America/New_York",
      "first_run_immediate": false
    },
    {
      "action": "update_message_threads",
      "limit": 100,
      "recurrence_pattern": "hourly",
      "first_run_immediate": false,
      "payload": {
        "n_days": 30
      }
    }
  ]
}
```

DST note:

- The scheduler keeps the run at `10:00` New York local wall-clock time across EST/EDT transitions, while `scheduled_at` in PostgreSQL remains UTC.

Implementation note:

- For manifest-seeded recurring tasks, `worker_manager.py` must call `enqueue_task` with `scheduled_at = NULL` and pass only `recurrence_pattern`/`time_of_day`/`timezone`.
- `enqueue_task` is the single owner of first-run calculation via `calculate_next_run(...)`.
- Do not precompute `calculate_next_run(...)` in manager code before calling `enqueue_task`; that causes an extra interval shift.

## Logs

Default log directory:

```text
output/worker-logs
```

Override it with:

```powershell
python workers/pws_workers/worker_manager.py start --log-dir output/my-worker-logs
```

Each worker gets:

- `<log_prefix>.out.log`
- `<log_prefix>.err.log`

The maintenance loop also gets its own log files.

## DSN and database selection

Worker startup uses the worker scripts' `--auto-dsn` flow by default and passes `--db-name`.

Stats and maintenance commands can also use:

- `--dsn` for an explicit DSN
- `--auto-dsn` to build from `.env` / `.env.local`
- `--no-auto-dsn` to disable automatic DSN resolution

## Maintenance loop

By default, `start` also launches a detached maintenance process that periodically runs `promote_scheduled_tasks()` and `reset_stuck_tasks()`.
If you run with `--no-maintenance`, scheduled tasks stay in `scheduled` until maintenance is re-enabled or promoted manually.

Disable it:

```powershell
python workers/pws_workers/worker_manager.py start --no-maintenance
```

Change the interval:

```powershell
python workers/pws_workers/worker_manager.py start --reset-interval-seconds 30
```

The manifest can also define maintenance actions. `small_server_disk_maintenance_run`
keeps row retention bounded. `postgres_table_compaction` is a worker-manager
built-in action for reclaiming PostgreSQL heap/index bloat with `VACUUM FULL`
on selected high-churn tables.

Default compaction target:

```json
{
  "name": "postgres_table_compaction",
  "enabled": true,
  "interval_minutes": 10080,
  "first_run_immediate": false,
  "payload": {
    "tables": [
      "public.task_metadata_history",
      "public.app_logs",
      "public.audit_log",
      "public.task_queue",
      "public.runtime_variables"
    ],
    "min_total_size_mb": 64,
    "lock_timeout_seconds": 5,
    "statement_timeout_seconds": 900,
    "analyze": true,
    "verbose": true,
    "reindex": false
  }
}
```

Notes:

- `VACUUM FULL` takes an exclusive lock per table.
- `lock_timeout_seconds` makes the action skip quickly if the table is busy.
- The size threshold avoids rewriting small tables.
- Take a snapshot or `pg_dump` before enabling an immediate first run.
