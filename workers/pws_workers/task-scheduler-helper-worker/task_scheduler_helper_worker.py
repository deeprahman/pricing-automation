#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

CURRENT_DIR = Path(__file__).resolve().parent
WORKERS_ROOT = Path(__file__).resolve().parents[2]
REPO_ROOT = Path(__file__).resolve().parents[3]
for candidate in (WORKERS_ROOT, REPO_ROOT):
    if str(candidate) not in sys.path:
        sys.path.insert(0, str(candidate))

from pws_workers.shared.worker_runtime import (
    SchedulerClient,
    StepLog,
    WorkerContext,
    WorkerRunner,
    DEFAULT_WORKER_LOG_DIR,
    add_common_worker_args,
    build_dsn,
    connect,
    configure_worker_logger,
)
from pws_workers.shared.runtime import (
    parse_runtime_variable_ttl_config,
    resolve_runtime_variable_ttl,
    set_runtime_variable,
)


WORKER = "task-scheduler-helper"
DEFAULT_HELPER_QUEUE = "task-scheduler-helper"
DEFAULT_HELPER_ACTION = "tsh_action"
DEFAULT_LOG_DIR = DEFAULT_WORKER_LOG_DIR
TERMINAL_TASK_STATUSES = {"completed", "failed"}
ALLOWED_RECURRENCE_PATTERNS = {"hourly", "daily", "weekly", "monthly"}
DEFAULT_SEED_TTL_MINUTES = 15

TSH_IN_DIR = CURRENT_DIR / "tsh_in"
TSH_OUT_DIR = CURRENT_DIR / "tsh_out"
ENQUEUE_FILE = TSH_IN_DIR / "enqueue_task.json"
ENQUEUED_FILE = TSH_IN_DIR / "enqueued_task.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Task scheduler helper worker")
    parser.add_argument("--dsn", default=None, help="Postgres DSN")
    parser.add_argument(
        "--auto-dsn",
        dest="auto_dsn",
        action="store_true",
        default=True,
        help="Build DSN from .env/env vars (default: on)",
    )
    parser.add_argument(
        "--no-auto-dsn",
        dest="auto_dsn",
        action="store_false",
        help="Disable auto DSN generation",
    )
    parser.add_argument(
        "--db-name",
        default="auto_pws",
        help="DB name override when auto-building DSN (default: auto_pws)",
    )
    parser.add_argument(
        "--helper-queue",
        default=DEFAULT_HELPER_QUEUE,
        help=f"Queue to poll for helper callbacks (default: {DEFAULT_HELPER_QUEUE})",
    )
    parser.add_argument(
        "--helper-action",
        default=DEFAULT_HELPER_ACTION,
        help=f"Action to handle and dump to tsh_out (default: {DEFAULT_HELPER_ACTION})",
    )
    parser.add_argument(
        "--log-dir",
        default=str(DEFAULT_LOG_DIR),
        help=f"Directory for helper logs when stderr is attached to a terminal (default: {DEFAULT_LOG_DIR})",
    )
    parser.add_argument("--poll-interval", type=float, default=1.0, help="Seconds between polls")
    parser.add_argument("--once", action="store_true", help="Run one enqueue/dequeue cycle and exit")
    add_common_worker_args(parser)
    return parser.parse_args()


def _as_optional_string(value: Any) -> Optional[str]:
    if value is None:
        return None
    if isinstance(value, str):
        value = value.strip()
        return value or None
    return str(value)


def _as_optional_int(value: Any) -> Optional[int]:
    if value is None or value == "":
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig") if path.exists() else ""


def _strip_json_line_comments(raw: str) -> str:
    out: List[str] = []
    in_string = False
    escape = False
    i = 0
    while i < len(raw):
        ch = raw[i]
        if in_string:
            out.append(ch)
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            i += 1
            continue

        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue

        if ch == "/" and i + 1 < len(raw) and raw[i + 1] == "/":
            i += 2
            while i < len(raw) and raw[i] not in "\r\n":
                i += 1
            continue

        out.append(ch)
        i += 1
    return "".join(out)


def _load_json_list(path: Path) -> List[Any]:
    raw = _read_text(path).strip()
    if not raw:
        return []
    cleaned = _strip_json_line_comments(raw)
    data = json.loads(cleaned)
    if not isinstance(data, list):
        raise ValueError(f"{path} must contain a JSON array")
    return data


def _write_json(path: Path, payload: Any) -> None:
    path.write_text(json.dumps(payload, indent=2, default=str) + "\n", encoding="utf-8")


def ensure_runtime_paths() -> None:
    TSH_IN_DIR.mkdir(parents=True, exist_ok=True)
    TSH_OUT_DIR.mkdir(parents=True, exist_ok=True)
    if not ENQUEUE_FILE.exists():
        _write_json(ENQUEUE_FILE, [])
    if not ENQUEUED_FILE.exists():
        _write_json(ENQUEUED_FILE, [])


def _normalize_return_handler(raw: Any, helper_queue: str, helper_action: str) -> Dict[str, str]:
    return_handler = raw if isinstance(raw, dict) else {}
    return {
        "worker": _as_optional_string(return_handler.get("worker")) or WORKER,
        "queue": _as_optional_string(return_handler.get("queue")) or helper_queue,
        "action": _as_optional_string(return_handler.get("action")) or helper_action,
    }


def _normalize_schedule(raw: Any) -> Optional[Dict[str, Any]]:
    if raw is None:
        return None
    if not isinstance(raw, dict):
        raise ValueError("schedule must be an object")

    recurrence_pattern = _as_optional_string(raw.get("recurrence_pattern"))
    if recurrence_pattern is not None:
        recurrence_pattern = recurrence_pattern.lower()
        if recurrence_pattern not in ALLOWED_RECURRENCE_PATTERNS:
            allowed = ", ".join(sorted(ALLOWED_RECURRENCE_PATTERNS))
            raise ValueError(f"schedule.recurrence_pattern must be one of: {allowed}")

    scheduled_at = _as_optional_string(raw.get("scheduled_at"))

    priority = _as_optional_int(raw.get("priority"))
    if priority is None:
        priority = 0
    if priority < 0 or priority > 100:
        raise ValueError("schedule.priority must be between 0 and 100")

    max_attempts = _as_optional_int(raw.get("max_attempts"))
    if max_attempts is None:
        max_attempts = 3
    if max_attempts < 1 or max_attempts > 10:
        raise ValueError("schedule.max_attempts must be between 1 and 10")

    task_type = "recurring" if recurrence_pattern else "immediate"
    return {
        "recurrence_pattern": recurrence_pattern,
        "scheduled_at": scheduled_at,
        "priority": priority,
        "max_attempts": max_attempts,
        "task_type": task_type,
    }


def _normalize_enqueue_record(raw: Any, helper_queue: str, helper_action: str) -> Dict[str, Any]:
    if not isinstance(raw, dict):
        raise ValueError("Each enqueue entry must be an object")

    queue_name = _as_optional_string(raw.get("queue"))
    if not queue_name:
        raise ValueError("queue is required")

    payload = raw.get("payload")
    if payload is None:
        payload = {}
    if not isinstance(payload, dict):
        raise ValueError("payload must be an object")

    action = _as_optional_string(raw.get("action")) or _as_optional_string(payload.get("action"))
    if not action:
        raise ValueError("action is required")

    worker = _as_optional_string(raw.get("worker")) or action
    return_handler = _normalize_return_handler(raw.get("return_handler"), helper_queue, helper_action)
    schedule = _normalize_schedule(raw.get("schedule"))

    merged_payload = dict(payload)
    merged_payload["action"] = action
    merged_payload["return_handler"] = return_handler
    merged_payload["return_handler_worker"] = return_handler["worker"]
    merged_payload["return_handler_queue"] = return_handler["queue"]
    merged_payload["return_handler_action"] = return_handler["action"]

    return {
        "worker": worker,
        "queue": queue_name,
        "action": action,
        "return_handler": return_handler,
        "payload": merged_payload,
        "schedule": schedule,
        "data_ref_seed": raw.get("data_ref_seed"),
    }


def _coerce_optional_bool(value: Any, *, field_name: str) -> Optional[bool]:
    if value is None:
        return None
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        lowered = value.strip().lower()
        if lowered in {"true", "1", "yes", "y"}:
            return True
        if lowered in {"false", "0", "no", "n"}:
            return False
    raise ValueError(f"{field_name} must be a boolean")


def _normalize_data_ref_seed(
    raw: Any,
    *,
    action: str,
    default_worker_id: str,
    runtime_variable_ttl_config: Optional[Dict[str, Any]],
) -> Optional[Dict[str, Any]]:
    if raw is None:
        return None
    if not isinstance(raw, dict):
        raise ValueError("data_ref_seed must be an object")

    scope = _as_optional_string(raw.get("scope"))
    key = _as_optional_string(raw.get("key"))
    value = raw.get("value")
    missing: List[str] = []
    if not scope:
        missing.append("scope")
    if not key:
        missing.append("key")
    if value is None:
        missing.append("value")
    if missing:
        raise ValueError(f"data_ref_seed missing required field(s): {', '.join(missing)}")
    if not isinstance(value, dict):
        raise ValueError("data_ref_seed.value must be an object")

    worker_id = _as_optional_string(raw.get("worker_id")) or default_worker_id
    ttl_minutes = _as_optional_int(raw.get("ttl_minutes"))
    if ttl_minutes is None:
        ttl_minutes = resolve_runtime_variable_ttl(
            runtime_variable_ttl_config,
            action=action,
            scope=scope,
            default_ttl_minutes=DEFAULT_SEED_TTL_MINUTES,
        )
    if ttl_minutes < 1:
        raise ValueError("data_ref_seed.ttl_minutes must be >= 1")

    is_secret = _coerce_optional_bool(raw.get("is_secret"), field_name="data_ref_seed.is_secret")
    if is_secret is None:
        is_secret = False

    return {
        "worker_id": worker_id,
        "scope": scope,
        "key": key,
        "value": value,
        "ttl_minutes": ttl_minutes,
        "is_secret": is_secret,
    }


def _redact_dsn(dsn: str) -> str:
    redacted = re.sub(r"(?i)(password=)[^\s]+", r"\1***", dsn)
    redacted = re.sub(r"://([^:/\s]+):([^@/\s]+)@", r"://\1:***@", redacted)
    return redacted


def _append_enqueued_records(records: List[Dict[str, Any]]) -> None:
    if not records:
        return
    current = _load_json_list(ENQUEUED_FILE)
    current.extend(records)
    _write_json(ENQUEUED_FILE, current)


def _parse_dotenv(path: Path) -> Dict[str, str]:
    data: Dict[str, str] = {}
    if not path.exists():
        return data
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        data[key.strip()] = value.strip().strip('"').strip("'")
    return data


def _load_local_env() -> Dict[str, str]:
    env: Dict[str, str] = {}
    for env_path in (REPO_ROOT / ".env", REPO_ROOT / ".env.prod", REPO_ROOT / ".env.local"):
        env.update(_parse_dotenv(env_path))
    env.update(os.environ)
    return env


def _ensure_runtime_vars_key_config(conn) -> None:
    with conn.cursor() as cur:
        cur.execute("SELECT current_setting('app.runtime_vars_key', true)")
        current_runtime_key = _as_optional_string((cur.fetchone() or [None])[0])
        if current_runtime_key:
            return

        cur.execute("SELECT current_setting('app.secrets_key', true)")
        secrets_key = _as_optional_string((cur.fetchone() or [None])[0])
        cur.execute("SELECT current_setting('app.secrets_key_id', true)")
        secrets_key_id = _as_optional_string((cur.fetchone() or [None])[0])

    env = _load_local_env()
    runtime_key = (
        secrets_key
        or _as_optional_string(env.get("RUNTIME_VARIABLES_ENCRYPTION_KEY"))
        or _as_optional_string(env.get("RUNTIME_VARS_KEY"))
        or _as_optional_string(env.get("SECRETS_ENCRYPTION_KEY"))
        or _as_optional_string(env.get("SECRET_ENCRYPTION_KEY"))
    )
    runtime_key_id = (
        secrets_key_id
        or _as_optional_string(env.get("RUNTIME_VARIABLES_ENCRYPTION_KEY_ID"))
        or _as_optional_string(env.get("RUNTIME_VARS_KEY_ID"))
        or _as_optional_string(env.get("SECRETS_ENCRYPTION_KEY_ID"))
        or _as_optional_string(env.get("SECRETS_KEY_ID"))
        or _as_optional_string(env.get("SECRET_ENCRYPTION_KEY_ID"))
    )

    if not runtime_key:
        raise RuntimeError("Missing app.runtime_vars_key for secret runtime variable encryption")

    with conn.cursor() as cur:
        cur.execute("SELECT set_config('app.runtime_vars_key', %s, false)", (runtime_key,))
        if runtime_key_id:
            cur.execute("SELECT set_config('app.runtime_vars_key_id', %s, false)", (runtime_key_id,))


def _task_output_path(task_uuid: str) -> Path:
    safe_task_uuid = re.sub(r"[^A-Za-z0-9_.-]+", "_", task_uuid)
    return TSH_OUT_DIR / f"task_uuid_{safe_task_uuid}.json"


def _get_runtime_variable(conn, *, worker_id: str, scope: str, key: str) -> Dict[str, Any]:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT get_runtime_variable(%s,%s,%s,%s,%s)",
            (worker_id, key, scope, False, False),
        )
        row = cur.fetchone()
    value = row[0] if row else None
    if value is None:
        raise LookupError(f"Runtime variable missing for worker_id={worker_id!r}, scope={scope!r}, key={key!r}")
    if isinstance(value, str):
        value = json.loads(value)
    if not isinstance(value, dict):
        return {"value": value}
    return value


def _validate_data_ref(payload: Dict[str, Any]) -> Dict[str, str]:
    data_ref = payload.get("data_ref")
    if not isinstance(data_ref, dict):
        raise ValueError("payload.data_ref must be an object")

    worker_id = _as_optional_string(data_ref.get("worker_id"))
    scope = _as_optional_string(data_ref.get("scope"))
    key = _as_optional_string(data_ref.get("key"))
    missing: List[str] = []
    if not worker_id:
        missing.append("worker_id")
    if not scope:
        missing.append("scope")
    if not key:
        missing.append("key")
    if missing:
        raise ValueError(f"payload.data_ref missing required field(s): {', '.join(missing)}")

    return {
        "worker_id": worker_id,
        "scope": scope,
        "key": key,
    }


def _resolve_db_connection(helper_queue_client, explicit_dsn: Optional[str]):
    client = getattr(helper_queue_client, "client", None)
    if client is not None:
        conn = getattr(client, "_conn", None)
        if conn is not None:
            return conn, False

    db_scheduler = getattr(helper_queue_client, "db_scheduler", None)
    if db_scheduler is not None:
        conn = getattr(db_scheduler, "conn", None)
        if conn is not None:
            return conn, False

    if explicit_dsn:
        return connect(explicit_dsn), True

    client = getattr(helper_queue_client, "client", None)
    if client is not None:
        dsn = _as_optional_string(getattr(client, "dsn", None))
        if dsn:
            return connect(dsn), True

    db_scheduler = getattr(helper_queue_client, "db_scheduler", None)
    if db_scheduler is not None:
        dsn = _as_optional_string(getattr(db_scheduler, "dsn", None))
        if dsn:
            return connect(dsn), True

    raise RuntimeError("Unable to resolve DB connection for callback data_ref lookup")


def _get_task_metadata(conn, api_key: str, task_id: int) -> Dict[str, Any]:
    with conn.cursor() as cur:
        cur.execute("SELECT get_task_metadata(%s, %s)", (api_key, task_id))
        row = cur.fetchone()
    raw = row[0] if row else None
    if raw is None:
        return {}
    if isinstance(raw, str):
        try:
            return json.loads(raw)
        except Exception:
            return {"raw": raw}
    if isinstance(raw, dict):
        return raw
    return {"value": raw}


def monitor_enqueued_tasks(step: StepLog, scheduler: SchedulerClient) -> int:
    records = _load_json_list(ENQUEUED_FILE)
    if not records:
        return 0

    changed_count = 0
    records_changed = False

    for raw_record in records:
        if not isinstance(raw_record, dict):
            continue

        task_uuid = _as_optional_string(raw_record.get("enqueued_task_uuid"))
        if not task_uuid:
            continue

        monitor_state = raw_record.get("monitor") if isinstance(raw_record.get("monitor"), dict) else {}
        last_status = _as_optional_string(monitor_state.get("last_known_status"))
        if last_status in TERMINAL_TASK_STATUSES:
            continue

        task_id = _as_optional_int(raw_record.get("enqueued_task_id"))
        if task_id is None:
            task_id = scheduler.lookup_task_id(task_uuid)
            if task_id is None:
                continue
            raw_record["enqueued_task_id"] = task_id
            records_changed = True

        try:
            status_snapshot = scheduler.get_task_status(task_id)
        except Exception as exc:
            step.log(
                "scheduler task status lookup failed",
                {
                    "task_uuid": task_uuid,
                    "task_id": task_id,
                    "error": str(exc),
                },
            )
            continue

        if status_snapshot is None:
            continue

        status_name = _as_optional_string(status_snapshot.get("status"))
        output_path = _task_output_path(task_uuid)
        checked_at = datetime.now(timezone.utc).isoformat()
        next_monitor_state = {
            "last_checked_at": checked_at,
            "last_known_status": status_name,
            "is_terminal": status_name in TERMINAL_TASK_STATUSES,
            "output_file": str(output_path),
        }

        should_persist = (
            not output_path.exists()
            or status_name != last_status
            or monitor_state.get("output_file") != str(output_path)
            or bool(monitor_state.get("is_terminal")) != next_monitor_state["is_terminal"]
        )
        if not should_persist:
            continue

        raw_record["task_status"] = status_name
        raw_record["task_status_checked_at"] = checked_at
        raw_record["monitor"] = next_monitor_state
        snapshot_payload = {
            "source": "secure_task_scheduler.get_task_status",
            "checked_at": checked_at,
            "task_uuid": task_uuid,
            "task_id": task_id,
            "task_status": status_snapshot,
            "enqueue_record": {key: value for key, value in raw_record.items() if key != "monitor"},
        }
        _write_json(output_path, snapshot_payload)
        records_changed = True
        changed_count += 1
        step.log(
            "scheduler task status updated",
            {
                "task_uuid": task_uuid,
                "task_id": task_id,
                "status": status_name,
                "output_file": str(output_path),
            },
        )

    if records_changed:
        _write_json(ENQUEUED_FILE, records)

    return changed_count


def enqueue_from_file(
    step: StepLog,
    scheduler: SchedulerClient,
    helper_queue: str,
    helper_action: str,
    runtime_variable_ttl_config: Optional[Dict[str, Any]] = None,
) -> int:
    raw_records = _load_json_list(ENQUEUE_FILE)
    if not raw_records:
        return 0

    moved: List[Dict[str, Any]] = []
    remaining: List[Any] = []
    successful_enqueues = 0

    for index, raw in enumerate(raw_records, start=1):
        try:
            task_def = _normalize_enqueue_record(raw, helper_queue, helper_action)
            seed_input = task_def.get("data_ref_seed")
            normalized_seed = _normalize_data_ref_seed(
                seed_input,
                action=task_def["action"],
                default_worker_id=scheduler.worker_id,
                runtime_variable_ttl_config=runtime_variable_ttl_config,
            )
            if isinstance(normalized_seed, dict):
                runtime_conn = getattr(scheduler, "_conn", None) or getattr(scheduler, "conn", None)
                if runtime_conn is None:
                    raise RuntimeError("scheduler does not expose a database connection for data_ref_seed writes")
                if bool(normalized_seed["is_secret"]):
                    _ensure_runtime_vars_key_config(runtime_conn)
                set_runtime_variable(
                    runtime_conn,
                    worker_id=normalized_seed["worker_id"],
                    scope=normalized_seed["scope"],
                    key=normalized_seed["key"],
                    value=normalized_seed["value"],
                    ttl_minutes=int(normalized_seed["ttl_minutes"]),
                    is_secret=bool(normalized_seed["is_secret"]),
                )
                task_def["payload"]["data_ref"] = {
                    "worker_id": normalized_seed["worker_id"],
                    "scope": normalized_seed["scope"],
                    "key": normalized_seed["key"],
                }
        except Exception as exc:
            failure_record: Dict[str, Any] = raw if isinstance(raw, dict) else {"raw_entry": raw}
            failure_record = dict(failure_record)
            failure_record["seed_status"] = "failed"
            failure_record["seed_error"] = str(exc)
            failure_record["task_status"] = "seed_failed"
            failure_record["task_status_checked_at"] = datetime.now(timezone.utc).isoformat()
            failure_record["enqueued_task_uuid"] = None
            failure_record["enqueued_at"] = datetime.now(timezone.utc).isoformat()
            moved.append(failure_record)
            step.log(
                "enqueue_task entry failed",
                {
                    "entry_index": index,
                    "error": str(exc),
                },
            )
            continue

        try:
            schedule = task_def.get("schedule")
            priority = int(schedule["priority"]) if isinstance(schedule, dict) else 0
            scheduled_at = schedule.get("scheduled_at") if isinstance(schedule, dict) else None
            max_attempts = int(schedule["max_attempts"]) if isinstance(schedule, dict) else 3
            recurrence_pattern = schedule.get("recurrence_pattern") if isinstance(schedule, dict) else None
            task_type = schedule.get("task_type") if isinstance(schedule, dict) else "immediate"

            try:
                task_uuid = scheduler.enqueue(
                    task_def["queue"],
                    task_def["worker"],
                    task_def["payload"],
                    priority=priority,
                    scheduled_at=scheduled_at,
                    max_attempts=max_attempts,
                    recurrence_pattern=recurrence_pattern,
                    task_type=task_type,
                )
            except TypeError:
                # Some test schedulers expose a minimal enqueue(queue, worker, payload) signature.
                task_uuid = scheduler.enqueue(
                    task_def["queue"],
                    task_def["worker"],
                    task_def["payload"],
                )
            if not task_uuid:
                raise RuntimeError("enqueue_task returned null task UUID")

            moved_record: Dict[str, Any] = {
                "worker": task_def["worker"],
                "queue": task_def["queue"],
                "action": task_def["action"],
                "return_handler": task_def["return_handler"],
                "payload": task_def["payload"],
                "enqueued_task_uuid": task_uuid,
                "enqueued_at": datetime.now(timezone.utc).isoformat(),
            }
            if isinstance(schedule, dict):
                moved_record["schedule"] = schedule
            if isinstance(normalized_seed, dict):
                moved_record["seed_status"] = "written"
                moved_record["data_ref"] = {
                    "worker_id": normalized_seed["worker_id"],
                    "scope": normalized_seed["scope"],
                    "key": normalized_seed["key"],
                }
                moved_record["data_ref_seed"] = {
                    "scope": normalized_seed["scope"],
                    "key": normalized_seed["key"],
                    "ttl_minutes": normalized_seed["ttl_minutes"],
                    "is_secret": normalized_seed["is_secret"],
                }

            moved.append(moved_record)
            successful_enqueues += 1
        except Exception as exc:
            remaining.append(raw)
            step.log(
                "enqueue_task entry failed",
                {
                    "entry_index": index,
                    "error": str(exc),
                },
            )

    _append_enqueued_records(moved)
    _write_json(ENQUEUE_FILE, remaining)

    if moved:
        step.log(
            "enqueue_task.json processed",
            {
                "enqueued_count": successful_enqueues,
                "record_count": len(moved),
                "remaining_count": len(remaining),
                "enqueued_file": str(ENQUEUED_FILE),
            },
        )

    return successful_enqueues


def handle_task(step: StepLog, helper_queue_client, task, helper_action: str, dsn: Optional[str] = None) -> None:
    try:
        action = _as_optional_string(task.payload.get("action"))
        if action != helper_action:
            helper_queue_client.fail_task(
                task,
                f"Unexpected action {action!r}; expected {helper_action!r}",
                retry=False,
            )
            return

        normalized_data_ref = _validate_data_ref(task.payload)
        conn, owns_connection = _resolve_db_connection(helper_queue_client, dsn)
        try:
            runtime_value = _get_runtime_variable(
                conn,
                worker_id=normalized_data_ref["worker_id"],
                scope=normalized_data_ref["scope"],
                key=normalized_data_ref["key"],
            )
            task_metadata: Dict[str, Any] = {}
            if task.task_id is not None:
                client = getattr(helper_queue_client, "client", None)
                api_key = getattr(client, "api_key", None)
                if api_key:
                    try:
                        task_metadata = _get_task_metadata(conn, api_key, int(task.task_id))
                    except Exception as exc:  # best-effort metadata capture
                        step.log(
                            "task_metadata lookup failed",
                            {
                                "task_id": task.task_id,
                                "error": str(exc),
                            },
                        )
        finally:
            if owns_connection:
                conn.close()

        output_payload = dict(task.payload)
        output_payload["data_ref_value"] = runtime_value
        output_payload["task_metadata"] = task_metadata
        output_payload["task_meta"] = {
            "task_uuid": task.task_uuid,
            "task_id": task.task_id,
            "queue_name": getattr(task, "queue_name", None),
            "worker": getattr(task, "worker", None),
        }
        output_payload["_helper_collection"] = {
            "collected_at": datetime.now(timezone.utc).isoformat(),
            "data_ref": normalized_data_ref,
            "runtime_value": runtime_value,
        }
        output_path = _task_output_path(task.task_uuid)
        _write_json(output_path, output_payload)

        helper_queue_client.complete_task(
            task,
            {
                "status": "payload_written",
                "task_uuid": task.task_uuid,
                "output_file": str(output_path),
                "data_ref": normalized_data_ref,
                "data_ref_value": runtime_value,
                "task_metadata": task_metadata,
                "task_meta": output_payload["task_meta"],
            },
        )
        step.log(
            "tsh_action payload dumped",
            {
                "task_uuid": task.task_uuid,
                "output_file": str(output_path),
                "data_ref": normalized_data_ref,
                "data_ref_value": runtime_value,
                "task_metadata": task_metadata,
                "task_meta": output_payload["task_meta"],
            },
        )
    except Exception as exc:
        helper_queue_client.fail_task(task, str(exc), retry=False)
        step.log(
            "helper dequeue failed",
            {
                "task_id": task.task_id,
                "task_uuid": task.task_uuid,
                "error": str(exc),
            },
        )


def before_poll(
    context: WorkerContext,
    helper_queue: str,
    helper_action: str,
    runtime_variable_ttl_config: Optional[Dict[str, Any]] = None,
) -> None:
    enqueue_from_file(
        context.step,
        context.scheduler,
        helper_queue,
        helper_action,
        runtime_variable_ttl_config=runtime_variable_ttl_config,
    )
    monitor_enqueued_tasks(context.step, context.scheduler)


def run_task(context: WorkerContext, task, helper_action: str) -> None:
    handle_task(context.step, context.main_queue, task, helper_action, context.dsn)


def main() -> None:
    args = parse_args()
    logger, log_path = configure_worker_logger(WORKER, args.log_dir)
    step = StepLog(logger)
    scheduler: Optional[SchedulerClient] = None

    try:
        ensure_runtime_paths()

        dsn = build_dsn(args.dsn, args.auto_dsn, args.db_name)
        if not dsn:
            raise SystemExit(
                "DSN is required. Use --dsn or leave auto DSN enabled with POSTGRES_PASSWORD in .env/env vars."
            )
        runtime_variable_ttl_config = parse_runtime_variable_ttl_config(args.runtime_variable_ttl_config)

        scheduler = SchedulerClient(
            logger,
            dsn,
            WORKER,
            [args.helper_queue],
            worker_id=args.worker_id,
            max_concurrent_tasks=args.max_concurrent_tasks,
            heartbeat_interval=args.heartbeat_interval,
        )
        context = WorkerContext(
            logger=logger,
            scheduler=scheduler,
            dsn=dsn,
            worker_name=WORKER,
            queue_name=args.helper_queue,
            step=step,
            poll_interval=args.poll_interval,
            max_concurrent_tasks=args.max_concurrent_tasks,
            heartbeat_interval=args.heartbeat_interval,
            lease_duration=args.lease_duration,
            drain_timeout=args.drain_timeout,
        )
        runner = WorkerRunner(
            context,
            lambda ctx, task: run_task(ctx, task, args.helper_action),
            before_poll=lambda ctx: before_poll(
                ctx,
                args.helper_queue,
                args.helper_action,
                runtime_variable_ttl_config=runtime_variable_ttl_config,
            ),
        )

        step.log(
            "task-scheduler-helper worker started",
            {
                "dsn": _redact_dsn(dsn),
                "helper_queue": args.helper_queue,
                "helper_action": args.helper_action,
                "worker_id": scheduler.worker_id,
                "max_concurrent_tasks": args.max_concurrent_tasks,
                "heartbeat_interval": args.heartbeat_interval,
                "lease_duration": args.lease_duration,
                "enqueue_file": str(ENQUEUE_FILE),
                "enqueued_file": str(ENQUEUED_FILE),
                "output_dir": str(TSH_OUT_DIR),
                "log_file": str(log_path),
            },
        )

        runner.run(once=args.once)
    except SystemExit:
        raise
    except Exception:
        logger.exception("task-scheduler-helper worker failed")
        raise SystemExit(1)
    finally:
        if scheduler is not None:
            scheduler.close()


if __name__ == "__main__":
    main()
