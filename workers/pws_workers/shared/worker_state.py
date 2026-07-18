from __future__ import annotations

import dataclasses
import os
import socket
import time
from datetime import datetime, timezone
from typing import Any, Dict, Optional


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


@dataclasses.dataclass(slots=True)
class WorkerState:
    hostname: str
    pid: int
    started_at: str
    last_checkpoint_at: Optional[str]
    lease_duration: str
    poll_interval_s: float
    drain_timeout_s: float
    heartbeat_interval: str
    max_concurrent_tasks: int
    status: str
    shutdown_requested: bool
    current_load: int
    in_flight_task_ids: list[int]
    last_heartbeat_at: Optional[str]
    consecutive_hb_failures: int
    session_tasks_completed: int
    session_tasks_failed: int
    was_clean_shutdown: bool
    interrupted_task_ids: list[int]
    recovery_attempted_at: Optional[str]
    recovery_notes: Optional[str]


class WorkerStateManager:
    CHECKPOINT_PERSIST_INTERVAL_SECONDS = 5 * 60

    def __init__(self, scheduler) -> None:
        self.scheduler = scheduler
        self.state: Optional[WorkerState] = None
        self._metadata_enabled = hasattr(scheduler, "patch_worker_metadata") and hasattr(scheduler, "get_worker_metadata")
        self._last_checkpoint_persist_at = 0.0
        self._last_checkpoint_signature: Optional[tuple[str, tuple[int, ...], bool]] = None

    def boot(self, context) -> Optional[Dict[str, Any]]:
        previous: Dict[str, Any] = {}
        if self._metadata_enabled:
            try:
                previous = self.scheduler.get_worker_metadata()
            except Exception as exc:
                app_logger = getattr(context, "app_logger", None)
                if app_logger is not None:
                    app_logger.warn(
                        "Worker metadata unavailable during boot",
                        exc=exc,
                        action_name="worker_boot",
                    )
                else:
                    context.logger.warning("Worker metadata unavailable during boot: %s", exc)
                self._metadata_enabled = False

        previous_recovery = previous.get("crash_recovery") if isinstance(previous, dict) else {}
        interrupted = []
        previous_crash = None
        if isinstance(previous_recovery, dict) and previous_recovery.get("was_clean_shutdown") is False:
            runtime_state = previous.get("runtime_state") if isinstance(previous.get("runtime_state"), dict) else {}
            interrupted = [
                int(task_id)
                for task_id in (previous_recovery.get("interrupted_task_ids") or runtime_state.get("in_flight_task_ids") or [])
                if task_id is not None
            ]
            previous_crash = previous

        now = utc_now_iso()
        self.state = WorkerState(
            hostname=socket.gethostname(),
            pid=os.getpid(),
            started_at=now,
            last_checkpoint_at=None,
            lease_duration=str(context.lease_duration),
            poll_interval_s=float(context.poll_interval),
            drain_timeout_s=float(context.drain_timeout),
            heartbeat_interval=str(context.heartbeat_interval),
            max_concurrent_tasks=int(context.max_concurrent_tasks),
            status="running",
            shutdown_requested=False,
            current_load=0,
            in_flight_task_ids=[],
            last_heartbeat_at=None,
            consecutive_hb_failures=0,
            session_tasks_completed=0,
            session_tasks_failed=0,
            was_clean_shutdown=False,
            interrupted_task_ids=interrupted,
            recovery_attempted_at=now if previous_crash else None,
            recovery_notes="previous process terminated without clean shutdown" if previous_crash else None,
        )
        self._persist(audit=True)
        return previous_crash

    def checkpoint(self, *, in_flight_task_ids: list[int], current_load: int) -> None:
        if self.state is None:
            return
        now = utc_now_iso()
        normalized_task_ids = [int(task_id) for task_id in in_flight_task_ids]
        status = "draining" if self.state.shutdown_requested else "running"
        signature = (status, tuple(normalized_task_ids), bool(self.state.shutdown_requested))
        self.state.last_checkpoint_at = now
        self.state.last_heartbeat_at = now
        self.state.current_load = int(current_load)
        self.state.in_flight_task_ids = normalized_task_ids
        self.state.status = status
        self.state.interrupted_task_ids = list(self.state.in_flight_task_ids)
        monotonic_now = time.monotonic()
        if (
            signature != self._last_checkpoint_signature
            or monotonic_now - self._last_checkpoint_persist_at >= self.CHECKPOINT_PERSIST_INTERVAL_SECONDS
        ):
            self._persist(audit=False)
            self._last_checkpoint_signature = signature
            self._last_checkpoint_persist_at = monotonic_now

    def record_task_completed(self) -> None:
        if self.state is None:
            return
        self.state.session_tasks_completed += 1
        self._persist(audit=True)

    def record_task_failed(self) -> None:
        if self.state is None:
            return
        self.state.session_tasks_failed += 1
        self._persist(audit=True)

    def shutdown(self, draining: bool = False) -> None:
        if self.state is None:
            return
        self.state.shutdown_requested = True
        self.state.status = "stopped" if not draining else "draining"
        self.state.current_load = 0
        self.state.in_flight_task_ids = []
        self.state.was_clean_shutdown = True
        self._persist(audit=True)

    def _persist(self, *, audit: bool) -> None:
        if not self._metadata_enabled or self.state is None:
            return
        self.scheduler.patch_worker_metadata(_dump_state(self.state), deep_merge=True, audit=audit)


def _dump_state(state: WorkerState) -> Dict[str, Any]:
    return {
        "process": {
            "hostname": state.hostname,
            "pid": state.pid,
            "started_at": state.started_at,
            "last_checkpoint_at": state.last_checkpoint_at,
        },
        "resolved_config": {
            "lease_duration": state.lease_duration,
            "poll_interval_s": state.poll_interval_s,
            "drain_timeout_s": state.drain_timeout_s,
            "heartbeat_interval": state.heartbeat_interval,
            "max_concurrent_tasks": state.max_concurrent_tasks,
        },
        "runtime_state": {
            "status": state.status,
            "shutdown_requested": state.shutdown_requested,
            "current_load": state.current_load,
            "in_flight_task_ids": list(state.in_flight_task_ids),
            "last_heartbeat_at": state.last_heartbeat_at,
            "consecutive_hb_failures": state.consecutive_hb_failures,
        },
        "session_stats": {
            "tasks_completed": state.session_tasks_completed,
            "tasks_failed": state.session_tasks_failed,
        },
        "crash_recovery": {
            "was_clean_shutdown": state.was_clean_shutdown,
            "interrupted_task_ids": list(state.interrupted_task_ids),
            "recovery_attempted_at": state.recovery_attempted_at,
            "recovery_notes": state.recovery_notes,
        },
    }
