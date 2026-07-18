# Task Scheduler Helper Worker How-To

Location: `workers/pws_workers/task-scheduler-helper-worker/task_scheduler_helper_worker.py`

Primary queue: `task-scheduler-helper`

This worker does two jobs in the same loop:

1. Reads `tsh_in/enqueue_task.json` and enqueues tasks for other workers.
2. Polls `task-scheduler-helper` queue for callback tasks (`tsh_action`) and writes callback outputs to `tsh_out`.

It also tracks status for already-enqueued tasks in `tsh_in/enqueued_task.json`.

## Files used by this worker

- Input queue file: `workers/pws_workers/task-scheduler-helper-worker/tsh_in/enqueue_task.json`
- Enqueued history: `workers/pws_workers/task-scheduler-helper-worker/tsh_in/enqueued_task.json`
- Output snapshots: `workers/pws_workers/task-scheduler-helper-worker/tsh_out/task_uuid_<uuid>.json`

## Enqueue input contract (`enqueue_task.json`)

Each array item can include:

- `worker` string, optional (defaults to top-level `action`)
- `queue` string, required
- `action` string, required
- `payload` object, optional
- `return_handler` object, optional
- `schedule` object, optional
- `data_ref_seed` object, optional

`return_handler` defaults to helper callback target:

```json
{
  "worker": "task-scheduler-helper",
  "queue": "task-scheduler-helper",
  "action": "tsh_action"
}
```

`schedule` supports:

- `recurrence_pattern`: `hourly | daily | weekly | monthly`
- `scheduled_at`: ISO datetime string (optional)
- `priority`: integer `0..100` (optional, default `0`)
- `max_attempts`: integer `1..10` (optional, default `3`)

If `schedule.recurrence_pattern` is present, helper enqueues with `task_type=recurring`.
If missing, helper enqueues with `task_type=immediate`.

`data_ref_seed` supports:

- `scope` (required)
- `key` (required)
- `value` (required; JSON object)
- `worker_id` (optional; defaults to helper worker's current `worker_id`)
- `ttl_minutes` (optional; defaults from runtime TTL config resolution by action/scope)
- `is_secret` (optional; defaults to `false`)

When `data_ref_seed` is present, helper writes the runtime variable first and injects:

```json
"payload": {
  "data_ref": {
    "worker_id": "<resolved_worker_id>",
    "scope": "<scope>",
    "key": "<key>"
  }
}
```

## Example: One-time enqueue record

```json
{
  "worker": "messages-worker",
  "queue": "messages-service",
  "action": "check_clasification",
  "payload": {
    "platform_id": 1,
    "thread_id": 91000002
  }
}
```

## Example: One-time enqueue record with `data_ref_seed`

```json
{
  "worker": "external-services-worker",
  "queue": "external-services",
  "action": "get_ownerrez_bookings",
  "payload": {
    "provider_key": "ownerrez",
    "platform_id": 1
  },
  "data_ref_seed": {
    "scope": "fetch-bookings-request",
    "key": "fetch_bookings_request_manual_20260413T120000Z",
    "value": {
      "requested_action": "get_bookings",
      "provider_key": "ownerrez",
      "platform_id": 1
    }
  }
}
```

## Example: Recurring enqueue record

```json
{
  "worker": "external-services-worker",
  "queue": "external-services",
  "action": "get_ownerrez_messages",
  "payload": {
    "thread_id": 91000002,
    "offset": 0,
    "limit": 6
  },
  "schedule": {
    "recurrence_pattern": "daily",
    "scheduled_at": "2026-03-24T00:00:00Z",
    "priority": 0,
    "max_attempts": 3
  }
}
```

Note: if recurring is enabled and `scheduled_at` is omitted, scheduler starts at the next recurrence boundary.

## What happens sequentially

Each poll cycle runs in this order:

1. Read `enqueue_task.json`.
2. Normalize each record:
   - Ensure `queue` and `action`.
   - Fill `worker` default.
   - Force `payload.action = action`.
   - Inject callback fields into payload:
     - `payload.return_handler`
     - `payload.return_handler_worker`
     - `payload.return_handler_queue`
     - `payload.return_handler_action`
   - Validate optional `schedule`.
3. Enqueue each valid record to secure scheduler (`enqueue_task`).
4. Move successful records to `enqueued_task.json` and remove them from `enqueue_task.json`.
5. For `data_ref_seed` write/validation failures:
   - Do not enqueue downstream task.
   - Move a failed tracking record to `enqueued_task.json` with `seed_status=failed`, `seed_error`, `task_status=seed_failed`, and `enqueued_task_uuid=null`.
6. Leave non-seed enqueue failures in `enqueue_task.json` and log the error.
7. Rely on `worker_manager` maintenance for `promote_scheduled_tasks()` and `reset_stuck_tasks()`.
8. Monitor `enqueued_task.json` records:
   - Resolve `enqueued_task_id` from `enqueued_task_uuid` when needed.
   - Call `get_task_status(...)`.
   - Write/refresh status snapshot in `tsh_out/task_uuid_<enqueued_task_uuid>.json`.
   - Update monitor fields in `enqueued_task.json`.
9. Dequeue one helper task from `task-scheduler-helper`.
10. For dequeued `tsh_action` task:
   - Validate `payload.data_ref` with required `worker_id`, `scope`, `key`.
   - Fetch runtime variable using `get_runtime_variable(worker_id, key, scope, false, false)`.
   - Fetch `task_metadata` from `task_queue` when available.
   - Write callback payload + resolved runtime value to `tsh_out/task_uuid_<task_uuid>.json`.
   - Complete helper task with summary metadata.

## Recurring task behavior

- Recurring continuation is handled by secure scheduler SQL, not by helper logic.
- A recurring task schedules the next run when current run is completed successfully.
- If a recurring run ends in terminal failure, next recurring run is not auto-created.
- Retries still apply before final failure according to scheduler rules.

## Run commands

```bash
python workers/pws_workers/task-scheduler-helper-worker/task_scheduler_helper_worker.py
```

Single-cycle mode:

```bash
python workers/pws_workers/task-scheduler-helper-worker/task_scheduler_helper_worker.py --once
```

Explicit DSN:

```bash
python workers/pws_workers/task-scheduler-helper-worker/task_scheduler_helper_worker.py --dsn "host=127.0.0.1 port=5432 dbname=auto_pws user=n8n password=***"
```

## Quick validation checklist

1. Add one record to `tsh_in/enqueue_task.json`.
2. Run helper with `--once`.
3. Confirm record moved to `tsh_in/enqueued_task.json`.
4. Confirm status snapshot written in `tsh_out`.
5. For callback-enabled pipelines, confirm callback output file includes:
   - `_helper_collection.runtime_value`
   - `data_ref_value`
   - `task_meta`
   - `task_metadata`

## Step-by-step: Enqueue `get_ownerrez_bookings` via helper (recommended)

Use this flow when you want helper to create runtime data automatically (no manual `set_runtime_variable(...)` SQL).

1. Open `workers/pws_workers/task-scheduler-helper-worker/tsh_in/enqueue_task.json`.
2. Add one array entry like this:

```json
[
  {
    "worker": "external-services-worker",
    "queue": "external-services",
    "action": "get_ownerrez_bookings",
    "payload": {
      "return_ref": {
        "worker": "task-scheduler-helper",
        "queue": "task-scheduler-helper",
        "action": "tsh_action"
      }
    },
    "data_ref_seed": {
      "scope": "fetch-bookings-request",
      "key": "fetch_bookings_request_manual_20260413T120000Z",
      "value": {
        "requested_action": "get_bookings",
        "provider_key": "ownerrez",
        "platform_id": 1,
        "timezone": "UTC",
        "focus_start": "2026-04-13",
        "focus_end": "2026-07-12",
        "listing_ids": ["389550", "389551"],
        "page_size": 2,
        "offset": 0,
        "request_kind": "manual",
        "provider_query": {
          "from": "2026-04-13",
          "to": "2026-07-12",
          "statuses": ["active", "pending"]
        }
      }
    }
  }
]
```

3. Run helper once:

```bash
python workers/pws_workers/task-scheduler-helper-worker/task_scheduler_helper_worker.py --once
```

4. What helper does automatically:
   - Writes runtime variable using `data_ref_seed`.
   - Injects `payload.data_ref` with resolved `worker_id/scope/key`.
   - Enqueues task to queue `external-services`.
   - Moves record to `tsh_in/enqueued_task.json`.

5. Verify enqueue + seed:
   - `tsh_in/enqueued_task.json` should contain:
     - `seed_status: "written"`
     - `data_ref` with actual `worker_id`, `scope`, `key`
     - `enqueued_task_uuid`
   - `tsh_out/task_uuid_<enqueued_task_uuid>.json` is updated by monitor with scheduler status.

6. Verify callback output:
   - After external worker runs and sends callback to helper (`tsh_action`), helper writes:
     - `workers/pws_workers/task-scheduler-helper-worker/tsh_out/task_uuid_<callback_task_uuid>.json`
   - That file includes:
     - `data_ref_value` (resolved runtime payload)
     - `_helper_collection.runtime_value`

## Legacy/manual flow (still supported)

If you prefer manual SQL seeding, your existing 2-step method is valid:

1. Call `set_runtime_variable(...)` in SQL.
2. Enqueue helper record with explicit `payload.data_ref`.

Example helper record for manual mode:

```json
[
  {
    "worker": "external-services-worker",
    "queue": "external-services",
    "action": "get_ownerrez_bookings",
    "payload": {
      "data_ref": {
        "worker_id": "<same worker_id used in SQL set_runtime_variable>",
        "scope": "fetch-bookings-request",
        "key": "fetch_bookings_request_manual_20260413T120000Z"
      },
      "return_ref": {
        "worker": "task-scheduler-helper",
        "queue": "task-scheduler-helper",
        "action": "tsh_action"
      }
    }
  }
]
```
