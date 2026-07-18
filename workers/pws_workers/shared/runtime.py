from __future__ import annotations

import json
import logging
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, Optional, Sequence

from .worker_runtime import (
    NoOpStepLog,
    SchedulerClient as BaseSchedulerClient,
    StepLog,
    Task,
    WorkerRunner as BaseWorkerRunner,
    _log_context_event,
    attach_task_meta,
    connect,
)

from .app_logger import NullAppLogger
from .worker_state import WorkerStateManager


class ManagedSchedulerClient(BaseSchedulerClient):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.state_manager = WorkerStateManager(self)

    def patch_worker_metadata(self, patch: Dict[str, Any], *, deep_merge: bool = True, audit: bool = True) -> Dict[str, Any]:
        row = self._fetchone(
            "SELECT patch_worker_metadata(%s, %s::jsonb, %s, %s)",
            (self.api_key, json.dumps(patch, default=str), deep_merge, audit),
        )
        return normalize_json_value(row[0] if row else {}) or {}

    def get_worker_metadata(self) -> Dict[str, Any]:
        row = self._fetchone("SELECT get_worker_metadata(%s)", (self.api_key,))
        return normalize_json_value(row[0] if row else {}) or {}

    def patch_task_metadata(
        self,
        task_id: int,
        patch: Dict[str, Any],
        *,
        log_history: bool = True,
        deep_merge: bool = True,
    ) -> Dict[str, Any]:
        row = self._fetchone(
            "SELECT patch_task_metadata(%s, %s, %s::jsonb, %s, %s)",
            (self.api_key, task_id, json.dumps(patch, default=str), log_history, deep_merge),
        )
        return normalize_json_value(row[0] if row else {}) or {}

    def get_task_metadata(self, task_id: int) -> Dict[str, Any]:
        row = self._fetchone("SELECT get_task_metadata(%s, %s)", (self.api_key, task_id))
        return normalize_json_value(row[0] if row else {}) or {}


class MultiQueue:
    def __init__(self, scheduler: ManagedSchedulerClient, queue_names: Sequence[str], primary_queue: str) -> None:
        self.scheduler = scheduler
        self.queue_names = tuple(queue_names)
        self.primary_queue = primary_queue

    def enqueue(self, worker: str, payload: Dict[str, Any]) -> Optional[str]:
        return self.scheduler.enqueue(self.primary_queue, worker, payload)

    def dequeue(self, lease_duration: str = "5 minutes") -> Optional[Task]:
        return self.scheduler.dequeue(self.queue_names, lease_duration)

    def complete_task(self, task: Task, result_data: Dict[str, Any]) -> None:
        self.scheduler.complete_task(task, result_data)

    def fail_task(self, task: Task, error_message: str, retry: bool = False, retry_delay: str = "30 seconds") -> None:
        self.scheduler.fail_task(task, error_message, retry=retry, retry_delay=retry_delay)


@dataclass(slots=True)
class ManagedWorkerContext:
    logger: logging.Logger
    app_logger: Any
    scheduler: ManagedSchedulerClient
    dsn: str
    worker_name: str
    queue_name: str
    subscribed_queues: Sequence[str]
    step: StepLog
    poll_interval: float
    max_concurrent_tasks: int
    heartbeat_interval: str
    lease_duration: str
    drain_timeout: float
    _queue_cache: Dict[str, Any] = field(default_factory=dict, init=False, repr=False)
    _main_queue: Optional[MultiQueue] = field(default=None, init=False, repr=False)

    def connect_db(self):
        return connect(self.dsn)

    def queue(self, queue_name: str):
        if queue_name not in self._queue_cache:
            self._queue_cache[queue_name] = self.scheduler.queue(queue_name)
        return self._queue_cache[queue_name]

    @property
    def main_queue(self) -> MultiQueue:
        if self._main_queue is None:
            self._main_queue = MultiQueue(self.scheduler, self.subscribed_queues, self.queue_name)
        return self._main_queue


class ManagedWorkerRunner(BaseWorkerRunner):
    def _heartbeat_loop(self) -> None:
        while not self._heartbeat_stop_event.is_set():
            tasks = self._snapshot_in_flight()
            in_flight_ids = [int(task.task_id) for task in tasks if task.task_id is not None]
            try:
                self.context.scheduler.worker_heartbeat(len(tasks), self.context.heartbeat_interval)
            except Exception as exc:  # pragma: no cover - runtime path
                _log_context_event(
                    self.context,
                    "warn",
                    "Worker heartbeat failed",
                    exc=exc,
                    metadata={"current_load": len(tasks)},
                )

            try:
                self.context.scheduler.state_manager.checkpoint(
                    in_flight_task_ids=in_flight_ids,
                    current_load=len(tasks),
                )
            except Exception as exc:  # pragma: no cover - runtime path
                _log_context_event(
                    self.context,
                    "warn",
                    "Worker state checkpoint failed",
                    exc=exc,
                    metadata={"current_load": len(tasks), "in_flight_task_ids": in_flight_ids},
                )

            for task in tasks:
                try:
                    self.context.scheduler.heartbeat_task(task, self.context.lease_duration)
                except Exception as exc:  # pragma: no cover - runtime path
                    message = str(exc)
                    if "Task not found or not in processing state" in message:
                        continue
                    _log_context_event(
                        self.context,
                        "warn",
                        "Task heartbeat failed",
                        exc=exc,
                        task=task,
                    )

            self._heartbeat_stop_event.wait(self._heartbeat_sleep)

    def _execute_task(self, task: Task) -> None:
        try:
            self.handler(self.context, task)
            try:
                self.context.scheduler.state_manager.record_task_completed()
            except Exception as exc:  # pragma: no cover - runtime path
                _log_context_event(
                    self.context,
                    "warn",
                    "Worker state completion checkpoint failed",
                    exc=exc,
                    task=task,
                )
        except Exception as exc:  # pragma: no cover - runtime path
            _log_context_event(
                self.context,
                "error",
                "Failed to handle task",
                exc=exc,
                task=task,
            )
            try:
                self.context.scheduler.state_manager.record_task_failed()
            except Exception as record_exc:
                _log_context_event(
                    self.context,
                    "error",
                    "Failed to record task failure",
                    exc=record_exc,
                    task=task,
                )
            try:
                self.context.main_queue.fail_task(task, str(exc), retry=False)
            except Exception as fail_exc:
                _log_context_event(
                    self.context,
                    "error",
                    "Failed to mark task as failed",
                    exc=fail_exc,
                    task=task,
                )


def enqueue_with_meta(
    queue,
    worker: str,
    payload: Dict[str, Any],
    *,
    current_task: Optional[Task] = None,
    current_worker: Optional[str] = None,
    current_action: Optional[str] = None,
    next_worker: Optional[str] = None,
    next_action: Optional[str] = None,
    parent_task_uuid: Optional[str] = None,
) -> Optional[str]:
    parent_uuid = parent_task_uuid or as_optional_string(getattr(current_task, "task_uuid", None))
    payload_with_meta = attach_task_meta(
        payload,
        task_creator_worker=current_worker,
        task_creator_action=current_action,
        return_data_handler_worker=next_worker,
        return_data_handler_action=next_action,
        parent_task_uuid=parent_uuid,
    )
    return queue.enqueue(worker, payload_with_meta)


def normalize_json_value(value: Any) -> Any:
    if isinstance(value, str):
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return value
    return value


def as_optional_string(value: Any) -> Optional[str]:
    if value is None:
        return None
    if isinstance(value, str):
        value = value.strip()
        return value or None
    return str(value)


def coerce_optional_int(value: Any, *, field_name: str = "value") -> Optional[int]:
    if value is None or value == "":
        return None
    try:
        return int(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{field_name} must be an integer") from exc


def coerce_required_int(payload: Dict[str, Any], field: str) -> int:
    value = payload.get(field)
    if value is None or value == "":
        raise ValueError(f"{field} is required")
    result = coerce_optional_int(value, field_name=field)
    if result is None:
        raise ValueError(f"{field} is required")
    return result


def get_booking_id(payload: Dict[str, Any], *, required: bool) -> Optional[int]:
    for field_name in ("booking_id", "booking_entry_id"):
        value = payload.get(field_name)
        if value is None or value == "":
            continue
        return coerce_optional_int(value, field_name=field_name)
    if required:
        raise ValueError("booking_id is required")
    return None


def _coerce_ttl_minutes(value: Any, *, field_name: str) -> int:
    ttl = coerce_optional_int(value, field_name=field_name)
    if ttl is None or ttl < 1:
        raise ValueError(f"{field_name} must be an integer >= 1")
    return int(ttl)


def _normalize_runtime_variable_ttl_action_config(raw: Any, *, field_name: str) -> Dict[str, Any]:
    if raw is None:
        return {}
    if not isinstance(raw, dict):
        raise ValueError(f"{field_name} must be an object")

    unknown = sorted(set(raw) - {"default_ttl_minutes", "by_scope"})
    if unknown:
        raise ValueError(f"{field_name} has unsupported fields: {', '.join(unknown)}")

    config: Dict[str, Any] = {}
    if raw.get("default_ttl_minutes") is not None:
        config["default_ttl_minutes"] = _coerce_ttl_minutes(
            raw.get("default_ttl_minutes"),
            field_name=f"{field_name}.default_ttl_minutes",
        )

    raw_by_scope = raw.get("by_scope") or {}
    if raw_by_scope:
        if not isinstance(raw_by_scope, dict):
            raise ValueError(f"{field_name}.by_scope must be an object")
        by_scope: Dict[str, int] = {}
        for raw_scope, raw_ttl in raw_by_scope.items():
            scope = as_optional_string(raw_scope)
            if not scope:
                raise ValueError(f"{field_name}.by_scope keys must be non-empty strings")
            by_scope[scope] = _coerce_ttl_minutes(
                raw_ttl,
                field_name=f"{field_name}.by_scope.{scope}",
            )
        if by_scope:
            config["by_scope"] = by_scope

    return config


def parse_runtime_variable_ttl_config(raw: Any) -> Optional[Dict[str, Any]]:
    if raw is None or raw == "":
        return None

    parsed = raw
    if isinstance(raw, str):
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise ValueError("runtime_variable_ttl_config must be valid JSON") from exc

    if not isinstance(parsed, dict):
        raise ValueError("runtime_variable_ttl_config must be an object")

    unknown = sorted(set(parsed) - {"default_ttl_minutes", "by_scope", "by_action"})
    if unknown:
        raise ValueError(f"runtime_variable_ttl_config has unsupported fields: {', '.join(unknown)}")

    config = _normalize_runtime_variable_ttl_action_config(
        {
            "default_ttl_minutes": parsed.get("default_ttl_minutes"),
            "by_scope": parsed.get("by_scope"),
        },
        field_name="runtime_variable_ttl_config",
    )

    raw_by_action = parsed.get("by_action") or {}
    if raw_by_action:
        if not isinstance(raw_by_action, dict):
            raise ValueError("runtime_variable_ttl_config.by_action must be an object")
        by_action: Dict[str, Dict[str, Any]] = {}
        for raw_action, raw_action_config in raw_by_action.items():
            action = as_optional_string(raw_action)
            if not action:
                raise ValueError("runtime_variable_ttl_config.by_action keys must be non-empty strings")
            by_action[action] = _normalize_runtime_variable_ttl_action_config(
                raw_action_config,
                field_name=f"runtime_variable_ttl_config.by_action.{action}",
            )
        if by_action:
            config["by_action"] = by_action

    return config or None


def resolve_runtime_variable_ttl(
    config: Optional[Dict[str, Any]],
    *,
    action: Optional[str],
    scope: Optional[str],
    default_ttl_minutes: int,
) -> int:
    resolved_action = as_optional_string(action)
    resolved_scope = as_optional_string(scope)

    if isinstance(config, dict):
        if resolved_action:
            action_config = config.get("by_action", {}).get(resolved_action)
            if isinstance(action_config, dict):
                action_scopes = action_config.get("by_scope") or {}
                if resolved_scope and resolved_scope in action_scopes:
                    return int(action_scopes[resolved_scope])
                if action_config.get("default_ttl_minutes") is not None:
                    return int(action_config["default_ttl_minutes"])

        worker_scopes = config.get("by_scope") or {}
        if resolved_scope and resolved_scope in worker_scopes:
            return int(worker_scopes[resolved_scope])

        if config.get("default_ttl_minutes") is not None:
            return int(config["default_ttl_minutes"])

    return int(default_ttl_minutes)


def metadata_only(data: Dict[str, Any]) -> Dict[str, Any]:
    return {key: value for key, value in data.items() if value is not None}


def default_step(context) -> StepLog:
    return getattr(context, "step", NoOpStepLog())


def default_app_logger(context):
    return getattr(context, "app_logger", NullAppLogger())


def task_log_kwargs(task, action_name: str) -> Dict[str, Any]:
    return {
        "action_name": action_name,
        "task_id": getattr(task, "task_id", None),
        "task_uuid": getattr(task, "task_uuid", None),
    }


def generate_key(prefix: str) -> str:
    import uuid

    return f"{prefix}_{uuid.uuid4().hex}"


def get_runtime_variable(conn, *, worker_id: str, scope: str, key: str) -> Dict[str, Any]:
    with conn.cursor() as cur:
        cur.execute("SELECT get_runtime_variable(%s, %s, %s, %s, %s)", (worker_id, key, scope, False, False))
        row = cur.fetchone()
    if not row or row[0] is None:
        raise LookupError(f"Runtime variable missing for scope={scope} key={key}")
    value = normalize_json_value(row[0])
    if not isinstance(value, dict):
        raise ValueError(f"Runtime variable scope={scope} key={key} must contain a JSON object")
    return value


def set_runtime_variable(
    conn,
    *,
    worker_id: str,
    scope: str,
    key: str,
    value: Dict[str, Any],
    ttl_minutes: int,
    is_secret: bool = False,
) -> None:
    expires_at = datetime.now(timezone.utc) + timedelta(minutes=ttl_minutes)
    with conn.cursor() as cur:
        cur.execute(
            "SELECT set_runtime_variable(%s, %s, %s::jsonb, %s, %s, %s, %s)",
            (
                worker_id,
                key,
                json.dumps(value, default=str),
                scope,
                None,
                is_secret,
                expires_at,
            ),
        )


def delete_runtime_variable(conn, *, worker_id: str, scope: str, key: str) -> None:
    with conn.cursor() as cur:
        cur.execute("SELECT delete_runtime_variable(%s, %s, %s)", (worker_id, key, scope))


def normalize_return_ref(payload: Dict[str, Any], *, default_queue: Optional[str]) -> Optional[Dict[str, Optional[str]]]:
    return_ref = payload.get("return_ref") if isinstance(payload.get("return_ref"), dict) else {}
    legacy_ref = payload.get("return_handler") if isinstance(payload.get("return_handler"), dict) else {}

    worker = (
        as_optional_string(return_ref.get("worker"))
        or as_optional_string(legacy_ref.get("worker"))
        or as_optional_string(payload.get("return_handler_worker"))
    )
    action = (
        as_optional_string(return_ref.get("action"))
        or as_optional_string(legacy_ref.get("action"))
        or as_optional_string(payload.get("return_handler_action"))
    )

    if "queue" in return_ref:
        queue = as_optional_string(return_ref.get("queue")) or default_queue
    else:
        queue = (
            as_optional_string(legacy_ref.get("queue"))
            or as_optional_string(payload.get("return_handler_queue"))
            or default_queue
        )

    if not worker or not action:
        return None
    return {
        "worker": worker,
        "queue": queue,
        "action": action,
    }
