# Messages Worker How-To

Location: `workers/pws_workers/messages-worker/messages_worker.py`

Primary queue: `messages-service`

This worker owns the message-processing pipeline. It accepts both live-message actions and dummy-message actions.

## Actions

### User-facing entry actions

- `fetch`
  - Starts the live fetch pipeline.
  - Downstream external action: `get_ownerrez_messages`

- `fetch_dummy`
  - Starts the dummy fetch pipeline.
  - Downstream external action: `get_dummy_messages`

- `scan_unclassified`
  - Claims a batch of pending/unclassified messages from the database and starts the live classification chain.
  - Calls `requeue_stale_processing_messages('15 minutes')` before claiming.
  - Downstream action: `handle_unclassified_messages`

- `handle_unclassified_messages`
  - Starts live classification for messages that already exist in the database.
  - Downstream external action: `classify_messages`

- `handle_unclassified_dummy_messages`
  - Starts dummy classification for messages that already exist in the database.
  - Downstream external action: `classify_dummy_messages`

- `check_classification`
  - Performs a direct thread-class lookup for one or more existing message threads.
  - Reads primary classes from the database and returns one merged, unique, sorted class list in task completion metadata.
  - Optionally supports `return_ref` to publish the result to runtime storage and enqueue a downstream callback task.
  - This action is independent of the fetch/classify pipeline chaining.
  - Legacy spelling `check_clasification` may be accepted only as a compatibility alias.

### Internal callback / pipeline actions

- `fetch_res_handler`
  - Receives fetch results back from `external-services-worker`

- `store_messages`
  - Stores returned message items and enqueues the next fetch page

- `handle_classified_messages`
  - Applies live classification results to the database

- `handle_classified_dummy_messages`
  - Applies dummy classification results to the database

## Live vs Dummy

- Use `fetch` for the live fetch path.
- Use `fetch_dummy` for the dummy fetch path.
- Use `handle_unclassified_messages` for live classification.
- Use `handle_unclassified_dummy_messages` for dummy classification.

The worker keeps these paths separate all the way through callbacks and requeueing.
The external worker currently distinguishes these flows by action name, callback action, and `source_action`, even where the underlying external implementation is still shared.

## Runtime Variable TTLs

- Runtime-variable TTLs are configured from `workers/pws_workers/worker_manifest.json`.
- Resolution precedence is: `action.by_scope[scope]` -> `action.default_ttl_minutes` -> `worker.by_scope[scope]` -> `worker.default_ttl_minutes` -> manifest default -> code fallback.
- In the checked-in manifest, this worker currently uses `default_ttl_minutes = 15`.

## Direct Payload Examples

### 1. Start live fetch

```json
{
  "action": "fetch",
  "booking_id": 51000002,
  "thread_id": 91000002,
  "platform_id": 1
}
```

### 2. Start dummy fetch

```json
{
  "action": "fetch_dummy",
  "booking_id": 51000002,
  "thread_id": 91000002,
  "platform_id": 1
}
```

### 3. Start live classification

This action expects a runtime variable that already contains:

```json
{
  "messages": [
    {
      "message_id": 123,
      "content": "guest text"
    }
  ]
}
```

Payload:

```json
{
  "action": "handle_unclassified_messages",
  "data_ref": {
    "scope": "scanner-classifier",
    "key": "scan-k"
  }
}
```

### 4. Start scan + auto-classification chain

```json
{
  "action": "scan_unclassified",
  "limit": 25
}
```

This action:

1. Requeues stale `processing` rows older than 15 minutes.
2. Claims up to `limit` pending guest rows via `fetch_unclassified_messages(limit, 'guest')`.
3. Writes claimed rows to `scanner-classifier`.
4. Enqueues `handle_unclassified_messages`.
5. Enqueues `scan_unclassified` again (same `limit`) to continue draining.

### 5. Start dummy classification

```json
{
  "action": "handle_unclassified_dummy_messages",
  "data_ref": {
    "scope": "scanner-classifier",
    "key": "scan-k"
  }
}
```

### 6. Check thread classifications

```json
{
  "action": "check_classification",
  "platform_id": 1,
  "thread_ids": [91000002, 91000003, 91000004]
}
```

### 7. Check thread classifications with downstream callback

```json
{
  "action": "check_classification",
  "platform_id": 1,
  "thread_ids": [91000002, 91000003, 91000004],
  "return_ref": {
    "worker": "messages-worker",
    "action": "check_classification_followup",
    "queue": "messages-service"
  }
}
```

## Task Scheduler Helper Examples

If you are enqueueing through `tests/task-scheduler-helper/task_scheduler_helper_worker.py`, the outer record looks like this:

```json
{
  "worker": "messages-worker",
  "queue": "messages-service",
  "action": "fetch_dummy",
  "payload": {
    "booking_id": 51000002,
    "thread_id": 91000002,
    "platform_id": 1
  }
}
```

For `check_classification`:

```json
{
  "worker": "messages-worker",
  "queue": "messages-service",
  "action": "check_classification",
  "payload": {
    "platform_id": 1,
    "thread_ids": [91000002, 91000003, 91000004]
  }
}
```

For `check_classification` with downstream callback to `task-scheduler-helper`:

```json
{
  "worker": "messages-worker",
  "queue": "messages-service",
  "action": "check_classification",
  "payload": {
    "platform_id": 1,
    "thread_ids": [91000002, 91000003, 91000004],
    "return_ref": {
      "worker": "task-scheduler-helper",
      "queue": "task-scheduler-helper",
      "action": "tsh_action"
    }
  }
}
```

Important when using task scheduler helper:

- Use `payload.return_ref` for the downstream callback emitted by `messages-worker`.
- The helper's top-level `return_handler` is separate helper plumbing and does not replace `payload.return_ref`.
- The downstream callback task payload received by `task-scheduler-helper:tsh_action` contains:

```json
{
  "action": "tsh_action",
  "data_ref": {
    "worker_id": "scheduler-worker-id",
    "scope": "check-classification-result",
    "key": "check_cls_res_xxx"
  }
}
```

## Sequential Behavior

### `fetch`

1. Reads `message_thread_progress`
2. Builds the next external fetch request
3. Enqueues `external-services-worker:get_ownerrez_messages`
4. Waits for `fetch_res_handler`
5. Stores messages with `store_messages`
6. Requeues `fetch` for the next page when needed

### `fetch_dummy`

1. Reads `message_thread_progress`
2. Builds the next external fetch request
3. Enqueues `external-services-worker:get_dummy_messages`
4. Waits for `fetch_res_handler`
5. Stores messages with `store_messages`
6. Requeues `fetch_dummy` for the next page when needed

### `scan_unclassified`

1. Validates `limit` (default `25`)
2. Requeues stale processing rows (`15 minutes`)
3. Claims pending guest rows using `fetch_unclassified_messages(limit, 'guest')`
4. If none found, completes with `status=no_messages`
5. Writes batch to runtime scope `scanner-classifier`
6. Enqueues `handle_unclassified_messages`
7. Enqueues `scan_unclassified` continuation with same `limit`

Direct SQL callers may omit the second argument or pass `NULL` to claim all sender roles. The worker wrapper defaults the role filter to `guest`.

### `handle_unclassified_messages`

1. Reads a runtime variable containing unclassified message rows
2. Writes a classify request to `classifier-extsvc`
3. Enqueues `external-services-worker:classify_messages`
4. Waits for `handle_classified_messages`
5. Applies the returned classes into the database

### `handle_unclassified_dummy_messages`

1. Reads a runtime variable containing unclassified message rows
2. Writes a classify request to `classifier-extsvc`
3. Enqueues `external-services-worker:classify_dummy_messages`
4. Waits for `handle_classified_dummy_messages`
5. Applies the returned classes into the database

### `check_classification`

1. Validates required fields: `platform_id` and non-empty `thread_ids`
2. If `return_ref` is present, validates it as an object with required `worker` and `action`; `queue` defaults to `messages-service`
3. Reads primary class names using SQL helper `get_thread_primary_classes(platform_id, thread_id)` for each requested thread ID
4. Builds canonical result payload with `status`, `action`, `platform_id`, `thread_ids`, and merged `classes` (unique + sorted)
5. If `return_ref` is not provided, completes task with result metadata
6. If `return_ref` is provided, writes the result to runtime variables under scope `check-classification-result` using the manifest-resolved TTL (currently 15 minutes in the checked-in manifest)
7. Enqueues the downstream task described by `return_ref` with payload `{"action": "<return_ref.action>", "data_ref": {...}}`
8. Adds `result_data_ref`, `return_ref`, and `downstream_task_uuid` to completion metadata
9. Invalid payload / invalid `return_ref` fails with `retry=false`
10. DB read, runtime write, or downstream enqueue error fails with `retry=true`
11. Legacy spelling `check_clasification` and legacy field `thread_id` may be accepted as compatibility aliases; new callers must use `check_classification` and `thread_ids`.

## Required Fields

### Fetch actions

- `booking_id` or `booking_entry_id`
- `thread_id`
- `platform_id`

### Scan action

- `action = scan_unclassified`
- optional `limit` (positive integer, defaults to `25`)

### Unclassified actions

- `data_ref.key`
- optional `data_ref.scope`

### `check_classification`

- `platform_id`
- `thread_ids`
- optional `return_ref` object
- `return_ref.worker` required when `return_ref` is provided
- `return_ref.action` required when `return_ref` is provided
- `return_ref.queue` optional (defaults to `messages-service`)

## Result Contract

`check_classification` completes with this result shape:

```json
{
  "status": "thread_classes_collected",
  "action": "check_classification",
  "platform_id": 1,
  "thread_ids": [91000002, 91000003, 91000004],
  "classes": [
    "booking_confirmation",
    "medical"
  ]
}
```

If no primary classes exist, `classes` is an empty array.

When `return_ref` is provided, completion metadata also includes callback wiring:

```json
{
  "status": "thread_classes_collected",
  "action": "check_classification",
  "platform_id": 1,
  "thread_ids": [91000002, 91000003, 91000004],
  "classes": [
    "booking_confirmation",
    "medical"
  ],
  "result_data_ref": {
    "worker_id": "scheduler-worker-id",
    "scope": "check-classification-result",
    "key": "check_cls_res_xxx"
  },
  "return_ref": {
    "worker": "messages-worker",
    "queue": "messages-service",
    "action": "check_classification_followup"
  },
  "downstream_task_uuid": "uuid"
}
```

The result is stored in task completion metadata (`task_queue.task_metadata`), not in the original payload.

You can retrieve it with worker manager task stats:

```powershell
python workers/pws_workers/worker_manager.py task-stat --task-uuid <task-uuid> --json
```

## Notes

- `fetch_res_handler`, `store_messages`, `handle_classified_messages`, and `handle_classified_dummy_messages` are normally triggered by the pipeline, not by users directly.
- For dummy fetch callbacks, the incoming payload carries `source_action: "get_dummy_messages"`, which is how the worker knows to requeue `fetch_dummy` instead of `fetch`.
- Default manifest seeds `scan_unclassified` hourly (`first_run_immediate=false`).
