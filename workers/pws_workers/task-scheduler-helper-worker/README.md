Task Scheduler Helper Worker
============================

Location: `workers/pws_workers/task-scheduler-helper-worker/task_scheduler_helper_worker.py`

Purpose
- Reads task definitions from `tsh_in/enqueue_task.json`.
- Enqueues each task into the secure task scheduler with its target `worker`, `queue`, `action`, `payload`, and optional scheduling controls.
- Relies on `worker_manager` maintenance for scheduler upkeep (`promote_scheduled_tasks()` and `reset_stuck_tasks()`).
- Monitors each enqueued task through `get_task_status(...)` from `schemas/secure_task_scheduler.sql`.
- Polls the `task-scheduler-helper` queue.
- For action `tsh_action`, validates `payload.data_ref`, reads the referenced runtime variable, and writes payload + collected runtime data to `tsh_out/task_uuid_{uuid}.json`.
- For monitored tasks, writes the latest scheduler status snapshot to `tsh_out/task_uuid_{enqueued-task-uuid}.json`.
- Moves successfully enqueued entries from `enqueue_task.json` into `enqueued_task.json`.
- For `tsh_action`, also fetches `task_queue.task_metadata` (when available) and adds it to the output file.

Input file
- Path: `workers/pws_workers/task-scheduler-helper-worker/tsh_in/enqueue_task.json`
- Structure: JSON array

```json
[
  {
    "worker": "external-services-worker",
    "queue": "external-services",
    "action": "get_ownerrez_messages",
    "return_handler": {
      "worker": "task-scheduler-helper",
      "queue": "task-scheduler-helper",
      "action": "tsh_action"
    },
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
]
```

Behavior details
- `worker` can be `null`; when missing/null, helper uses `action` as the task name.
- `payload.action` is forced to the top-level `action`.
- Optional `schedule` object supports:
  - `recurrence_pattern` (`hourly`, `daily`, `weekly`, `monthly`)
  - `scheduled_at` (ISO timestamp; optional)
  - `priority` (0-100; optional, default `0`)
  - `max_attempts` (1-10; optional, default `3`)
- `schedule.recurrence_pattern` enables recurring mode; helper enqueues with `task_type=recurring`. Without it, helper enqueues with `task_type=immediate`.
- Schedule metadata stays out of `payload`; only task business data + return-handler fields are sent to downstream workers.
- If recurring is enabled and `scheduled_at` is omitted, first run time is determined by scheduler recurrence logic (next interval boundary).
- `return_handler` is copied into:
  - `payload.return_handler`
  - `payload.return_handler_worker`
  - `payload.return_handler_queue`
  - `payload.return_handler_action`
- For dequeued `tsh_action` callbacks, `payload.data_ref` is required and must include:
  - `worker_id`
  - `scope`
  - `key`
- For dequeued `tsh_action` callbacks, helper reads `get_runtime_variable(worker_id, key, scope, false, false)` and stores the value in output field `_helper_collection.runtime_value`.
- The resolved runtime value is also mirrored to top-level `data_ref_value` for convenience.
- Each output file includes `task_meta` with `task_uuid`, `task_id`, `queue_name`, and `worker`.
- Successfully enqueued entries are appended to `tsh_in/enqueued_task.json` with:
  - `enqueued_task_id` once the helper resolves it from the scheduler
  - `enqueued_task_uuid`
  - `enqueued_at`
  - normalized `schedule` (when provided)
- The helper also updates top-level tracking fields:
  - `task_status`
  - `task_status_checked_at`
- The helper adds `monitor` metadata after status checks:
  - `last_checked_at`
  - `last_known_status`
  - `is_terminal`
  - `output_file`
- Failed entries stay in `enqueue_task.json`.

Run
```bash
python workers/pws_workers/task-scheduler-helper-worker/task_scheduler_helper_worker.py
```

Useful options
```bash
# Manual DSN override
python workers/pws_workers/task-scheduler-helper-worker/task_scheduler_helper_worker.py --dsn "host=127.0.0.1 port=5432 dbname=auto_pws user=n8n password=***"

# Single cycle (process enqueue file once + one dequeue attempt)
python workers/pws_workers/task-scheduler-helper-worker/task_scheduler_helper_worker.py --once

# Worker runtime controls
python workers/pws_workers/task-scheduler-helper-worker/task_scheduler_helper_worker.py --max-concurrent-tasks 2 --heartbeat-interval "15 seconds"
```

DSN behavior
- By default, DSN auto-build is enabled.
- Auto DSN reads `.env`/environment values and uses `auto_pws` as the default DB name.
- If you disable auto DSN, pass `--dsn`.

Output
- Callback payload files are written to:
  - `workers/pws_workers/task-scheduler-helper-worker/tsh_out/task_uuid_<task-uuid>.json` containing:
    - Original payload (with return handler fields)
    - `_helper_collection` (data_ref and runtime_value)
    - `data_ref_value` (same as `_helper_collection.runtime_value`)
    - `task_metadata` (from `task_queue.task_metadata` via `get_task_metadata(api_key, task_id)`)
    - `task_meta` (task_uuid, task_id, queue_name, worker)
- Scheduler status snapshots for enqueued tasks are written to the same folder using the enqueued task UUID.
- Runtime logs are written to `output/worker-logs/task-scheduler-helper.err.log` when using the worker stack; direct runs default to the shared runtime log directory.
- Uses the shared worker runtime in `pws_workers.shared.worker_runtime`, so target queue enqueues reuse the same scheduler worker registration.
