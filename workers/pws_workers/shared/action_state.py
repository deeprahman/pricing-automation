from __future__ import annotations

import dataclasses
from datetime import datetime, timezone
from typing import Any, Dict, Optional


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


@dataclasses.dataclass(slots=True)
class StepCheckpoint:
    completed_at: str
    data: Dict[str, Any]


@dataclasses.dataclass(slots=True)
class AttemptError:
    attempt: int
    failed_at_step: str
    error: str
    failed_at: str


@dataclasses.dataclass(slots=True)
class ActionProgress:
    items_total: int
    items_processed: int
    last_processed_id: Optional[Any]
    percent_complete: float


@dataclasses.dataclass(slots=True)
class ActionState:
    action: str
    task_id: Optional[int]
    task_uuid: Optional[str]
    attempt: int
    started_at: str
    last_updated_at: Optional[str]
    current_step: Optional[str]
    completed_steps: list[str]
    checkpoints: Dict[str, StepCheckpoint]
    progress: Optional[ActionProgress]
    error_history: list[AttemptError]


class ActionStateManager:
    def __init__(self, context, task, state: ActionState, *, enabled: bool) -> None:
        self.context = context
        self.task = task
        self.state = state
        self.enabled = enabled

    @classmethod
    def load(cls, context, task) -> "ActionStateManager":
        action = str((getattr(task, "payload", {}) or {}).get("action") or "unknown")
        task_id = getattr(task, "task_id", None)
        task_uuid = getattr(task, "task_uuid", None)
        attempt = int(getattr(task, "attempts", 0) or 0)
        now = utc_now_iso()

        enabled = bool(
            task_id
            and getattr(context, "scheduler", None) is not None
            and hasattr(context.scheduler, "get_task_metadata")
            and hasattr(context.scheduler, "patch_task_metadata")
        )
        raw_state: Dict[str, Any] = {}
        if enabled:
            try:
                metadata = context.scheduler.get_task_metadata(int(task_id))
                if isinstance(metadata, dict):
                    raw_state = metadata.get("action_state") or {}
            except Exception as exc:
                app_logger = getattr(context, "app_logger", None)
                if app_logger is not None:
                    app_logger.warn(
                        "Action state unavailable",
                        exc=exc,
                        action_name="action_state",
                        task_id=int(task_id),
                        task_uuid=str(task_uuid) if task_uuid is not None else None,
                    )
                else:
                    logger = getattr(context, "logger", None)
                    if logger is not None:
                        logger.warning("Action state unavailable for task %s: %s", task_id, exc)
                enabled = False

        existing = raw_state if isinstance(raw_state, dict) and raw_state.get("action") == action else {}
        previous_attempt = int(existing.get("attempt") or 0)
        started_at = existing.get("started_at") if previous_attempt == attempt else now
        state = ActionState(
            action=action,
            task_id=int(task_id) if task_id is not None else None,
            task_uuid=str(task_uuid) if task_uuid is not None else None,
            attempt=attempt,
            started_at=str(started_at or now),
            last_updated_at=now,
            current_step=existing.get("current_step"),
            completed_steps=[str(value) for value in existing.get("completed_steps") or []],
            checkpoints=_load_checkpoints(existing.get("checkpoints")),
            progress=_load_progress(existing.get("progress")),
            error_history=_load_errors(existing.get("error_history")),
        )
        manager = cls(context, task, state, enabled=enabled)
        manager._persist(log_history=False)
        return manager

    def is_step_done(self, step: str) -> bool:
        return step in self.state.checkpoints

    def get_step_data(self, step: str) -> Dict[str, Any]:
        checkpoint = self.state.checkpoints.get(step)
        if checkpoint is None:
            raise KeyError(step)
        return dict(checkpoint.data)

    def begin_step(self, step: str) -> None:
        self.state.current_step = step
        self.state.last_updated_at = utc_now_iso()
        self._persist(log_history=False)

    def checkpoint(self, step: str, data: Optional[Dict[str, Any]] = None) -> None:
        completed_at = utc_now_iso()
        self.state.current_step = step
        self.state.last_updated_at = completed_at
        if step not in self.state.completed_steps:
            self.state.completed_steps.append(step)
        self.state.checkpoints[step] = StepCheckpoint(completed_at=completed_at, data=dict(data or {}))
        self._persist(log_history=True)

    def set_progress(
        self,
        *,
        items_total: int,
        items_processed: int,
        last_processed_id: Optional[Any],
    ) -> None:
        percent = 0.0
        if items_total > 0:
            percent = round((float(items_processed) / float(items_total)) * 100.0, 2)
        self.state.progress = ActionProgress(
            items_total=int(items_total),
            items_processed=int(items_processed),
            last_processed_id=last_processed_id,
            percent_complete=percent,
        )
        self.state.last_updated_at = utc_now_iso()
        self._persist(log_history=False)

    def get_resume_cursor(self) -> Optional[Any]:
        return None if self.state.progress is None else self.state.progress.last_processed_id

    def record_failure(self, step: str, error: str) -> None:
        failed_at = utc_now_iso()
        self.state.current_step = step
        self.state.last_updated_at = failed_at
        self.state.error_history.append(
            AttemptError(
                attempt=self.state.attempt,
                failed_at_step=step,
                error=str(error),
                failed_at=failed_at,
            )
        )
        self._persist(log_history=True)

    def _persist(self, *, log_history: bool) -> None:
        if not self.enabled or self.state.task_id is None:
            return
        patch = {"action_state": _dump_state(self.state)}
        self.context.scheduler.patch_task_metadata(
            self.state.task_id,
            patch,
            log_history=log_history,
            deep_merge=True,
        )


def _load_checkpoints(raw: Any) -> Dict[str, StepCheckpoint]:
    if not isinstance(raw, dict):
        return {}
    result: Dict[str, StepCheckpoint] = {}
    for step, payload in raw.items():
        if not isinstance(payload, dict):
            continue
        result[str(step)] = StepCheckpoint(
            completed_at=str(payload.get("completed_at") or utc_now_iso()),
            data=dict(payload.get("data") or {}),
        )
    return result


def _load_progress(raw: Any) -> Optional[ActionProgress]:
    if not isinstance(raw, dict):
        return None
    return ActionProgress(
        items_total=int(raw.get("items_total") or 0),
        items_processed=int(raw.get("items_processed") or 0),
        last_processed_id=raw.get("last_processed_id"),
        percent_complete=float(raw.get("percent_complete") or 0.0),
    )


def _load_errors(raw: Any) -> list[AttemptError]:
    if not isinstance(raw, list):
        return []
    errors: list[AttemptError] = []
    for entry in raw:
        if not isinstance(entry, dict):
            continue
        errors.append(
            AttemptError(
                attempt=int(entry.get("attempt") or 0),
                failed_at_step=str(entry.get("failed_at_step") or "unknown"),
                error=str(entry.get("error") or ""),
                failed_at=str(entry.get("failed_at") or utc_now_iso()),
            )
        )
    return errors


def _dump_state(state: ActionState) -> Dict[str, Any]:
    checkpoints = {
        step: {
            "completed_at": checkpoint.completed_at,
            "data": dict(checkpoint.data),
        }
        for step, checkpoint in state.checkpoints.items()
    }
    progress = None
    if state.progress is not None:
        progress = {
            "items_total": state.progress.items_total,
            "items_processed": state.progress.items_processed,
            "last_processed_id": state.progress.last_processed_id,
            "percent_complete": state.progress.percent_complete,
        }
    return {
        "action": state.action,
        "task_id": state.task_id,
        "task_uuid": state.task_uuid,
        "attempt": state.attempt,
        "started_at": state.started_at,
        "last_updated_at": state.last_updated_at,
        "current_step": state.current_step,
        "completed_steps": list(state.completed_steps),
        "checkpoints": checkpoints,
        "progress": progress,
        "error_history": [
            {
                "attempt": error.attempt,
                "failed_at_step": error.failed_at_step,
                "error": error.error,
                "failed_at": error.failed_at,
            }
            for error in state.error_history
        ],
    }
