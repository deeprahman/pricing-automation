from __future__ import annotations

import json
import logging
import threading
import time
import traceback
from typing import Any, Dict, Optional

import psycopg  # type: ignore


LEVEL_RANK = {
    "DEBUG": 10,
    "INFO": 20,
    "WARN": 30,
    "ERROR": 40,
    "FATAL": 50,
}


class NullAppLogger:
    def debug(self, *_args, **_kwargs) -> None:
        return None

    def info(self, *_args, **_kwargs) -> None:
        return None

    def warn(self, *_args, **_kwargs) -> None:
        return None

    def error(self, *_args, **_kwargs) -> None:
        return None

    def fatal(self, *_args, **_kwargs) -> None:
        return None

    def db_before_write(self, *_args, **_kwargs) -> None:
        return None

    def db_after_write(self, *_args, **_kwargs) -> None:
        return None

    def db_before_read(self, *_args, **_kwargs) -> None:
        return None

    def db_after_read(self, *_args, **_kwargs) -> None:
        return None

    def after_processing(self, *_args, **_kwargs) -> None:
        return None

    def close(self) -> None:
        return None


class AppLogger:
    def __init__(
        self,
        *,
        dsn: str,
        worker_id: str,
        worker_name: str,
        fallback_logger: logging.Logger,
        level_cache_ttl: float = 30.0,
    ) -> None:
        self.dsn = dsn
        self.worker_id = worker_id
        self.worker_name = worker_name
        self.fallback_logger = fallback_logger
        self.level_cache_ttl = float(level_cache_ttl)
        self._conn = None
        self._conn_lock = threading.RLock()
        self._level = "INFO"
        self._level_lock = threading.Lock()
        self._last_level_refresh = 0.0
        self._warned_db_write = False
        self._warned_level_read = False

    def debug(self, message: str, **kwargs) -> None:
        self._write("DEBUG", message, **kwargs)

    def info(self, message: str, **kwargs) -> None:
        self._write("INFO", message, **kwargs)

    def warn(self, message: str, **kwargs) -> None:
        self._write("WARN", message, **kwargs)

    def error(self, message: str, exc: Optional[BaseException] = None, **kwargs) -> None:
        self._write("ERROR", message, exc=exc, **kwargs)

    def fatal(self, message: str, exc: Optional[BaseException] = None, **kwargs) -> None:
        self._write("FATAL", message, exc=exc, **kwargs)

    def db_before_write(self, operation: str, data: Any, **kwargs) -> None:
        self.debug(operation, metadata={"phase": "db_before_write", "data": data}, **kwargs)

    def db_after_write(self, operation: str, result: Any, **kwargs) -> None:
        self.debug(operation, metadata={"phase": "db_after_write", "result": result}, **kwargs)

    def db_before_read(self, operation: str, params: Any, **kwargs) -> None:
        self.debug(operation, metadata={"phase": "db_before_read", "params": params}, **kwargs)

    def db_after_read(self, operation: str, result: Any, **kwargs) -> None:
        self.debug(operation, metadata={"phase": "db_after_read", "result": result}, **kwargs)

    def after_processing(self, operation: str, summary: Any, **kwargs) -> None:
        self.debug(operation, metadata={"phase": "after_processing", "summary": summary}, **kwargs)

    def close(self) -> None:
        with self._conn_lock:
            if self._conn is not None:
                self._conn.close()
                self._conn = None

    def _write(
        self,
        level: str,
        message: str,
        *,
        exc: Optional[BaseException] = None,
        action_name: Optional[str] = None,
        task_id: Optional[int] = None,
        task_uuid: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
        error_code: Optional[str] = None,
        error_stack: Optional[str] = None,
    ) -> None:
        if not self._should_log(level):
            return

        stack = error_stack
        if exc is not None and stack is None:
            stack = "".join(traceback.format_exception(type(exc), exc, exc.__traceback__))

        base_metadata = {
            "worker_id": self.worker_id,
            "worker_name": self.worker_name,
            "task_id": task_id,
            "task_uuid": task_uuid,
            "action_name": action_name,
        }
        if metadata:
            base_metadata.update(metadata)

        self._write_to_db(level, message, base_metadata, error_code=error_code, error_stack=stack)

    def _should_log(self, level: str) -> bool:
        self._refresh_level()
        current = self._level if self._level in LEVEL_RANK else "INFO"
        return LEVEL_RANK[level] >= LEVEL_RANK[current]

    def _refresh_level(self) -> None:
        now = time.monotonic()
        if now - self._last_level_refresh < self.level_cache_ttl:
            return
        with self._level_lock:
            if now - self._last_level_refresh < self.level_cache_ttl:
                return
            try:
                conn = self._ensure_conn()
                with conn.cursor() as cur:
                    cur.execute(
                        "SELECT get_runtime_variable(%s, %s, %s, %s, %s)",
                        (self.worker_id, "logging_level", "global", False, False),
                    )
                    row = cur.fetchone()
                level = row[0] if row else None
                if isinstance(level, str):
                    try:
                        level = json.loads(level)
                    except json.JSONDecodeError:
                        pass
                candidate = str(level or "INFO").upper()
                if candidate in LEVEL_RANK:
                    self._level = candidate
                self._warned_level_read = False
            except Exception as exc:
                if not self._warned_level_read:
                    self.fallback_logger.warning("AppLogger level refresh failed: %s", exc)
                    self._warned_level_read = True
            finally:
                self._last_level_refresh = now

    def _write_to_db(
        self,
        level: str,
        message: str,
        metadata: Dict[str, Any],
        *,
        error_code: Optional[str],
        error_stack: Optional[str],
    ) -> None:
        try:
            conn = self._ensure_conn()
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO app_logs (
                        level,
                        message,
                        source,
                        workflow_name,
                        metadata,
                        error_code,
                        error_stack
                    ) VALUES (%s, %s, %s, %s, %s::jsonb, %s, %s)
                    """,
                    (
                        level,
                        message,
                        self.worker_name,
                        self.worker_name,
                        json.dumps(metadata, default=str),
                        error_code,
                        error_stack,
                    ),
                )
            self._warned_db_write = False
        except Exception as exc:
            if not self._warned_db_write:
                self.fallback_logger.warning("AppLogger DB write failed: %s", exc)
                self._warned_db_write = True

    def _ensure_conn(self):
        with self._conn_lock:
            if self._conn is None or self._conn.closed:
                self._conn = psycopg.connect(self.dsn, autocommit=True)
            return self._conn
