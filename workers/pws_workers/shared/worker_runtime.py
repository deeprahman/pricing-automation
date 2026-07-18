from __future__ import annotations

import argparse
import concurrent.futures
import json
import logging
import os
import re
import signal
import socket
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, Optional, Sequence

import psycopg  # type: ignore

from .app_logger import NullAppLogger


DEFAULT_WORKER_LOG_DIR = Path(__file__).resolve().parent / "logs"
WORKER_LOG_FORMAT = "%(asctime)s | %(levelname)-5s | %(message)s"


def pretty(payload: Any) -> str:
    return json.dumps(payload, indent=2, sort_keys=True, default=str)


def _resolve_log_level(env: Optional[Dict[str, str]] = None) -> int:
    source = env if env is not None else _load_repo_env(Path(__file__).resolve().parents[3])
    level_name = str(source.get("LOG_LEVEL") or "INFO").strip().upper()
    resolved = getattr(logging, level_name, None)
    return resolved if isinstance(resolved, int) else logging.INFO


def configure_worker_logger(worker_name: str, log_dir: Optional[str | Path] = None) -> tuple[logging.Logger, Path]:
    resolved_log_dir = Path(log_dir).expanduser() if log_dir is not None else DEFAULT_WORKER_LOG_DIR
    resolved_log_dir.mkdir(parents=True, exist_ok=True)
    log_path = resolved_log_dir / f"{worker_name}.err.log"
    log_level = _resolve_log_level()

    stream = sys.stderr
    if hasattr(stream, "isatty") and stream.isatty():
        stream = log_path.open("a", encoding="utf-8")
        sys.stderr = stream

    logger = logging.getLogger(worker_name)
    logger.setLevel(log_level)
    logger.propagate = False

    for handler in list(logger.handlers):
        logger.removeHandler(handler)
        handler.close()

    handler = logging.StreamHandler(stream)
    handler.setFormatter(logging.Formatter(WORKER_LOG_FORMAT))
    logger.addHandler(handler)
    return logger, log_path


class StepLog:
    """Numbered step logger for readable worker output."""

    def __init__(self, logger: logging.Logger):
        self.logger = logger
        self._counter = 0
        self._lock = threading.Lock()

    def log(self, title: str, payload: Optional[Dict[str, Any]] = None) -> None:
        with self._lock:
            self._counter += 1
            counter = self._counter

        spacer = "=" * 60
        self.logger.info("\n%s\nSTEP %02d: %s\n%s", spacer, counter, title, spacer)
        if payload is not None:
            self.logger.info("payload:\n%s", pretty(payload))
        self.logger.info("")


class NoOpStepLog:
    def log(self, _title: str, _payload: Optional[Dict[str, Any]] = None) -> None:
        return None


def _parse_dotenv(path: Path) -> Dict[str, str]:
    env: Dict[str, str] = {}
    if not path.exists():
        return env
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        env[key.strip()] = value.strip().strip('"').strip("'")
    return env


def _load_repo_env(repo_root: Path) -> Dict[str, str]:
    env: Dict[str, str] = {}
    for path in (repo_root / ".env", repo_root / ".env.prod", repo_root / ".env.local"):
        env.update(_parse_dotenv(path))
    env.update(os.environ)
    return env


def build_dsn(
    cli_dsn: Optional[str],
    auto: bool,
    db_name: Optional[str] = None,
    repo_root: Optional[Path] = None,
) -> Optional[str]:
    if cli_dsn:
        return cli_dsn
    if not auto:
        return None

    root = repo_root or Path(__file__).resolve().parents[3]
    env = _load_repo_env(root)
    host = env.get("POSTGRES_HOST") or env.get("HOST") or "127.0.0.1"
    port = env.get("POSTGRES_HOST_PORT") or env.get("POSTGRES_PORT") or "5432"
    dbname = db_name or env.get("SCHEMA_DB") or env.get("POSTGRES_DB") or "auto_pws"
    user = env.get("POSTGRES_USER") or "n8n"
    password = env.get("POSTGRES_PASSWORD")
    if not password:
        return None
    return f"host={host} port={port} dbname={dbname} user={user} password={password}"


def connect(dsn: str):
    conn = psycopg.connect(dsn, autocommit=True)
    env = _load_repo_env(Path(__file__).resolve().parents[3])
    secrets_key = (
        env.get("SECRETS_ENCRYPTION_KEY")
        or env.get("SECRET_ENCRYPTION_KEY")
    )
    secrets_key_id = (
        env.get("SECRETS_ENCRYPTION_KEY_ID")
        or env.get("SECRETS_KEY_ID")
        or env.get("SECRET_ENCRYPTION_KEY_ID")
    )
    if secrets_key or secrets_key_id:
        with conn.cursor() as cur:
            if secrets_key:
                cur.execute("SELECT set_config('app.secrets_key', %s, false)", (str(secrets_key),))
            if secrets_key_id:
                cur.execute("SELECT set_config('app.secrets_key_id', %s, false)", (str(secrets_key_id),))
    return conn


def _as_optional_string(value: Any) -> Optional[str]:
    if value is None:
        return None
    if isinstance(value, str):
        value = value.strip()
        return value or None
    return str(value)


def normalize_task_meta(meta: Any) -> Dict[str, Any]:
    meta_obj = meta if isinstance(meta, dict) else {}
    workers = meta_obj.get("workers") if isinstance(meta_obj.get("workers"), dict) else {}
    actions = meta_obj.get("actions") if isinstance(meta_obj.get("actions"), dict) else {}
    return {
        "workers": {
            "task_creator": _as_optional_string(workers.get("task_creator")),
            "return_data_handler": _as_optional_string(workers.get("return_data_handler")),
        },
        "actions": {
            "task_creator": _as_optional_string(actions.get("task_creator")),
            "return_data_handler": _as_optional_string(actions.get("return_data_handler")),
        },
        "parent_task_uuid": _as_optional_string(meta_obj.get("parent_task_uuid")),
    }


def build_task_meta(
    *,
    task_creator_worker: Optional[str],
    task_creator_action: Optional[str],
    return_data_handler_worker: Optional[str] = None,
    return_data_handler_action: Optional[str] = None,
    parent_task_uuid: Optional[str] = None,
) -> Dict[str, Any]:
    return {
        "workers": {
            "task_creator": _as_optional_string(task_creator_worker),
            "return_data_handler": _as_optional_string(return_data_handler_worker),
        },
        "actions": {
            "task_creator": _as_optional_string(task_creator_action),
            "return_data_handler": _as_optional_string(return_data_handler_action),
        },
        "parent_task_uuid": _as_optional_string(parent_task_uuid),
    }


def attach_task_meta(
    payload: Dict[str, Any],
    *,
    task_creator_worker: Optional[str],
    task_creator_action: Optional[str],
    return_data_handler_worker: Optional[str] = None,
    return_data_handler_action: Optional[str] = None,
    parent_task_uuid: Optional[str] = None,
) -> Dict[str, Any]:
    normalized_existing = normalize_task_meta(payload.get("meta"))
    payload_with_meta = dict(payload)
    payload_with_meta["meta"] = build_task_meta(
        task_creator_worker=task_creator_worker or normalized_existing["workers"]["task_creator"],
        task_creator_action=task_creator_action or normalized_existing["actions"]["task_creator"],
        return_data_handler_worker=(
            return_data_handler_worker
            if return_data_handler_worker is not None
            else normalized_existing["workers"]["return_data_handler"]
        ),
        return_data_handler_action=(
            return_data_handler_action
            if return_data_handler_action is not None
            else normalized_existing["actions"]["return_data_handler"]
        ),
        parent_task_uuid=parent_task_uuid or normalized_existing["parent_task_uuid"],
    )
    return payload_with_meta


def normalize_payload_meta(payload: Dict[str, Any]) -> Dict[str, Any]:
    payload["meta"] = normalize_task_meta(payload.get("meta"))
    return payload


@dataclass(slots=True)
class Task:
    worker: str
    payload: Dict[str, Any]
    task_id: Optional[int] = None
    task_uuid: Optional[str] = None
    attempts: int = 0
    max_attempts: int = 0
    queue_name: str = "default"

    @property
    def task_name(self) -> str:
        return self.worker


_INTERVAL_RE = re.compile(r"^\s*(\d+(?:\.\d+)?)\s*(milliseconds?|seconds?|minutes?|hours?)\s*$", re.IGNORECASE)


def interval_to_seconds(value: str | float | int) -> float:
    if isinstance(value, (int, float)):
        return float(value)

    match = _INTERVAL_RE.match(value)
    if not match:
        raise ValueError(f"Unsupported interval value: {value!r}")
    amount = float(match.group(1))
    unit = match.group(2).lower()
    if unit.startswith("millisecond"):
        return amount / 1000.0
    if unit.startswith("second"):
        return amount
    if unit.startswith("minute"):
        return amount * 60.0
    if unit.startswith("hour"):
        return amount * 3600.0
    raise ValueError(f"Unsupported interval unit: {unit!r}")


def default_worker_id(logical_worker_name: str) -> str:
    host = re.sub(r"[^a-zA-Z0-9_.-]+", "-", socket.gethostname()).strip("-") or "host"
    base = f"{logical_worker_name}@{host}-{os.getpid()}"
    return base[:100]


class SchedulerClient:
    """Single secure-task-scheduler registration shared by all queue handles."""

    TASK_STATUS_COLUMNS = (
        "id",
        "task_uuid",
        "task_name",
        "status",
        "worker_id",
        "attempts",
        "max_attempts",
        "queue_name",
        "scheduled_at",
        "started_at",
        "completed_at",
        "lease_expires_at",
        "last_error",
        "task_type",
        "priority",
        "created_at",
        "updated_at",
    )

    def __init__(
        self,
        logger: logging.Logger,
        dsn: str,
        logical_worker_name: str,
        subscribed_queues: Sequence[str],
        *,
        worker_id: Optional[str] = None,
        max_concurrent_tasks: int = 1,
        heartbeat_interval: str = "30 seconds",
    ) -> None:
        if max_concurrent_tasks < 1:
            raise ValueError("max_concurrent_tasks must be >= 1")
        if not subscribed_queues:
            raise ValueError("At least one subscribed queue is required")

        self.logger = logger
        self.dsn = dsn
        self.logical_worker_name = logical_worker_name
        self.subscribed_queues = tuple(dict.fromkeys(subscribed_queues))
        self.worker_id = worker_id or default_worker_id(logical_worker_name)
        self.max_concurrent_tasks = max_concurrent_tasks
        self.heartbeat_interval = heartbeat_interval
        self._conn = connect(dsn)
        self._lock = threading.RLock()
        self._api_key: Optional[str] = None
        self._queue_cache: Dict[str, SchedulerQueue] = {}

        for queue_name in self.subscribed_queues:
            self.ensure_queue(queue_name)
        self._register_worker()

    @property
    def api_key(self) -> str:
        if not self._api_key:
            raise RuntimeError("Scheduler worker is not registered")
        return self._api_key

    def _fetchone(self, sql: str, params: Sequence[Any]) -> Optional[tuple]:
        with self._lock:
            with self._conn.cursor() as cur:
                cur.execute(sql, params)
                return cur.fetchone()

    def _exec(self, sql: str, params: Sequence[Any]) -> None:
        with self._lock:
            with self._conn.cursor() as cur:
                cur.execute(sql, params)

    def _register_worker(self) -> None:
        row = self._fetchone(
            """
            SELECT worker_id, api_key, success
            FROM register_worker(%s, %s, %s, %s::interval, %s::jsonb)
            """,
            (
                self.worker_id,
                self.logical_worker_name,
                self.max_concurrent_tasks,
                self.heartbeat_interval,
                json.dumps(list(self.subscribed_queues)),
            ),
        )
        if not row or not row[2]:
            raise RuntimeError("Failed to register secure scheduler worker.")
        self._api_key = str(row[1])

    def ensure_queue(self, queue_name: str, description: Optional[str] = None) -> None:
        self._exec(
            "SELECT create_queue(%s, %s)",
            (queue_name, description or f"Auto-created queue for {self.logical_worker_name}"),
        )

    def queue(self, queue_name: str) -> "SchedulerQueue":
        if queue_name not in self._queue_cache:
            self._queue_cache[queue_name] = SchedulerQueue(self, queue_name)
        return self._queue_cache[queue_name]

    def enqueue(
        self,
        queue_name: str,
        worker: str,
        payload: Dict[str, Any],
        *,
        priority: int = 0,
        scheduled_at: Any = None,
        max_attempts: int = 3,
        recurrence_pattern: Optional[str] = None,
        task_type: str = "immediate",
    ) -> Optional[str]:
        self.ensure_queue(queue_name)
        row = self._fetchone(
            """
            SELECT enqueue_task(
                %s,
                %s,
                %s::jsonb,
                %s,
                %s,
                %s,
                %s,
                %s,
                %s
            )
            """,
            (
                self.api_key,
                worker,
                json.dumps(payload, default=str),
                task_type,
                priority,
                scheduled_at,
                max_attempts,
                recurrence_pattern,
                queue_name,
            ),
        )
        return str(row[0]) if row and row[0] is not None else None

    def lookup_task_id(self, task_uuid: str) -> Optional[int]:
        row = self._fetchone(
            "SELECT id FROM task_queue WHERE task_uuid = %s::uuid",
            (task_uuid,),
        )
        return int(row[0]) if row and row[0] is not None else None

    def get_task_status(self, task_id: int) -> Optional[Dict[str, Any]]:
        row = self._fetchone(
            """
            SELECT
                id,
                task_uuid,
                task_name,
                status,
                worker_id,
                attempts,
                max_attempts,
                queue_name,
                scheduled_at,
                started_at,
                completed_at,
                lease_expires_at,
                last_error,
                task_type,
                priority,
                created_at,
                updated_at
            FROM get_task_status(%s, %s)
            """,
            (self.api_key, task_id),
        )
        if row is None:
            return None
        return {
            column: row[index]
            for index, column in enumerate(self.TASK_STATUS_COLUMNS)
        }

    def reset_stuck_tasks(self) -> int:
        row = self._fetchone(
            "SELECT reset_stuck_tasks()",
            (),
        )
        return int(row[0]) if row and row[0] is not None else 0

    def add_task_dependencies(self, task_uuid: str, prerequisite_task_uuids: Sequence[str]) -> int:
        normalized = [str(value) for value in prerequisite_task_uuids if value]
        if not normalized:
            return 0
        row = self._fetchone(
            "SELECT add_task_dependencies(%s, %s::uuid, %s::uuid[])",
            (self.api_key, task_uuid, normalized),
        )
        return int(row[0]) if row and row[0] is not None else 0

    def dequeue(self, queue_names: Iterable[str], lease_duration: str = "5 minutes") -> Optional[Task]:
        row = self._fetchone(
            """
            SELECT task_id, task_uuid, task_name, task_data, attempts, max_attempts, queue_name
            FROM dequeue_task(%s, %s::interval, %s::varchar[])
            """,
            (self.api_key, lease_duration, list(queue_names)),
        )
        if row is None:
            return None

        task_data = row[3] or {}
        if isinstance(task_data, str):
            task_data = json.loads(task_data)
        return Task(
            worker=str(row[2]),
            payload=task_data,
            task_id=int(row[0]) if row[0] is not None else None,
            task_uuid=str(row[1]) if row[1] is not None else None,
            attempts=int(row[4]),
            max_attempts=int(row[5]),
            queue_name=str(row[6]),
        )

    def complete_task(self, task: Task, result_data: Dict[str, Any]) -> None:
        if task.task_id is None:
            return
        self._exec(
            "SELECT complete_task(%s, %s, %s::jsonb)",
            (self.api_key, task.task_id, json.dumps(result_data, default=str)),
        )

    def fail_task(
        self,
        task: Task,
        error_message: str,
        retry: bool = False,
        retry_delay: str = "30 seconds",
    ) -> None:
        if task.task_id is None:
            return
        self._exec(
            "SELECT fail_task(%s, %s, %s, %s, %s::interval)",
            (self.api_key, task.task_id, error_message, retry, retry_delay),
        )

    def worker_heartbeat(self, current_load: Optional[int] = None, heartbeat_interval: Optional[str] = None) -> None:
        self._exec(
            "SELECT worker_heartbeat(%s, %s, %s::interval)",
            (self.api_key, current_load, heartbeat_interval or self.heartbeat_interval),
        )

    def heartbeat_task(self, task: Task, extend_by: str = "5 minutes") -> None:
        if task.task_id is None:
            return
        self._exec(
            "SELECT heartbeat_task(%s, %s, %s::interval)",
            (self.api_key, task.task_id, extend_by),
        )

    def close(self) -> None:
        with self._lock:
            if self._conn is not None:
                self._conn.close()


class SchedulerQueue:
    def __init__(self, client: SchedulerClient, queue_name: str) -> None:
        self.client = client
        self.queue_name = queue_name

    def enqueue(self, worker: str, payload: Dict[str, Any]) -> Optional[str]:
        return self.client.enqueue(self.queue_name, worker, payload)

    def dequeue(self, lease_duration: str = "5 minutes") -> Optional[Task]:
        return self.client.dequeue([self.queue_name], lease_duration)

    def complete_task(self, task: Task, result_data: Dict[str, Any]) -> None:
        self.client.complete_task(task, result_data)

    def fail_task(self, task: Task, error_message: str, retry: bool = False, retry_delay: str = "30 seconds") -> None:
        self.client.fail_task(task, error_message, retry=retry, retry_delay=retry_delay)

    def close(self) -> None:
        return None


def enqueue_with_meta(
    queue: SchedulerQueue,
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
    parent_uuid = parent_task_uuid
    if parent_uuid is None and current_task is not None:
        parent_uuid = _as_optional_string(getattr(current_task, "task_uuid", None))

    payload_with_meta = attach_task_meta(
        payload,
        task_creator_worker=current_worker,
        task_creator_action=current_action,
        return_data_handler_worker=next_worker,
        return_data_handler_action=next_action,
        parent_task_uuid=parent_uuid,
    )
    return queue.enqueue(worker, payload_with_meta)


@dataclass(slots=True)
class WorkerContext:
    logger: logging.Logger
    scheduler: SchedulerClient
    dsn: str
    worker_name: str
    queue_name: str
    step: StepLog
    poll_interval: float
    max_concurrent_tasks: int
    heartbeat_interval: str
    lease_duration: str
    drain_timeout: float
    app_logger: Any = field(default_factory=NullAppLogger)
    _queue_cache: Dict[str, SchedulerQueue] = field(default_factory=dict, init=False, repr=False)

    def connect_db(self):
        return connect(self.dsn)

    def queue(self, queue_name: str) -> SchedulerQueue:
        if queue_name not in self._queue_cache:
            self._queue_cache[queue_name] = self.scheduler.queue(queue_name)
        return self._queue_cache[queue_name]

    @property
    def main_queue(self) -> SchedulerQueue:
        return self.queue(self.queue_name)


TaskHandler = Callable[[WorkerContext, Task], None]
LoopHook = Callable[[WorkerContext], None]


class WorkerRunner:
    """Bounded-concurrency polling worker with worker/task heartbeats."""

    def __init__(
        self,
        context: WorkerContext,
        handler: TaskHandler,
        *,
        before_poll: Optional[LoopHook] = None,
    ) -> None:
        self.context = context
        self.handler = handler
        self.before_poll = before_poll
        self._stop_event = threading.Event()
        self._heartbeat_stop_event = threading.Event()
        self._in_flight: Dict[concurrent.futures.Future[None], Task] = {}
        self._in_flight_lock = threading.Lock()
        self._signal_handlers: Dict[int, Any] = {}
        self._heartbeat_sleep = max(
            0.1,
            min(
                interval_to_seconds(self.context.heartbeat_interval) / 2.0,
                interval_to_seconds(self.context.lease_duration) / 2.0,
            ),
        )

    def request_shutdown(self, reason: str = "requested") -> None:
        if self._stop_event.is_set():
            return
        _log_context_event(
            self.context,
            "info",
            "Worker shutdown requested",
            metadata={"reason": reason},
        )
        self._stop_event.set()

    def run(self, *, once: bool = False) -> None:
        heartbeat_thread = threading.Thread(
            target=self._heartbeat_loop,
            name=f"{self.context.worker_name}-heartbeat",
            daemon=True,
        )
        self._install_signal_handlers()
        self.context.scheduler.worker_heartbeat(0, self.context.heartbeat_interval)
        heartbeat_thread.start()
        try:
            with concurrent.futures.ThreadPoolExecutor(
                max_workers=self.context.max_concurrent_tasks,
                thread_name_prefix=f"{self.context.worker_name}-task",
            ) as executor:
                if once:
                    self._run_before_poll()
                    task = self.context.main_queue.dequeue(self.context.lease_duration)
                    if task is not None:
                        normalize_payload_meta(task.payload)
                        self._submit_task(executor, task)
                    self._drain_in_flight(self.context.drain_timeout)
                    return

                while not self._stop_event.is_set():
                    self._reap_completed_futures()
                    self._run_before_poll()

                    if self._stop_event.is_set():
                        break

                    if self._in_flight_count() >= self.context.max_concurrent_tasks:
                        self._stop_event.wait(min(self.context.poll_interval, 0.1))
                        continue

                    task = self.context.main_queue.dequeue(self.context.lease_duration)
                    if task is None:
                        self._stop_event.wait(self.context.poll_interval)
                        continue

                    normalize_payload_meta(task.payload)
                    self._submit_task(executor, task)

                self._drain_in_flight(self.context.drain_timeout)
        finally:
            self._heartbeat_stop_event.set()
            heartbeat_thread.join(timeout=max(1.0, self._heartbeat_sleep * 2.0))
            self._restore_signal_handlers()

    def _install_signal_handlers(self) -> None:
        if threading.current_thread() is not threading.main_thread():
            return
        for signame in ("SIGINT", "SIGTERM"):
            signum = getattr(signal, signame, None)
            if signum is None:
                continue
            self._signal_handlers[signum] = signal.getsignal(signum)
            signal.signal(signum, self._handle_signal)

    def _restore_signal_handlers(self) -> None:
        if threading.current_thread() is not threading.main_thread():
            return
        for signum, previous in self._signal_handlers.items():
            signal.signal(signum, previous)
        self._signal_handlers.clear()

    def _handle_signal(self, signum: int, _frame: Any) -> None:
        self.request_shutdown(f"signal {signum}")

    def _run_before_poll(self) -> None:
        if self.before_poll is None:
            return
        self.before_poll(self.context)

    def _submit_task(self, executor: concurrent.futures.ThreadPoolExecutor, task: Task) -> None:
        future = executor.submit(self._execute_task, task)
        with self._in_flight_lock:
            self._in_flight[future] = task

    def _in_flight_count(self) -> int:
        with self._in_flight_lock:
            return len(self._in_flight)

    def _snapshot_in_flight(self) -> list[Task]:
        with self._in_flight_lock:
            return list(self._in_flight.values())

    def _reap_completed_futures(self) -> None:
        done: list[tuple[concurrent.futures.Future[None], Task]] = []
        with self._in_flight_lock:
            for future, task in self._in_flight.items():
                if future.done():
                    done.append((future, task))
            for future, _task in done:
                self._in_flight.pop(future, None)

        for future, task in done:
            try:
                future.result()
            except Exception as exc:  # pragma: no cover - wrapper logs already
                _log_context_event(
                    self.context,
                    "error",
                    "Unhandled task wrapper failure",
                    exc=exc,
                    task=task,
                )

    def _drain_in_flight(self, timeout_seconds: float) -> None:
        deadline = time.monotonic() + max(timeout_seconds, 0.0)
        while True:
            self._reap_completed_futures()
            if self._in_flight_count() == 0:
                return
            if time.monotonic() >= deadline:
                in_flight_count = self._in_flight_count()
                _log_context_event(
                    self.context,
                    "warn",
                    "Worker drain timeout reached",
                    metadata={"in_flight_tasks": in_flight_count},
                )
                return
            time.sleep(0.05)

    def _heartbeat_loop(self) -> None:
        while not self._heartbeat_stop_event.is_set():
            tasks = self._snapshot_in_flight()
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
        except Exception as exc:  # pragma: no cover - runtime path
            _log_context_event(
                self.context,
                "error",
                "Failed to handle task",
                exc=exc,
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


def _log_context_event(
    context: Any,
    level: str,
    message: str,
    *,
    exc: Optional[BaseException] = None,
    task: Optional[Task] = None,
    metadata: Optional[Dict[str, Any]] = None,
) -> None:
    app_logger = getattr(context, "app_logger", None)
    kwargs: Dict[str, Any] = {"action_name": "worker_runtime"}
    if metadata:
        kwargs["metadata"] = metadata
    if task is not None:
        kwargs["task_id"] = getattr(task, "task_id", None)
        kwargs["task_uuid"] = getattr(task, "task_uuid", None)

    if app_logger is not None:
        method = getattr(app_logger, level, None)
        if callable(method):
            if exc is not None:
                method(message, exc=exc, **kwargs)
            else:
                method(message, **kwargs)
            return

    fallback_logger = getattr(context, "logger", None)
    if fallback_logger is None:
        return

    suffix = f": {exc}" if exc is not None else ""
    if level == "info":
        fallback_logger.info("%s%s", message, suffix)
    elif level == "warn":
        fallback_logger.warning("%s%s", message, suffix)
    elif level == "error":
        fallback_logger.error(message, exc_info=exc)
    else:
        fallback_logger.critical(message, exc_info=exc)


def add_common_worker_args(
    parser: argparse.ArgumentParser,
    *,
    max_concurrent_default: int = 1,
    heartbeat_interval_default: str = "30 seconds",
    lease_duration_default: str = "5 minutes",
    drain_timeout_default: float = 30.0,
) -> argparse.ArgumentParser:
    parser.add_argument("--worker-id", default=None, help="Exact worker_id override for secure_task_scheduler")
    parser.add_argument(
        "--max-concurrent-tasks",
        type=int,
        default=max_concurrent_default,
        help=f"Maximum in-flight tasks for this process (default: {max_concurrent_default})",
    )
    parser.add_argument(
        "--heartbeat-interval",
        default=heartbeat_interval_default,
        help=f"Worker heartbeat interval (default: {heartbeat_interval_default})",
    )
    parser.add_argument(
        "--lease-duration",
        default=lease_duration_default,
        help=f"Task lease duration and heartbeat extension interval (default: {lease_duration_default})",
    )
    parser.add_argument(
        "--drain-timeout",
        type=float,
        default=drain_timeout_default,
        help=f"Seconds to wait for in-flight tasks during shutdown (default: {drain_timeout_default})",
    )
    parser.add_argument("--runtime-variable-ttl-config", default=None, help=argparse.SUPPRESS)
    return parser
