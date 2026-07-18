# Universal Secure Task Scheduler Specification

**Version:** 1.0  
**Status:** Normative implementation guide  
**Scope:** Secure task scheduler database schema, stored APIs, worker-facing contract, and test requirements  
**Target file:** `schemas/universal_secure_task_scheduler_specification.md`  

> This specification is written for AI coding tools and engineers implementing a secure, universal task scheduler. It distills the scheduler behavior from the schema modules in this directory and turns it into an implementation contract. Preserve the invariants even if the final implementation uses a different language, migration framework, or service layer.

---

## 1. Source Files Read

This document is derived from these scheduler schema files:

| Source file | Role |
|---|---|
| `schemas/secure_task_scheduler.sql` | Core PostgreSQL scheduler: worker auth, queues, tasks, leasing, retries, recurrence, audit, monitoring |
| `schemas/secure_task_scheduler_metadata.sql` | Worker metadata, task metadata, metadata history, deep JSON merge, metadata cleanup |
| `schemas/secure_task_scheduler_dependencies.sql` | Task dependency graph, cycle prevention, dependency-gated dequeue, auto-fail propagation |
| `schemas/secure_task_scheduler_runtime_variables.sql` | Runtime variables, scoped config/value storage, encrypted secret variables |

Behavioral expectations were cross-checked against:

| Test file | Coverage |
|---|---|
| `schemas/tests/secure_task_scheduler_test.sql` | Core queue lifecycle, recurrence, leases, auth, cleanup, stats, lineage |
| `schemas/tests/secure_task_scheduler_metadata_test.sql` | Metadata deep merge, validation, ownership, lease checks, cleanup |
| `schemas/tests/secure_task_scheduler_dependencies_test.sql` | Dependency gating, batch dependencies, removal, cycle detection, auto-fail |
| `schemas/tests/secure_task_scheduler_runtime_variables_test.sql` | Runtime variable CRUD, encryption, expiry, fallback, cascade behavior |

---

## 2. Design Goal

Build a secure scheduler that lets authenticated workers enqueue, dequeue, heartbeat, complete, fail, retry, inspect, and coordinate tasks across named queues.

The scheduler must:

- Support multiple named queues and worker queue subscriptions.
- Use atomic task claiming so concurrent workers never process the same task.
- Use leases and heartbeats so stuck work can be recovered.
- Enforce worker authentication, rate limiting, payload validation, ownership checks, and audit logging.
- Support delayed and recurring tasks.
- Support retries with terminal failure after max attempts.
- Support task dependency gates.
- Support worker and task metadata with audit/history.
- Support scoped runtime variables, including encrypted secret values.
- Expose monitoring views and stats APIs.
- Be testable through database-level or service-level integration tests.

---

## 3. Non-Negotiable Invariants

An implementation is not acceptable unless these invariants hold:

1. A worker can only dequeue from the intersection of its subscribed queues and the queues requested by the dequeue call.
2. Dequeue must be atomic. Use row locks equivalent to `SELECT ... FOR UPDATE SKIP LOCKED`, a compare-and-swap update, or another proven concurrency primitive.
3. A task in `processing` is owned by exactly one worker and protected by a lease.
4. Only the owning worker can heartbeat, complete, fail, or mutate metadata for a processing task.
5. Expired leases must prevent task metadata mutation and allow stuck task recovery.
6. API keys must never be stored in plaintext. Store only hashes and a short non-secret prefix.
7. All worker-controlled inputs must be validated before writes.
8. All security-sensitive operations must be audit logged, including failures where practical.
9. A dependency-blocked task must not dequeue until every prerequisite task is `completed`.
10. A failed prerequisite must cause pending, retrying, or scheduled dependents to fail.
11. Recurring task completion must create the next scheduled run while preserving queue, payload, priority, max attempts, recurrence pattern, recurrence time, and recurrence timezone.
12. Cleanup functions must enforce minimum retention guards so accidental short retention cannot erase recent operational history.
13. Secret runtime variables must be encrypted at rest and decrypted only when the configured encryption key is available.
14. Handlers and workers must use scheduler APIs. They must not write raw state transitions directly to scheduler tables.

---

## 4. Installation and Module Order

For the PostgreSQL implementation, install modules in this order:

1. `secure_task_scheduler.sql`
2. `secure_task_scheduler_metadata.sql`
3. `secure_task_scheduler_dependencies.sql`
4. `secure_task_scheduler_runtime_variables.sql`
5. Optional maintenance modules that call scheduler cleanup functions

The dependency module overrides `dequeue_task(...)` to add dependency gating. If another module also replaces `dequeue_task(...)`, the final installed version must include both queue-subscription enforcement and dependency gating.

For production migrations, prefer non-destructive `CREATE IF NOT EXISTS` and `ALTER` migrations. The core source file is a bootstrap-style schema and uses `DROP ... CASCADE`; do not blindly apply destructive drops to a live scheduler unless the task explicitly requires rebuilding the schema.

---

## 5. Core Domain Model

### 5.1 Task Status

Required task states:

| Status | Meaning |
|---|---|
| `pending` | Ready to run when scheduled time has arrived |
| `scheduled` | Delayed or recurring task waiting for future promotion |
| `processing` | Claimed by a worker and protected by a lease |
| `retrying` | Failed attempt released for retry after a delay |
| `completed` | Terminal success |
| `failed` | Terminal failure |

Allowed transitions:

| From | To | Trigger |
|---|---|---|
| none | `pending` | Enqueue immediate task due now |
| none | `scheduled` | Enqueue delayed or recurring task in the future |
| `scheduled` | `pending` | `promote_scheduled_tasks()` when due |
| `pending` or `retrying` | `processing` | `dequeue_task()` atomic claim |
| `processing` | `completed` | `complete_task()` by owning worker |
| `processing` | `retrying` | `fail_task()` when attempts remain |
| `processing` | `failed` | `fail_task()` when attempts exhausted or retry disabled |
| `processing` | `pending` | `reset_stuck_tasks()` after lease expiry |
| `pending`, `retrying`, or `scheduled` | `failed` | dependency auto-fail |

Never allow arbitrary status updates from application code.

### 5.2 Task Type

Required task types:

| Type | Meaning |
|---|---|
| `immediate` | Normal task that should be runnable as soon as possible |
| `delayed` | One-time task scheduled for later |
| `recurring` | Task that schedules a future clone when completed |
| `periodic` | Reserved for periodic scheduler use |

### 5.3 Audit Operation

At minimum, audit these operations:

| Operation | Example trigger |
|---|---|
| `enqueue` | Task created |
| `dequeue` | Task claimed |
| `heartbeat` | Task lease extended |
| `complete` | Task completed |
| `fail` | Task failed or retried |
| `reset` | Scheduled task promoted or stuck task reset |
| `cleanup` | Old completed or failed tasks deleted |
| `worker_register` | Worker created, reactivated, or materially reconfigured |
| `worker_heartbeat` | Worker process heartbeat |
| `worker_meta_patch` | Worker metadata changed |
| `task_meta_patch` | Task metadata changed |
| `meta_cleanup` | Metadata history cleaned |
| `worker_meta_delete` | Worker metadata deleted |
| `task_meta_delete` | Task metadata deleted |

---

## 6. Required Tables

### 6.1 `worker_api_keys`

Stores authentication material for workers.

Required columns:

| Column | Required behavior |
|---|---|
| `worker_id` | Unique logical worker identity |
| `api_key_hash` | SHA-256 or stronger hash of the API key |
| `api_key_prefix` | Short non-secret display prefix, for diagnostics only |
| `is_active` | Inactive keys must be rejected |
| `expires_at` | Expired keys must be rejected |
| `last_used_at` | Updated on successful authentication |
| `permissions` | JSON permission map for future fine-grained controls |

API keys should be generated as high-entropy random values. The reference implementation uses `sk_` plus 32 random bytes encoded as hex.

### 6.2 `rate_limits`

Tracks request counts by `(identifier, operation, window_start)`.

Use it to enforce per-worker limits on enqueue, dequeue, complete, fail, heartbeat, metadata, dependency, and runtime variable operations.

### 6.3 `audit_log`

Append-only security and lifecycle history.

Required fields:

| Field | Purpose |
|---|---|
| `operation` | Enum or constrained operation name |
| `entity_type` | `task`, `worker`, `queue`, `runtime_variable`, etc. |
| `entity_id` | Numeric entity ID where available |
| `actor_id` | Worker ID, `system`, or admin identity |
| `old_values` | JSON snapshot or sparse old state |
| `new_values` | JSON snapshot or sparse new state |
| `success` | Whether the operation succeeded |
| `error_message` | Failure reason |
| `created_at` | Audit timestamp |

### 6.4 `queue_registry`

Registry of named queues.

Required behavior:

- Queue names must match `^[a-z0-9_-]+$`.
- Queues can be active or inactive.
- Enqueue and worker subscription updates must reject missing or inactive queues.
- Default queues should include at least `default`, `maintenance`, and any domain queues required by the application.

### 6.5 `task_queue`

Primary task table.

Required column groups:

| Group | Columns |
|---|---|
| Identity | `id`, `task_uuid` |
| Metadata | `task_name`, `task_type`, `queue_name` |
| Payload | `task_data`, `task_metadata` |
| Scheduling | `status`, `priority`, `scheduled_at` |
| Worker assignment | `worker_id`, `started_at`, `completed_at` |
| Retry | `attempts`, `max_attempts`, `last_error`, `error_count` |
| Lease | `lease_expires_at`, `last_heartbeat_at` |
| Recurrence | `recurrence_pattern`, `recurrence_time`, `recurrence_timezone`, `next_run_at` |
| Audit | `created_by`, `created_at`, `updated_at` |

Required constraints:

- `priority` range: `0` to `100`.
- `max_attempts` range: `1` to `10`.
- `attempts` cannot be negative.
- `task_name` cannot be blank and must fit within 255 characters.
- `task_data` must not exceed configured maximum size. Reference default: 100 KB.
- `scheduled_at` cannot be more than one year in the future.
- `recurrence_pattern`, if present, must be one of `hourly`, `daily`, `weekly`, `monthly`.
- `recurrence_time` and `recurrence_timezone` must be both null or both provided.
- `hourly` recurrence must not use `recurrence_time` or `recurrence_timezone`.
- `queue_name` must reference an active queue when enqueued.

### 6.6 `worker_registry`

Stores worker identity, queue subscriptions, capacity, heartbeat, and counters.

Required columns:

| Column | Required behavior |
|---|---|
| `worker_id` | Unique logical worker identity |
| `worker_name` | Human-readable name |
| `subscribed_queues` | JSON array or normalized relation of queue names |
| `max_concurrent_tasks` | Positive, capped at 50 in the reference |
| `current_load` | Non-negative current processing count |
| `last_seen_at` | Updated by worker heartbeat |
| `is_active` | Inactive workers cannot dequeue |
| `heartbeat_interval` | Expected heartbeat cadence |
| `expected_next_heartbeat` | Used to mark workers stale |
| `tasks_completed`, `tasks_failed` | Counters updated on terminal outcomes |
| `total_processing_time` | Aggregate processing duration |

### 6.7 `scheduler_config`

Key-value configuration for operational defaults.

Recommended keys:

| Key | Reference default |
|---|---|
| `default_lease_duration` | `5 minutes` |
| `max_retry_delay` | `1 hour` |
| `cleanup_retention` | `30 days` |
| `worker_timeout` | `10 minutes` |
| `max_concurrent_tasks_per_worker` | `10` |
| `rate_limit_enqueue` | `1000` |
| `rate_limit_dequeue` | `1000` |
| `max_task_data_size_kb` | `100` |
| `enable_queue_isolation` | `true` |
| `metadata_retention_days` | `90` |
| `metadata_max_size_kb` | `100` |
| `metadata_default_merge` | `deep` |
| `metadata_history_enabled` | `true` |

### 6.8 `worker_metadata`

Stores arbitrary JSON object metadata per worker.

Required behavior:

- One row per worker.
- `metadata` must be a JSON object.
- `version` increments on every patch.
- Worker deletion cascades metadata deletion.
- Reserved metadata keys are rejected.

### 6.9 `task_metadata_history`

Stores task metadata patch history.

Required behavior:

- Each row references a task.
- Store `worker_id`, `patch`, `metadata_after`, and timestamp.
- `patch` and `metadata_after` must be JSON objects.
- Cleanup must run in batches and reject retention below seven days.

### 6.10 `task_dependencies`

Stores prerequisite relationships.

Required behavior:

- Composite primary key on `(task_id, prerequisite_task_id)`.
- Both columns reference `task_queue(id)` with delete cascade.
- Self-dependencies are forbidden.
- Cycles are forbidden.
- Duplicate dependency insertions must be idempotent.

### 6.11 `runtime_variables`

Stores scoped values used by workers at runtime.

Required fields:

| Column | Required behavior |
|---|---|
| `variable_scope` | Scope name, pattern `^[a-z0-9_-]+$` |
| `variable_key` | Key name, pattern `^[a-zA-Z0-9_.:-]+$` |
| `variable_value` | JSONB value, encrypted envelope when secret |
| `description` | Optional human description |
| `is_secret` | Enables encryption at rest |
| `expires_at` | Expired rows ignored unless explicitly included |
| `created_by` | Active worker ID, cascade delete when worker is deleted |

If runtime variable APIs are exposed outside a trusted backend, authenticate with API keys rather than bare worker IDs.

---

## 7. Required Stored API Surface

The names below reflect the PostgreSQL reference. Other implementations may expose equivalent service methods, but behavior must match.

### 7.1 Security Helpers

| API | Required behavior |
|---|---|
| `validate_worker_auth(p_api_key)` | Hash the key, find active non-expired key, update `last_used_at`, return worker ID, reject invalid keys |
| `check_rate_limit(identifier, operation, max_requests, window_minutes)` | Increment counter and reject requests over limit |
| `validate_task_data_size(json, max_size_kb)` | Reject oversized task/result/metadata payloads |
| `log_audit(...)` | Append an audit record |
| `calculate_next_run(pattern, base_time, recurrence_time, recurrence_timezone)` | Return next run timestamp, preserving local wall-clock time when time/timezone are supplied |

### 7.2 Queue APIs

| API | Required behavior |
|---|---|
| `create_queue(queue_name, description)` | Validate and create a queue idempotently |
| `get_queue_stats_by_queue()` | Return total, pending, processing, completed in 24h, failed in 24h, average completion time per queue |
| `get_queue_stats()` | Return global queue counts and oldest pending timestamp |

### 7.3 Task APIs

| API | Required behavior |
|---|---|
| `enqueue_task(api_key, task_name, task_data, task_type, priority, scheduled_at, max_attempts, recurrence_pattern, queue_name, recurrence_time, recurrence_timezone)` | Auth, rate limit, validate, insert pending or scheduled task, audit, return UUID |
| `dequeue_task(api_key, lease_duration, queue_names)` | Auth, rate limit, validate lease, enforce queue intersection, enforce capacity, skip dependency-blocked tasks, atomically claim highest priority due task |
| `heartbeat_task(api_key, task_id, extend_by)` | Owning worker extends task lease and updates heartbeat timestamp |
| `complete_task(api_key, task_id, result_data)` | Owning worker completes task, writes result metadata, decrements load, increments counters, creates next recurring task when needed |
| `fail_task(api_key, task_id, error_message, retry_delay)` | Owning worker retries or terminally fails task based on attempts |
| `fail_task(api_key, task_id, error_message, retry, retry_delay)` | Boolean overload or equivalent for explicit retry disable |
| `promote_scheduled_tasks()` | Move due scheduled tasks to pending |
| `reset_stuck_tasks()` | Move expired processing tasks back to pending and mark stale workers inactive |
| `cleanup_old_tasks(older_than, batch_size)` | Delete old completed/failed tasks in guarded batches |
| `get_task_status(api_key, task_id)` | Authenticated task status lookup |
| `get_task_ancestors_descendants(task_uuid)` | Traverse lineage through `task_data.meta.parent_task_uuid`, terminate safely on cycles |

### 7.4 Worker APIs

| API | Required behavior |
|---|---|
| `register_worker(worker_id, worker_name, max_concurrent_tasks, heartbeat_interval, subscribed_queues)` | Validate worker and queues, issue new API key, create/reactivate worker, audit material changes |
| `update_worker_subscriptions(api_key, subscribed_queues)` | Auth, validate queues, update subscriptions |
| `worker_heartbeat(api_key, current_load, heartbeat_interval)` | Auth, update worker liveness and expected next heartbeat |
| `get_worker_stats(worker_id)` | Return worker load, capacity, subscriptions, counters, availability, last-seen age |

### 7.5 Metadata APIs

| API | Required behavior |
|---|---|
| `jsonb_deep_merge(base, patch)` | Recursively merge JSON objects |
| `validate_metadata_keys(metadata)` | Reject `_system`, `_internal`, `_reserved`, and any key starting with `_` |
| `patch_worker_metadata(api_key, patch, use_deep_merge, audit)` | Auth, rate limit, validate object/keys/size, merge, increment version, optional audit |
| `delete_worker_metadata(api_key)` | Auth, delete metadata row, audit, return whether row existed |
| `get_worker_metadata(api_key)` | Auth, return metadata or `{}` |
| `get_worker_metadata_profile(api_key)` | Return worker registry, config, and metadata as one JSON profile |
| `get_all_workers_metadata(active_only)` | Monitoring/admin query for worker metadata |
| `patch_task_metadata(api_key, task_id, patch, log_history, use_deep_merge)` | Auth, require owned processing task with unexpired lease, merge, optional history, audit |
| `delete_task_metadata(api_key, task_id, log_history)` | Auth, require owned processing task with unexpired lease, clear metadata, optional history, audit |
| `get_task_metadata(api_key, task_id)` | Auth, require ownership, return metadata |
| `get_task_metadata_history(api_key, task_id, limit)` | Auth, return recent metadata history |
| `cleanup_task_metadata_history(older_than, batch_size)` | Guarded batch cleanup |

### 7.6 Dependency APIs

| API | Required behavior |
|---|---|
| `task_dependency_creates_cycle(task_id, prerequisite_task_id)` | Recursive cycle check |
| `auto_fail_dependent_tasks(prerequisite_task_id, reason)` | Fail pending/retrying/scheduled dependent tasks |
| `add_task_dependency(api_key, task_uuid, prerequisite_task_uuid)` | Auth, validate tasks, reject self/cycle, insert idempotently, auto-fail if prerequisite already failed |
| `add_task_dependencies(api_key, task_uuid, prerequisite_task_uuids)` | Batch version with de-duplication and missing-prerequisite reporting |
| `remove_task_dependency(api_key, task_uuid, prerequisite_task_uuid)` | Auth, delete dependency, return whether deleted |
| `get_task_dependencies(api_key, task_uuid)` | Auth, list prerequisites and statuses |
| failed-task trigger | On task status change to `failed`, auto-fail dependents and audit |

### 7.7 Runtime Variable APIs

| API | Required behavior |
|---|---|
| `runtime_vars_encrypt_jsonb(value)` | Encrypt JSON value using configured key, return envelope with algorithm, key ID, ciphertext |
| `runtime_vars_decrypt_jsonb(stored, is_secret)` | Decrypt encrypted envelope, return plaintext JSON; support legacy plain secret rows |
| `validate_runtime_worker_id(worker_id)` | Ensure worker ID is non-empty, active, and registered |
| `set_runtime_variable(worker_id, key, value, scope, description, is_secret, expires_at)` | Validate worker/scope/key/expiry, encrypt secrets, upsert, return decrypted value |
| `get_runtime_variable(worker_id, key, scope, fallback_to_global, include_expired)` | Validate worker, read non-expired scoped value, optionally fallback to global, decrypt secret |
| `delete_runtime_variable(worker_id, key, scope)` | Validate worker, delete row, return whether deleted |

---

## 8. Task Lifecycle Requirements

### 8.1 Enqueue

Enqueue must:

- Authenticate the caller.
- Apply enqueue rate limit.
- Validate queue existence and activity.
- Validate task name, priority, max attempts, schedule horizon, recurrence, and payload size.
- Calculate `scheduled_at` and `next_run_at`.
- Insert with `pending` if due now, otherwise `scheduled`.
- Set `created_by` to authenticated worker ID.
- Audit the operation.
- Return a durable task UUID.

### 8.2 Promotion

Scheduled tasks are not claimable until promoted or directly treated as due by the claim query. The reference uses `promote_scheduled_tasks()`:

- Find `status = 'scheduled' AND scheduled_at <= NOW()`.
- Set status to `pending`.
- Clear worker and lease fields.
- Audit promoted count.

### 8.3 Dequeue

Dequeue must:

- Authenticate the worker.
- Apply dequeue rate limit.
- Reject lease durations greater than one hour.
- Load worker subscriptions.
- Intersect worker subscriptions with requested queues.
- Reject if intersection is empty.
- Enforce active worker and available capacity.
- Select only due tasks in `pending` or `retrying`.
- Skip tasks that have incomplete prerequisites.
- Prefer higher priority, then older scheduled time, then fewer attempts.
- Lock atomically to prevent duplicate claims.
- Move selected task to `processing`.
- Set `worker_id`, `started_at`, `lease_expires_at`.
- Increment `attempts` and worker `current_load`.
- Audit the claim.
- Return task ID, UUID, name, payload, attempts, max attempts, and queue.

### 8.4 Heartbeat

Task heartbeat must:

- Authenticate worker.
- Rate limit heartbeat calls.
- Reject extensions greater than one hour.
- Require the task to be `processing`.
- Require the authenticated worker to own the task.
- Only update if the current lease has not expired.
- Set `last_heartbeat_at` and extend `lease_expires_at`.

Worker heartbeat must update `last_seen_at`, `expected_next_heartbeat`, optional `current_load`, and `updated_at`.

### 8.5 Complete

Completion must:

- Authenticate worker.
- Rate limit completion calls.
- Validate result payload size.
- Require the task to be `processing`.
- Require the authenticated worker to own the task.
- For recurring tasks, insert a new future scheduled task preserving recurrence and queue fields.
- Set current task to `completed`.
- Store result data in `task_metadata` or another documented result field.
- Clear lease.
- Decrement worker load.
- Increment completed counter and total processing time.
- Audit the transition.

### 8.6 Fail and Retry

Failure must:

- Authenticate worker.
- Rate limit failure calls.
- Require the task to be `processing`.
- Require the authenticated worker to own the task.
- Truncate very long errors. Reference cap: 10,000 characters.
- If attempts remain and retry is enabled:
  - set status to `retrying`
  - set `scheduled_at = NOW() + retry_delay`
  - clear `worker_id`
  - clear lease
  - decrement worker load
- If attempts are exhausted or retry disabled:
  - set status to `failed`
  - preserve/raise attempts to max as appropriate
  - clear lease
  - decrement worker load
  - increment failed counter
- Audit error and attempts.

### 8.7 Stuck Task Reset

Stuck reset must:

- Find `processing` tasks with `lease_expires_at < NOW()`.
- Move them to `pending`.
- Clear worker and lease.
- Append a reset reason to `last_error`.
- Mark workers inactive when `expected_next_heartbeat < NOW()`.
- Reset inactive worker `current_load` to zero.
- Audit reset counts.

### 8.8 Cleanup

Task cleanup must:

- Delete only terminal `completed` or `failed` tasks.
- Enforce minimum retention of seven days.
- Enforce maximum batch size. Reference max: 10,000.
- Delete in batches and optionally sleep briefly between batches.
- Audit deleted count.

---

## 9. Recurrence Rules

Supported recurrence patterns:

- `hourly`
- `daily`
- `weekly`
- `monthly`

When no local time is supplied:

- Hourly: next whole hour.
- Daily: next day boundary.
- Weekly: next week boundary.
- Monthly: next month boundary.

When `recurrence_time` and `recurrence_timezone` are supplied:

- Both fields are required together.
- Timezone must be a valid database/application timezone.
- `hourly` must reject local time recurrence.
- Daily, weekly, and monthly recurrence must preserve the requested local wall-clock time across DST changes.
- Completion of a recurring task must clone the task for the next run and keep the same queue.

---

## 10. Dependency Rules

Dependencies are task-to-task prerequisites.

Implementation requirements:

- Dependencies are addressed externally by task UUID.
- Internally, store relationships by stable task IDs.
- Reject missing target or missing prerequisite tasks.
- Reject self-dependency.
- Reject cycles using recursive traversal or graph logic.
- Batch add must de-duplicate input UUIDs.
- Batch add must report missing prerequisites before partial insertion where possible.
- `dequeue_task()` must skip any task where at least one prerequisite is not `completed`.
- If a prerequisite is already failed when a dependency is added, immediately fail the dependent task.
- If a prerequisite later transitions to `failed`, fail all pending, retrying, or scheduled dependents.
- Auto-fail should set a dependency-specific `last_error` reason and increment `error_count`.

---

## 11. Metadata Rules

### 11.1 JSON Merge

Metadata patches must support:

- Deep merge: recursively merge nested objects.
- Shallow merge: top-level override.

Default to deep merge unless a caller explicitly asks for shallow merge.

### 11.2 Key Validation

Reject metadata keys:

- `_system`
- `_internal`
- `_reserved`
- Any key starting with `_`

This reserves underscore-prefixed keys for scheduler internals.

### 11.3 Worker Metadata

Worker metadata:

- Belongs to the authenticated worker.
- Must be JSON object patches.
- Must enforce size limits.
- Must increment version on patch.
- Should allow audit suppression for high-frequency checkpoint updates.
- Delete should return `false` if no row existed and `true` if deleted.
- Get should return `{}` if absent.

### 11.4 Task Metadata

Task metadata:

- Can only be patched or deleted by the task owner.
- Requires task status `processing`.
- Requires `lease_expires_at > NOW()`.
- Must optionally write `task_metadata_history`.
- Must audit both successful and rejected writes where practical.
- Get requires task ownership.

---

## 12. Runtime Variable Rules

Runtime variables provide scoped JSON values for workers.

Required behavior:

- Scopes are names such as `global`, `tenant_acme`, or worker-specific scopes.
- Keys support letters, digits, underscore, dot, colon, and hyphen.
- Non-secret values are stored as plain JSON.
- Secret values are stored as encrypted envelopes.
- Reads ignore expired rows unless `include_expired = true`.
- Reads can optionally fall back from a specific scope to `global`.
- Upserting a key can transition non-secret to secret and secret to non-secret.
- Secret writes require an encryption key.
- Encrypted secret reads require the matching decryption key.
- Wrong key reads must fail without leaking plaintext.
- Legacy plain secret rows can be read for backwards compatibility.
- Deleting a worker should cascade delete runtime variables created by that worker.

Reference encryption settings:

- `app.runtime_vars_key`: required key material for secret encrypt/decrypt.
- `app.runtime_vars_key_id`: optional key ID stored in the envelope.
- Envelope key: `_enc_v1`.
- Algorithm label: `pgp_sym_encrypt`.
- Cipher: AES-256 equivalent.

---

## 13. Security Requirements

### 13.1 Authentication

All public worker APIs should authenticate with API keys except APIs intentionally restricted to trusted internal contexts.

API key validation must reject:

- Unknown key.
- Inactive key.
- Expired key.
- Empty or malformed key.

Successful validation should update `last_used_at`.

### 13.2 Authorization

Enforce authorization at every state transition:

- Queue authorization through subscription intersection.
- Task ownership for heartbeat, complete, fail, and task metadata writes.
- Active worker requirement for dequeue and runtime variable operations.
- Lease validity for metadata writes.

### 13.3 Rate Limits

Reference limits:

| Operation | Limit |
|---|---|
| `enqueue` | 1,000 per 60 minutes |
| `dequeue` | 1,000 per 60 minutes |
| `heartbeat` | 10,000 per 60 minutes |
| `complete` | 10,000 per 60 minutes |
| `fail` | 10,000 per 60 minutes |
| metadata operations | 10,000 per 60 minutes |
| runtime variable get | 20,000 per 60 minutes |
| runtime variable set/delete | 10,000 per 60 minutes |
| dependency operations | 10,000 per 60 minutes |
| status lookup | 10,000 per 60 minutes |

The implementation may make limits configurable, but must have sane defaults.

### 13.4 Input Validation

Validate at least:

- Queue names.
- Worker IDs and worker capacity.
- Task names.
- Task payload and result size.
- Priority range.
- Attempts range.
- Schedule horizon.
- Recurrence pattern/time/timezone.
- Metadata keys and JSON object shape.
- Runtime variable scope/key/expiry.
- Lease duration and heartbeat extension.

### 13.5 Audit

Audit rows should never contain raw secrets. When auditing secret operations, record metadata such as key, scope, actor, success, and error category, not plaintext values.

### 13.6 Privilege Boundary

For PostgreSQL:

- Implement public APIs as `SECURITY DEFINER` functions where direct table privileges are restricted.
- Workers should receive execute rights on functions, not broad update rights on scheduler tables.
- Search path should be controlled in production deployments.

For service-layer implementations:

- Keep table/repository writes private to the scheduler service.
- Expose only typed methods equivalent to the stored API surface.

---

## 14. Performance and Indexing

Required indexes or equivalent access paths:

| Object | Access path |
|---|---|
| `task_queue` | `(status, scheduled_at)` for scheduled/pending promotion |
| `task_queue` | `(queue_name, status, priority DESC, scheduled_at ASC)` for dequeue |
| `task_queue` | `(priority DESC, scheduled_at ASC)` for pending ordering |
| `task_queue` | `(worker_id, lease_expires_at)` for processing leases |
| `task_queue` | `(status, next_run_at)` for retry/recurrence inspection |
| `task_queue` | expression on `task_data.meta.parent_task_uuid` for lineage |
| `worker_registry` | active workers by `last_seen_at` |
| `rate_limits` | `(identifier, operation, window_start)` |
| `audit_log` | created time, actor/time, entity/entity ID |
| `task_dependencies` | prerequisite task ID |
| `worker_metadata` | updated time, version, JSON GIN/equivalent |
| `task_metadata_history` | task/time and created time |
| `runtime_variables` | `(variable_scope, variable_key)`, expiry, created_by |

Atomic dequeue must remain efficient under multiple workers polling the same queue.

---

## 15. Monitoring Views and Queries

Provide views or APIs equivalent to:

| View/API | Purpose |
|---|---|
| `ready_queue` | Due pending/retrying tasks ordered by priority |
| `processing_tasks` | Active processing tasks with lease time remaining |
| `queue_worker_subscriptions` | Worker-to-queue subscription mapping |
| `metadata_stats` | Metadata volume and size statistics |
| `get_queue_stats()` | Global task counts |
| `get_queue_stats_by_queue()` | Per-queue task counts |
| `get_worker_stats()` | Worker load and health |
| `get_task_status()` | Task detail lookup |
| `get_task_ancestors_descendants()` | Lineage traversal |

---

## 16. Error Handling Contract

Errors should be explicit and stable enough for tests and worker clients to understand.

Required rejection cases:

- Invalid or expired API key.
- Worker inactive or not registered.
- Worker not subscribed to requested queue.
- Lease duration or extension over one hour.
- Task not found or not in required status.
- Worker does not own task.
- Lease expired.
- Queue missing or inactive.
- Priority outside `0..100`.
- Max attempts outside `1..10`.
- Schedule more than one year in the future.
- Invalid recurrence pattern/time/timezone combination.
- Payload or metadata over size limit.
- Reserved metadata key.
- Cleanup retention under seven days.
- Dependency self-reference or cycle.
- Secret runtime variable write/read without key.
- Secret runtime variable read with wrong key.

When returning no work from `dequeue_task()`, do not raise an error. Return an empty result.

---

## 17. Required Test Coverage

An implementation guide for an AI coding tool should generate tests for every item below.

### 17.1 Core Scheduler Tests

- Install prerequisites and required tables/functions.
- Create queues.
- Register workers and issue non-plaintext API keys.
- Reject invalid, inactive, and expired API keys.
- Update worker subscriptions.
- Reject dequeue from unsubscribed queues.
- Reject leases over one hour.
- Enqueue immediate, delayed, retrying, and recurring tasks.
- Reject invalid queue, priority, max attempts, recurrence pair, and timezone.
- Promote due scheduled tasks.
- Dequeue tasks by priority and schedule order.
- Verify concurrent workers do not claim the same task.
- Heartbeat extends a lease.
- Complete task transitions to `completed`.
- Complete recurring task creates next scheduled task and preserves queue and local time metadata.
- Fail task transitions to `retrying` when attempts remain.
- Fail task transitions to `failed` when max attempts reached or retry disabled.
- Reset stuck tasks and stale workers.
- Cleanup old completed/failed tasks and reject retention below seven days.
- Validate monitoring stats and views.
- Traverse parent/child lineage and terminate on cycles.

### 17.2 Metadata Tests

- Deep merge nested JSON.
- Shallow merge top-level JSON.
- Reject reserved metadata keys.
- Patch/get/delete worker metadata.
- Version increments on worker metadata patches.
- Patch/get/delete task metadata.
- Reject wrong-worker task metadata access.
- Reject task metadata updates after lease expiry.
- Reject task metadata updates for completed tasks.
- Write and read metadata history.
- Cleanup metadata history with retention and batch guards.
- Exercise repeated patch/get performance.

### 17.3 Dependency Tests

- Add single dependency.
- Ensure dependent task is blocked until prerequisite completes.
- Add multiple prerequisites.
- Remove dependency idempotently.
- Reject self dependency.
- Reject dependency cycle.
- Auto-fail dependent when prerequisite fails.
- Auto-fail dependent when dependency is added to an already failed prerequisite.
- Reject dependency operations with invalid auth.

### 17.4 Runtime Variable Tests

- Set/get non-secret JSON values.
- Store non-secret raw JSON.
- Set/get encrypted secret values.
- Verify raw storage does not contain plaintext secret.
- Reject secret write without encryption key.
- Reject encrypted secret read without key.
- Reject encrypted secret read with wrong key.
- Read legacy plain secret rows.
- Fallback from scoped value to global.
- Transition non-secret to secret.
- Transition secret to non-secret.
- Ignore expired values by default and return them with `include_expired`.
- Delete variables.
- Reject invalid or inactive worker IDs.
- Verify worker deletion cascades runtime variables.

---

## 18. AI Coding Tool Implementation Instructions

When using this file to generate or refactor a scheduler:

1. Start by creating the domain states, task table, worker table, queue registry, API key table, rate limit table, and audit table.
2. Implement authentication and rate limiting before task state transitions.
3. Implement enqueue, dequeue, heartbeat, complete, fail, promotion, reset, and cleanup in that order.
4. Add queue subscription enforcement to dequeue before testing concurrency.
5. Add dependency gating to dequeue before declaring dequeue complete.
6. Add metadata APIs only after task ownership and lease rules are stable.
7. Add runtime variables and encryption after worker identity is stable.
8. Add monitoring views and stats after base writes work.
9. Write integration tests around the public APIs, not direct table writes.
10. Do not bypass the API functions in workers or handlers.

For PostgreSQL code generation:

- Prefer idempotent DDL for migrations.
- Use `CREATE EXTENSION IF NOT EXISTS "uuid-ossp"` or native UUID generation.
- Use `pgcrypto` or an equivalent cryptographic library.
- Use `TIMESTAMPTZ` for all absolute timestamps.
- Use `JSONB` for payloads and metadata.
- Use `SECURITY DEFINER` with controlled privileges for public functions.
- Use `FOR UPDATE SKIP LOCKED` for dequeue.
- Add indexes before load testing.

For application-service code generation:

- Wrap scheduler state transitions in database transactions.
- Implement atomic claim with row locking, compare-and-swap, or database-specific advisory locks.
- Hash API keys before lookup.
- Keep raw API keys only in memory long enough to return them at registration.
- Keep the scheduler write model private to the service.
- Emit audit events from the same transaction as state changes when possible.

---

## 19. Common Anti-Patterns

Do not implement any of these:

- Direct worker updates to `task_queue.status`.
- Plaintext API key storage.
- Dequeue without a transaction or lock.
- Queue filtering without checking worker subscriptions.
- Task completion without ownership check.
- Metadata patching without lease validation.
- Recurring task clone that loses queue or timezone fields.
- Retrying a task without clearing `worker_id` and lease.
- Cleanup without minimum retention guard.
- Secret runtime variables stored as plain JSON after `is_secret = true`.
- Dependency graph without cycle detection.
- Monitoring code that requires table writes.

---

## 20. Minimum Acceptance Checklist

A scheduler built from this specification is ready for worker integration when all of these are true:

- Workers can register and receive one-time visible API keys.
- Invalid, inactive, and expired keys are rejected.
- Queues can be created and workers can subscribe to them.
- Tasks can be enqueued into active queues.
- Concurrent workers can dequeue from the same queue without duplicate claims.
- Workers cannot dequeue outside their subscriptions.
- Leases are set, heartbeated, and expired correctly.
- Completion, retry, terminal failure, and recurring reschedule all work.
- Stuck tasks are recoverable.
- Dependency-blocked tasks wait and auto-fail correctly.
- Worker metadata and task metadata support deep merge and history.
- Runtime variables support scoped reads, fallback, expiry, and encrypted secrets.
- Cleanup functions are guarded and batched.
- Monitoring views/API calls return useful state.
- Tests cover the core, metadata, dependency, and runtime variable suites listed above.

