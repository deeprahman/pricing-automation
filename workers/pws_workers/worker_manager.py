#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import logging
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional, Sequence
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

CURRENT_DIR = Path(__file__).resolve().parent
WORKERS_ROOT = CURRENT_DIR.parent
REPO_ROOT = CURRENT_DIR.parents[1]
DEFAULT_MANIFEST_PATH = CURRENT_DIR / "worker_manifest.json"
DEFAULT_LOG_DIR = REPO_ROOT / "output" / "worker-logs"
DEFAULT_CONTAINER_NAME = "n8n-postgres"
DEFAULT_SCHEMA_SCRIPT_PATH = "/docker-entrypoint-initdb.d/00-run-schemas.sh"
DEFAULT_SCAN_LIMIT = 25
VALID_RECURRENCE_PATTERNS = {"hourly", "daily", "weekly", "monthly"}
TIME_OF_DAY_PATTERN = re.compile(r"^(?:[01]\d|2[0-3]):[0-5]\d(?::[0-5]\d)?$")
ACTIVE_TASK_STATUSES = ("pending", "scheduled", "processing", "retrying")
MANAGER_SEED_WORKER_ID = "worker-manager-seeder"
MANIFEST_SEED_CHECK_INTERVAL_SECONDS = 6 * 60 * 60
MANAGER_STATE_ID = "default"
MANAGER_STATE_UPDATE_INTERVAL_SECONDS = 30
POSTGRES_TABLE_COMPACTION_ACTION = "postgres_table_compaction"
DEFAULT_POSTGRES_COMPACTION_TABLES = (
    "public.task_metadata_history",
    "public.app_logs",
    "public.audit_log",
    "public.task_queue",
    "public.runtime_variables",
)
SQL_IDENTIFIER_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

for candidate in (WORKERS_ROOT, REPO_ROOT):
    if str(candidate) not in sys.path:
        sys.path.insert(0, str(candidate))

from pws_workers.shared.runtime import parse_runtime_variable_ttl_config
from pws_workers.shared.worker_runtime import build_dsn, connect


@dataclass(frozen=True)
class SeedScheduleConfig:
    action: str
    recurrence_pattern: str
    limit: int = DEFAULT_SCAN_LIMIT
    first_run_immediate: bool = True
    time_of_day: Optional[str] = None
    timezone: Optional[str] = None
    payload: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class StartupSeedConfig:
    action: str
    limit: int = DEFAULT_SCAN_LIMIT


@dataclass(frozen=True)
class WorkerManifestEntry:
    name: str
    primary_queue: str
    subscribed_queues: tuple[str, ...]
    script_path: Path
    args: tuple[str, ...]
    log_prefix: str
    startup_delay_seconds: float
    seed_schedule: Optional[SeedScheduleConfig] = None
    seed_schedules: tuple[SeedScheduleConfig, ...] = ()
    startup_seed: Optional[StartupSeedConfig] = None
    runtime_variable_ttl_config: Optional[dict[str, Any]] = None
    enabled: bool = True


@dataclass(frozen=True)
class MaintenanceActionConfig:
    """Configuration for a maintenance action."""
    name: str
    enabled: bool = True
    interval_minutes: int = 60  # Default: run every hour
    first_run_immediate: bool = True
    payload: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class MaintenanceConfig:
    reset_interval_seconds: int = 60
    log_prefix: str = "worker-maintenance"
    actions: tuple[MaintenanceActionConfig, ...] = ()


@dataclass(frozen=True)
class WorkerManifest:
    path: Path
    workers: tuple[WorkerManifestEntry, ...]
    maintenance: MaintenanceConfig
    runtime_variable_ttl_config: Optional[dict[str, Any]] = None


@dataclass(frozen=True)
class ManagedProcess:
    name: str
    process_id: int
    command_line: str
    kind: str


@dataclass(frozen=True)
class SupervisionOutcome:
    database_available: bool
    database_error: Optional[str]
    started_workers: tuple[str, ...]
    stopped_workers: tuple[str, ...]
    maintenance_started: bool
    maintenance_stopped: bool
    running_workers: tuple[str, ...] = ()
    maintenance_running: bool = False
    maintenance_pid: Optional[int] = None
    seed_checked: bool = False
    seed_success: Optional[bool] = None
    seed_error: Optional[str] = None


def _parse_dotenv(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    if not path.exists():
        return env
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        env[key.strip()] = value.strip().strip('"').strip("'")
    return env


def load_repo_env(repo_root: Path = REPO_ROOT) -> dict[str, str]:
    env: dict[str, str] = {}
    for path in (repo_root / ".env", repo_root / ".env.prod", repo_root / ".env.local"):
        env.update(_parse_dotenv(path))
    env.update(os.environ)
    return env


def resolve_log_level(env: Optional[dict[str, str]] = None) -> int:
    source = env if env is not None else load_repo_env(REPO_ROOT)
    level_name = str(source.get("LOG_LEVEL") or "INFO").strip().upper()
    resolved = getattr(logging, level_name, None)
    return resolved if isinstance(resolved, int) else logging.INFO


def normalize_path_text(value: str | Path | None) -> str:
    if value is None:
        return ""
    text = str(value)
    return text.replace("/", "\\").lower() if os.name == "nt" else text.replace("\\", "/")


def resolve_full_path(base_path: Path, raw_path: str) -> Path:
    candidate = Path(raw_path)
    return candidate.resolve() if candidate.is_absolute() else (base_path / candidate).resolve()


def _parse_manifest_bool(value: Any, *, field_name: str) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        lowered = value.strip().lower()
        if lowered in {"true", "1", "yes", "on"}:
            return True
        if lowered in {"false", "0", "no", "off"}:
            return False
    raise ValueError(f"{field_name} must be a boolean")


def _env_flag_enabled(name: str) -> bool:
    value = os.environ.get(name)
    if value is None or str(value).strip() == "":
        return False
    return _parse_manifest_bool(value, field_name=name)


def _parse_seed_schedule(raw_seed: Any, *, worker_name: str, field_name: str = "seed_schedule") -> Optional[SeedScheduleConfig]:
    if raw_seed is None:
        return None
    if not isinstance(raw_seed, dict):
        raise ValueError(f"Manifest worker '{worker_name}' has invalid '{field_name}'")

    action = str(raw_seed.get("action") or "").strip()
    if not action:
        raise ValueError(f"Manifest worker '{worker_name}' {field_name} requires 'action'")

    recurrence_pattern = str(raw_seed.get("recurrence_pattern") or "").strip().lower()
    if not recurrence_pattern:
        raise ValueError(f"Manifest worker '{worker_name}' {field_name} requires 'recurrence_pattern'")
    if recurrence_pattern not in VALID_RECURRENCE_PATTERNS:
        allowed = ", ".join(sorted(VALID_RECURRENCE_PATTERNS))
        raise ValueError(
            f"Manifest worker '{worker_name}' {field_name} has invalid recurrence_pattern '{recurrence_pattern}'. "
            f"Allowed values: {allowed}"
        )

    raw_limit = raw_seed.get("limit", DEFAULT_SCAN_LIMIT)
    try:
        limit = int(raw_limit)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"Manifest worker '{worker_name}' {field_name} limit must be an integer") from exc
    if limit < 1:
        raise ValueError(f"Manifest worker '{worker_name}' {field_name} limit must be >= 1")

    if "first_run_immediate" in raw_seed:
        first_run_immediate = _parse_manifest_bool(
            raw_seed.get("first_run_immediate"),
            field_name=f"{field_name}.first_run_immediate",
        )
    else:
        first_run_immediate = True

    raw_time_of_day = raw_seed.get("time_of_day")
    if raw_time_of_day is None:
        time_of_day: Optional[str] = None
    elif isinstance(raw_time_of_day, str):
        time_of_day = raw_time_of_day.strip()
        if not time_of_day:
            raise ValueError(f"Manifest worker '{worker_name}' {field_name} time_of_day must not be empty")
        if TIME_OF_DAY_PATTERN.fullmatch(time_of_day) is None:
            raise ValueError(
                f"Manifest worker '{worker_name}' {field_name} time_of_day must use HH:MM or HH:MM:SS (24-hour)"
            )
    else:
        raise ValueError(f"Manifest worker '{worker_name}' {field_name} time_of_day must be a string")

    raw_timezone = raw_seed.get("timezone")
    if raw_timezone is None:
        timezone: Optional[str] = None
    elif isinstance(raw_timezone, str):
        timezone = raw_timezone.strip()
        if not timezone:
            raise ValueError(f"Manifest worker '{worker_name}' {field_name} timezone must not be empty")
        try:
            ZoneInfo(timezone)
        except ZoneInfoNotFoundError as exc:
            raise ValueError(f"Manifest worker '{worker_name}' {field_name} timezone '{timezone}' is invalid") from exc
    else:
        raise ValueError(f"Manifest worker '{worker_name}' {field_name} timezone must be a string")

    if (time_of_day is None) != (timezone is None):
        raise ValueError(
            f"Manifest worker '{worker_name}' {field_name} requires both time_of_day and timezone when either is set"
        )
    if time_of_day is not None and recurrence_pattern not in {"daily", "weekly", "monthly"}:
        raise ValueError(
            f"Manifest worker '{worker_name}' {field_name} time_of_day/timezone is only supported for daily, weekly, or monthly recurrence_pattern"
        )

    raw_payload = raw_seed.get("payload")
    if raw_payload is None:
        payload: dict[str, Any] = {}
    elif isinstance(raw_payload, dict):
        payload = dict(raw_payload)
    else:
        raise ValueError(f"Manifest worker '{worker_name}' {field_name} payload must be an object")
    if "action" in payload or "limit" in payload:
        raise ValueError(
            f"Manifest worker '{worker_name}' {field_name} payload must not override reserved keys: action, limit"
        )

    return SeedScheduleConfig(
        action=action,
        recurrence_pattern=recurrence_pattern,
        limit=limit,
        first_run_immediate=first_run_immediate,
        time_of_day=time_of_day,
        timezone=timezone,
        payload=payload,
    )


def _parse_seed_schedules(raw_schedules: Any, *, worker_name: str) -> tuple[SeedScheduleConfig, ...]:
    if raw_schedules is None:
        return ()
    if not isinstance(raw_schedules, list):
        raise ValueError(f"Manifest worker '{worker_name}' has invalid 'seed_schedules'")
    if not raw_schedules:
        raise ValueError(f"Manifest worker '{worker_name}' seed_schedules must not be empty")

    parsed: list[SeedScheduleConfig] = []
    for index, raw_seed in enumerate(raw_schedules):
        if raw_seed is None:
            raise ValueError(f"Manifest worker '{worker_name}' seed_schedules[{index}] must be an object")
        schedule = _parse_seed_schedule(raw_seed, worker_name=worker_name, field_name=f"seed_schedules[{index}]")
        if schedule is None:
            continue
        parsed.append(schedule)
    return tuple(parsed)


def _parse_startup_seed(raw_seed: Any, *, worker_name: str) -> Optional[StartupSeedConfig]:
    if raw_seed is None:
        return None
    if not isinstance(raw_seed, dict):
        raise ValueError(f"Manifest worker '{worker_name}' has invalid 'startup_seed'")

    action = str(raw_seed.get("action") or "").strip()
    if not action:
        raise ValueError(f"Manifest worker '{worker_name}' startup_seed requires 'action'")

    raw_limit = raw_seed.get("limit", DEFAULT_SCAN_LIMIT)
    try:
        limit = int(raw_limit)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"Manifest worker '{worker_name}' startup_seed limit must be an integer") from exc
    if limit < 1:
        raise ValueError(f"Manifest worker '{worker_name}' startup_seed limit must be >= 1")

    return StartupSeedConfig(action=action, limit=limit)


def _parse_maintenance_actions(raw_actions: Any) -> tuple[MaintenanceActionConfig, ...]:
    """Parse maintenance actions from manifest."""
    if raw_actions is None:
        return ()
    if not isinstance(raw_actions, list):
        raise ValueError("maintenance.actions must be an array")

    parsed_actions: list[MaintenanceActionConfig] = []
    for index, raw_action in enumerate(raw_actions):
        if not isinstance(raw_action, dict):
            raise ValueError(f"maintenance.actions[{index}] must be an object")

        action_name = str(raw_action.get("name") or "").strip()
        if not action_name:
            raise ValueError(f"maintenance.actions[{index}] must have a 'name'")

        try:
            interval_minutes = int(raw_action.get("interval_minutes") or 60)
            if interval_minutes < 1:
                raise ValueError(f"maintenance.actions[{index}] interval_minutes must be >= 1")
        except (TypeError, ValueError) as exc:
            raise ValueError(f"maintenance.actions[{index}] interval_minutes must be an integer >= 1") from exc

        raw_payload = raw_action.get("payload")
        if raw_payload is None:
            payload: dict[str, Any] = {}
        elif isinstance(raw_payload, dict):
            payload = dict(raw_payload)
        else:
            raise ValueError(f"maintenance.actions[{index}] payload must be an object")

        parsed_actions.append(
            MaintenanceActionConfig(
                name=action_name,
                enabled=_parse_manifest_bool(
                    raw_action.get("enabled", True),
                    field_name=f"maintenance.actions[{index}].enabled",
                ),
                interval_minutes=interval_minutes,
                first_run_immediate=_parse_manifest_bool(
                    raw_action.get("first_run_immediate", True),
                    field_name=f"maintenance.actions[{index}].first_run_immediate",
                ),
                payload=payload,
            )
        )

    return tuple(parsed_actions)

def _merge_runtime_variable_ttl_action_configs(
    base: Optional[dict[str, Any]],
    override: Optional[dict[str, Any]],
) -> Optional[dict[str, Any]]:
    base_cfg = base or {}
    override_cfg = override or {}
    merged: dict[str, Any] = {}

    default_ttl = override_cfg.get("default_ttl_minutes", base_cfg.get("default_ttl_minutes"))
    if default_ttl is not None:
        merged["default_ttl_minutes"] = int(default_ttl)

    by_scope = dict(base_cfg.get("by_scope") or {})
    by_scope.update(override_cfg.get("by_scope") or {})
    if by_scope:
        merged["by_scope"] = by_scope

    return merged or None


def merge_runtime_variable_ttl_configs(
    base: Optional[dict[str, Any]],
    override: Optional[dict[str, Any]],
) -> Optional[dict[str, Any]]:
    merged = _merge_runtime_variable_ttl_action_configs(base, override) or {}
    base_actions = dict((base or {}).get("by_action") or {})
    override_actions = dict((override or {}).get("by_action") or {})

    by_action: dict[str, Any] = {}
    for action_name in dict.fromkeys([*base_actions.keys(), *override_actions.keys()]):
        action_config = _merge_runtime_variable_ttl_action_configs(
            base_actions.get(action_name),
            override_actions.get(action_name),
        )
        if action_config:
            by_action[action_name] = action_config

    if by_action:
        merged["by_action"] = by_action

    return merged or None


def build_runtime_variable_ttl_launch_args(config: Optional[dict[str, Any]]) -> list[str]:
    if not config:
        return []
    return ["--runtime-variable-ttl-config", json.dumps(config, separators=(",", ":"), sort_keys=True)]


def load_manifest(path: str | Path = DEFAULT_MANIFEST_PATH) -> WorkerManifest:
    manifest_path = resolve_full_path(REPO_ROOT, str(path))
    raw = json.loads(manifest_path.read_text(encoding="utf-8"))
    base_path = manifest_path.parent

    if isinstance(raw, list):
        raw_workers = raw
        raw_maintenance: dict[str, Any] = {}
    elif isinstance(raw, dict):
        raw_workers = raw.get("workers") or []
        raw_maintenance = raw.get("maintenance") or {}
    else:
        raise ValueError(f"Manifest must be a JSON object or array: {manifest_path}")

    runtime_variable_ttl_config = parse_runtime_variable_ttl_config(
        raw.get("runtime_variables") if isinstance(raw, dict) else None
    )

    workers: list[WorkerManifestEntry] = []
    for raw_entry in raw_workers:
        if not isinstance(raw_entry, dict):
            raise ValueError("Each manifest worker entry must be an object")
        name = str(raw_entry.get("name") or "").strip()
        script_path = str(raw_entry.get("script_path") or "").strip()
        if not name or not script_path:
            raise ValueError("Manifest entries require both 'name' and 'script_path'")
        primary_queue = str(raw_entry.get("primary_queue") or name).strip() or name
        raw_subscribed_queues = raw_entry.get("subscribed_queues") or [primary_queue]
        if not isinstance(raw_subscribed_queues, list) or not all(isinstance(value, str) and value.strip() for value in raw_subscribed_queues):
            raise ValueError(f"Manifest worker '{name}' has invalid 'subscribed_queues'")
        subscribed_queues = tuple(dict.fromkeys([primary_queue, *(value.strip() for value in raw_subscribed_queues if value.strip())]))
        args = raw_entry.get("args") or []
        if not isinstance(args, list) or not all(isinstance(value, str) for value in args):
            raise ValueError(f"Manifest worker '{name}' has invalid 'args'")
        has_seed_schedule = "seed_schedule" in raw_entry and raw_entry.get("seed_schedule") is not None
        has_seed_schedules = "seed_schedules" in raw_entry and raw_entry.get("seed_schedules") is not None
        if has_seed_schedule and has_seed_schedules:
            raise ValueError(f"Manifest worker '{name}' must not define both 'seed_schedule' and 'seed_schedules'")

        seed_schedule = _parse_seed_schedule(raw_entry.get("seed_schedule"), worker_name=name)
        seed_schedules = _parse_seed_schedules(raw_entry.get("seed_schedules"), worker_name=name)
        if not seed_schedules and seed_schedule is not None:
            seed_schedules = (seed_schedule,)
        startup_seed = _parse_startup_seed(raw_entry.get("startup_seed"), worker_name=name)
        worker_runtime_ttl_config = merge_runtime_variable_ttl_configs(
            runtime_variable_ttl_config,
            parse_runtime_variable_ttl_config(raw_entry.get("runtime_variables")),
        )
        workers.append(
            WorkerManifestEntry(
                name=name,
                primary_queue=primary_queue,
                subscribed_queues=subscribed_queues,
                script_path=resolve_full_path(base_path, script_path),
                args=tuple(args),
                log_prefix=str(raw_entry.get("log_prefix") or name).strip() or name,
                startup_delay_seconds=float(raw_entry.get("startup_delay_seconds") or 2.0),
                seed_schedule=seed_schedule,
                seed_schedules=seed_schedules,
                startup_seed=startup_seed,
                runtime_variable_ttl_config=worker_runtime_ttl_config,
                enabled=_parse_manifest_bool(raw_entry.get("enabled", True), field_name=f"Manifest worker '{name}' enabled"),
            )
        )

    maintenance = MaintenanceConfig(
        reset_interval_seconds=max(1, int(raw_maintenance.get("reset_interval_seconds", 60))),
        log_prefix=str(raw_maintenance.get("log_prefix") or "worker-maintenance").strip() or "worker-maintenance",
        actions=_parse_maintenance_actions(raw_maintenance.get("actions")),
    )
    return WorkerManifest(
        path=manifest_path,
        workers=tuple(workers),
        maintenance=maintenance,
        runtime_variable_ttl_config=runtime_variable_ttl_config,
    )


def select_manifest_workers(
    manifest: WorkerManifest,
    include_names: Optional[Sequence[str]] = None,
    exclude_names: Optional[Sequence[str]] = None,
) -> list[WorkerManifestEntry]:
    include = {name.strip() for name in (include_names or []) if name and name.strip()}
    exclude = {name.strip() for name in (exclude_names or []) if name and name.strip()}
    known = {entry.name for entry in manifest.workers}

    unknown = sorted((include | exclude) - known)
    if unknown:
        available = ", ".join(sorted(known))
        raise ValueError(f"Unknown worker(s): {', '.join(unknown)}. Available workers: {available}")

    selected: list[WorkerManifestEntry] = []
    for entry in manifest.workers:
        if not entry.enabled:
            continue
        if include and entry.name not in include:
            continue
        if entry.name in exclude:
            continue
        selected.append(entry)
    return selected


def get_manifest_worker(manifest: WorkerManifest, name: str) -> WorkerManifestEntry:
    for entry in manifest.workers:
        if entry.name == name:
            return entry
    available = ", ".join(sorted(entry.name for entry in manifest.workers))
    raise ValueError(f"Unknown worker '{name}'. Available workers: {available}")


def collect_manifest_queue_names(workers: Sequence[WorkerManifestEntry]) -> list[str]:
    queue_names: list[str] = []
    seen: set[str] = set()
    for worker in workers:
        for queue_name in worker.subscribed_queues:
            if queue_name in seen:
                continue
            seen.add(queue_name)
            queue_names.append(queue_name)
    return queue_names


def resolve_worker_args(args_template: Sequence[str], target_db: str, resolved_log_dir: Path) -> list[str]:
    resolved: list[str] = []
    for value in args_template:
        if value == "{db}":
            resolved.append(target_db)
        elif value == "{logdir}":
            resolved.append(str(resolved_log_dir))
        else:
            resolved.append(value)
    return resolved


def quote_command(parts: Sequence[str]) -> str:
    return subprocess.list2cmdline(list(parts)) if os.name == "nt" else " ".join(subprocess.list2cmdline([part]) for part in parts)


def get_log_excerpt(path: Path, *, tail_lines: int = 20) -> str:
    if not path.exists():
        return ""
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    return "\n".join(lines[-tail_lines:]).strip()


def is_process_running(process_id: int) -> bool:
    for process in iter_processes():
        if process["pid"] == process_id:
            return True
    return False


def wait_for_process_exit(process_id: int, timeout_seconds: float) -> bool:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        if not is_process_running(process_id):
            return True
        time.sleep(0.25)
    return not is_process_running(process_id)


def _iter_processes_from_procfs() -> list[dict[str, Any]]:
    proc_root = Path("/proc")
    if not proc_root.exists():
        return []

    processes: list[dict[str, Any]] = []
    for entry in proc_root.iterdir():
        if not entry.is_dir() or not entry.name.isdigit():
            continue
        cmdline_path = entry / "cmdline"
        try:
            raw = cmdline_path.read_bytes()
        except OSError:
            continue
        if not raw:
            continue
        command_line = raw.replace(b"\x00", b" ").decode("utf-8", errors="replace").strip()
        lowered = command_line.lower()
        if "python" not in lowered and "py " not in lowered:
            continue
        processes.append({"pid": int(entry.name), "command_line": command_line})
    return processes


def iter_processes() -> list[dict[str, Any]]:
    if os.name == "nt":
        command = [
            "powershell",
            "-NoProfile",
            "-Command",
            (
                "Get-CimInstance Win32_Process "
                "-Filter \"Name = 'python.exe' OR Name = 'pythonw.exe' OR Name = 'py.exe'\" "
                "| Select-Object ProcessId, CommandLine | ConvertTo-Json -Compress"
            ),
        ]
        completed = subprocess.run(command, capture_output=True, text=True, check=False)
        if completed.returncode != 0:
            raise RuntimeError(completed.stderr.strip() or "Failed to inspect running Python processes")
        text = completed.stdout.strip()
        if not text:
            return []
        payload = json.loads(text)
        rows = payload if isinstance(payload, list) else [payload]
        return [
            {"pid": int(row.get("ProcessId")), "command_line": str(row.get("CommandLine") or "")}
            for row in rows
            if row.get("ProcessId") is not None
        ]

    if shutil.which("ps") is None:
        return _iter_processes_from_procfs()

    completed = subprocess.run(["ps", "-eo", "pid=,args="], capture_output=True, text=True, check=False)
    if completed.returncode != 0:
        fallback = _iter_processes_from_procfs()
        if fallback:
            return fallback
        raise RuntimeError(completed.stderr.strip() or "Failed to inspect running processes")

    processes: list[dict[str, Any]] = []
    for line in completed.stdout.splitlines():
        raw = line.strip()
        if not raw:
            continue
        pid_text, _, command_line = raw.partition(" ")
        if not pid_text.isdigit():
            continue
        lowered = command_line.lower()
        if "python" not in lowered and "py " not in lowered:
            continue
        processes.append({"pid": int(pid_text), "command_line": command_line})
    return processes


def find_managed_worker_processes(workers: Sequence[WorkerManifestEntry]) -> list[ManagedProcess]:
    processes = iter_processes()
    matches: list[ManagedProcess] = []
    for process in processes:
        command_line = process["command_line"]
        normalized = normalize_path_text(command_line)
        if not normalized:
            continue
        for worker in workers:
            if normalize_path_text(worker.script_path) in normalized:
                matches.append(
                    ManagedProcess(
                        name=worker.name,
                        process_id=int(process["pid"]),
                        command_line=command_line,
                        kind="worker",
                    )
                )
                break
    return sorted(matches, key=lambda item: item.process_id)


def find_maintenance_processes(manager_script_path: Path) -> list[ManagedProcess]:
    script_token = normalize_path_text(manager_script_path)
    matches: list[ManagedProcess] = []
    for process in iter_processes():
        command_line = process["command_line"]
        normalized = normalize_path_text(command_line)
        if script_token in normalized and " maintenance" in normalized:
            matches.append(
                ManagedProcess(
                    name="worker-maintenance",
                    process_id=int(process["pid"]),
                    command_line=command_line,
                    kind="maintenance",
                )
            )
    return sorted(matches, key=lambda item: item.process_id)


def stop_process(process: ManagedProcess) -> None:
    if os.name == "nt":
        subprocess.run(["taskkill", "/PID", str(process.process_id), "/T"], check=False, capture_output=True, text=True)
        if wait_for_process_exit(process.process_id, 5.0):
            return
        subprocess.run(["taskkill", "/PID", str(process.process_id), "/T", "/F"], check=False, capture_output=True, text=True)
        if not wait_for_process_exit(process.process_id, 3.0):
            raise RuntimeError(f"Failed to stop {process.kind} '{process.name}' (PID {process.process_id})")
        return

    try:
        os.kill(process.process_id, signal.SIGTERM)
    except ProcessLookupError:
        return
    if wait_for_process_exit(process.process_id, 5.0):
        return
    os.kill(process.process_id, signal.SIGKILL)
    if not wait_for_process_exit(process.process_id, 3.0):
        raise RuntimeError(f"Failed to stop {process.kind} '{process.name}' (PID {process.process_id})")


def ensure_worker_scripts_exist(workers: Sequence[WorkerManifestEntry]) -> None:
    for worker in workers:
        if not worker.script_path.exists():
            raise FileNotFoundError(f"Managed worker script not found: {worker.script_path}")


def resolve_executable_path(command_name: str) -> str:
    resolved = shutil.which(command_name)
    if not resolved:
        raise FileNotFoundError(f"Executable not found on PATH: {command_name}")
    return resolved


def run_captured_command(command: Sequence[str], failure_message: str) -> str:
    completed = subprocess.run(command, capture_output=True, text=True, check=False)
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).strip()
        if detail:
            raise RuntimeError(f"{failure_message}\n{detail}")
        raise RuntimeError(f"{failure_message} Exit code: {completed.returncode}")
    return completed.stdout.strip()


def run_streaming_command(command: Sequence[str], failure_message: str) -> None:
    completed = subprocess.run(command, check=False)
    if completed.returncode != 0:
        raise RuntimeError(f"{failure_message} Exit code: {completed.returncode}")


def resolve_target_db_name(
    explicit_db_name: Optional[str],
    *,
    docker_path: Optional[str] = None,
    container_name: Optional[str] = None,
    prefer_container: bool = False,
) -> str:
    if explicit_db_name:
        return explicit_db_name
    if prefer_container and docker_path and container_name:
        try:
            resolved = run_captured_command(
                [docker_path, "exec", container_name, "bash", "-lc", 'printf "%s" "${SCHEMA_DB:-auto_pws}"'],
                f"Failed to resolve SCHEMA_DB from container '{container_name}'.",
            )
            if resolved:
                return resolved
        except RuntimeError:
            pass
    env = load_repo_env(REPO_ROOT)
    return env.get("SCHEMA_DB") or env.get("POSTGRES_DB") or "auto_pws"


def test_postgres_ready(docker_path: str, container_name: str, target_db: str) -> bool:
    completed = subprocess.run(
        [
            docker_path,
            "exec",
            "-e",
            f"TARGET_DB={target_db}",
            container_name,
            "bash",
            "-lc",
            'pg_isready -U "$POSTGRES_USER" -d "$TARGET_DB" >/dev/null',
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    return completed.returncode == 0


def assert_postgres_ready(docker_path: str, container_name: str, target_db: str, context: str) -> None:
    if not test_postgres_ready(docker_path, container_name, target_db):
        raise RuntimeError(f"Postgres is not ready for database '{target_db}' ({context}).")


def assert_container_running(docker_path: str, container_name: str) -> None:
    run_captured_command([docker_path, "inspect", container_name], f"Docker container not found: {container_name}")
    is_running = run_captured_command(
        [docker_path, "inspect", "-f", "{{.State.Running}}", container_name],
        f"Failed to inspect Docker container state: {container_name}",
    )
    if is_running.strip() != "true":
        raise RuntimeError(f"Docker container is not running: {container_name}")


def refresh_database(docker_path: str, container_name: str, schema_script_path: str, target_db: str) -> None:
    assert_container_running(docker_path, container_name)
    assert_postgres_ready(docker_path, container_name, target_db, "before schema reset")
    run_streaming_command(
        [docker_path, "exec", container_name, "bash", "-lc", schema_script_path],
        f"Schema reset failed using '{schema_script_path}' in container '{container_name}'.",
    )
    assert_postgres_ready(docker_path, container_name, target_db, "after schema reset")


def seed_database(docker_path: str, container_name: str, target_db: str, seed_path: Path) -> list[Path]:
    assert_container_running(docker_path, container_name)
    assert_postgres_ready(docker_path, container_name, target_db, "before loading seed data")
    if seed_path.is_file():
        seed_files = [seed_path]
    elif seed_path.is_dir():
        seed_files = sorted(path for path in seed_path.iterdir() if path.is_file() and path.suffix.lower() == ".sql")
    else:
        raise FileNotFoundError(f"Seed path not found: {seed_path}")

    if not seed_files:
        raise RuntimeError(f"No SQL seed files were found in: {seed_path}")

    for sql_file in seed_files:
        completed = subprocess.run(
            [
                docker_path,
                "exec",
                "-i",
                "-e",
                f"TARGET_DB={target_db}",
                container_name,
                "bash",
                "-lc",
                'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$TARGET_DB"',
            ],
            input=sql_file.read_bytes(),
            capture_output=True,
            check=False,
        )
        if completed.returncode != 0:
            stderr = completed.stderr.decode("utf-8", errors="replace").strip()
            raise RuntimeError(f"Failed to execute seed SQL file '{sql_file}' against database '{target_db}'.\n{stderr}")

    assert_postgres_ready(docker_path, container_name, target_db, "after loading seed data")
    return seed_files


def start_detached_process(
    command: Sequence[str],
    *,
    cwd: Path,
    stdout_log: Path,
    stderr_log: Path,
) -> subprocess.Popen[Any]:
    stdout_log.parent.mkdir(parents=True, exist_ok=True)
    for path in (stdout_log, stderr_log):
        if path.exists():
            path.unlink()

    creation_kwargs: dict[str, Any] = {
        "cwd": str(cwd),
        "stdin": subprocess.DEVNULL,
    }
    if os.name == "nt":
        creation_kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.DETACHED_PROCESS
    else:
        creation_kwargs["start_new_session"] = True

    with stdout_log.open("w", encoding="utf-8") as stdout_handle, stderr_log.open("w", encoding="utf-8") as stderr_handle:
        process = subprocess.Popen(
            list(command),
            stdout=stdout_handle,
            stderr=stderr_handle,
            **creation_kwargs,
        )
    return process


def start_worker(
    worker: WorkerManifestEntry,
    *,
    python_path: str,
    repo_root: Path,
    target_db: str,
    resolved_log_dir: Path,
) -> dict[str, Any]:
    worker_args = resolve_worker_args(worker.args, target_db, resolved_log_dir)
    worker_args.extend(build_runtime_variable_ttl_launch_args(worker.runtime_variable_ttl_config))
    command = [python_path, "-u", str(worker.script_path), *worker_args]
    stdout_log = resolved_log_dir / f"{worker.log_prefix}.out.log"
    stderr_log = resolved_log_dir / f"{worker.log_prefix}.err.log"
    process = start_detached_process(command, cwd=repo_root, stdout_log=stdout_log, stderr_log=stderr_log)

    time.sleep(worker.startup_delay_seconds)
    if process.poll() is not None:
        message = [f"Worker '{worker.name}' exited during startup."]
        stderr_excerpt = get_log_excerpt(stderr_log)
        stdout_excerpt = get_log_excerpt(stdout_log)
        if stderr_excerpt:
            message.append(f"stderr:\n{stderr_excerpt}")
        if stdout_excerpt:
            message.append(f"stdout:\n{stdout_excerpt}")
        raise RuntimeError("\n".join(message))

    return {
        "name": worker.name,
        "process_id": process.pid,
        "script_path": str(worker.script_path),
        "stdout_log": str(stdout_log),
        "stderr_log": str(stderr_log),
        "command": quote_command(command),
    }


def start_maintenance_process(
    *,
    python_path: str,
    manifest_path: Path,
    target_db: str,
    reset_interval_seconds: int,
    log_prefix: str,
    resolved_log_dir: Path,
) -> dict[str, Any]:
    command = [
        python_path,
        "-u",
        str(Path(__file__).resolve()),
        "maintenance",
        "--manifest",
        str(manifest_path),
        "--auto-dsn",
        "--db-name",
        target_db,
        "--interval-seconds",
        str(reset_interval_seconds),
    ]
    stdout_log = resolved_log_dir / f"{log_prefix}.out.log"
    stderr_log = resolved_log_dir / f"{log_prefix}.err.log"
    process = start_detached_process(command, cwd=REPO_ROOT, stdout_log=stdout_log, stderr_log=stderr_log)
    time.sleep(1.0)
    if process.poll() is not None:
        raise RuntimeError(f"Maintenance process exited during startup.\nstderr:\n{get_log_excerpt(stderr_log)}")
    return {
        "name": "worker-maintenance",
        "process_id": process.pid,
        "stdout_log": str(stdout_log),
        "stderr_log": str(stderr_log),
        "command": quote_command(command),
    }


def build_manager_dsn(args: argparse.Namespace) -> str:
    dsn = build_dsn(args.dsn, args.auto_dsn, db_name=args.db_name, repo_root=REPO_ROOT)
    if not dsn:
        raise RuntimeError("Unable to resolve a Postgres DSN. Use --dsn or configure .env, .env.prod, or .env.local.")
    return dsn


def probe_database(dsn: str) -> tuple[bool, Optional[str]]:
    try:
        with connect(dsn) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
                cur.fetchone()
        return True, None
    except Exception as exc:
        return False, str(exc)


WORKER_MANAGER_STATE_SCHEMA_STATEMENTS = (
    """
    CREATE TABLE IF NOT EXISTS worker_manager_state (
        manager_id VARCHAR(100) PRIMARY KEY DEFAULT 'default',
        supervisor_status TEXT NOT NULL DEFAULT 'unknown',
        supervisor_pid INTEGER,
        supervisor_started_at TIMESTAMPTZ,
        supervisor_last_seen_at TIMESTAMPTZ,
        database_available BOOLEAN,
        database_error TEXT,
        managed_workers_expected INTEGER NOT NULL DEFAULT 0,
        managed_workers_running INTEGER NOT NULL DEFAULT 0,
        managed_worker_names JSONB NOT NULL DEFAULT '[]'::JSONB,
        started_workers JSONB NOT NULL DEFAULT '[]'::JSONB,
        stopped_workers JSONB NOT NULL DEFAULT '[]'::JSONB,
        seed_check_interval_seconds INTEGER,
        last_seed_check_at TIMESTAMPTZ,
        last_seed_success BOOLEAN,
        last_seed_error TEXT,
        maintenance_enabled BOOLEAN,
        maintenance_status TEXT NOT NULL DEFAULT 'unknown',
        maintenance_pid INTEGER,
        maintenance_started_at TIMESTAMPTZ,
        maintenance_last_seen_at TIMESTAMPTZ,
        maintenance_interval_seconds INTEGER,
        maintenance_action_count INTEGER NOT NULL DEFAULT 0,
        maintenance_actions JSONB NOT NULL DEFAULT '[]'::JSONB,
        last_promote_count INTEGER,
        last_reset_count INTEGER,
        last_maintenance_action_at TIMESTAMPTZ,
        last_maintenance_action_name TEXT,
        last_maintenance_action_success BOOLEAN,
        last_maintenance_action_rows BIGINT,
        last_maintenance_action_duration_seconds NUMERIC,
        last_maintenance_action_error TEXT,
        last_maintenance_loop_error TEXT,
        manifest_path TEXT,
        db_name TEXT,
        log_dir TEXT,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """,
    """
    CREATE INDEX IF NOT EXISTS idx_worker_manager_state_supervisor_seen
    ON worker_manager_state (supervisor_last_seen_at DESC)
    """,
    """
    CREATE INDEX IF NOT EXISTS idx_worker_manager_state_maintenance_seen
    ON worker_manager_state (maintenance_last_seen_at DESC)
    """,
)


def ensure_worker_manager_state_schema(dsn: str, logger: Optional[logging.Logger] = None) -> bool:
    try:
        with connect(dsn) as conn:
            with conn.cursor() as cur:
                for statement in WORKER_MANAGER_STATE_SCHEMA_STATEMENTS:
                    cur.execute(statement)
        return True
    except Exception as exc:  # pragma: no cover - runtime environment dependent
        if logger is not None:
            logger.warning("Worker manager state table is unavailable: %s", exc)
        return False


def _json_param(value: Any) -> str:
    return json.dumps(value, default=str, separators=(",", ":"), sort_keys=True)


def _maintenance_actions_payload(actions: Sequence[MaintenanceActionConfig]) -> list[dict[str, Any]]:
    return [
        {
            "name": action.name,
            "enabled": action.enabled,
            "interval_minutes": action.interval_minutes,
            "first_run_immediate": action.first_run_immediate,
            "payload": action.payload,
        }
        for action in actions
    ]


def record_worker_manager_supervisor_state(
    dsn: str,
    *,
    outcome: SupervisionOutcome,
    selected_workers: Sequence[WorkerManifestEntry],
    running_worker_names: Sequence[str],
    maintenance_processes: Sequence[ManagedProcess],
    target_db: str,
    manifest_path: Path,
    resolved_log_dir: Path,
    no_maintenance: bool,
    seed_check_interval_seconds: int,
    seed_checked_at: Optional[datetime],
    logger: Optional[logging.Logger] = None,
) -> None:
    maintenance_pid = maintenance_processes[0].process_id if maintenance_processes else None
    maintenance_status = "disabled" if no_maintenance else ("running" if maintenance_processes else "missing")
    now = datetime.now(timezone.utc)
    try:
        with connect(dsn) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO worker_manager_state (
                        manager_id,
                        supervisor_status,
                        supervisor_pid,
                        supervisor_started_at,
                        supervisor_last_seen_at,
                        database_available,
                        database_error,
                        managed_workers_expected,
                        managed_workers_running,
                        managed_worker_names,
                        started_workers,
                        stopped_workers,
                        seed_check_interval_seconds,
                        last_seed_check_at,
                        last_seed_success,
                        last_seed_error,
                        maintenance_enabled,
                        maintenance_status,
                        maintenance_pid,
                        manifest_path,
                        db_name,
                        log_dir,
                        updated_at
                    ) VALUES (
                        %s, %s, %s, %s, %s, %s, %s, %s, %s,
                        %s::jsonb, %s::jsonb, %s::jsonb, %s, %s, %s, %s,
                        %s, %s, %s, %s, %s, %s, %s
                    )
                    ON CONFLICT (manager_id) DO UPDATE SET
                        supervisor_status = EXCLUDED.supervisor_status,
                        supervisor_pid = EXCLUDED.supervisor_pid,
                        supervisor_started_at = CASE
                            WHEN worker_manager_state.supervisor_pid IS DISTINCT FROM EXCLUDED.supervisor_pid
                            THEN EXCLUDED.supervisor_started_at
                            ELSE COALESCE(worker_manager_state.supervisor_started_at, EXCLUDED.supervisor_started_at)
                        END,
                        supervisor_last_seen_at = EXCLUDED.supervisor_last_seen_at,
                        database_available = EXCLUDED.database_available,
                        database_error = EXCLUDED.database_error,
                        managed_workers_expected = EXCLUDED.managed_workers_expected,
                        managed_workers_running = EXCLUDED.managed_workers_running,
                        managed_worker_names = EXCLUDED.managed_worker_names,
                        started_workers = EXCLUDED.started_workers,
                        stopped_workers = EXCLUDED.stopped_workers,
                        seed_check_interval_seconds = EXCLUDED.seed_check_interval_seconds,
                        last_seed_check_at = CASE
                            WHEN EXCLUDED.last_seed_check_at IS NULL
                            THEN worker_manager_state.last_seed_check_at
                            ELSE EXCLUDED.last_seed_check_at
                        END,
                        last_seed_success = CASE
                            WHEN EXCLUDED.last_seed_check_at IS NULL
                            THEN worker_manager_state.last_seed_success
                            ELSE EXCLUDED.last_seed_success
                        END,
                        last_seed_error = CASE
                            WHEN EXCLUDED.last_seed_check_at IS NULL
                            THEN worker_manager_state.last_seed_error
                            ELSE EXCLUDED.last_seed_error
                        END,
                        maintenance_enabled = EXCLUDED.maintenance_enabled,
                        maintenance_status = EXCLUDED.maintenance_status,
                        maintenance_pid = EXCLUDED.maintenance_pid,
                        manifest_path = EXCLUDED.manifest_path,
                        db_name = EXCLUDED.db_name,
                        log_dir = EXCLUDED.log_dir,
                        updated_at = EXCLUDED.updated_at
                    """,
                    (
                        MANAGER_STATE_ID,
                        "running" if outcome.database_available else "degraded",
                        os.getpid(),
                        now,
                        now,
                        outcome.database_available,
                        outcome.database_error,
                        len(selected_workers),
                        len(running_worker_names),
                        _json_param([worker.name for worker in selected_workers]),
                        _json_param(list(outcome.started_workers)),
                        _json_param(list(outcome.stopped_workers)),
                        int(seed_check_interval_seconds),
                        seed_checked_at if outcome.seed_checked else None,
                        outcome.seed_success if outcome.seed_checked else None,
                        outcome.seed_error if outcome.seed_checked else None,
                        not no_maintenance,
                        maintenance_status,
                        maintenance_pid,
                        str(manifest_path),
                        target_db,
                        str(resolved_log_dir),
                        now,
                    ),
                )
    except Exception as exc:  # pragma: no cover - runtime environment dependent
        if logger is not None:
            logger.debug("Failed to record worker manager supervisor state: %s", exc, exc_info=True)


def record_worker_manager_maintenance_state(
    dsn: str,
    *,
    status: str,
    enabled: bool,
    interval_seconds: int,
    actions: Sequence[MaintenanceActionConfig],
    promote_count: Optional[int] = None,
    reset_count: Optional[int] = None,
    last_action_result: Optional["MaintenanceActionResult"] = None,
    loop_error: Optional[str] = None,
    logger: Optional[logging.Logger] = None,
) -> None:
    now = datetime.now(timezone.utc)
    action_at = now if last_action_result is not None else None
    try:
        with connect(dsn) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO worker_manager_state (
                        manager_id,
                        maintenance_enabled,
                        maintenance_status,
                        maintenance_pid,
                        maintenance_started_at,
                        maintenance_last_seen_at,
                        maintenance_interval_seconds,
                        maintenance_action_count,
                        maintenance_actions,
                        last_promote_count,
                        last_reset_count,
                        last_maintenance_action_at,
                        last_maintenance_action_name,
                        last_maintenance_action_success,
                        last_maintenance_action_rows,
                        last_maintenance_action_duration_seconds,
                        last_maintenance_action_error,
                        last_maintenance_loop_error,
                        updated_at
                    ) VALUES (
                        %s, %s, %s, %s, %s, %s, %s, %s, %s::jsonb,
                        %s, %s, %s, %s, %s, %s, %s, %s, %s, %s
                    )
                    ON CONFLICT (manager_id) DO UPDATE SET
                        maintenance_enabled = EXCLUDED.maintenance_enabled,
                        maintenance_status = EXCLUDED.maintenance_status,
                        maintenance_pid = EXCLUDED.maintenance_pid,
                        maintenance_started_at = CASE
                            WHEN worker_manager_state.maintenance_pid IS DISTINCT FROM EXCLUDED.maintenance_pid
                            THEN EXCLUDED.maintenance_started_at
                            ELSE COALESCE(worker_manager_state.maintenance_started_at, EXCLUDED.maintenance_started_at)
                        END,
                        maintenance_last_seen_at = EXCLUDED.maintenance_last_seen_at,
                        maintenance_interval_seconds = EXCLUDED.maintenance_interval_seconds,
                        maintenance_action_count = EXCLUDED.maintenance_action_count,
                        maintenance_actions = EXCLUDED.maintenance_actions,
                        last_promote_count = EXCLUDED.last_promote_count,
                        last_reset_count = EXCLUDED.last_reset_count,
                        last_maintenance_action_at = CASE
                            WHEN EXCLUDED.last_maintenance_action_at IS NULL
                            THEN worker_manager_state.last_maintenance_action_at
                            ELSE EXCLUDED.last_maintenance_action_at
                        END,
                        last_maintenance_action_name = CASE
                            WHEN EXCLUDED.last_maintenance_action_at IS NULL
                            THEN worker_manager_state.last_maintenance_action_name
                            ELSE EXCLUDED.last_maintenance_action_name
                        END,
                        last_maintenance_action_success = CASE
                            WHEN EXCLUDED.last_maintenance_action_at IS NULL
                            THEN worker_manager_state.last_maintenance_action_success
                            ELSE EXCLUDED.last_maintenance_action_success
                        END,
                        last_maintenance_action_rows = CASE
                            WHEN EXCLUDED.last_maintenance_action_at IS NULL
                            THEN worker_manager_state.last_maintenance_action_rows
                            ELSE EXCLUDED.last_maintenance_action_rows
                        END,
                        last_maintenance_action_duration_seconds = CASE
                            WHEN EXCLUDED.last_maintenance_action_at IS NULL
                            THEN worker_manager_state.last_maintenance_action_duration_seconds
                            ELSE EXCLUDED.last_maintenance_action_duration_seconds
                        END,
                        last_maintenance_action_error = CASE
                            WHEN EXCLUDED.last_maintenance_action_at IS NULL
                            THEN worker_manager_state.last_maintenance_action_error
                            ELSE EXCLUDED.last_maintenance_action_error
                        END,
                        last_maintenance_loop_error = EXCLUDED.last_maintenance_loop_error,
                        updated_at = EXCLUDED.updated_at
                    """,
                    (
                        MANAGER_STATE_ID,
                        enabled,
                        status,
                        os.getpid(),
                        now,
                        now,
                        int(interval_seconds),
                        len(actions),
                        _json_param(_maintenance_actions_payload(actions)),
                        promote_count,
                        reset_count,
                        action_at,
                        last_action_result.action_name if last_action_result else None,
                        last_action_result.success if last_action_result else None,
                        last_action_result.rows_affected if last_action_result else None,
                        last_action_result.duration_seconds if last_action_result else None,
                        last_action_result.error if last_action_result else None,
                        loop_error,
                        now,
                    ),
                )
    except Exception as exc:  # pragma: no cover - runtime environment dependent
        if logger is not None:
            logger.debug("Failed to record worker manager maintenance state: %s", exc, exc_info=True)


def stop_managed_processes(processes: Sequence[ManagedProcess], logger: Optional[logging.Logger] = None) -> list[str]:
    stopped: list[str] = []
    for process in processes:
        message = f"Stopping {process.kind} '{process.name}' (PID {process.process_id})"
        if logger is None:
            print(message)
        else:
            logger.info(message)
        stop_process(process)
        stopped.append(process.name)
    return stopped


def collect_seed_workers(workers: Sequence[WorkerManifestEntry]) -> list[WorkerManifestEntry]:
    return [
        worker
        for worker in workers
        if worker.seed_schedules or worker.seed_schedule is not None or worker.startup_seed is not None
    ]


def _build_seed_schedule_payload(*, worker_name: str, schedule: SeedScheduleConfig) -> dict[str, Any]:
    payload: dict[str, Any] = {"action": schedule.action, "limit": schedule.limit}
    for key, value in schedule.payload.items():
        if key in {"action", "limit"}:
            raise ValueError(
                f"Manifest worker '{worker_name}' seed schedule payload must not override reserved key '{key}'"
            )
        payload[key] = value
    return payload


def _register_manager_seed_worker(conn, queue_names: Sequence[str]) -> str:
    with conn.cursor() as cur:
        for queue_name in queue_names:
            cur.execute(
                "SELECT create_queue(%s, %s)",
                (queue_name, f"Auto-created queue for worker-manager seeding: {queue_name}"),
            )
        cur.execute(
            """
            SELECT worker_id, api_key, success
            FROM register_worker(%s, %s, %s, %s::interval, %s::jsonb)
            """,
            (
                MANAGER_SEED_WORKER_ID,
                MANAGER_SEED_WORKER_ID,
                5,
                "30 seconds",
                json.dumps(list(queue_names)),
            ),
        )
        row = cur.fetchone()
    if not row or not row[2]:
        raise RuntimeError("Failed to register worker-manager seeder worker")
    return str(row[1])


def _has_active_scan_task(
    cur,
    *,
    worker_name: str,
    queue_name: str,
    action: str,
    recurrence_pattern: Optional[str],
    recurrence_time: Optional[str],
    recurrence_timezone: Optional[str],
) -> bool:
    recurrence_sql = "AND recurrence_pattern = %s" if recurrence_pattern is not None else "AND recurrence_pattern IS NULL"
    recurrence_time_sql = (
        "AND recurrence_time = %s::time AND recurrence_timezone = %s"
        if recurrence_time is not None and recurrence_timezone is not None
        else "AND recurrence_time IS NULL AND recurrence_timezone IS NULL"
    )
    params: list[Any] = [worker_name, queue_name, list(ACTIVE_TASK_STATUSES), action]
    if recurrence_pattern is not None:
        params.append(recurrence_pattern)
    if recurrence_time is not None and recurrence_timezone is not None:
        params.extend([recurrence_time, recurrence_timezone])
    cur.execute(
        f"""
        SELECT EXISTS(
            SELECT 1
            FROM task_queue
            WHERE task_name = %s
              AND queue_name = %s
              AND status::text = ANY(%s::text[])
              AND (task_data->>'action') = %s
              {recurrence_sql}
              {recurrence_time_sql}
        )
        """,
        tuple(params),
    )
    row = cur.fetchone()
    return bool(row and row[0])


def _enqueue_manifest_seed_task(
    cur,
    *,
    api_key: str,
    worker_name: str,
    queue_name: str,
    payload: dict[str, Any],
    task_type: str,
    scheduled_at: Any,
    recurrence_pattern: Optional[str],
    recurrence_time: Optional[str],
    recurrence_timezone: Optional[str],
) -> Optional[str]:
    cur.execute(
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
            %s,
            %s,
            %s
        )
        """,
        (
            api_key,
            worker_name,
            json.dumps(payload, default=str),
            task_type,
            0,
            scheduled_at,
            3,
            recurrence_pattern,
            queue_name,
            recurrence_time,
            recurrence_timezone,
        ),
    )
    row = cur.fetchone()
    return str(row[0]) if row and row[0] is not None else None


def ensure_manifest_seed_tasks(
    *,
    dsn: str,
    workers: Sequence[WorkerManifestEntry],
    logger: Optional[logging.Logger] = None,
) -> list[dict[str, Any]]:
    seed_workers = collect_seed_workers(workers)
    if not seed_workers:
        return []

    queue_names = list(dict.fromkeys(worker.primary_queue for worker in seed_workers))
    results: list[dict[str, Any]] = []
    with connect(dsn) as conn:
        api_key = _register_manager_seed_worker(conn, queue_names)
        with conn.cursor() as cur:
            for worker in seed_workers:
                schedules = list(worker.seed_schedules)
                if not schedules and worker.seed_schedule is not None:
                    schedules = [worker.seed_schedule]
                startup_seed = worker.startup_seed

                for schedule in schedules:
                    recurring_exists = _has_active_scan_task(
                        cur,
                        worker_name=worker.name,
                        queue_name=worker.primary_queue,
                        action=schedule.action,
                        recurrence_pattern=schedule.recurrence_pattern,
                        recurrence_time=schedule.time_of_day,
                        recurrence_timezone=schedule.timezone,
                    )

                    result: dict[str, Any] = {
                        "worker": worker.name,
                        "queue_name": worker.primary_queue,
                        "action": schedule.action,
                        "limit": schedule.limit,
                        "recurrence_pattern": schedule.recurrence_pattern,
                        "time_of_day": schedule.time_of_day,
                        "timezone": schedule.timezone,
                        "first_run_immediate": schedule.first_run_immediate,
                        "created_recurring": False,
                        "created_immediate": False,
                        "recurring_task_uuid": None,
                        "immediate_task_uuid": None,
                    }

                    if recurring_exists:
                        results.append(result)
                        continue

                    immediate_needed = False
                    if schedule.first_run_immediate:
                        immediate_needed = not _has_active_scan_task(
                            cur,
                            worker_name=worker.name,
                            queue_name=worker.primary_queue,
                            action=schedule.action,
                            recurrence_pattern=None,
                            recurrence_time=None,
                            recurrence_timezone=None,
                        )

                    recurring_payload = _build_seed_schedule_payload(worker_name=worker.name, schedule=schedule)
                    recurring_task_uuid = _enqueue_manifest_seed_task(
                        cur,
                        api_key=api_key,
                        worker_name=worker.name,
                        queue_name=worker.primary_queue,
                        payload=recurring_payload,
                        task_type="recurring",
                        scheduled_at=None,
                        recurrence_pattern=schedule.recurrence_pattern,
                        recurrence_time=schedule.time_of_day,
                        recurrence_timezone=schedule.timezone,
                    )
                    result["created_recurring"] = True
                    result["recurring_task_uuid"] = recurring_task_uuid

                    if immediate_needed:
                        immediate_task_uuid = _enqueue_manifest_seed_task(
                            cur,
                            api_key=api_key,
                            worker_name=worker.name,
                            queue_name=worker.primary_queue,
                            payload=recurring_payload,
                            task_type="immediate",
                            scheduled_at=None,
                            recurrence_pattern=None,
                            recurrence_time=None,
                            recurrence_timezone=None,
                        )
                        result["created_immediate"] = True
                        result["immediate_task_uuid"] = immediate_task_uuid

                    results.append(result)

                if startup_seed is None:
                    continue

                result = {
                    "worker": worker.name,
                    "queue_name": worker.primary_queue,
                    "action": startup_seed.action,
                    "limit": startup_seed.limit,
                    "created_startup_seed": False,
                    "startup_task_uuid": None,
                }
                startup_needed = not _has_active_scan_task(
                    cur,
                    worker_name=worker.name,
                    queue_name=worker.primary_queue,
                    action=startup_seed.action,
                    recurrence_pattern=None,
                    recurrence_time=None,
                    recurrence_timezone=None,
                )
                if startup_needed:
                    startup_task_uuid = _enqueue_manifest_seed_task(
                        cur,
                        api_key=api_key,
                        worker_name=worker.name,
                        queue_name=worker.primary_queue,
                        payload={
                            "action": startup_seed.action,
                            "limit": startup_seed.limit,
                        },
                        task_type="immediate",
                        scheduled_at=None,
                        recurrence_pattern=None,
                        recurrence_time=None,
                        recurrence_timezone=None,
                    )
                    result["created_startup_seed"] = True
                    result["startup_task_uuid"] = startup_task_uuid
                results.append(result)

    for item in results:
        if "recurrence_pattern" in item:
            message = (
                "manifest seed schedule checked for worker '%s': recurring=%s immediate=%s limit=%s recurrence=%s"
                % (
                    item["worker"],
                    "created" if item["created_recurring"] else "existing",
                    "created" if item["created_immediate"] else "skipped",
                    item["limit"],
                    (
                        f"{item['recurrence_pattern']}@{item['time_of_day']} {item['timezone']}"
                        if item.get("time_of_day") and item.get("timezone")
                        else item["recurrence_pattern"]
                    ),
                )
            )
        else:
            message = (
                "manifest startup seed checked for worker '%s': seed=%s limit=%s action=%s"
                % (
                    item["worker"],
                    "created" if item["created_startup_seed"] else "skipped",
                    item["limit"],
                    item["action"],
                )
            )
        if logger is None:
            print(message)
        else:
            logger.info(message)

    return results


def ensure_workers_running(
    workers: Sequence[WorkerManifestEntry],
    *,
    python_path: str,
    repo_root: Path,
    target_db: str,
    resolved_log_dir: Path,
    logger: logging.Logger,
) -> list[dict[str, Any]]:
    running = {process.name for process in find_managed_worker_processes(workers)}
    started_workers: list[dict[str, Any]] = []
    for worker in workers:
        if worker.name in running:
            continue
        logger.info("Starting worker '%s'", worker.name)
        started = start_worker(
            worker,
            python_path=python_path,
            repo_root=repo_root,
            target_db=target_db,
            resolved_log_dir=resolved_log_dir,
        )
        logger.info("Worker '%s' started with PID %s", worker.name, started["process_id"])
        started_workers.append(started)
    return started_workers


def ensure_maintenance_running(
    *,
    python_path: str,
    manifest_path: Path,
    target_db: str,
    reset_interval_seconds: int,
    log_prefix: str,
    resolved_log_dir: Path,
    logger: logging.Logger,
) -> bool:
    if find_maintenance_processes(Path(__file__).resolve()):
        return False
    logger.info("Starting maintenance process")
    started = start_maintenance_process(
        python_path=python_path,
        manifest_path=manifest_path,
        target_db=target_db,
        reset_interval_seconds=reset_interval_seconds,
        log_prefix=log_prefix,
        resolved_log_dir=resolved_log_dir,
    )
    logger.info("Maintenance process started with PID %s", started["process_id"])
    return True


def supervise_once(
    *,
    selected_workers: Sequence[WorkerManifestEntry],
    python_path: str,
    target_db: str,
    resolved_log_dir: Path,
    manifest_path: Path,
    maintenance_log_prefix: str,
    reset_interval_seconds: int,
    logger: logging.Logger,
    dsn: str,
    no_maintenance: bool,
    ensure_seed_tasks: bool = True,
) -> SupervisionOutcome:
    database_available, error_message = probe_database(dsn)
    if not database_available:
        stopped_workers = stop_managed_processes(find_managed_worker_processes(selected_workers), logger)
        maintenance_processes = [] if no_maintenance else find_maintenance_processes(Path(__file__).resolve())
        maintenance_stopped = bool(maintenance_processes)
        stop_managed_processes(maintenance_processes, logger)
        return SupervisionOutcome(
            database_available=False,
            database_error=error_message,
            started_workers=(),
            stopped_workers=tuple(stopped_workers),
            maintenance_started=False,
            maintenance_stopped=maintenance_stopped,
            running_workers=(),
            maintenance_running=False,
            maintenance_pid=None,
            seed_checked=False,
            seed_success=None,
            seed_error=None,
        )

    started_workers = ensure_workers_running(
        selected_workers,
        python_path=python_path,
        repo_root=REPO_ROOT,
        target_db=target_db,
        resolved_log_dir=resolved_log_dir,
        logger=logger,
    )
    seed_success: Optional[bool] = None
    seed_error: Optional[str] = None
    if ensure_seed_tasks:
        try:
            ensure_manifest_seed_tasks(dsn=dsn, workers=selected_workers, logger=logger)
            seed_success = True
        except Exception as exc:  # pragma: no cover - runtime path
            seed_success = False
            seed_error = str(exc)
            logger.warning("Failed to ensure manifest seed tasks: %s", exc)

    maintenance_started = False
    maintenance_processes: list[ManagedProcess] = []
    if not no_maintenance:
        maintenance_started = ensure_maintenance_running(
            python_path=python_path,
            manifest_path=manifest_path,
            target_db=target_db,
            reset_interval_seconds=reset_interval_seconds,
            log_prefix=maintenance_log_prefix,
            resolved_log_dir=resolved_log_dir,
            logger=logger,
        )
        maintenance_processes = find_maintenance_processes(Path(__file__).resolve())
    running_worker_names = sorted(
        {process.name for process in find_managed_worker_processes(selected_workers)}
        | {item["name"] for item in started_workers}
    )
    return SupervisionOutcome(
        database_available=True,
        database_error=None,
        started_workers=tuple(item["name"] for item in started_workers),
        stopped_workers=(),
        maintenance_started=maintenance_started,
        maintenance_stopped=False,
        running_workers=tuple(running_worker_names),
        maintenance_running=bool(maintenance_processes),
        maintenance_pid=maintenance_processes[0].process_id if maintenance_processes else None,
        seed_checked=ensure_seed_tasks,
        seed_success=seed_success,
        seed_error=seed_error,
    )


def fetch_worker_stats(dsn: str, worker_names: Optional[Sequence[str]] = None) -> list[dict[str, Any]]:
    selected = set(worker_names or [])
    with connect(dsn) as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT
                    worker_id,
                    worker_name,
                    is_active,
                    current_load,
                    max_capacity,
                    subscribed_queues,
                    tasks_completed,
                    tasks_failed,
                    availability_ratio,
                    last_seen_seconds
                FROM get_worker_stats()
                """
            )
            rows = cur.fetchall()

    items = []
    for row in rows:
        payload = {
            "worker_id": row[0],
            "worker_name": row[1],
            "is_active": row[2],
            "current_load": row[3],
            "max_capacity": row[4],
            "subscribed_queues": row[5],
            "tasks_completed": row[6],
            "tasks_failed": row[7],
            "availability_ratio": float(row[8]) if row[8] is not None else None,
            "last_seen_seconds": row[9],
        }
        if selected and payload["worker_name"] not in selected:
            continue
        items.append(payload)
    return items


def fetch_task_detail(dsn: str, *, task_id: Optional[int], task_uuid: Optional[str]) -> Optional[dict[str, Any]]:
    if task_id is None and task_uuid is None:
        return None
    where_clause = "id = %s" if task_id is not None else "task_uuid = %s::uuid"
    value = task_id if task_id is not None else task_uuid
    with connect(dsn) as conn:
        with conn.cursor() as cur:
            cur.execute(
                f"""
                SELECT
                    id,
                    task_uuid,
                    task_name,
                    queue_name,
                    status,
                    worker_id,
                    attempts,
                    max_attempts,
                    task_type,
                    priority,
                    scheduled_at,
                    started_at,
                    completed_at,
                    lease_expires_at,
                    last_error,
                    task_data,
                    task_metadata,
                    created_at,
                    updated_at
                FROM task_queue
                WHERE {where_clause}
                LIMIT 1
                """,
                (value,),
            )
            row = cur.fetchone()
    if row is None:
        return None
    return {
        "id": row[0],
        "task_uuid": str(row[1]),
        "task_name": row[2],
        "queue_name": row[3],
        "status": row[4],
        "worker_id": row[5],
        "attempts": row[6],
        "max_attempts": row[7],
        "task_type": row[8],
        "priority": row[9],
        "scheduled_at": row[10],
        "started_at": row[11],
        "completed_at": row[12],
        "lease_expires_at": row[13],
        "last_error": row[14],
        "task_data": row[15],
        "task_metadata": row[16],
        "created_at": row[17],
        "updated_at": row[18],
    }


def fetch_task_stats(dsn: str, queue_names: Optional[Sequence[str]] = None) -> dict[str, Any]:
    with connect(dsn) as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT
                    total_tasks,
                    pending_tasks,
                    processing_tasks,
                    scheduled_tasks,
                    retrying_tasks,
                    completed_tasks_24h,
                    failed_tasks_24h,
                    avg_completion_time,
                    oldest_pending_task
                FROM get_queue_stats()
                """
            )
            summary_row = cur.fetchone()

            if queue_names:
                cur.execute(
                    """
                    SELECT
                        queue_name,
                        COUNT(*) AS total_tasks,
                        COUNT(*) FILTER (WHERE status = 'pending') AS pending_tasks,
                        COUNT(*) FILTER (WHERE status = 'processing') AS processing_tasks,
                        COUNT(*) FILTER (WHERE status = 'scheduled') AS scheduled_tasks,
                        COUNT(*) FILTER (WHERE status = 'retrying') AS retrying_tasks,
                        COUNT(*) FILTER (WHERE status = 'completed') AS completed_tasks,
                        COUNT(*) FILTER (WHERE status = 'failed') AS failed_tasks
                    FROM task_queue
                    WHERE queue_name = ANY(%s::varchar[])
                    GROUP BY queue_name
                    ORDER BY queue_name
                    """,
                    (list(queue_names),),
                )
            else:
                cur.execute(
                    """
                    SELECT
                        queue_name,
                        COUNT(*) AS total_tasks,
                        COUNT(*) FILTER (WHERE status = 'pending') AS pending_tasks,
                        COUNT(*) FILTER (WHERE status = 'processing') AS processing_tasks,
                        COUNT(*) FILTER (WHERE status = 'scheduled') AS scheduled_tasks,
                        COUNT(*) FILTER (WHERE status = 'retrying') AS retrying_tasks,
                        COUNT(*) FILTER (WHERE status = 'completed') AS completed_tasks,
                        COUNT(*) FILTER (WHERE status = 'failed') AS failed_tasks
                    FROM task_queue
                    GROUP BY queue_name
                    ORDER BY queue_name
                    """
                )
            queue_rows = cur.fetchall()

    return {
        "summary": {
            "total_tasks": summary_row[0],
            "pending_tasks": summary_row[1],
            "processing_tasks": summary_row[2],
            "scheduled_tasks": summary_row[3],
            "retrying_tasks": summary_row[4],
            "completed_tasks_24h": summary_row[5],
            "failed_tasks_24h": summary_row[6],
            "avg_completion_time": summary_row[7],
            "oldest_pending_task": summary_row[8],
        },
        "queues": [
            {
                "queue_name": row[0],
                "total_tasks": row[1],
                "pending_tasks": row[2],
                "processing_tasks": row[3],
                "scheduled_tasks": row[4],
                "retrying_tasks": row[5],
                "completed_tasks": row[6],
                "failed_tasks": row[7],
            }
            for row in queue_rows
        ],
    }


def print_json(payload: Any) -> None:
    print(json.dumps(payload, indent=2, default=str))


def print_worker_status(
    processes: Sequence[ManagedProcess],
    db_workers: Sequence[dict[str, Any]],
    *,
    as_json: bool,
) -> None:
    payload = {
        "processes": [
            {
                "name": process.name,
                "process_id": process.process_id,
                "kind": process.kind,
                "command_line": process.command_line,
            }
            for process in processes
        ],
        "database_workers": list(db_workers),
    }
    if as_json:
        print_json(payload)
        return

    print("Worker processes")
    if not processes:
        print("  none")
    else:
        for process in processes:
            print(f"  {process.name}: PID={process.process_id}")

    print("")
    print("Database worker stats")
    if not db_workers:
        print("  none")
        return
    for item in db_workers:
        print(
            f"  {item['worker_name']} [{item['worker_id']}] active={item['is_active']} "
            f"load={item['current_load']}/{item['max_capacity']} "
            f"completed={item['tasks_completed']} failed={item['tasks_failed']} "
            f"last_seen_seconds={item['last_seen_seconds']}"
        )


def print_task_status(payload: dict[str, Any], *, as_json: bool) -> None:
    if as_json:
        print_json(payload)
        return

    detail = payload.get("detail")
    if detail:
        print("Task detail")
        for key, value in detail.items():
            print(f"  {key}: {value}")
        print("")

    summary = payload["summary"]
    print("Task summary")
    for key, value in summary.items():
        print(f"  {key}: {value}")

    print("")
    print("Queue stats")
    if not payload["queues"]:
        print("  none")
        return
    for queue in payload["queues"]:
        print(
            f"  {queue['queue_name']}: total={queue['total_tasks']} pending={queue['pending_tasks']} "
            f"processing={queue['processing_tasks']} scheduled={queue['scheduled_tasks']} "
            f"retrying={queue['retrying_tasks']} completed={queue['completed_tasks']} failed={queue['failed_tasks']}"
        )


def _quote_sql_identifier(value: str) -> str:
    if SQL_IDENTIFIER_PATTERN.fullmatch(value) is None:
        raise ValueError(f"Invalid SQL identifier: {value!r}")
    return f'"{value}"'


def _quote_sql_name(value: str) -> str:
    parts = [part.strip() for part in value.split(".")]
    if not parts or len(parts) > 2 or any(not part for part in parts):
        raise ValueError(f"Invalid SQL name: {value!r}")
    return ".".join(_quote_sql_identifier(part) for part in parts)


def _parse_bool_payload(payload: dict[str, Any], key: str, default: bool) -> bool:
    if key not in payload:
        return default
    return _parse_manifest_bool(payload[key], field_name=f"{POSTGRES_TABLE_COMPACTION_ACTION}.payload.{key}")


def _parse_float_payload(payload: dict[str, Any], key: str, default: float, *, minimum: float) -> float:
    raw_value = payload.get(key, default)
    try:
        value = float(raw_value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{POSTGRES_TABLE_COMPACTION_ACTION}.payload.{key} must be numeric") from exc
    if value < minimum:
        raise ValueError(f"{POSTGRES_TABLE_COMPACTION_ACTION}.payload.{key} must be >= {minimum:g}")
    return value


def _parse_int_payload(payload: dict[str, Any], key: str, default: int, *, minimum: int) -> int:
    raw_value = payload.get(key, default)
    try:
        value = int(raw_value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{POSTGRES_TABLE_COMPACTION_ACTION}.payload.{key} must be an integer") from exc
    if value < minimum:
        raise ValueError(f"{POSTGRES_TABLE_COMPACTION_ACTION}.payload.{key} must be >= {minimum}")
    return value


def _parse_compaction_tables(payload: dict[str, Any]) -> tuple[str, ...]:
    raw_tables = payload.get("tables", list(DEFAULT_POSTGRES_COMPACTION_TABLES))
    if not isinstance(raw_tables, list) or not raw_tables:
        raise ValueError(f"{POSTGRES_TABLE_COMPACTION_ACTION}.payload.tables must be a non-empty array")

    tables: list[str] = []
    for index, raw_table in enumerate(raw_tables):
        if not isinstance(raw_table, str) or not raw_table.strip():
            raise ValueError(f"{POSTGRES_TABLE_COMPACTION_ACTION}.payload.tables[{index}] must be a table name")
        table_name = raw_table.strip()
        _quote_sql_name(table_name)
        if "." not in table_name:
            table_name = f"public.{table_name}"
        if table_name not in tables:
            tables.append(table_name)
    return tuple(tables)


def _fetch_relation_size(cur, table_name: str) -> Optional[dict[str, Any]]:
    schema_name, relation_name = table_name.split(".", 1)
    cur.execute(
        """
        SELECT
            c.oid::regclass::text AS relation_name,
            pg_total_relation_size(c.oid)::bigint AS total_size_bytes,
            pg_relation_size(c.oid)::bigint AS heap_size_bytes,
            pg_indexes_size(c.oid)::bigint AS index_size_bytes,
            COALESCE(s.n_live_tup, 0)::bigint AS live_rows,
            COALESCE(s.n_dead_tup, 0)::bigint AS dead_rows
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
        WHERE n.nspname = %s
          AND c.relname = %s
          AND c.relkind IN ('r', 'm')
        LIMIT 1
        """,
        (schema_name, relation_name),
    )
    row = cur.fetchone()
    if not row:
        return None
    return {
        "relation_name": str(row[0]),
        "total_size_bytes": int(row[1] or 0),
        "heap_size_bytes": int(row[2] or 0),
        "index_size_bytes": int(row[3] or 0),
        "live_rows": int(row[4] or 0),
        "dead_rows": int(row[5] or 0),
    }


def execute_postgres_table_compaction(
    conn,
    action: MaintenanceActionConfig,
    logger: logging.Logger,
) -> tuple[int, dict[str, Any]]:
    payload = action.payload
    tables = _parse_compaction_tables(payload)
    min_total_size_mb = _parse_float_payload(payload, "min_total_size_mb", 64.0, minimum=0.0)
    lock_timeout_seconds = _parse_int_payload(payload, "lock_timeout_seconds", 5, minimum=1)
    statement_timeout_seconds = _parse_int_payload(payload, "statement_timeout_seconds", 900, minimum=30)
    analyze = _parse_bool_payload(payload, "analyze", True)
    verbose = _parse_bool_payload(payload, "verbose", True)
    reindex = _parse_bool_payload(payload, "reindex", False)
    dry_run = _parse_bool_payload(payload, "dry_run", False)
    min_total_size_bytes = int(min_total_size_mb * 1024 * 1024)

    compacted = 0
    failed = 0
    skipped = 0
    table_results: list[dict[str, Any]] = []

    with conn.cursor() as cur:
        cur.execute("SELECT set_config('lock_timeout', %s, false)", (f"{lock_timeout_seconds}s",))
        cur.execute("SELECT set_config('statement_timeout', %s, false)", (f"{statement_timeout_seconds}s",))

        for table_name in tables:
            before = _fetch_relation_size(cur, table_name)
            if before is None:
                skipped += 1
                table_results.append({"table": table_name, "status": "skipped_missing"})
                logger.info("postgres compaction skipped missing table: %s", table_name)
                continue

            if before["total_size_bytes"] < min_total_size_bytes:
                skipped += 1
                table_results.append(
                    {
                        "table": table_name,
                        "status": "skipped_below_threshold",
                        "before_size_bytes": before["total_size_bytes"],
                        "min_total_size_bytes": min_total_size_bytes,
                        "live_rows": before["live_rows"],
                        "dead_rows": before["dead_rows"],
                    }
                )
                logger.info(
                    "postgres compaction skipped table below threshold: %s size_bytes=%s threshold_bytes=%s",
                    table_name,
                    before["total_size_bytes"],
                    min_total_size_bytes,
                )
                continue

            qualified_table = _quote_sql_name(table_name)
            vacuum_options = ["FULL"]
            if verbose:
                vacuum_options.append("VERBOSE")
            if analyze:
                vacuum_options.append("ANALYZE")
            vacuum_sql = f"VACUUM ({', '.join(vacuum_options)}) {qualified_table}"

            started_at = time.time()
            try:
                if dry_run:
                    after = before
                    status = "would_compact"
                else:
                    logger.info(
                        "postgres compaction started: table=%s size_bytes=%s live_rows=%s dead_rows=%s",
                        table_name,
                        before["total_size_bytes"],
                        before["live_rows"],
                        before["dead_rows"],
                    )
                    cur.execute(vacuum_sql)
                    if reindex:
                        cur.execute(f"REINDEX TABLE {qualified_table}")
                    after = _fetch_relation_size(cur, table_name) or before
                    compacted += 1
                    status = "compacted"

                duration_seconds = time.time() - started_at
                saved_bytes = before["total_size_bytes"] - after["total_size_bytes"]
                table_results.append(
                    {
                        "table": table_name,
                        "status": status,
                        "before_size_bytes": before["total_size_bytes"],
                        "after_size_bytes": after["total_size_bytes"],
                        "saved_bytes": saved_bytes,
                        "duration_seconds": duration_seconds,
                        "live_rows": after["live_rows"],
                        "dead_rows": after["dead_rows"],
                    }
                )
                logger.info(
                    "postgres compaction completed: table=%s status=%s duration_seconds=%.2f saved_bytes=%s",
                    table_name,
                    status,
                    duration_seconds,
                    saved_bytes,
                )
            except Exception as exc:
                failed += 1
                error_msg = f"{type(exc).__name__}: {exc}"
                table_results.append(
                    {
                        "table": table_name,
                        "status": "failed",
                        "before_size_bytes": before["total_size_bytes"],
                        "duration_seconds": time.time() - started_at,
                        "error": error_msg,
                    }
                )
                logger.warning("postgres compaction failed for table %s: %s", table_name, error_msg)

    return compacted, {
        "tables": table_results,
        "tables_compacted": compacted,
        "tables_failed": failed,
        "tables_skipped": skipped,
        "min_total_size_mb": min_total_size_mb,
        "lock_timeout_seconds": lock_timeout_seconds,
        "statement_timeout_seconds": statement_timeout_seconds,
        "dry_run": dry_run,
    }


@dataclass
class MaintenanceActionResult:
    """Result of a maintenance action execution."""
    action_name: str
    success: bool
    start_time: float
    end_time: float
    duration_seconds: float
    rows_affected: Optional[int] = None
    error: Optional[str] = None
    details: Optional[dict[str, Any]] = None


def execute_maintenance_action(
    conn,
    action: MaintenanceActionConfig,
    logger: logging.Logger,
) -> MaintenanceActionResult:
    """Execute a single maintenance action by calling its SQL function.

    Args:
        conn: Database connection
        action: Maintenance action configuration
        logger: Logger instance

    Returns:
        MaintenanceActionResult with execution details
    """
    start_time = time.time()
    action_name = action.name

    try:
        logger.info("maintenance action started: %s payload=%s", action_name, action.payload)

        if action_name == POSTGRES_TABLE_COMPACTION_ACTION:
            rows_affected, details = execute_postgres_table_compaction(conn, action, logger)
        else:
            function_name = _quote_sql_name(action_name)
            with conn.cursor() as cur:
                # Build SQL function call with keyword arguments.
                if action.payload:
                    param_names = list(action.payload.keys())
                    for param_name in param_names:
                        _quote_sql_identifier(param_name)
                    param_list = ", ".join(f"{_quote_sql_identifier(k)} => %s" for k in param_names)
                    query = f"SELECT {function_name}({param_list}) AS result;"
                    param_values = tuple(action.payload[k] for k in param_names)
                    logger.debug("executing SQL: %s with params: %s", query, param_values)
                    cur.execute(query, param_values)
                else:
                    query = f"SELECT {function_name}() AS result;"
                    logger.debug("executing SQL: %s", query)
                    cur.execute(query)

                row = cur.fetchone()
                result = row[0] if row else None

                # Functions like cleanup_old_tasks() return a plain INTEGER (deleted row count).
                # Others may return a JSON string or a dict. Handle all three cases.
                rows_affected: Optional[int] = None
                details: Optional[dict[str, Any]] = None

                if isinstance(result, (int, float)):
                    # Plain numeric return — treat the value itself as the row count.
                    rows_affected = int(result)
                elif isinstance(result, str):
                    try:
                        parsed = json.loads(result)
                    except json.JSONDecodeError:
                        parsed = {"raw_output": result}
                    if isinstance(parsed, dict):
                        details = parsed
                        raw_affected = parsed.get("rows_deleted") or parsed.get("rows_archived") or parsed.get("rows_affected")
                        rows_affected = int(raw_affected) if raw_affected is not None else None
                    elif isinstance(parsed, (int, float)):
                        rows_affected = int(parsed)
                elif isinstance(result, dict):
                    details = result
                    raw_affected = result.get("rows_deleted") or result.get("rows_archived") or result.get("rows_affected")
                    rows_affected = int(raw_affected) if raw_affected is not None else None

        end_time = time.time()
        duration = end_time - start_time

        logger.info(
            "maintenance action completed: %s duration_seconds=%.2f rows_affected=%s",
            action_name,
            duration,
            rows_affected,
        )

        return MaintenanceActionResult(
            action_name=action_name,
            success=True,
            start_time=start_time,
            end_time=end_time,
            duration_seconds=duration,
            rows_affected=rows_affected,
            details=details,
        )

    except Exception as exc:
        end_time = time.time()
        duration = end_time - start_time
        error_msg = f"{type(exc).__name__}: {str(exc)}"

        logger.error(
            "maintenance action failed: %s duration_seconds=%.2f error=%s",
            action_name,
            duration,
            error_msg,
        )

        return MaintenanceActionResult(
            action_name=action_name,
            success=False,
            start_time=start_time,
            end_time=end_time,
            duration_seconds=duration,
            error=error_msg,
        )


def should_run_maintenance_action(
    last_run_times: dict[str, float],
    action: MaintenanceActionConfig,
) -> bool:
    """Determine if a maintenance action should run now.

    Args:
        last_run_times: Dict of action_name -> last_run_timestamp
        action: Action configuration

    Returns:
        True if enough time has passed since last run
    """
    if not action.enabled:
        return False

    now = time.time()
    last_run = last_run_times.get(action.name)
    if last_run is None:
        return action.first_run_immediate
    interval_seconds = action.interval_minutes * 60

    return (now - last_run) >= interval_seconds


def execute_all_maintenance_actions(
    dsn: str,
    actions: Sequence[MaintenanceActionConfig],
    last_run_times: dict[str, float],
    logger: logging.Logger,
) -> tuple[list[MaintenanceActionResult], dict[str, float]]:
    """Execute all maintenance actions that are due.

    Args:
        dsn: Database connection string
        actions: All configured maintenance actions
        last_run_times: Dict of action_name -> last_run_timestamp
        logger: Logger instance

    Returns:
        Tuple of (results, updated_last_run_times)
    """
    results: list[MaintenanceActionResult] = []

    with connect(dsn) as conn:
        for action in actions:
            if not should_run_maintenance_action(last_run_times, action):
                if action.enabled and action.name not in last_run_times and not action.first_run_immediate:
                    last_run_times[action.name] = time.time()
                continue

            result = execute_maintenance_action(conn, action, logger)
            results.append(result)

            # Update last run time after each attempted maintenance pass. Some
            # actions use short lock timeouts and may partially skip work by design.
            last_run_times[action.name] = result.end_time

    return results, last_run_times

def run_maintenance_loop(
    dsn: str,
    interval_seconds: int,
    actions: Sequence[MaintenanceActionConfig] = (),
) -> None:
    """Main maintenance loop: promotes tasks, resets stuck tasks, executes maintenance actions.

    Args:
        dsn: Database connection string
        interval_seconds: Loop interval in seconds
        actions: Configured maintenance actions from manifest
    """
    stop_requested = False
    log_level = resolve_log_level()
    last_run_times: dict[str, float] = {}  # Track when each action last ran

    def _handle_signal(_signum: int, _frame: Any) -> None:
        nonlocal stop_requested
        stop_requested = True

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    logging.basicConfig(
        level=log_level,
        format="%(asctime)s | %(levelname)-5s | %(message)s",
        stream=sys.stderr,
    )
    logger = logging.getLogger("worker-maintenance")
    logger.setLevel(log_level)

    enabled_actions = [a for a in actions if a.enabled]
    state_schema_ready = ensure_worker_manager_state_schema(dsn, logger)
    if state_schema_ready:
        record_worker_manager_maintenance_state(
            dsn,
            status="running",
            enabled=True,
            interval_seconds=interval_seconds,
            actions=actions,
            logger=logger,
        )
    logger.info(
        "maintenance loop started: interval_seconds=%s "
        "operations=promote_scheduled_tasks,reset_stuck_tasks,execute_maintenance_actions "
        "maintenance_actions=%d",
        interval_seconds,
        len(enabled_actions),
    )

    while not stop_requested:
        try:
            # 1. Promote scheduled tasks
            with connect(dsn) as conn:
                with conn.cursor() as cur:
                    cur.execute("SELECT promote_scheduled_tasks()")
                    promote_row = cur.fetchone()
                    cur.execute("SELECT reset_stuck_tasks()")
                    reset_row = cur.fetchone()

            promote_count = int(promote_row[0]) if promote_row and promote_row[0] is not None else 0
            reset_count = int(reset_row[0]) if reset_row and reset_row[0] is not None else 0

            if promote_count > 0:
                logger.info("promote_scheduled_tasks processed: promoted_count=%s", promote_count)
            if reset_count > 0:
                logger.info("reset_stuck_tasks processed: reset_count=%s", reset_count)

            # 2. Execute maintenance actions
            latest_action_result: Optional[MaintenanceActionResult] = None
            if enabled_actions:
                results, last_run_times = execute_all_maintenance_actions(
                    dsn,
                    enabled_actions,
                    last_run_times,
                    logger,
                )
                latest_action_result = results[-1] if results else None

                # Log summary
                if results:
                    successful = sum(1 for r in results if r.success)
                    failed = sum(1 for r in results if not r.success)
                    total_duration = sum(r.duration_seconds for r in results)
                    total_rows = sum(r.rows_affected or 0 for r in results if r.success)

                    logger.info(
                        "maintenance actions executed: total=%d successful=%d failed=%d "
                        "total_duration_seconds=%.2f total_rows_affected=%d",
                        len(results), successful, failed, total_duration, total_rows,
                    )

            if state_schema_ready:
                record_worker_manager_maintenance_state(
                    dsn,
                    status="running",
                    enabled=True,
                    interval_seconds=interval_seconds,
                    actions=actions,
                    promote_count=promote_count,
                    reset_count=reset_count,
                    last_action_result=latest_action_result,
                    loop_error=None,
                    logger=logger,
                )

        except Exception as exc:  # pragma: no cover - runtime path
            logger.warning("maintenance loop error: %s", exc, exc_info=True)
            if state_schema_ready:
                record_worker_manager_maintenance_state(
                    dsn,
                    status="degraded",
                    enabled=True,
                    interval_seconds=interval_seconds,
                    actions=actions,
                    loop_error=f"{type(exc).__name__}: {exc}",
                    logger=logger,
                )

        # Sleep for the interval
        for _ in range(interval_seconds):
            if stop_requested:
                break
            time.sleep(1.0)

    logger.info("maintenance loop stopped")
    if state_schema_ready:
        record_worker_manager_maintenance_state(
            dsn,
            status="stopped",
            enabled=True,
            interval_seconds=interval_seconds,
            actions=actions,
            logger=logger,
        )

def command_start(args: argparse.Namespace) -> int:
    manifest = load_manifest(args.manifest)
    selected_workers = select_manifest_workers(manifest, include_names=args.worker, exclude_names=([args.debug_worker] if args.debug_worker else []))
    ensure_worker_scripts_exist(selected_workers)
    if args.debug_worker:
        _ = get_manifest_worker(manifest, args.debug_worker)

    python_path = resolve_executable_path(args.python_exe)
    docker_path = resolve_executable_path("docker") if args.refresh_db or args.seed_path else None
    target_db = resolve_target_db_name(
        args.db_name,
        docker_path=docker_path,
        container_name=args.container_name,
        prefer_container=bool(docker_path),
    )
    resolved_log_dir = resolve_full_path(REPO_ROOT, args.log_dir)
    resolved_log_dir.mkdir(parents=True, exist_ok=True)

    if args.refresh_db or args.seed_path:
        all_workers = select_manifest_workers(manifest)
        existing_workers = find_managed_worker_processes(all_workers)
        for process in existing_workers:
            print(f"Stopping existing worker '{process.name}' (PID {process.process_id})")
            stop_process(process)
        for process in find_maintenance_processes(Path(__file__).resolve()):
            print(f"Stopping maintenance process (PID {process.process_id})")
            stop_process(process)
    else:
        for process in find_managed_worker_processes(selected_workers):
            print(f"Stopping existing worker '{process.name}' (PID {process.process_id})")
            stop_process(process)

    if args.refresh_db:
        if not docker_path:
            raise RuntimeError("Docker is required for --refresh-db")
        print(f"Resetting schema in container '{args.container_name}' for database '{target_db}'")
        refresh_database(docker_path, args.container_name, args.schema_script_path, target_db)

    if args.seed_path:
        if not docker_path:
            raise RuntimeError("Docker is required for --seed-path")
        seed_files = seed_database(docker_path, args.container_name, target_db, resolve_full_path(REPO_ROOT, args.seed_path))
        for path in seed_files:
            print(f"Applied seed: {path}")

    started_workers: list[dict[str, Any]] = []
    try:
        for worker in selected_workers:
            print(f"Starting worker '{worker.name}'")
            started_workers.append(
                start_worker(
                    worker,
                    python_path=python_path,
                    repo_root=REPO_ROOT,
                    target_db=target_db,
                    resolved_log_dir=resolved_log_dir,
                )
            )
    except Exception:
        for process in find_managed_worker_processes(selected_workers):
            if any(process.process_id == item["process_id"] for item in started_workers):
                stop_process(process)
        raise

    maintenance_info = None
    no_maintenance = args.no_maintenance or _env_flag_enabled("WORKER_DISABLE_MAINTENANCE")
    if not no_maintenance:
        maintenance_processes = find_maintenance_processes(Path(__file__).resolve())
        if not maintenance_processes:
            print("Starting maintenance process")
            maintenance_info = start_maintenance_process(
                python_path=python_path,
                manifest_path=manifest.path,
                target_db=target_db,
                reset_interval_seconds=args.reset_interval_seconds or manifest.maintenance.reset_interval_seconds,
                log_prefix=manifest.maintenance.log_prefix,
                resolved_log_dir=resolved_log_dir,
            )
        else:
            maintenance_info = {
                "name": "worker-maintenance",
                "process_id": maintenance_processes[0].process_id,
                "command": maintenance_processes[0].command_line,
            }

    seed_workers = collect_seed_workers(selected_workers)
    if seed_workers:
        seed_dsn = build_dsn(None, True, db_name=target_db, repo_root=REPO_ROOT)
        if not seed_dsn:
            raise RuntimeError(
                "Unable to resolve a Postgres DSN for manifest seed scheduling. "
                "Configure .env/.env.prod/.env.local with DB credentials."
            )
        ensure_manifest_seed_tasks(dsn=seed_dsn, workers=seed_workers)

    print("")
    print("Worker summary")
    for item in started_workers:
        print(f"  {item['name']}: PID={item['process_id']}")
        print(f"    Script: {item['script_path']}")
        print(f"    Stdout: {item['stdout_log']}")
        print(f"    Stderr: {item['stderr_log']}")

    if maintenance_info:
        print("")
        print(f"Maintenance: PID={maintenance_info['process_id']}")

    if args.debug_worker:
        debug_target = get_manifest_worker(manifest, args.debug_worker)
        debug_command = quote_command(
            [
                python_path,
                "-u",
                str(debug_target.script_path),
                *resolve_worker_args(debug_target.args, target_db, resolved_log_dir),
                *build_runtime_variable_ttl_launch_args(debug_target.runtime_variable_ttl_config),
            ]
        )
        print("")
        print(f"Debug worker reserved for VS Code: {debug_target.name}")
        print(f"  Script: {debug_target.script_path}")
        print(f"  Launch: {debug_command}")

    return 0


def command_supervise(args: argparse.Namespace) -> int:
    manifest = load_manifest(args.manifest)
    selected_workers = select_manifest_workers(manifest, include_names=args.worker, exclude_names=([args.debug_worker] if args.debug_worker else []))
    ensure_worker_scripts_exist(selected_workers)
    if args.debug_worker:
        _ = get_manifest_worker(manifest, args.debug_worker)

    python_path = resolve_executable_path(args.python_exe)
    target_db = resolve_target_db_name(args.db_name)
    dsn = build_dsn(args.dsn, args.auto_dsn, db_name=target_db, repo_root=REPO_ROOT)
    if not dsn:
        raise RuntimeError("Unable to resolve a Postgres DSN for supervision. Use --dsn or configure .env, .env.prod, or .env.local.")
    resolved_log_dir = resolve_full_path(REPO_ROOT, args.log_dir)
    resolved_log_dir.mkdir(parents=True, exist_ok=True)
    log_level = resolve_log_level()

    logging.basicConfig(
        level=log_level,
        format="%(asctime)s | %(levelname)-5s | %(message)s",
        stream=sys.stderr,
    )
    logger = logging.getLogger("worker-supervisor")
    logger.setLevel(log_level)

    stop_requested = False

    def _handle_signal(_signum: int, _frame: Any) -> None:
        nonlocal stop_requested
        stop_requested = True

    previous_handlers = {
        signal.SIGTERM: signal.getsignal(signal.SIGTERM),
        signal.SIGINT: signal.getsignal(signal.SIGINT),
    }
    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    last_db_state: Optional[bool] = None
    no_maintenance = args.no_maintenance or _env_flag_enabled("WORKER_DISABLE_MAINTENANCE")
    seed_check_interval_seconds = float(
        os.environ.get("WORKER_MANIFEST_SEED_CHECK_INTERVAL_SECONDS") or MANIFEST_SEED_CHECK_INTERVAL_SECONDS
    )
    seed_check_interval_seconds = max(args.retry_interval_seconds, seed_check_interval_seconds)
    last_manifest_seed_check_at: Optional[float] = None
    state_update_interval_seconds = float(
        os.environ.get("WORKER_MANAGER_STATE_UPDATE_INTERVAL_SECONDS") or MANAGER_STATE_UPDATE_INTERVAL_SECONDS
    )
    state_update_interval_seconds = max(5.0, state_update_interval_seconds)
    last_state_update_at: Optional[float] = None
    last_state_schema_attempt_at: float = 0.0
    state_schema_ready = ensure_worker_manager_state_schema(dsn, logger)
    try:
        logger.info(
            "worker supervision started: db_name=%s retry_interval_seconds=%s maintenance=%s",
            target_db,
            args.retry_interval_seconds,
            "off" if no_maintenance else "on",
        )
        while not stop_requested:
            now = time.monotonic()
            ensure_seed_tasks = (
                last_manifest_seed_check_at is None
                or (now - last_manifest_seed_check_at) >= seed_check_interval_seconds
            )
            outcome = supervise_once(
                selected_workers=selected_workers,
                python_path=python_path,
                target_db=target_db,
                resolved_log_dir=resolved_log_dir,
                manifest_path=manifest.path,
                maintenance_log_prefix=manifest.maintenance.log_prefix,
                reset_interval_seconds=args.reset_interval_seconds or manifest.maintenance.reset_interval_seconds,
                logger=logger,
                dsn=dsn,
                no_maintenance=no_maintenance,
                ensure_seed_tasks=ensure_seed_tasks,
            )
            seed_checked_at: Optional[datetime] = None
            if ensure_seed_tasks and outcome.database_available:
                last_manifest_seed_check_at = now
                seed_checked_at = datetime.now(timezone.utc)

            if outcome.database_available != last_db_state:
                if outcome.database_available:
                    logger.info("Database connection is available")
                else:
                    if outcome.database_error:
                        logger.warning("Database connection is unavailable; retrying. reason=%s", outcome.database_error)
                    else:
                        logger.warning("Database connection is unavailable; retrying")
                last_db_state = outcome.database_available

            if outcome.started_workers:
                logger.info("Started workers: %s", ", ".join(outcome.started_workers))
            if outcome.stopped_workers:
                logger.info("Stopped workers: %s", ", ".join(outcome.stopped_workers))
            if outcome.maintenance_started:
                logger.info("Maintenance supervision is running")
            if outcome.maintenance_stopped:
                logger.info("Maintenance process stopped while database was unavailable")

            if not state_schema_ready and outcome.database_available and (now - last_state_schema_attempt_at) >= 60:
                last_state_schema_attempt_at = now
                state_schema_ready = ensure_worker_manager_state_schema(dsn, logger)

            if state_schema_ready and (
                last_state_update_at is None or (now - last_state_update_at) >= state_update_interval_seconds
            ):
                maintenance_processes = [] if no_maintenance else find_maintenance_processes(Path(__file__).resolve())
                running_worker_names = outcome.running_workers or tuple(
                    sorted(process.name for process in find_managed_worker_processes(selected_workers))
                )
                record_worker_manager_supervisor_state(
                    dsn,
                    outcome=outcome,
                    selected_workers=selected_workers,
                    running_worker_names=running_worker_names,
                    maintenance_processes=maintenance_processes,
                    target_db=target_db,
                    manifest_path=manifest.path,
                    resolved_log_dir=resolved_log_dir,
                    no_maintenance=no_maintenance,
                    seed_check_interval_seconds=int(seed_check_interval_seconds),
                    seed_checked_at=seed_checked_at,
                    logger=logger,
                )
                last_state_update_at = now

            if stop_requested:
                break
            time.sleep(args.retry_interval_seconds)
    finally:
        signal.signal(signal.SIGTERM, previous_handlers[signal.SIGTERM])
        signal.signal(signal.SIGINT, previous_handlers[signal.SIGINT])
        stop_managed_processes(find_managed_worker_processes(selected_workers), logger)
        if not no_maintenance:
            stop_managed_processes(find_maintenance_processes(Path(__file__).resolve()), logger)
        logger.info("worker supervision stopped")

    return 0


def command_stop(args: argparse.Namespace) -> int:
    manifest = load_manifest(args.manifest)
    selected_workers = select_manifest_workers(manifest, include_names=args.worker)
    processes = find_managed_worker_processes(selected_workers)
    maintenance_processes = [] if args.worker else find_maintenance_processes(Path(__file__).resolve())

    if not processes and not maintenance_processes:
        print("No managed worker processes are currently running.")
        return 0

    for process in processes:
        print(f"Stopping worker '{process.name}' (PID {process.process_id})")
        stop_process(process)

    for process in maintenance_processes:
        print(f"Stopping maintenance process (PID {process.process_id})")
        stop_process(process)

    return 0


def command_restart(args: argparse.Namespace) -> int:
    if args.refresh_db or args.seed_path:
        stop_args = argparse.Namespace(manifest=args.manifest, worker=[])
    else:
        stop_args = argparse.Namespace(manifest=args.manifest, worker=args.worker)
    command_stop(stop_args)
    return command_start(args)


def command_refresh_db(args: argparse.Namespace) -> int:
    docker_path = resolve_executable_path("docker")
    target_db = resolve_target_db_name(
        args.db_name,
        docker_path=docker_path,
        container_name=args.container_name,
        prefer_container=True,
    )
    print(f"Resetting schema in container '{args.container_name}' for database '{target_db}'")
    refresh_database(docker_path, args.container_name, args.schema_script_path, target_db)
    return 0


def command_seed(args: argparse.Namespace) -> int:
    docker_path = resolve_executable_path("docker")
    target_db = resolve_target_db_name(
        args.db_name,
        docker_path=docker_path,
        container_name=args.container_name,
        prefer_container=True,
    )
    seed_files = seed_database(docker_path, args.container_name, target_db, resolve_full_path(REPO_ROOT, args.path))
    for path in seed_files:
        print(f"Applied seed: {path}")
    return 0


def command_worker_stat(args: argparse.Namespace) -> int:
    manifest = load_manifest(args.manifest)
    selected_workers = select_manifest_workers(manifest, include_names=args.worker)
    selected_names = [worker.name for worker in selected_workers]
    dsn = build_manager_dsn(args)
    db_workers = fetch_worker_stats(dsn, selected_names)
    processes = find_managed_worker_processes(selected_workers)
    print_worker_status(processes, db_workers, as_json=args.json)
    return 0


def command_task_stat(args: argparse.Namespace) -> int:
    manifest = load_manifest(args.manifest)
    selected_workers = select_manifest_workers(manifest, include_names=args.worker)
    selected_queue_names = collect_manifest_queue_names(selected_workers) if args.worker else None
    dsn = build_manager_dsn(args)
    detail = fetch_task_detail(dsn, task_id=args.task_id, task_uuid=args.task_uuid)
    payload = fetch_task_stats(dsn, selected_queue_names)
    payload["detail"] = detail
    print_task_status(payload, as_json=args.json)
    return 0


def command_maintenance(args: argparse.Namespace) -> int:
    """Run the maintenance loop with actions from manifest."""
    manifest = load_manifest(args.manifest)

    run_maintenance_loop(
        dsn=build_manager_dsn(args),
        interval_seconds=args.interval_seconds,
        actions=manifest.maintenance.actions,
    )
    return 0


def add_manifest_arg(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--manifest", default=str(DEFAULT_MANIFEST_PATH), help=f"Worker manifest path (default: {DEFAULT_MANIFEST_PATH})")


def add_worker_filter_arg(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--worker", action="append", default=[], help="Worker name to include. Repeat to target multiple workers.")


def add_container_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--container-name", default=DEFAULT_CONTAINER_NAME, help=f"Docker container name (default: {DEFAULT_CONTAINER_NAME})")
    parser.add_argument(
        "--schema-script-path",
        default=DEFAULT_SCHEMA_SCRIPT_PATH,
        help=f"Schema bootstrap script path inside the container (default: {DEFAULT_SCHEMA_SCRIPT_PATH})",
    )
    parser.add_argument("--db-name", default=None, help="Target database name override")


def add_dsn_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--dsn", default=None, help="Explicit Postgres DSN")
    parser.add_argument(
        "--auto-dsn",
        dest="auto_dsn",
        action="store_true",
        default=True,
        help="Build DSN from .env/.env.prod/.env.local and environment variables (default: on)",
    )
    parser.add_argument(
        "--no-auto-dsn",
        dest="auto_dsn",
        action="store_false",
        help="Disable automatic DSN generation",
    )
    parser.add_argument("--db-name", default=None, help="Database name override when auto-building the DSN")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Manage the Python workers under workers/pws_workers/")
    subparsers = parser.add_subparsers(dest="command", required=True)

    start_parser = subparsers.add_parser("start", help="Start workers from the manifest")
    add_manifest_arg(start_parser)
    add_worker_filter_arg(start_parser)
    add_container_args(start_parser)
    start_parser.add_argument("--python-exe", default="python", help="Python executable used to launch workers")
    start_parser.add_argument("--log-dir", default=str(DEFAULT_LOG_DIR), help=f"Directory for stdout/stderr logs (default: {DEFAULT_LOG_DIR})")
    start_parser.add_argument("--refresh-db", action="store_true", help="Reset the schema before starting workers")
    start_parser.add_argument("--seed-path", default=None, help="Seed SQL file or directory to apply before worker startup")
    start_parser.add_argument("--debug-worker", default=None, help="Worker name to exclude from background startup for VS Code debugging")
    start_parser.add_argument(
        "--no-maintenance",
        action="store_true",
        help="Skip the background maintenance process (scheduled-task promotion and stuck-task reset)",
    )
    start_parser.add_argument(
        "--reset-interval-seconds",
        type=int,
        default=None,
        help="Maintenance interval in seconds for scheduled-task promotion and stuck-task reset",
    )
    start_parser.set_defaults(func=command_start)

    supervise_parser = subparsers.add_parser("supervise", help="Keep managed workers running and recover from DB outages")
    add_manifest_arg(supervise_parser)
    add_worker_filter_arg(supervise_parser)
    add_dsn_args(supervise_parser)
    supervise_parser.add_argument("--python-exe", default="python", help="Python executable used to launch workers")
    supervise_parser.add_argument("--log-dir", default=str(DEFAULT_LOG_DIR), help=f"Directory for stdout/stderr logs (default: {DEFAULT_LOG_DIR})")
    supervise_parser.add_argument("--debug-worker", default=None, help="Worker name to exclude from background startup for VS Code debugging")
    supervise_parser.add_argument(
        "--no-maintenance",
        action="store_true",
        help="Skip the background maintenance process (scheduled-task promotion and stuck-task reset)",
    )
    supervise_parser.add_argument(
        "--reset-interval-seconds",
        type=int,
        default=None,
        help="Maintenance interval in seconds for scheduled-task promotion and stuck-task reset",
    )
    supervise_parser.add_argument("--retry-interval-seconds", type=float, default=5.0, help="Seconds between DB health checks and restart attempts")
    supervise_parser.set_defaults(func=command_supervise)

    stop_parser = subparsers.add_parser("stop", help="Stop running managed workers")
    add_manifest_arg(stop_parser)
    add_worker_filter_arg(stop_parser)
    stop_parser.set_defaults(func=command_stop)

    restart_parser = subparsers.add_parser("restart", help="Restart managed workers")
    add_manifest_arg(restart_parser)
    add_worker_filter_arg(restart_parser)
    add_container_args(restart_parser)
    restart_parser.add_argument("--python-exe", default="python", help="Python executable used to launch workers")
    restart_parser.add_argument("--log-dir", default=str(DEFAULT_LOG_DIR), help=f"Directory for stdout/stderr logs (default: {DEFAULT_LOG_DIR})")
    restart_parser.add_argument("--refresh-db", action="store_true", help="Reset the schema before starting workers")
    restart_parser.add_argument("--seed-path", default=None, help="Seed SQL file or directory to apply before worker startup")
    restart_parser.add_argument("--debug-worker", default=None, help="Worker name to exclude from background startup for VS Code debugging")
    restart_parser.add_argument(
        "--no-maintenance",
        action="store_true",
        help="Skip the background maintenance process (scheduled-task promotion and stuck-task reset)",
    )
    restart_parser.add_argument(
        "--reset-interval-seconds",
        type=int,
        default=None,
        help="Maintenance interval in seconds for scheduled-task promotion and stuck-task reset",
    )
    restart_parser.set_defaults(func=command_restart)

    refresh_parser = subparsers.add_parser("refresh-db", help="Reset the schema database inside Docker")
    add_container_args(refresh_parser)
    refresh_parser.set_defaults(func=command_refresh_db)

    seed_parser = subparsers.add_parser("seed", help="Apply a SQL seed file or directory inside Docker")
    add_container_args(seed_parser)
    seed_parser.add_argument("--path", required=True, help="Seed SQL file or directory path")
    seed_parser.set_defaults(func=command_seed)

    worker_stat_parser = subparsers.add_parser("worker-stat", help="Show worker process and database stats")
    add_manifest_arg(worker_stat_parser)
    add_worker_filter_arg(worker_stat_parser)
    add_dsn_args(worker_stat_parser)
    worker_stat_parser.add_argument("--json", action="store_true", help="Emit JSON")
    worker_stat_parser.set_defaults(func=command_worker_stat)

    task_stat_parser = subparsers.add_parser("task-stat", help="Show task scheduler stats")
    add_manifest_arg(task_stat_parser)
    add_worker_filter_arg(task_stat_parser)
    add_dsn_args(task_stat_parser)
    task_stat_parser.add_argument("--task-id", type=int, default=None, help="Specific task id to inspect")
    task_stat_parser.add_argument("--task-uuid", default=None, help="Specific task UUID to inspect")
    task_stat_parser.add_argument("--json", action="store_true", help="Emit JSON")
    task_stat_parser.set_defaults(func=command_task_stat)

    maintenance_parser = subparsers.add_parser(
        "maintenance",
        help="Run the background maintenance loop (scheduled-task promotion and stuck-task reset)",
    )
    add_manifest_arg(maintenance_parser)
    add_dsn_args(maintenance_parser)
    maintenance_parser.add_argument("--interval-seconds", type=int, default=60, help=argparse.SUPPRESS)
    maintenance_parser.set_defaults(func=command_maintenance)

    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
