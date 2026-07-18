#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Optional, Sequence

CURRENT_DIR = Path(__file__).resolve().parent
WORKERS_ROOT = Path(__file__).resolve().parents[2]
REPO_ROOT = Path(__file__).resolve().parents[3]
for candidate in (WORKERS_ROOT, REPO_ROOT):
    if str(candidate) not in sys.path:
        sys.path.insert(0, str(candidate))

from pws_workers.shared.worker_runtime import (
    NoOpStepLog,
    add_common_worker_args,
    build_dsn,
    configure_worker_logger,
    normalize_payload_meta,
)
from pws_workers.shared import (
    ActionStateManager,
    AppLogger,
    ManagedSchedulerClient as MessagesSchedulerClient,
    ManagedWorkerContext as MessagesWorkerContext,
    ManagedWorkerRunner as MessagesWorkerRunner,
    NullAppLogger,
    as_optional_string as _as_optional_string,
    coerce_optional_int as _coerce_optional_int,
    coerce_required_int as _coerce_required_int,
    default_app_logger as _default_app_logger,
    default_step as _default_step,
    delete_runtime_variable,
    enqueue_with_meta,
    generate_key as _generate_key,
    get_booking_id as _get_booking_id,
    get_runtime_variable,
    metadata_only as _metadata_only,
    parse_runtime_variable_ttl_config,
    resolve_runtime_variable_ttl,
    set_runtime_variable,
    task_log_kwargs as _task_log_kwargs,
)


WORKER = "messages-worker"
PRIMARY_QUEUE = "messages-service"
SUBSCRIBED_QUEUES: Sequence[str] = (PRIMARY_QUEUE,)

FETCH_ACTION = "fetch"
FETCH_DUMMY_ACTION = "fetch_dummy"
FETCH_RESPONSE_ACTION = "fetch_res_handler"
STORE_MESSAGES_ACTION = "store_messages"
SCAN_UNCLASSIFIED_ACTION = "scan_unclassified"
CHECK_CLASSIFICATION_ACTION = "check_classification"
CHECK_CLASIFICATION_ACTION = "check_clasification"
HANDLE_UNCLASSIFIED_ACTION = "handle_unclassified_messages"
HANDLE_UNCLASSIFIED_DUMMY_ACTION = "handle_unclassified_dummy_messages"
HANDLE_CLASSIFIED_ACTION = "handle_classified_messages"
HANDLE_CLASSIFIED_DUMMY_ACTION = "handle_classified_dummy_messages"

EXTERNAL_SERVICES_WORKER = "external-services-worker"
EXTERNAL_SERVICES_QUEUE = "external-services"
EXTERNAL_SERVICE_FETCH_ACTION = "get_ownerrez_messages"
EXTERNAL_SERVICE_DUMMY_FETCH_ACTION = "get_dummy_messages"
EXTERNAL_SERVICE_CLASSIFY_ACTION = "classify_messages"
EXTERNAL_SERVICE_DUMMY_CLASSIFY_ACTION = "classify_dummy_messages"
RUNTIME_SCOPE_SOURCE = "scanner-classifier"
RUNTIME_SCOPE_IN = "classifier-extsvc"
RUNTIME_SCOPE_OUT = "extsvc-classifier"
RUNTIME_SCOPE_FETCH_REQUEST = "fetch-extsvc-request"
RUNTIME_SCOPE_FETCH_RESPONSE = "extsvc-fetch-response"
RUNTIME_SCOPE_FETCH_STORE = "fetch-store-request"
RUNTIME_SCOPE_STORE_FETCH = "store-next-fetch"
RUNTIME_SCOPE_CHECK_CLASIFICATION_OUT = "check-classification-result"
RUNTIME_TTL_MINUTES = 15
DEFAULT_SCAN_UNCLASSIFIED_LIMIT = 25
SCAN_STALE_AFTER_INTERVAL = "15 minutes"
FALLBACK_MESSAGE_CLASS = "unclassified"
RUNTIME_VARIABLE_TTL_CONFIG: Optional[Dict[str, Any]] = None


def _warn_runtime_variable_unavailable(
    log,
    task,
    *,
    action_name: str,
    worker_id: str,
    scope: str,
    key: str,
    reason: Exception,
) -> None:
    log.warn(
        "runtime variable unavailable",
        metadata={
            "runtime_worker_id": worker_id,
            "runtime_scope": scope,
            "runtime_key": key,
            "reason": str(reason),
        },
        **_task_log_kwargs(task, action_name),
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Combined messages worker")
    parser.add_argument("--dsn", default=None, help="Postgres DSN")
    parser.add_argument("--auto-dsn", action="store_true", help="Build DSN from .env/env vars")
    parser.add_argument("--db-name", default=None, help="DB name override when auto-building DSN")
    parser.add_argument(
        "--log-dir",
        default=str(CURRENT_DIR / "logs"),
        help="Directory for worker log files",
    )
    parser.add_argument("--poll-interval", type=float, default=1.0, help="Seconds between polls")
    add_common_worker_args(parser)
    return parser.parse_args()


def build_fetch_return_ref() -> Dict[str, str]:
    return {"worker": WORKER, "queue": PRIMARY_QUEUE, "action": FETCH_RESPONSE_ACTION}


def build_classify_return_ref() -> Dict[str, str]:
    return {"worker": WORKER, "queue": PRIMARY_QUEUE, "action": HANDLE_CLASSIFIED_ACTION}


def build_dummy_classify_return_ref() -> Dict[str, str]:
    return {"worker": WORKER, "queue": PRIMARY_QUEUE, "action": HANDLE_CLASSIFIED_DUMMY_ACTION}


def _resolve_runtime_ttl(*, action: str, scope: str, default_ttl_minutes: int = RUNTIME_TTL_MINUTES) -> int:
    return resolve_runtime_variable_ttl(
        RUNTIME_VARIABLE_TTL_CONFIG,
        action=action,
        scope=scope,
        default_ttl_minutes=default_ttl_minutes,
    )


def fetch_thread_progress(conn, booking_id: int, thread_id: int, platform_id: int) -> Optional[Dict[str, Any]]:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT booking_id, last_seen_mid, last_seen_date_utc, "offset", "limit", total
            FROM message_thread_progress
            WHERE booking_id = %s
              AND thread_id = %s
              AND platform_id = %s
            LIMIT 1
            """,
            (booking_id, thread_id, platform_id),
        )
        row = cur.fetchone()
    if not row:
        return None
    return {
        "booking_id": int(row[0]),
        "last_seen_mid": int(row[1]) if row[1] is not None else None,
        "last_seen_date_utc": row[2],
        "offset": int(row[3]),
        "limit": int(row[4]),
        "total": int(row[5]),
    }


def upsert_thread_progress(
    conn,
    *,
    platform_id: int,
    thread_id: int,
    booking_id: int,
    offset: int,
    limit: int,
    total: int,
    last_seen_mid: Optional[int],
    last_seen_date_utc: Optional[str],
) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO message_thread_progress (
                platform_id,
                thread_id,
                booking_id,
                last_seen_mid,
                last_seen_date_utc,
                "offset",
                "limit",
                total
            ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (platform_id, thread_id) DO UPDATE
            SET booking_id = EXCLUDED.booking_id,
                last_seen_mid = EXCLUDED.last_seen_mid,
                last_seen_date_utc = EXCLUDED.last_seen_date_utc,
                "offset" = EXCLUDED."offset",
                "limit" = EXCLUDED."limit",
                total = EXCLUDED.total
            """,
            (
                platform_id,
                thread_id,
                booking_id,
                last_seen_mid,
                last_seen_date_utc,
                offset,
                limit,
                total,
            ),
        )


def get_thread_primary_classes(conn, *, platform_id: int, thread_id: int) -> Dict[str, Any]:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT to_jsonb(t)
            FROM get_thread_primary_classes(%s, %s) AS t
            """,
            (platform_id, thread_id),
        )
        row = cur.fetchone()

    if not row:
        return {
            "platform_id": int(platform_id),
            "thread_id": int(thread_id),
            "classes": [],
            "class_pos": [],
            "ids_message": [],
        }

    record = row[0]
    if isinstance(record, str):
        try:
            record = json.loads(record)
        except Exception:
            record = {}
    if not isinstance(record, dict):
        record = {}

    raw_classes = record.get("classes", [])
    raw_class_pos = record.get("class_pos", [])
    raw_ids_message = record.get("ids_message", [])

    classes = [str(item) for item in raw_classes or [] if item is not None] if isinstance(raw_classes, list) else []
    class_pos = [int(item) for item in raw_class_pos or [] if item is not None] if isinstance(raw_class_pos, list) else []
    ids_message = [int(item) for item in raw_ids_message or [] if item is not None] if isinstance(raw_ids_message, list) else []

    return {
        "platform_id": int(record["platform_id"]) if record.get("platform_id") is not None else int(platform_id),
        "thread_id": int(record["thread_id"]) if record.get("thread_id") is not None else int(thread_id),
        "classes": classes,
        "class_pos": class_pos,
        "ids_message": ids_message,
    }


def _normalize_data_ref(payload: Dict[str, Any], *, default_scope: str) -> Dict[str, Optional[str]]:
    data_ref = payload.get("data_ref") if isinstance(payload.get("data_ref"), dict) else {}
    return {
        "worker_id": _as_optional_string(data_ref.get("worker_id")),
        "scope": _as_optional_string(data_ref.get("scope")) or default_scope,
        "key": _as_optional_string(data_ref.get("key")),
    }


def _message_date_utc(item: Dict[str, Any]) -> Optional[str]:
    return _as_optional_string(item.get("date_utc")) or _as_optional_string(item.get("sent_date_utc"))


def _parse_utc_datetime(value: Any) -> Optional[datetime]:
    raw_value = _as_optional_string(value)
    if raw_value is None:
        return None
    normalized = raw_value[:-1] + "+00:00" if raw_value.endswith("Z") else raw_value
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _format_since_utc(value: Any) -> Optional[str]:
    if value is None:
        return None
    if isinstance(value, datetime):
        parsed = value
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
    return _as_optional_string(value)


def _latest_message_item(items: list[Any]) -> Dict[str, Any]:
    latest_item: Dict[str, Any] = {}
    latest_date: Optional[datetime] = None
    latest_date_raw: Optional[str] = None
    latest_mid: Optional[int] = None
    for item in items:
        if not isinstance(item, dict):
            continue
        item_date_raw = _message_date_utc(item)
        item_date = _parse_utc_datetime(item_date_raw)
        item_mid = _coerce_optional_int(item.get("id"))
        if not latest_item:
            latest_item = item
            latest_date = item_date
            latest_date_raw = item_date_raw
            latest_mid = item_mid
            continue
        if item_date is not None and (latest_date is None or item_date > latest_date):
            latest_item = item
            latest_date = item_date
            latest_date_raw = item_date_raw
            latest_mid = item_mid
            continue
        if item_date is not None and latest_date is not None and item_date == latest_date:
            if item_mid is not None and (latest_mid is None or item_mid > latest_mid):
                latest_item = item
                latest_mid = item_mid
            continue
        if item_date is None and latest_date is None and item_date_raw and latest_date_raw and item_date_raw > latest_date_raw:
            latest_item = item
            latest_date_raw = item_date_raw
            latest_mid = item_mid
            continue
        if item_date is None and latest_date is None and item_date_raw == latest_date_raw:
            if item_mid is not None and (latest_mid is None or item_mid > latest_mid):
                latest_item = item
                latest_mid = item_mid
    return latest_item


def build_fetch_request_data(
    *,
    booking_id: int,
    thread_id: int,
    platform_id: int,
    offset: Optional[int],
    limit: Optional[int],
    since_utc: Optional[str] = None,
    last_seen_mid: Optional[int] = None,
) -> Dict[str, Any]:
    return {
        "booking_id": booking_id,
        "thread_id": thread_id,
        "platform_id": platform_id,
        "offset": offset,
        "limit": limit,
        "since_utc": since_utc,
        "last_seen_mid": last_seen_mid,
    }


def resolve_external_fetch_action(fetch_action: str) -> str:
    if fetch_action == FETCH_DUMMY_ACTION:
        return EXTERNAL_SERVICE_DUMMY_FETCH_ACTION
    return EXTERNAL_SERVICE_FETCH_ACTION


def resolve_next_fetch_action(payload: Dict[str, Any]) -> str:
    explicit_action = _as_optional_string(payload.get("next_fetch_action"))
    if explicit_action:
        return explicit_action
    source_action = _as_optional_string(payload.get("source_action"))
    if source_action == EXTERNAL_SERVICE_DUMMY_FETCH_ACTION:
        return FETCH_DUMMY_ACTION
    return FETCH_ACTION


def resolve_external_classify_action(worker_action: str) -> str:
    if worker_action == HANDLE_UNCLASSIFIED_DUMMY_ACTION:
        return EXTERNAL_SERVICE_DUMMY_CLASSIFY_ACTION
    return EXTERNAL_SERVICE_CLASSIFY_ACTION


def resolve_classify_return_ref(worker_action: str) -> Dict[str, str]:
    if worker_action == HANDLE_UNCLASSIFIED_DUMMY_ACTION:
        return build_dummy_classify_return_ref()
    return build_classify_return_ref()


def build_store_messages_payload(payload: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    result = payload.get("result")
    if not isinstance(result, dict):
        return None
    items = result.get("items")
    if not isinstance(items, list) or not items:
        return None
    booking_id = _get_booking_id(payload, required=False)
    thread_data = result.get("thread") if isinstance(result.get("thread"), dict) else {}
    if booking_id is None:
        booking_id = _coerce_optional_int(thread_data.get("booking_id"))
    if booking_id is None:
        raise ValueError("booking_id is required")
    thread_id = _coerce_optional_int(payload.get("thread_id"))
    if thread_id is None:
        thread_id = _coerce_optional_int(thread_data.get("id"))
    if thread_id is None:
        raise ValueError("thread_id is required")
    platform_id = _coerce_required_int(payload, "platform_id")
    return {
        "action": STORE_MESSAGES_ACTION,
        "booking_id": booking_id,
        "thread_id": thread_id,
        "platform_id": platform_id,
        "next_fetch_action": resolve_next_fetch_action(payload),
        "items": items,
    }


def resolve_progress_update(payload: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    if payload.get("error") is not None:
        return None
    platform_id = _coerce_optional_int(payload.get("platform_id"))
    booking_id = _get_booking_id(payload, required=False)
    result = payload.get("result")
    if not isinstance(result, dict):
        return None
    thread_data = result.get("thread") if isinstance(result.get("thread"), dict) else {}
    if booking_id is None:
        booking_id = _coerce_optional_int(thread_data.get("booking_id"))
    if booking_id is None:
        return None
    thread_id = _coerce_optional_int(payload.get("thread_id"))
    if thread_id is None:
        thread_id = _coerce_optional_int(thread_data.get("id"))
    if thread_id is None:
        raise ValueError("thread_id is required for progress updates")
    items = result.get("items") if isinstance(result.get("items"), list) else []
    if not items:
        return None
    offset = _coerce_optional_int(result.get("offset"))
    limit = _coerce_optional_int(result.get("limit"))
    if offset is None:
        offset = _coerce_optional_int(payload.get("offset")) or 0
    if limit is None:
        limit = _coerce_optional_int(payload.get("limit")) or len(items)
    total = _coerce_optional_int(result.get("total"))
    if total is None:
        total = int(offset) + len(items)
    last_item = _latest_message_item(items)
    return {
        "platform_id": platform_id,
        "thread_id": thread_id,
        "booking_id": booking_id,
        "offset": offset,
        "limit": limit,
        "total": total,
        "last_seen_mid": _coerce_optional_int(last_item.get("id")),
        "last_seen_date_utc": _message_date_utc(last_item),
    }


def ensure_platform_exists(conn, platform_id: int) -> None:
    with conn.cursor() as cur:
        cur.execute("SELECT to_regclass('platforms')")
        row = cur.fetchone()
        if not row or row[0] is None:
            return
        cur.execute(
            """
            INSERT INTO platforms (id, name, type, is_active)
            VALUES (%s, %s, %s, TRUE)
            ON CONFLICT (id) DO NOTHING
            """,
            (platform_id, f"messages_worker_platform_{platform_id}", "pms"),
        )


def upsert_message_item(
    conn,
    *,
    platform_id: int,
    thread_id: int,
    booking_id: int,
    item: Dict[str, Any],
) -> int:
    mid = _coerce_required_int(item, "id")
    body = _as_optional_string(item.get("body"))
    date_utc = _message_date_utc(item)
    if not body:
        raise ValueError("item.body is required")
    if not date_utc:
        raise ValueError("item.date_utc or item.sent_date_utc is required")
    metadata = _metadata_only(
        {
            "booking_id": booking_id,
            "from_role": _as_optional_string(item.get("from_role")),
            "from_contact_id": _coerce_optional_int(item.get("from_contact_id")),
            "is_draft": item.get("is_draft") if "is_draft" in item else None,
        }
    )
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO messages (
                platform_id,
                thread_id,
                mid,
                content,
                message_timestamp,
                metadata
            ) VALUES (%s, %s, %s, %s, %s::timestamptz, %s::jsonb)
            ON CONFLICT (platform_id, thread_id, mid) DO UPDATE
            SET content = EXCLUDED.content,
                message_timestamp = EXCLUDED.message_timestamp,
                metadata = EXCLUDED.metadata
            RETURNING id
            """,
            (platform_id, thread_id, mid, body, date_utc, json.dumps(metadata, default=str)),
        )
        row = cur.fetchone()
    if not row or row[0] is None:
        raise RuntimeError("message upsert did not return an id")
    return int(row[0])


def _find_class_id(conn, name: str) -> Optional[int]:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT id
            FROM message_classes
            WHERE name = %s
            LIMIT 1
            """,
            (name,),
        )
        row = cur.fetchone()
    if not row or row[0] is None:
        return None
    return int(row[0])


def resolve_class_id(
    conn,
    name: str,
    *,
    fallback_name: str = FALLBACK_MESSAGE_CLASS,
) -> tuple[int, str]:
    class_id = _find_class_id(conn, name)
    if class_id is not None:
        return class_id, name

    fallback_id = _find_class_id(conn, fallback_name)
    if fallback_id is None:
        raise ValueError(f"class '{name}' not found and fallback class '{fallback_name}' is missing")
    return fallback_id, fallback_name


def replace_lookup(conn, *, message_id: int, class_id: int) -> None:
    with conn.cursor() as cur:
        cur.execute("DELETE FROM message_class_lookup WHERE message_id = %s", (message_id,))
        cur.execute(
            """
            INSERT INTO message_class_lookup (message_id, class_id, is_primary, source)
            VALUES (%s, %s, TRUE, 'auto')
            """,
            (message_id, class_id),
        )


def set_status(conn, *, message_id: int, status: str, last_error: Optional[str]) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE message_processing_status
            SET status = %s, last_error = %s, updated_at = NOW()
            WHERE message_id = %s
            """,
            (status, last_error, message_id),
        )


def requeue_stale_processing_messages(conn, *, stale_after: str = SCAN_STALE_AFTER_INTERVAL) -> int:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT message_id
            FROM requeue_stale_processing_messages(%s::interval)
            """,
            (str(stale_after),),
        )
        rows = cur.fetchall()
    return len(rows or [])


def fetch_unclassified_messages(
    conn,
    *,
    limit: int,
    from_role: Optional[str] = "guest",
) -> list[Dict[str, Any]]:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT message_id, content
            FROM fetch_unclassified_messages(%s::integer, %s::text)
            """,
            (int(limit), from_role),
        )
        rows = cur.fetchall()
    return [{"message_id": int(row[0]), "content": str(row[1])} for row in rows or []]


def _pending_after_cursor(items: list[Dict[str, Any]], cursor: Optional[Any], *, key_name: str) -> tuple[list[Dict[str, Any]], int]:
    if cursor is None:
        return list(items), 0
    processed = 0
    pending: list[Dict[str, Any]] = []
    skipping = True
    for item in items:
        current = item.get(key_name) if isinstance(item, dict) else None
        if skipping:
            processed += 1
            if current == cursor:
                skipping = False
            continue
        pending.append(item)
    if skipping:
        return [], len(items)
    return pending, processed


def _handle_fetch_request(context, task, *, requested_action: str) -> None:
    queue = context.main_queue
    step = _default_step(context)
    log = _default_app_logger(context)
    state = ActionStateManager.load(context, task)
    payload = task.payload
    data_ref = _normalize_data_ref(payload, default_scope=RUNTIME_SCOPE_STORE_FETCH)
    source_worker_id = data_ref["worker_id"] or context.scheduler.worker_id
    source_scope = str(data_ref["scope"])
    source_key = data_ref["key"]

    booking_id: int
    thread_id: int
    platform_id: int
    if source_key:
        if not state.is_step_done("fetch_input_loaded"):
            state.begin_step("fetch_input_loaded")
            try:
                with context.connect_db() as conn:
                    log.db_before_read(
                        "read fetch input runtime variable",
                        params={"scope": source_scope, "key": source_key},
                        **_task_log_kwargs(task, "handle_fetch"),
                    )
                    source_payload = get_runtime_variable(
                        conn,
                        worker_id=source_worker_id,
                        scope=source_scope,
                        key=str(source_key),
                    )
                    log.db_after_read(
                        "read fetch input runtime variable",
                        result={
                            "has_booking_id": isinstance(source_payload, dict) and source_payload.get("booking_id") is not None,
                            "has_thread_id": isinstance(source_payload, dict) and source_payload.get("thread_id") is not None,
                        },
                        **_task_log_kwargs(task, "handle_fetch"),
                    )
            except Exception as exc:
                if isinstance(exc, LookupError):
                    _warn_runtime_variable_unavailable(
                        log,
                        task,
                        action_name="handle_fetch",
                        worker_id=source_worker_id,
                        scope=source_scope,
                        key=str(source_key),
                        reason=exc,
                    )
                log.error(
                    "failed to read fetch input runtime variable",
                    exc=exc,
                    error_code="FETCH_INPUT_READ_FAILED",
                    **_task_log_kwargs(task, "handle_fetch"),
                )
                state.record_failure("fetch_input_loaded", str(exc))
                queue.fail_task(task, f"read fetch input failed: {exc}", retry=True)
                return

            if not isinstance(source_payload, dict):
                queue.fail_task(task, "fetch input runtime payload missing", retry=False)
                return

            try:
                booking_id = _get_booking_id(source_payload, required=True)
                thread_id = _coerce_required_int(source_payload, "thread_id")
                platform_id = _coerce_required_int(source_payload, "platform_id")
            except Exception as exc:
                queue.fail_task(task, f"invalid fetch input runtime payload: {exc}", retry=False)
                return

            state.checkpoint(
                "fetch_input_loaded",
                {
                    "source_worker_id": source_worker_id,
                    "source_scope": source_scope,
                    "source_key": source_key,
                    "booking_id": booking_id,
                    "thread_id": thread_id,
                    "platform_id": platform_id,
                },
            )

        source_data = state.get_step_data("fetch_input_loaded")
        booking_id = int(source_data["booking_id"])
        thread_id = int(source_data["thread_id"])
        platform_id = int(source_data["platform_id"])
    else:
        booking_id = _get_booking_id(payload, required=True)
        thread_id = _coerce_required_int(payload, "thread_id")
        platform_id = _coerce_required_int(payload, "platform_id")

    external_action = resolve_external_fetch_action(requested_action)
    log.info(
        "task started",
        metadata={
            "booking_id": booking_id,
            "thread_id": thread_id,
            "requested_action": requested_action,
            "external_action": external_action,
        },
        **_task_log_kwargs(task, "handle_fetch"),
    )

    if not state.is_step_done("fetch_request_built"):
        with context.connect_db() as conn:
            log.db_before_read(
                "read message thread progress",
                params={"booking_id": booking_id, "thread_id": thread_id, "platform_id": platform_id},
                **_task_log_kwargs(task, "handle_fetch"),
            )
            progress_row = fetch_thread_progress(conn, booking_id, thread_id, platform_id)
            log.db_after_read(
                "read message thread progress",
                result=progress_row,
                **_task_log_kwargs(task, "handle_fetch"),
            )
        offset = None
        limit = None
        since_utc = None
        last_seen_mid = None
        if progress_row:
            last_seen_mid = progress_row.get("last_seen_mid")
            if requested_action == FETCH_DUMMY_ACTION:
                offset = progress_row["offset"] + progress_row["limit"]
                limit = progress_row["limit"]
            else:
                since_utc = _format_since_utc(progress_row.get("last_seen_date_utc"))
        state.checkpoint(
            "fetch_request_built",
            {
                "booking_id": booking_id,
                "thread_id": thread_id,
                "platform_id": platform_id,
                "offset": offset,
                "limit": limit,
                "since_utc": since_utc,
                "last_seen_mid": last_seen_mid,
            },
        )
    request_data = state.get_step_data("fetch_request_built")
    request_payload = build_fetch_request_data(
        booking_id=int(request_data["booking_id"]),
        thread_id=int(request_data["thread_id"]),
        platform_id=int(request_data["platform_id"]),
        offset=request_data.get("offset"),
        limit=request_data.get("limit"),
        since_utc=_as_optional_string(request_data.get("since_utc")),
        last_seen_mid=_coerce_optional_int(request_data.get("last_seen_mid")),
    )

    if not state.is_step_done("request_written"):
        state.begin_step("request_written")
        request_key = _generate_key("fetch_req")
        try:
            with context.connect_db() as conn:
                log.db_before_write(
                    "write fetch request runtime variable",
                    data={"scope": RUNTIME_SCOPE_FETCH_REQUEST, "key": request_key},
                    **_task_log_kwargs(task, "handle_fetch"),
                )
                set_runtime_variable(
                    conn,
                    worker_id=context.scheduler.worker_id,
                    scope=RUNTIME_SCOPE_FETCH_REQUEST,
                    key=request_key,
                    value=request_payload,
                    ttl_minutes=_resolve_runtime_ttl(action=requested_action, scope=RUNTIME_SCOPE_FETCH_REQUEST),
                )
                log.db_after_write(
                    "write fetch request runtime variable",
                    result={"scope": RUNTIME_SCOPE_FETCH_REQUEST, "key": request_key},
                    **_task_log_kwargs(task, "handle_fetch"),
                )
        except Exception as exc:
            log.error(
                "failed to persist fetch request runtime variable",
                exc=exc,
                error_code="FETCH_REQUEST_STORE_FAILED",
                **_task_log_kwargs(task, "handle_fetch"),
            )
            state.record_failure("request_written", str(exc))
            queue.fail_task(task, f"store fetch request failed: {exc}", retry=True)
            return
        state.checkpoint("request_written", {"request_key": request_key})

    if not state.is_step_done("downstream_enqueued"):
        state.begin_step("downstream_enqueued")
        request_key = state.get_step_data("request_written")["request_key"]
        downstream_payload = {
            "action": external_action,
            "data_ref": {
                "worker_id": context.scheduler.worker_id,
                "scope": RUNTIME_SCOPE_FETCH_REQUEST,
                "key": request_key,
            },
            "return_ref": build_fetch_return_ref(),
        }
        log.db_before_write("enqueue external fetch task", data=downstream_payload, **_task_log_kwargs(task, "handle_fetch"))
        downstream_task_uuid = enqueue_with_meta(
            context.queue(EXTERNAL_SERVICES_QUEUE),
            EXTERNAL_SERVICES_WORKER,
            downstream_payload,
            current_task=task,
            current_worker=WORKER,
            current_action=requested_action,
            next_worker=WORKER,
            next_action=FETCH_RESPONSE_ACTION,
        )
        log.db_after_write(
            "enqueue external fetch task",
            result={"downstream_task_uuid": downstream_task_uuid},
            **_task_log_kwargs(task, "handle_fetch"),
        )
        state.checkpoint("downstream_enqueued", {"downstream_task_uuid": downstream_task_uuid})

    request_key = state.get_step_data("request_written")["request_key"]
    status = (
        "forwarded_to_external_service"
        if requested_action == FETCH_ACTION
        else "forwarded_to_external_service_handler"
    )
    result = {
        "status": status,
        "booking_id": booking_id,
        "thread_id": thread_id,
        "platform_id": platform_id,
        "requested_action": requested_action,
        "external_action": external_action,
        "offset": request_payload.get("offset"),
        "limit": request_payload.get("limit"),
        "since_utc": request_payload.get("since_utc"),
        "request_key": request_key,
        "downstream_task_uuid": state.get_step_data("downstream_enqueued")["downstream_task_uuid"],
    }
    step.log("messages worker fetch forwarded", result)
    log.info("task completed", metadata=result, **_task_log_kwargs(task, "handle_fetch"))
    queue.complete_task(task, result)


def handle_fetch(context, task) -> None:
    _handle_fetch_request(context, task, requested_action=FETCH_ACTION)


def handle_fetch_dummy(context, task) -> None:
    _handle_fetch_request(context, task, requested_action=FETCH_DUMMY_ACTION)


def handle_fetch_response(context, task) -> None:
    queue = context.main_queue
    step = _default_step(context)
    log = _default_app_logger(context)
    state = ActionStateManager.load(context, task)
    payload = task.payload

    response_ref = _normalize_data_ref(payload, default_scope=RUNTIME_SCOPE_FETCH_RESPONSE)
    response_worker_id = response_ref["worker_id"] or context.scheduler.worker_id
    response_scope = str(response_ref["scope"])
    response_key = response_ref["key"]

    source_payload = payload
    if response_key:
        if not state.is_step_done("response_loaded"):
            state.begin_step("response_loaded")
            try:
                with context.connect_db() as conn:
                    log.db_before_read(
                        "read fetch response runtime variable",
                        params={"scope": response_scope, "key": response_key},
                        **_task_log_kwargs(task, "handle_fetch_response"),
                    )
                    response_payload = get_runtime_variable(
                        conn,
                        worker_id=response_worker_id,
                        scope=response_scope,
                        key=str(response_key),
                    )
                    log.db_after_read(
                        "read fetch response runtime variable",
                        result={
                            "has_result": isinstance(response_payload, dict) and isinstance(response_payload.get("result"), dict),
                            "has_error": isinstance(response_payload, dict) and response_payload.get("error") is not None,
                        },
                        **_task_log_kwargs(task, "handle_fetch_response"),
                    )
            except Exception as exc:
                if isinstance(exc, LookupError):
                    _warn_runtime_variable_unavailable(
                        log,
                        task,
                        action_name="handle_fetch_response",
                        worker_id=response_worker_id,
                        scope=response_scope,
                        key=str(response_key),
                        reason=exc,
                    )
                log.error(
                    "failed to read fetch response runtime variable",
                    exc=exc,
                    error_code="FETCH_RESPONSE_READ_FAILED",
                    **_task_log_kwargs(task, "handle_fetch_response"),
                )
                state.record_failure("response_loaded", str(exc))
                queue.fail_task(task, f"read fetch response failed: {exc}", retry=True)
                return

            if not isinstance(response_payload, dict):
                queue.fail_task(task, "fetch response runtime payload missing", retry=False)
                return

            state.checkpoint(
                "response_loaded",
                {
                    "response_worker_id": response_worker_id,
                    "response_scope": response_scope,
                    "response_key": response_key,
                },
            )
            source_payload = response_payload
        else:
            response_data = state.get_step_data("response_loaded")
            response_worker_id = _as_optional_string(response_data.get("response_worker_id")) or response_worker_id
            response_scope = _as_optional_string(response_data.get("response_scope")) or response_scope
            response_key = _as_optional_string(response_data.get("response_key")) or response_key
            try:
                with context.connect_db() as conn:
                    source_payload = get_runtime_variable(
                        conn,
                        worker_id=response_worker_id,
                        scope=response_scope,
                        key=str(response_key),
                    )
            except Exception as exc:
                if isinstance(exc, LookupError):
                    _warn_runtime_variable_unavailable(
                        log,
                        task,
                        action_name="handle_fetch_response",
                        worker_id=response_worker_id,
                        scope=response_scope,
                        key=str(response_key),
                        reason=exc,
                    )
                log.error(
                    "failed to read fetch response runtime variable",
                    exc=exc,
                    error_code="FETCH_RESPONSE_READ_FAILED",
                    **_task_log_kwargs(task, "handle_fetch_response"),
                )
                state.record_failure("response_loaded", str(exc))
                queue.fail_task(task, f"read fetch response failed: {exc}", retry=True)
                return
            if not isinstance(source_payload, dict):
                queue.fail_task(task, "fetch response runtime payload missing", retry=False)
                return

    booking_id = _get_booking_id(source_payload, required=False)
    platform_id = _coerce_required_int(source_payload, "platform_id")
    thread_id = _coerce_optional_int(source_payload.get("thread_id"))
    result_payload = source_payload.get("result")
    error = _as_optional_string(source_payload.get("error"))
    next_fetch_action = resolve_next_fetch_action(source_payload)
    if booking_id is None and isinstance(result_payload, dict):
        thread_data = result_payload.get("thread") if isinstance(result_payload.get("thread"), dict) else {}
        booking_id = _coerce_optional_int(thread_data.get("booking_id"))
    if booking_id is None:
        raise ValueError("booking_id is required")
    log.info(
        "task started",
        metadata={"booking_id": booking_id, "thread_id": thread_id, "next_fetch_action": next_fetch_action},
        **_task_log_kwargs(task, "handle_fetch_response"),
    )

    progress_update = resolve_progress_update(source_payload)
    if progress_update and not state.is_step_done("progress_updated"):
        state.begin_step("progress_updated")
        with context.connect_db() as conn:
            log.db_before_write("upsert thread progress", data=progress_update, **_task_log_kwargs(task, "handle_fetch_response"))
            upsert_thread_progress(conn, **progress_update)
            log.db_after_write(
                "upsert thread progress",
                result={"thread_id": progress_update["thread_id"], "offset": progress_update["offset"]},
                **_task_log_kwargs(task, "handle_fetch_response"),
            )
        state.checkpoint("progress_updated", {"thread_id": progress_update["thread_id"]})

    store_payload = build_store_messages_payload(source_payload) if error is None else None
    if store_payload and not state.is_step_done("store_payload_written"):
        state.begin_step("store_payload_written")
        store_key = _generate_key("store_req")
        try:
            with context.connect_db() as conn:
                log.db_before_write(
                    "write store request runtime variable",
                    data={"scope": RUNTIME_SCOPE_FETCH_STORE, "key": store_key},
                    **_task_log_kwargs(task, "handle_fetch_response"),
                )
                set_runtime_variable(
                    conn,
                    worker_id=context.scheduler.worker_id,
                    scope=RUNTIME_SCOPE_FETCH_STORE,
                    key=store_key,
                    value=store_payload,
                    ttl_minutes=_resolve_runtime_ttl(action=FETCH_RESPONSE_ACTION, scope=RUNTIME_SCOPE_FETCH_STORE),
                )
                log.db_after_write(
                    "write store request runtime variable",
                    result={"scope": RUNTIME_SCOPE_FETCH_STORE, "key": store_key},
                    **_task_log_kwargs(task, "handle_fetch_response"),
                )
        except Exception as exc:
            log.error(
                "failed to persist store request payload",
                exc=exc,
                error_code="FETCH_STORE_PAYLOAD_STORE_FAILED",
                **_task_log_kwargs(task, "handle_fetch_response"),
            )
            state.record_failure("store_payload_written", str(exc))
            queue.fail_task(task, f"store downstream store payload failed: {exc}", retry=True)
            return
        state.checkpoint("store_payload_written", {"store_key": store_key})

    if store_payload and not state.is_step_done("store_task_enqueued"):
        state.begin_step("store_task_enqueued")
        store_key = state.get_step_data("store_payload_written")["store_key"]
        store_enqueue_payload = {
            "action": STORE_MESSAGES_ACTION,
            "data_ref": {
                "worker_id": context.scheduler.worker_id,
                "scope": RUNTIME_SCOPE_FETCH_STORE,
                "key": store_key,
            },
        }
        log.db_before_write(
            "enqueue store task",
            data=store_enqueue_payload,
            **_task_log_kwargs(task, "handle_fetch_response"),
        )
        store_task_uuid = enqueue_with_meta(
            queue,
            WORKER,
            store_enqueue_payload,
            current_task=task,
            current_worker=WORKER,
            current_action=FETCH_RESPONSE_ACTION,
            next_worker=WORKER,
            next_action=STORE_MESSAGES_ACTION,
        )
        log.db_after_write(
            "enqueue store task",
            result={"store_task_uuid": store_task_uuid},
            **_task_log_kwargs(task, "handle_fetch_response"),
        )
        state.checkpoint("store_task_enqueued", {"store_task_uuid": store_task_uuid})

    store_task_uuid = state.get_step_data("store_task_enqueued")["store_task_uuid"] if store_payload else None
    if store_task_uuid:
        status = (
            "store_enqueued"
            if next_fetch_action == FETCH_ACTION
            else "forwarded_to_store_messages"
        )
    else:
        status = "fetch_response_processed"
    result = {
        "status": status,
        "booking_id": booking_id,
        "thread_id": thread_id,
        "platform_id": platform_id,
        "next_fetch_action": next_fetch_action,
        "result_present": isinstance(result_payload, dict),
        "error": error,
        "response_key": response_key,
        "store_task_uuid": store_task_uuid,
        "progress_updated": bool(progress_update),
    }
    step.log("messages worker fetch response handled", result)
    log.info("task completed", metadata=result, **_task_log_kwargs(task, "handle_fetch_response"))
    queue.complete_task(task, result)


def handle_store_messages(context, task) -> None:
    queue = context.main_queue
    step = _default_step(context)
    log = _default_app_logger(context)
    state = ActionStateManager.load(context, task)
    payload = task.payload

    source_ref = _normalize_data_ref(payload, default_scope=RUNTIME_SCOPE_FETCH_STORE)
    source_worker_id = source_ref["worker_id"] or context.scheduler.worker_id
    source_scope = str(source_ref["scope"])
    source_key = source_ref["key"]
    source_payload = payload
    if source_key:
        if not state.is_step_done("store_input_loaded"):
            state.begin_step("store_input_loaded")
            try:
                with context.connect_db() as conn:
                    log.db_before_read(
                        "read store input runtime variable",
                        params={"scope": source_scope, "key": source_key},
                        **_task_log_kwargs(task, "handle_store_messages"),
                    )
                    loaded = get_runtime_variable(
                        conn,
                        worker_id=source_worker_id,
                        scope=source_scope,
                        key=str(source_key),
                    )
                    log.db_after_read(
                        "read store input runtime variable",
                        result={"items_count": len(loaded.get("items", [])) if isinstance(loaded, dict) else None},
                        **_task_log_kwargs(task, "handle_store_messages"),
                    )
            except Exception as exc:
                if isinstance(exc, LookupError):
                    _warn_runtime_variable_unavailable(
                        log,
                        task,
                        action_name="handle_store_messages",
                        worker_id=source_worker_id,
                        scope=source_scope,
                        key=str(source_key),
                        reason=exc,
                    )
                log.error(
                    "failed to read store input runtime variable",
                    exc=exc,
                    error_code="STORE_INPUT_READ_FAILED",
                    **_task_log_kwargs(task, "handle_store_messages"),
                )
                state.record_failure("store_input_loaded", str(exc))
                queue.fail_task(task, f"read store input failed: {exc}", retry=True)
                return

            if not isinstance(loaded, dict):
                queue.fail_task(task, "store input runtime payload missing", retry=False)
                return
            state.checkpoint(
                "store_input_loaded",
                {
                    "source_worker_id": source_worker_id,
                    "source_scope": source_scope,
                    "source_key": source_key,
                },
            )
            source_payload = loaded
        else:
            source_data = state.get_step_data("store_input_loaded")
            source_worker_id = _as_optional_string(source_data.get("source_worker_id")) or source_worker_id
            source_scope = _as_optional_string(source_data.get("source_scope")) or source_scope
            source_key = _as_optional_string(source_data.get("source_key")) or source_key
            try:
                with context.connect_db() as conn:
                    source_payload = get_runtime_variable(
                        conn,
                        worker_id=source_worker_id,
                        scope=source_scope,
                        key=str(source_key),
                    )
            except Exception as exc:
                if isinstance(exc, LookupError):
                    _warn_runtime_variable_unavailable(
                        log,
                        task,
                        action_name="handle_store_messages",
                        worker_id=source_worker_id,
                        scope=source_scope,
                        key=str(source_key),
                        reason=exc,
                    )
                log.error(
                    "failed to read store input runtime variable",
                    exc=exc,
                    error_code="STORE_INPUT_READ_FAILED",
                    **_task_log_kwargs(task, "handle_store_messages"),
                )
                state.record_failure("store_input_loaded", str(exc))
                queue.fail_task(task, f"read store input failed: {exc}", retry=True)
                return
            if not isinstance(source_payload, dict):
                queue.fail_task(task, "store input runtime payload missing", retry=False)
                return

    booking_id = _get_booking_id(source_payload, required=True)
    thread_id = _coerce_required_int(source_payload, "thread_id")
    platform_id = _coerce_required_int(source_payload, "platform_id")
    next_fetch_action = resolve_next_fetch_action(source_payload)
    items = source_payload.get("items")
    if not isinstance(items, list):
        raise ValueError("items must be a list")
    log.info(
        "task started",
        metadata={"booking_id": booking_id, "items_count": len(items), "next_fetch_action": next_fetch_action},
        **_task_log_kwargs(task, "handle_store_messages"),
    )

    if not state.is_step_done("store_loop_completed"):
        state.begin_step("store_loop")
        failed_item_ids: list[int] = []
        with context.connect_db() as conn:
            ensure_platform_exists(conn, platform_id)
            pending, processed = _pending_after_cursor(items, state.get_resume_cursor(), key_name="id")
            for item in pending:
                item_mid = None
                if isinstance(item, dict):
                    try:
                        item_mid = _coerce_optional_int(item.get("id"))
                    except ValueError:
                        item_mid = None
                log.db_before_write(
                    "upsert message item",
                    data={"platform_id": platform_id, "thread_id": thread_id, "mid": item_mid},
                    **_task_log_kwargs(task, "handle_store_messages"),
                )
                try:
                    upsert_message_item(
                        conn,
                        platform_id=platform_id,
                        thread_id=thread_id,
                        booking_id=booking_id,
                        item=item,
                    )
                except ValueError as exc:
                    if item_mid is not None:
                        failed_item_ids.append(int(item_mid))
                    log.error(
                        "store message item skipped",
                        exc=exc,
                        error_code="STORE_MESSAGE_ITEM_SKIPPED",
                        metadata={
                            "booking_id": booking_id,
                            "platform_id": platform_id,
                            "thread_id": thread_id,
                            "mid": item_mid,
                            "item_meta": {
                                "date_utc": item.get("date_utc") if isinstance(item, dict) else None,
                                "from_role": item.get("from_role") if isinstance(item, dict) else None,
                                "removed_utc": item.get("removed_utc") if isinstance(item, dict) else None,
                                "has_body": bool(
                                    isinstance(item, dict)
                                    and _as_optional_string(item.get("body"))
                                ),
                            },
                            "reason": str(exc),
                        },
                        **_task_log_kwargs(task, "handle_store_messages"),
                    )
                    continue
                processed += 1
                state.set_progress(
                    items_total=len(items),
                    items_processed=processed,
                    last_processed_id=item_mid,
                )
                log.db_after_write(
                    "upsert message item",
                    result={"processed_count": processed, "last_mid": item_mid},
                    **_task_log_kwargs(task, "handle_store_messages"),
                )
        state.checkpoint(
            "store_loop_completed",
            {
                "processed_count": processed,
                "failed_count": len(failed_item_ids),
                "failed_item_ids": failed_item_ids,
            },
        )

    if not state.is_step_done("next_fetch_payload_written"):
        state.begin_step("next_fetch_payload_written")
        next_fetch_payload = {
            "booking_id": booking_id,
            "thread_id": thread_id,
            "platform_id": platform_id,
        }
        next_fetch_key = _generate_key("next_fetch")
        try:
            with context.connect_db() as conn:
                log.db_before_write(
                    "write next fetch runtime variable",
                    data={"scope": RUNTIME_SCOPE_STORE_FETCH, "key": next_fetch_key},
                    **_task_log_kwargs(task, "handle_store_messages"),
                )
                set_runtime_variable(
                    conn,
                    worker_id=context.scheduler.worker_id,
                    scope=RUNTIME_SCOPE_STORE_FETCH,
                    key=next_fetch_key,
                    value=next_fetch_payload,
                    ttl_minutes=_resolve_runtime_ttl(action=STORE_MESSAGES_ACTION, scope=RUNTIME_SCOPE_STORE_FETCH),
                )
                log.db_after_write(
                    "write next fetch runtime variable",
                    result={"scope": RUNTIME_SCOPE_STORE_FETCH, "key": next_fetch_key},
                    **_task_log_kwargs(task, "handle_store_messages"),
                )
        except Exception as exc:
            log.error(
                "failed to persist next fetch payload",
                exc=exc,
                error_code="STORE_NEXT_FETCH_PAYLOAD_STORE_FAILED",
                **_task_log_kwargs(task, "handle_store_messages"),
            )
            state.record_failure("next_fetch_payload_written", str(exc))
            queue.fail_task(task, f"store next fetch payload failed: {exc}", retry=True)
            return
        state.checkpoint("next_fetch_payload_written", {"next_fetch_key": next_fetch_key})

    if not state.is_step_done("next_fetch_enqueued"):
        next_fetch_key = state.get_step_data("next_fetch_payload_written")["next_fetch_key"]
        next_fetch_enqueue_payload = {
            "action": next_fetch_action,
            "data_ref": {
                "worker_id": context.scheduler.worker_id,
                "scope": RUNTIME_SCOPE_STORE_FETCH,
                "key": next_fetch_key,
            },
        }
        log.db_before_write(
            "enqueue next fetch task",
            data=next_fetch_enqueue_payload,
            **_task_log_kwargs(task, "handle_store_messages"),
        )
        next_fetch_task_uuid = enqueue_with_meta(
            queue,
            WORKER,
            next_fetch_enqueue_payload,
            current_task=task,
            current_worker=WORKER,
            current_action=STORE_MESSAGES_ACTION,
            next_worker=WORKER,
            next_action=next_fetch_action,
        )
        log.db_after_write(
            "enqueue next fetch task",
            result={"next_fetch_task_uuid": next_fetch_task_uuid},
            **_task_log_kwargs(task, "handle_store_messages"),
        )
        state.checkpoint("next_fetch_enqueued", {"next_fetch_task_uuid": next_fetch_task_uuid})

    result = {
        "status": "store_completed" if next_fetch_action == FETCH_ACTION else "stored_messages",
        "booking_id": booking_id,
        "thread_id": thread_id,
        "platform_id": platform_id,
        "next_fetch_action": next_fetch_action,
        "next_fetch_key": state.get_step_data("next_fetch_payload_written")["next_fetch_key"],
        "items_total": len(items),
        "processed_count": state.get_step_data("store_loop_completed")["processed_count"],
        "failed_count": state.get_step_data("store_loop_completed").get("failed_count", 0),
        "failed_item_ids": state.get_step_data("store_loop_completed").get("failed_item_ids", []),
        "next_fetch_task_uuid": state.get_step_data("next_fetch_enqueued")["next_fetch_task_uuid"],
    }
    step.log("messages worker store handled", result)
    log.info("task completed", metadata=result, **_task_log_kwargs(task, "handle_store_messages"))
    queue.complete_task(task, result)


def _normalize_scan_unclassified_limit(payload: Dict[str, Any]) -> int:
    raw_limit = payload.get("limit")
    if raw_limit is None:
        return DEFAULT_SCAN_UNCLASSIFIED_LIMIT
    limit = _coerce_optional_int(raw_limit, field_name="limit")
    if limit is None or int(limit) < 1:
        raise ValueError("limit must be a positive integer")
    return int(limit)


def _handle_scan_unclassified(context, task, *, requested_action: str) -> None:
    queue = context.main_queue
    log = _default_app_logger(context)
    state = ActionStateManager.load(context, task)
    payload = task.payload if isinstance(task.payload, dict) else {}

    if not state.is_step_done("scan_input_loaded"):
        try:
            limit = _normalize_scan_unclassified_limit(payload)
        except Exception as exc:
            queue.fail_task(task, f"SCAN_UNCLASSIFIED_INPUT_INVALID: {exc}", retry=False)
            return
        state.checkpoint("scan_input_loaded", {"limit": limit})

    scan_input = state.get_step_data("scan_input_loaded")
    limit = int(scan_input["limit"])

    log.info(
        "task started",
        metadata={"requested_action": requested_action, "limit": limit},
        **_task_log_kwargs(task, "handle_scan_unclassified"),
    )

    if not state.is_step_done("stale_requeued"):
        state.begin_step("stale_requeued")
        try:
            with context.connect_db() as conn:
                log.db_before_write(
                    "requeue stale processing messages",
                    data={"stale_after": SCAN_STALE_AFTER_INTERVAL},
                    **_task_log_kwargs(task, "handle_scan_unclassified"),
                )
                requeued_stale_count = requeue_stale_processing_messages(
                    conn,
                    stale_after=SCAN_STALE_AFTER_INTERVAL,
                )
                log.db_after_write(
                    "requeue stale processing messages",
                    result={"requeued_stale_count": requeued_stale_count},
                    **_task_log_kwargs(task, "handle_scan_unclassified"),
                )
        except Exception as exc:
            log.error(
                "failed to requeue stale processing messages",
                exc=exc,
                error_code="SCAN_STALE_REQUEUE_FAILED",
                **_task_log_kwargs(task, "handle_scan_unclassified"),
            )
            state.record_failure("stale_requeued", str(exc))
            queue.fail_task(task, f"requeue stale processing messages failed: {exc}", retry=True)
            return
        state.checkpoint("stale_requeued", {"requeued_stale_count": requeued_stale_count})

    stale_data = state.get_step_data("stale_requeued")
    requeued_stale_count = int(stale_data.get("requeued_stale_count") or 0)

    if not state.is_step_done("batch_prepared"):
        state.begin_step("batch_prepared")
        try:
            with context.connect_db() as conn:
                log.db_before_read(
                    "fetch unclassified messages",
                    params={"limit": limit},
                    **_task_log_kwargs(task, "handle_scan_unclassified"),
                )
                messages = fetch_unclassified_messages(conn, limit=limit)
                log.db_after_read(
                    "fetch unclassified messages",
                    result={"batch_size": len(messages)},
                    **_task_log_kwargs(task, "handle_scan_unclassified"),
                )

                runtime_key = None
                runtime_scope = RUNTIME_SCOPE_SOURCE
                runtime_worker_id = context.scheduler.worker_id
                if messages:
                    runtime_key = _generate_key("unclassified")
                    log.db_before_write(
                        "write unclassified batch runtime variable",
                        data={"scope": runtime_scope, "key": runtime_key, "batch_size": len(messages)},
                        **_task_log_kwargs(task, "handle_scan_unclassified"),
                    )
                    set_runtime_variable(
                        conn,
                        worker_id=runtime_worker_id,
                        scope=runtime_scope,
                        key=runtime_key,
                        value={"messages": messages},
                        ttl_minutes=_resolve_runtime_ttl(
                            action=requested_action,
                            scope=runtime_scope,
                        ),
                    )
                    log.db_after_write(
                        "write unclassified batch runtime variable",
                        result={"scope": runtime_scope, "key": runtime_key},
                        **_task_log_kwargs(task, "handle_scan_unclassified"),
                    )
        except Exception as exc:
            log.error(
                "failed to prepare unclassified message batch",
                exc=exc,
                error_code="SCAN_BATCH_PREPARE_FAILED",
                **_task_log_kwargs(task, "handle_scan_unclassified"),
            )
            state.record_failure("batch_prepared", str(exc))
            queue.fail_task(task, f"prepare unclassified batch failed: {exc}", retry=True)
            return

        state.checkpoint(
            "batch_prepared",
            {
                "runtime_worker_id": context.scheduler.worker_id,
                "runtime_scope": RUNTIME_SCOPE_SOURCE,
                "runtime_key": runtime_key,
                "batch_size": len(messages),
                "message_ids": [int(row["message_id"]) for row in messages],
                "scanned_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
            },
        )

    batch_data = state.get_step_data("batch_prepared")
    batch_size = int(batch_data.get("batch_size") or 0)
    runtime_worker_id = _as_optional_string(batch_data.get("runtime_worker_id")) or context.scheduler.worker_id
    runtime_scope = _as_optional_string(batch_data.get("runtime_scope")) or RUNTIME_SCOPE_SOURCE
    runtime_key = _as_optional_string(batch_data.get("runtime_key"))
    scanned_at = _as_optional_string(batch_data.get("scanned_at"))

    if batch_size < 1:
        result = {
            "status": "no_messages",
            "requested_action": requested_action,
            "limit": limit,
            "batch_size": 0,
            "requeued_stale_count": requeued_stale_count,
        }
        log.info("task completed", metadata=result, **_task_log_kwargs(task, "handle_scan_unclassified"))
        queue.complete_task(task, result)
        return

    if runtime_key is None:
        message = "runtime key missing for non-empty unclassified batch"
        state.record_failure("batch_prepared", message)
        queue.fail_task(task, message, retry=True)
        return

    if not state.is_step_done("downstream_enqueued"):
        state.begin_step("downstream_enqueued")
        downstream_payload: Dict[str, Any] = {
            "action": HANDLE_UNCLASSIFIED_ACTION,
            "data_ref": {
                "worker_id": runtime_worker_id,
                "scope": runtime_scope,
                "key": runtime_key,
            },
            "batch_size": batch_size,
        }
        if scanned_at is not None:
            downstream_payload["scanned_at"] = scanned_at

        try:
            log.db_before_write(
                "enqueue unclassified handler",
                data=downstream_payload,
                **_task_log_kwargs(task, "handle_scan_unclassified"),
            )
            downstream_task_uuid = enqueue_with_meta(
                queue,
                WORKER,
                downstream_payload,
                current_task=task,
                current_worker=WORKER,
                current_action=requested_action,
                next_worker=WORKER,
                next_action=HANDLE_UNCLASSIFIED_ACTION,
            )
            log.db_after_write(
                "enqueue unclassified handler",
                result={"downstream_task_uuid": downstream_task_uuid},
                **_task_log_kwargs(task, "handle_scan_unclassified"),
            )
        except Exception as exc:
            log.error(
                "failed to enqueue unclassified handler",
                exc=exc,
                error_code="SCAN_DOWNSTREAM_ENQUEUE_FAILED",
                **_task_log_kwargs(task, "handle_scan_unclassified"),
            )
            state.record_failure("downstream_enqueued", str(exc))
            queue.fail_task(task, f"enqueue unclassified handler failed: {exc}", retry=True)
            return
        state.checkpoint("downstream_enqueued", {"downstream_task_uuid": downstream_task_uuid})

    if not state.is_step_done("rescan_enqueued"):
        state.begin_step("rescan_enqueued")
        rescan_payload = {"action": requested_action, "limit": limit}
        try:
            log.db_before_write(
                "enqueue scan continuation",
                data=rescan_payload,
                **_task_log_kwargs(task, "handle_scan_unclassified"),
            )
            next_scan_task_uuid = enqueue_with_meta(
                queue,
                WORKER,
                rescan_payload,
                current_task=task,
                current_worker=WORKER,
                current_action=requested_action,
                next_worker=WORKER,
                next_action=requested_action,
            )
            log.db_after_write(
                "enqueue scan continuation",
                result={"next_scan_task_uuid": next_scan_task_uuid},
                **_task_log_kwargs(task, "handle_scan_unclassified"),
            )
        except Exception as exc:
            log.error(
                "failed to enqueue scan continuation",
                exc=exc,
                error_code="SCAN_RESCAN_ENQUEUE_FAILED",
                **_task_log_kwargs(task, "handle_scan_unclassified"),
            )
            state.record_failure("rescan_enqueued", str(exc))
            queue.fail_task(task, f"enqueue scan continuation failed: {exc}", retry=True)
            return
        state.checkpoint("rescan_enqueued", {"next_scan_task_uuid": next_scan_task_uuid})

    result = {
        "status": "batch_enqueued",
        "requested_action": requested_action,
        "batch_size": batch_size,
        "limit": limit,
        "runtime_scope": runtime_scope,
        "runtime_key": runtime_key,
        "downstream_task_uuid": state.get_step_data("downstream_enqueued")["downstream_task_uuid"],
        "next_scan_task_uuid": state.get_step_data("rescan_enqueued")["next_scan_task_uuid"],
        "requeued_stale_count": requeued_stale_count,
    }
    log.info("task completed", metadata=result, **_task_log_kwargs(task, "handle_scan_unclassified"))
    queue.complete_task(task, result)


def handle_scan_unclassified(context, task) -> None:
    _handle_scan_unclassified(context, task, requested_action=SCAN_UNCLASSIFIED_ACTION)


def _normalize_check_classification_payload(payload: Dict[str, Any]) -> tuple[int, list[int], Optional[Dict[str, Any]]]:
    platform_id = _coerce_required_int(payload, "platform_id")

    raw_thread_ids = payload.get("thread_ids")
    if raw_thread_ids is None:
        legacy_thread_id = _coerce_optional_int(payload.get("thread_id"))
        if legacy_thread_id is None:
            raise ValueError("thread_ids must be a non-empty array")
        raw_thread_ids = [int(legacy_thread_id)]

    if not isinstance(raw_thread_ids, list) or not raw_thread_ids:
        raise ValueError("thread_ids must be a non-empty array")

    thread_ids: list[int] = []
    seen: set[int] = set()
    for index, raw_value in enumerate(raw_thread_ids):
        thread_id = _coerce_optional_int(raw_value, field_name=f"thread_ids[{index}]")
        if thread_id is None:
            raise ValueError(f"thread_ids[{index}] must be an integer")
        normalized = int(thread_id)
        if normalized in seen:
            continue
        seen.add(normalized)
        thread_ids.append(normalized)

    if not thread_ids:
        raise ValueError("thread_ids must be a non-empty array")

    booking_context = payload.get("booking_context") if isinstance(payload.get("booking_context"), dict) else None
    return int(platform_id), thread_ids, booking_context


def _handle_check_classification(context, task, *, requested_action: str) -> None:
    queue = context.main_queue
    log = _default_app_logger(context)
    state = ActionStateManager.load(context, task)
    payload = task.payload

    try:
        platform_id, thread_ids, booking_context = _normalize_check_classification_payload(payload)
    except Exception as exc:
        queue.fail_task(task, f"THREAD_CLASS_INPUT_INVALID: {exc}", retry=False)
        return

    resolved_return_ref: Optional[Dict[str, str]] = None
    if "return_ref" in payload:
        raw_return_ref = payload.get("return_ref")
        if not isinstance(raw_return_ref, dict):
            queue.fail_task(task, "return_ref must be an object when provided", retry=False)
            return
        return_worker = _as_optional_string(raw_return_ref.get("worker"))
        return_action = _as_optional_string(raw_return_ref.get("action"))
        return_queue = _as_optional_string(raw_return_ref.get("queue")) or PRIMARY_QUEUE
        if not return_worker or not return_action:
            queue.fail_task(task, "return_ref.worker and return_ref.action are required", retry=False)
            return
        resolved_return_ref = {
            "worker": return_worker,
            "queue": return_queue,
            "action": return_action,
        }

    log.info(
        "task started",
        metadata={
            "action": requested_action,
            "platform_id": platform_id,
            "thread_ids": thread_ids,
            "return_ref_present": bool(resolved_return_ref),
        },
        **_task_log_kwargs(task, "handle_check_classification"),
    )

    if not state.is_step_done("classes_read"):
        state.begin_step("classes_read")
        try:
            with context.connect_db() as conn:
                merged_classes: set[str] = set()
                thread_class_details: list[Dict[str, Any]] = []
                for thread_id in thread_ids:
                    log.db_before_read(
                        "read thread primary classes",
                        params={"platform_id": platform_id, "thread_id": thread_id},
                        **_task_log_kwargs(task, "handle_check_classification"),
                    )
                    class_data = get_thread_primary_classes(conn, platform_id=platform_id, thread_id=thread_id)
                    thread_classes = [
                        str(item)
                        for item in class_data.get("classes", [])
                        if item is not None
                    ]
                    class_pos = [
                        int(item)
                        for item in class_data.get("class_pos", [])
                        if item is not None
                    ]
                    ids_message = [
                        int(item)
                        for item in class_data.get("ids_message", [])
                        if item is not None
                    ]
                    log.db_after_read(
                        "read thread primary classes",
                        result={
                            "thread_id": thread_id,
                            "classes_count": len(thread_classes),
                            "class_pos_count": len(class_pos),
                            "ids_message_count": len(ids_message),
                        },
                        **_task_log_kwargs(task, "handle_check_classification"),
                    )
                    merged_classes.update(thread_classes)
                    thread_class_details.append(
                        {
                            "thread_id": int(thread_id),
                            "classes": thread_classes,
                            "class_pos": class_pos,
                            "ids_message": ids_message,
                        }
                    )
        except Exception as exc:
            log.error(
                "failed to read thread primary classes",
                exc=exc,
                error_code="THREAD_CLASS_READ_FAILED",
                **_task_log_kwargs(task, "handle_check_classification"),
            )
            state.record_failure("classes_read", str(exc))
            queue.fail_task(task, f"read thread primary classes failed: {exc}", retry=True)
            return

        checkpoint_data: Dict[str, Any] = {
            "platform_id": platform_id,
            "thread_ids": thread_ids,
            "classes": sorted(merged_classes),
            "thread_class_details": thread_class_details,
        }
        if booking_context is not None:
            checkpoint_data["booking_context"] = booking_context
        state.checkpoint(
            "classes_read",
            checkpoint_data,
        )

    classes_data = state.get_step_data("classes_read").get("classes")
    classes = sorted({str(item) for item in classes_data if item is not None}) if isinstance(classes_data, list) else []
    classes_read_data = state.get_step_data("classes_read")
    raw_thread_class_details = classes_read_data.get("thread_class_details")
    thread_class_details = raw_thread_class_details if isinstance(raw_thread_class_details, list) else []
    resolved_thread_ids = [
        int(value)
        for value in classes_read_data.get("thread_ids") or []
        if _coerce_optional_int(value) is not None
    ]
    result = {
        "status": "thread_classes_collected",
        "action": CHECK_CLASSIFICATION_ACTION,
        "platform_id": platform_id,
        "thread_ids": resolved_thread_ids,
        "classes": classes,
        "thread_class_details": thread_class_details,
    }
    if isinstance(classes_read_data.get("booking_context"), dict):
        result["booking_context"] = classes_read_data.get("booking_context")

    if resolved_return_ref is not None:
        if not state.is_step_done("result_runtime_written"):
            state.begin_step("result_runtime_written")
            result_key = _generate_key("check_cls_res")
            try:
                with context.connect_db() as conn:
                    log.db_before_write(
                        "write check_classification result runtime variable",
                        data={"scope": RUNTIME_SCOPE_CHECK_CLASIFICATION_OUT, "key": result_key},
                        **_task_log_kwargs(task, "handle_check_classification"),
                    )
                    set_runtime_variable(
                        conn,
                        worker_id=context.scheduler.worker_id,
                        scope=RUNTIME_SCOPE_CHECK_CLASIFICATION_OUT,
                        key=result_key,
                        value=result,
                        ttl_minutes=_resolve_runtime_ttl(
                            action=requested_action,
                            scope=RUNTIME_SCOPE_CHECK_CLASIFICATION_OUT,
                        ),
                    )
                    log.db_after_write(
                        "write check_classification result runtime variable",
                        result={"scope": RUNTIME_SCOPE_CHECK_CLASIFICATION_OUT, "key": result_key},
                        **_task_log_kwargs(task, "handle_check_classification"),
                    )
            except Exception as exc:
                log.error(
                    "failed to store check_classification result runtime variable",
                    exc=exc,
                    error_code="CHECK_CLASS_RESULT_STORE_FAILED",
                    **_task_log_kwargs(task, "handle_check_classification"),
                )
                state.record_failure("result_runtime_written", str(exc))
                queue.fail_task(task, f"store check_classification result failed: {exc}", retry=True)
                return
            state.checkpoint(
                "result_runtime_written",
                {
                    "result_worker_id": context.scheduler.worker_id,
                    "result_scope": RUNTIME_SCOPE_CHECK_CLASIFICATION_OUT,
                    "result_key": result_key,
                    "return_worker": resolved_return_ref["worker"],
                    "return_queue": resolved_return_ref["queue"],
                    "return_action": resolved_return_ref["action"],
                },
            )

        return_data = state.get_step_data("result_runtime_written")
        result_worker_id = str(return_data["result_worker_id"])
        result_scope = str(return_data["result_scope"])
        result_key = str(return_data["result_key"])
        return_worker = str(return_data["return_worker"])
        return_queue = str(return_data["return_queue"])
        return_action = str(return_data["return_action"])

        if not state.is_step_done("return_enqueued"):
            state.begin_step("return_enqueued")
            return_payload = {
                "action": return_action,
                "data_ref": {
                    "worker_id": result_worker_id,
                    "scope": result_scope,
                    "key": result_key,
                },
            }
            try:
                log.db_before_write(
                    "enqueue check_classification downstream task",
                    data={"worker": return_worker, "queue": return_queue, "payload": return_payload},
                    **_task_log_kwargs(task, "handle_check_classification"),
                )
                downstream_task_uuid = enqueue_with_meta(
                    context.queue(return_queue),
                    return_worker,
                    return_payload,
                    current_task=task,
                    current_worker=WORKER,
                    current_action=requested_action,
                    next_worker=return_worker,
                    next_action=return_action,
                )
                log.db_after_write(
                    "enqueue check_classification downstream task",
                    result={"downstream_task_uuid": downstream_task_uuid},
                    **_task_log_kwargs(task, "handle_check_classification"),
                )
            except Exception as exc:
                log.error(
                    "failed to enqueue check_classification downstream task",
                    exc=exc,
                    error_code="CHECK_CLASS_ENQUEUE_FAILED",
                    **_task_log_kwargs(task, "handle_check_classification"),
                )
                state.record_failure("return_enqueued", str(exc))
                queue.fail_task(task, f"enqueue check_classification downstream task failed: {exc}", retry=True)
                return
            state.checkpoint("return_enqueued", {"downstream_task_uuid": downstream_task_uuid})

        result["result_data_ref"] = {
            "worker_id": result_worker_id,
            "scope": result_scope,
            "key": result_key,
        }
        result["return_ref"] = {
            "worker": return_worker,
            "queue": return_queue,
            "action": return_action,
        }
        result["downstream_task_uuid"] = state.get_step_data("return_enqueued")["downstream_task_uuid"]

    log.info("task completed", metadata=result, **_task_log_kwargs(task, "handle_check_classification"))
    queue.complete_task(task, result)


def handle_check_classification(context, task) -> None:
    _handle_check_classification(context, task, requested_action=CHECK_CLASSIFICATION_ACTION)


def handle_check_clasification(context, task) -> None:
    _handle_check_classification(context, task, requested_action=CHECK_CLASIFICATION_ACTION)


def _handle_unclassified_messages(context, task, *, requested_action: str) -> None:
    queue = context.main_queue
    log = _default_app_logger(context)
    state = ActionStateManager.load(context, task)
    payload = task.payload
    external_action = resolve_external_classify_action(requested_action)
    return_ref = resolve_classify_return_ref(requested_action)
    data_ref = payload.get("data_ref") if isinstance(payload.get("data_ref"), dict) else {}
    source_worker_id = _as_optional_string(data_ref.get("worker_id")) or context.scheduler.worker_id
    scope = _as_optional_string(data_ref.get("scope")) or RUNTIME_SCOPE_SOURCE
    key = _as_optional_string(data_ref.get("key"))
    if not key:
        queue.fail_task(task, "missing data_ref.key", retry=False)
        return
    log.info(
        "task started",
        metadata={
            "source_worker_id": source_worker_id,
            "scope": scope,
            "key": key,
            "requested_action": requested_action,
            "external_action": external_action,
            "callback_action": return_ref["action"],
        },
        **_task_log_kwargs(task, "handle_unclassified_messages"),
    )

    if not state.is_step_done("classify_enqueued"):
        if not state.is_step_done("data_read"):
            state.begin_step("data_read")
            with context.connect_db() as conn:
                log.db_before_read("read unclassified batch", params={"scope": scope, "key": key}, **_task_log_kwargs(task, "handle_unclassified_messages"))
                batch = get_runtime_variable(conn, worker_id=source_worker_id, scope=scope, key=key)
                log.db_after_read(
                    "read unclassified batch",
                    result={"messages_count": len(batch.get("messages", [])) if isinstance(batch, dict) else None},
                    **_task_log_kwargs(task, "handle_unclassified_messages"),
                )
            messages = batch.get("messages") if isinstance(batch, dict) else None
            if not isinstance(messages, list) or not messages:
                queue.fail_task(task, "runtime var missing messages", retry=False)
                return
            state.checkpoint(
                "data_read",
                {
                    "source_worker_id": source_worker_id,
                    "source_scope": scope,
                    "source_key": key,
                    "items_count": len(messages),
                },
            )

        source_data = state.get_step_data("data_read")
        source_worker_id = _as_optional_string(source_data.get("source_worker_id")) or source_worker_id
        scope = _as_optional_string(source_data.get("source_scope")) or scope
        key = _as_optional_string(source_data.get("source_key")) or key

        with context.connect_db() as conn:
            batch = get_runtime_variable(conn, worker_id=source_worker_id, scope=scope, key=key)
            messages = batch.get("messages") if isinstance(batch, dict) else []
            items = [{"pk": int(row["message_id"]), "body": str(row["content"])} for row in messages]
            if not state.is_step_done("request_written"):
                req_key = _generate_key("classify_req")
                log.db_before_write(
                    "write classify request runtime variable",
                    data={"scope": RUNTIME_SCOPE_IN, "key": req_key, "items_count": len(items)},
                    **_task_log_kwargs(task, "handle_unclassified_messages"),
                )
                set_runtime_variable(
                    conn,
                    worker_id=context.scheduler.worker_id,
                    scope=RUNTIME_SCOPE_IN,
                    key=req_key,
                    value={"items": items},
                    ttl_minutes=_resolve_runtime_ttl(action=requested_action, scope=RUNTIME_SCOPE_IN),
                )
                log.db_after_write(
                    "write classify request runtime variable",
                    result={"scope": RUNTIME_SCOPE_IN, "key": req_key},
                    **_task_log_kwargs(task, "handle_unclassified_messages"),
                )
                state.checkpoint("request_written", {"request_key": req_key, "items_count": len(items)})

        if not state.is_step_done("classify_enqueued"):
            classify_payload = {
                "action": external_action,
                "data_ref": {
                    "worker_id": context.scheduler.worker_id,
                    "scope": RUNTIME_SCOPE_IN,
                    "key": state.get_step_data("request_written")["request_key"],
                },
                "return_ref": dict(return_ref),
                "original_ref": {
                    "worker_id": source_worker_id,
                    "scope": scope,
                    "key": key,
                },
            }
            log.db_before_write("enqueue classify task", data=classify_payload, **_task_log_kwargs(task, "handle_unclassified_messages"))
            downstream_task_uuid = enqueue_with_meta(
                context.queue(EXTERNAL_SERVICES_QUEUE),
                EXTERNAL_SERVICES_WORKER,
                classify_payload,
                current_task=task,
                current_worker=WORKER,
                current_action=requested_action,
                next_worker=WORKER,
                next_action=str(return_ref["action"]),
            )
            log.db_after_write(
                "enqueue classify task",
                result={"downstream_task_uuid": downstream_task_uuid},
                **_task_log_kwargs(task, "handle_unclassified_messages"),
            )
            state.checkpoint(
                "classify_enqueued",
                {
                    "downstream_task_uuid": downstream_task_uuid,
                    "request_key": state.get_step_data("request_written")["request_key"],
                },
            )

    cleanup_error = None
    try:
        with context.connect_db() as conn:
            delete_runtime_variable(conn, worker_id=source_worker_id, scope=scope, key=key)
    except Exception as exc:
        cleanup_error = str(exc)

    result = {
        "status": "forwarded",
        "requested_action": requested_action,
        "external_action": external_action,
        "callback_action": return_ref["action"],
        "items": state.get_step_data("request_written").get("items_count"),
        "request_key": state.get_step_data("request_written")["request_key"],
        "downstream_task_uuid": state.get_step_data("classify_enqueued")["downstream_task_uuid"],
        "cleanup_error": cleanup_error,
    }
    log.info("task completed", metadata=result, **_task_log_kwargs(task, "handle_unclassified_messages"))
    queue.complete_task(task, result)


def handle_unclassified_messages(context, task) -> None:
    _handle_unclassified_messages(context, task, requested_action=HANDLE_UNCLASSIFIED_ACTION)


def handle_unclassified_dummy_messages(context, task) -> None:
    _handle_unclassified_messages(context, task, requested_action=HANDLE_UNCLASSIFIED_DUMMY_ACTION)


def _handle_classified_messages(context, task, *, requested_action: str) -> None:
    queue = context.main_queue
    log = _default_app_logger(context)
    state = ActionStateManager.load(context, task)
    payload = task.payload
    data_ref = payload.get("data_ref") if isinstance(payload.get("data_ref"), dict) else {}
    result_worker_id = _as_optional_string(data_ref.get("worker_id")) or context.scheduler.worker_id
    scope = _as_optional_string(data_ref.get("scope")) or RUNTIME_SCOPE_OUT
    key = _as_optional_string(data_ref.get("key"))
    if not key:
        queue.fail_task(task, "missing data_ref.key", retry=False)
        return
    log.info(
        "task started",
        metadata={
            "result_worker_id": result_worker_id,
            "scope": scope,
            "key": key,
            "requested_action": requested_action,
        },
        **_task_log_kwargs(task, "handle_classified_messages"),
    )

    errors: list[str] = []
    if not state.is_step_done("results_applied"):
        if not state.is_step_done("data_read"):
            state.begin_step("data_read")
            with context.connect_db() as conn:
                log.db_before_read("read classify results", params={"scope": scope, "key": key}, **_task_log_kwargs(task, "handle_classified_messages"))
                result_payload = get_runtime_variable(conn, worker_id=result_worker_id, scope=scope, key=key)
                log.db_after_read(
                    "read classify results",
                    result={"results_count": len(result_payload.get("results", [])) if isinstance(result_payload, dict) else None},
                    **_task_log_kwargs(task, "handle_classified_messages"),
                )
            results = result_payload.get("results") if isinstance(result_payload, dict) else None
            if not isinstance(results, list):
                queue.fail_task(task, "results missing", retry=False)
                return
            state.checkpoint(
                "data_read",
                {
                    "result_worker_id": result_worker_id,
                    "result_scope": scope,
                    "result_key": key,
                    "results_count": len(results),
                },
            )

        result_data = state.get_step_data("data_read")
        result_worker_id = _as_optional_string(result_data.get("result_worker_id")) or result_worker_id
        scope = _as_optional_string(result_data.get("result_scope")) or scope
        key = _as_optional_string(result_data.get("result_key")) or key

        with context.connect_db() as conn:
            result_payload = get_runtime_variable(conn, worker_id=result_worker_id, scope=scope, key=key)
            results = result_payload.get("results") if isinstance(result_payload, dict) else []
            pending, processed = _pending_after_cursor(results, state.get_resume_cursor(), key_name="pk")
            for item in pending:
                try:
                    pk = _coerce_required_int(item, "pk")
                    cls = _as_optional_string(item.get("class"))
                    if not cls:
                        raise ValueError("class is required")
                    log.db_before_write(
                        "persist classified result",
                        data={"message_id": pk, "class": cls},
                        **_task_log_kwargs(task, "handle_classified_messages"),
                    )
                    class_id, resolved_class = resolve_class_id(conn, cls)
                    if resolved_class != cls:
                        log.warn(
                            "classified result category missing; mapped to unclassified",
                            metadata={
                                "message_id": pk,
                                "returned_class": cls,
                                "mapped_class": resolved_class,
                            },
                            **_task_log_kwargs(task, "handle_classified_messages"),
                        )
                    replace_lookup(conn, message_id=pk, class_id=class_id)
                    set_status(conn, message_id=pk, status="completed", last_error=None)
                    processed += 1
                    state.set_progress(items_total=len(results), items_processed=processed, last_processed_id=pk)
                    log.db_after_write(
                        "persist classified result",
                        result={
                            "message_id": pk,
                            "class": resolved_class,
                            "class_id": class_id,
                            "processed": processed,
                        },
                        **_task_log_kwargs(task, "handle_classified_messages"),
                    )
                except ValueError as exc:
                    errors.append(f"pk={item.get('pk')}: {exc}")
                    try:
                        set_status(conn, message_id=int(item.get("pk")), status="failed", last_error=str(exc))
                    except Exception:
                        pass
                except Exception as exc:
                    state.record_failure("apply_results", str(exc))
                    queue.fail_task(task, f"apply classified result failed: {exc}", retry=True)
                    return
        if not errors:
            state.checkpoint(
                "results_applied",
                {"processed_count": state.state.progress.items_processed if state.state.progress else 0},
            )

    cleanup_error = None
    try:
        with context.connect_db() as conn:
            delete_runtime_variable(conn, worker_id=result_worker_id, scope=scope, key=key)
    except Exception as exc:
        cleanup_error = str(exc)

    if errors:
        queue.fail_task(task, "; ".join(errors), retry=False)
        return

    result = {
        "status": "classified",
        "requested_action": requested_action,
        "processed": state.get_step_data("results_applied").get("processed_count", 0),
        "runtime_key": key,
        "cleanup_error": cleanup_error,
    }
    log.info("task completed", metadata=result, **_task_log_kwargs(task, "handle_classified_messages"))
    queue.complete_task(task, result)


def handle_classified_messages(context, task) -> None:
    _handle_classified_messages(context, task, requested_action=HANDLE_CLASSIFIED_ACTION)


def handle_classified_dummy_messages(context, task) -> None:
    _handle_classified_messages(context, task, requested_action=HANDLE_CLASSIFIED_DUMMY_ACTION)


def handle_task(context, task) -> None:
    normalize_payload_meta(task.payload)
    action = task.payload.get("action")
    if action == SCAN_UNCLASSIFIED_ACTION:
        handle_scan_unclassified(context, task)
        return
    if action == FETCH_ACTION:
        handle_fetch(context, task)
        return
    if action == FETCH_DUMMY_ACTION:
        handle_fetch_dummy(context, task)
        return
    if action == FETCH_RESPONSE_ACTION:
        handle_fetch_response(context, task)
        return
    if action == STORE_MESSAGES_ACTION:
        handle_store_messages(context, task)
        return
    if action == CHECK_CLASSIFICATION_ACTION:
        handle_check_classification(context, task)
        return
    if action == CHECK_CLASIFICATION_ACTION:
        handle_check_clasification(context, task)
        return
    if action == HANDLE_UNCLASSIFIED_ACTION:
        handle_unclassified_messages(context, task)
        return
    if action == HANDLE_UNCLASSIFIED_DUMMY_ACTION:
        handle_unclassified_dummy_messages(context, task)
        return
    if action == HANDLE_CLASSIFIED_ACTION:
        handle_classified_messages(context, task)
        return
    if action == HANDLE_CLASSIFIED_DUMMY_ACTION:
        handle_classified_dummy_messages(context, task)
        return
    context.main_queue.fail_task(task, f"Unexpected action {action}", retry=False)


def run_task(context, task) -> None:
    handle_task(context, task)


def main() -> None:
    global RUNTIME_VARIABLE_TTL_CONFIG
    args = parse_args()
    RUNTIME_VARIABLE_TTL_CONFIG = parse_runtime_variable_ttl_config(args.runtime_variable_ttl_config)
    logger, log_path = configure_worker_logger(WORKER, args.log_dir)
    step = NoOpStepLog()
    scheduler: Optional[MessagesSchedulerClient] = None
    app_logger: Any = NullAppLogger()

    try:
        dsn = build_dsn(args.dsn, args.auto_dsn, args.db_name)
        if not dsn:
            raise SystemExit("DSN is required (use --dsn or --auto-dsn with POSTGRES_PASSWORD set).")

        scheduler = MessagesSchedulerClient(
            logger,
            dsn,
            WORKER,
            SUBSCRIBED_QUEUES,
            worker_id=args.worker_id,
            max_concurrent_tasks=args.max_concurrent_tasks,
            heartbeat_interval=args.heartbeat_interval,
        )
        app_logger = AppLogger(
            dsn=dsn,
            worker_id=scheduler.worker_id,
            worker_name=WORKER,
            fallback_logger=logger,
        )
        context = MessagesWorkerContext(
            logger=logger,
            app_logger=app_logger,
            scheduler=scheduler,
            dsn=dsn,
            worker_name=WORKER,
            queue_name=PRIMARY_QUEUE,
            subscribed_queues=SUBSCRIBED_QUEUES,
            step=step,
            poll_interval=args.poll_interval,
            max_concurrent_tasks=args.max_concurrent_tasks,
            heartbeat_interval=args.heartbeat_interval,
            lease_duration=args.lease_duration,
            drain_timeout=args.drain_timeout,
        )
        previous_crash = scheduler.state_manager.boot(context)
        if previous_crash:
            interrupted = (
                previous_crash.get("crash_recovery", {}).get("interrupted_task_ids")
                or previous_crash.get("runtime_state", {}).get("in_flight_task_ids")
                or []
            )
            if interrupted:
                app_logger.warn(
                    "crash recovery interrupted tasks detected",
                    metadata={"interrupted_task_ids": interrupted},
                    action_name="worker_startup",
                )

        runner = MessagesWorkerRunner(context, run_task)
        app_logger.info(
            "messages worker started",
            metadata={
                "worker_id": scheduler.worker_id,
                "primary_queue": PRIMARY_QUEUE,
                "subscribed_queues": list(SUBSCRIBED_QUEUES),
                "max_concurrent_tasks": args.max_concurrent_tasks,
                "heartbeat_interval": args.heartbeat_interval,
                "lease_duration": args.lease_duration,
                "runtime_variable_ttl_config": RUNTIME_VARIABLE_TTL_CONFIG,
                "log_file": str(log_path),
            },
            action_name="worker_startup",
        )
        runner.run()
    except SystemExit:
        raise
    except Exception as exc:
        if isinstance(app_logger, NullAppLogger):
            logger.exception("messages worker failed")
        else:
            app_logger.error("messages worker failed", exc=exc, action_name="worker_runtime")
        raise SystemExit(1)
    finally:
        if scheduler is not None:
            if not isinstance(app_logger, NullAppLogger):
                app_logger.info("messages worker shutting down", action_name="worker_shutdown")
            try:
                scheduler.state_manager.shutdown()
            except Exception as exc:
                if isinstance(app_logger, NullAppLogger):
                    logger.exception("messages worker clean shutdown checkpoint failed")
                else:
                    app_logger.error(
                        "messages worker clean shutdown checkpoint failed",
                        exc=exc,
                        action_name="worker_shutdown",
                    )
            try:
                app_logger.close()
            except Exception:
                logger.exception("messages worker app logger close failed")
            scheduler.close()


if __name__ == "__main__":
    main()
