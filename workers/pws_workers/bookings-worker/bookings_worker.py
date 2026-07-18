#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import hashlib
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, Optional, Sequence
from urllib.parse import parse_qs, urlparse
from zoneinfo import ZoneInfo

CURRENT_DIR = Path(__file__).resolve().parent
WORKERS_ROOT = Path(__file__).resolve().parents[2]
REPO_ROOT = Path(__file__).resolve().parents[3]
for candidate in (WORKERS_ROOT, REPO_ROOT):
    if str(candidate) not in sys.path:
        sys.path.insert(0, str(candidate))

from pws_workers.shared.worker_runtime import (  # noqa: E402
    NoOpStepLog,
    add_common_worker_args,
    build_dsn,
    connect,
    configure_worker_logger,
    normalize_payload_meta,
)
from pws_workers.shared import (  # noqa: E402
    ActionStateManager,
    AppLogger,
    ManagedSchedulerClient,
    ManagedWorkerContext,
    ManagedWorkerRunner,
    NullAppLogger,
    as_optional_string,
    coerce_optional_int,
    default_app_logger,
    default_step,
    delete_runtime_variable,
    enqueue_with_meta,
    generate_key,
    get_runtime_variable,
    parse_runtime_variable_ttl_config,
    resolve_runtime_variable_ttl,
    set_runtime_variable,
    task_log_kwargs,
)


WORKER = "bookings-worker"
PRIMARY_QUEUE = "bookings"
SUBSCRIBED_QUEUES: Sequence[str] = (PRIMARY_QUEUE,)
SUPPORTED_ACTIONS = (
    "get_bookings",
    "get_bookings_ret",
    "register_bookings",
    "scan_actives",
    "update_message_threads",
    "bso_start_chain",
    "process_checkout",
    "scan_checked_out",
)

GET_BOOKINGS_ACTION = "get_bookings"
GET_BOOKINGS_RET_ACTION = "get_bookings_ret"
GET_BOOKINGS_RET_ALIASES = ("ret_get_bookings", "get_boogings_ret")
REGISTER_BOOKINGS_ACTION = "register_bookings"
SCAN_ACTIVES_ACTION = "scan_actives"
UPDATE_MESSAGE_THREADS_ACTION = "update_message_threads"
PROCESS_CHECKOUT_ACTION = "process_checkout"
SCAN_CHECKED_OUT_ACTION = "scan_checked_out"
BSO_START_CHAIN_ACTION = "bso_start_chain"
BSO_START_CHAIN_ALIASES = ("start_bso_chain",)

FETCH_REQUEST_SCOPE = "fetch-bookings-request"
FETCH_PAGE_SCOPE = "fetch-bookings-page"
FETCH_RESCAN_SCOPE = "fetch-bookings-rescan"
REGISTER_REQUEST_SCOPE = "register-bookings-request"
CHECK_CLASSIFICATION_SCOPE = "check-classification-result"
CHECK_CLASIFICATION_LEGACY_SCOPE = "check-clasification-result"

EXTERNAL_SERVICES_WORKER = "external-services-worker"
EXTERNAL_SERVICES_QUEUE = "external-services"

MESSAGES_WORKER = "messages-worker"
MESSAGES_QUEUE = "messages-service"
MESSAGES_CHECK_CLASSIFICATION_ACTION = "check_classification"
MESSAGES_FETCH_ACTION = "fetch"

PROPERTY_PLATFORM_WORKER = "property-platform-worker"
PROPERTY_PLATFORM_QUEUE = "property-platform"
PROPERTY_PLATFORM_ACTION = "get_linked_listings"

BSO_WORKER = "booking-special-operation-worker"
BSO_QUEUE = "booking-special-operation"
BSO_REMOVE_ACTION = "remove-bso"

RUNTIME_TTL_MINUTES = 15
DEFAULT_LIMIT = 100
GET_BOOKINGS_DEFAULT_LIMIT = 30
DEFAULT_GET_BOOKINGS_N_DAYS = 30
DEFAULT_GET_BOOKINGS_DERIVATION_TIMEZONE = "America/New_York"
BOOKINGS_OWNERREZ_PLATFORM_ID_ENV = "BOOKINGS_OWNERREZ_PLATFORM_ID"
RUNTIME_VARIABLE_TTL_CONFIG: Optional[Dict[str, Any]] = None
PROCESS_CHECKOUT_SINGLE_FLIGHT_LOCK_KEY = 2_742_189_101

_PROVIDER_KEY_PATTERN = re.compile(r"^[a-z0-9-]+$")
_CANCELLED_STATUSES = frozenset(
    {
        "cancelled",
        "canceled",
        "cancelled_by_guest",
        "canceled_by_guest",
        "cancelled_by_host",
        "canceled_by_host",
        "void",
        "voided",
    }
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Bookings worker")
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


def _resolve_runtime_ttl(*, action: str, scope: str, default_ttl_minutes: int = RUNTIME_TTL_MINUTES) -> int:
    return resolve_runtime_variable_ttl(
        RUNTIME_VARIABLE_TTL_CONFIG,
        action=action,
        scope=scope,
        default_ttl_minutes=default_ttl_minutes,
    )


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _local_today() -> date:
    return datetime.now().date()


def _today_in_timezone(timezone_name: str) -> date:
    tz_text = (as_optional_string(timezone_name) or "").strip()
    if not tz_text:
        tz_text = DEFAULT_GET_BOOKINGS_DERIVATION_TIMEZONE
    try:
        tz = ZoneInfo(tz_text)
    except Exception:
        tz = timezone.utc
    return datetime.now(tz).date()


def _resolve_default_platform_id(provider_key: str) -> Optional[int]:
    normalized = (provider_key or "").strip().lower()
    if normalized != "ownerrez":
        return None
    parsed = coerce_optional_int(os.getenv(BOOKINGS_OWNERREZ_PLATFORM_ID_ENV), field_name=BOOKINGS_OWNERREZ_PLATFORM_ID_ENV)
    if parsed is None:
        return None
    return int(parsed)


def _resolve_platform_id(payload: Dict[str, Any], *, provider_key: str) -> int:
    parsed_payload_platform_id = coerce_optional_int(payload.get("platform_id"), field_name="platform_id")
    if parsed_payload_platform_id is not None:
        return int(parsed_payload_platform_id)
    resolved_default = _resolve_default_platform_id(provider_key)
    if resolved_default is None:
        raise ValueError("platform_id is required")
    return int(resolved_default)


def _open_get_bookings_lock_connection(dsn: str):
    return connect(dsn)


def _get_bookings_single_flight_lock_key(*, request_payload: Dict[str, Any]) -> int:
    identity = {
        "provider_key": as_optional_string(request_payload.get("provider_key")) or "",
        "platform_id": int(request_payload.get("platform_id") or 0),
        "focus_start": as_optional_string(request_payload.get("focus_start")) or "",
        "focus_end": as_optional_string(request_payload.get("focus_end")) or "",
        "offset": int(request_payload.get("offset") or 0),
        "page_size": int(request_payload.get("page_size") or 0),
    }
    digest = hashlib.sha256(json.dumps(identity, sort_keys=True).encode("utf-8")).digest()
    return int.from_bytes(digest[:8], "big", signed=True)


def _try_acquire_get_bookings_single_flight_lock(conn, *, lock_key: int) -> bool:
    with conn.cursor() as cur:
        cur.execute("SELECT pg_try_advisory_lock(%s)", (int(lock_key),))
        row = cur.fetchone()
    return bool(row and row[0])


def _release_get_bookings_single_flight_lock(conn, *, lock_key: int) -> None:
    with conn.cursor() as cur:
        cur.execute("SELECT pg_advisory_unlock(%s)", (int(lock_key),))


def _normalize_data_ref(payload: Dict[str, Any], *, default_scope: str) -> Dict[str, Optional[str]]:
    data_ref = payload.get("data_ref") if isinstance(payload.get("data_ref"), dict) else {}
    scope = as_optional_string(data_ref.get("scope")) or default_scope
    if scope == CHECK_CLASIFICATION_LEGACY_SCOPE:
        scope = CHECK_CLASSIFICATION_SCOPE
    return {
        "worker_id": as_optional_string(data_ref.get("worker_id")),
        "scope": scope,
        "key": as_optional_string(data_ref.get("key")),
    }


def _coerce_required_int(payload: Dict[str, Any], field_name: str) -> int:
    raw_value = payload.get(field_name)
    value = coerce_optional_int(raw_value, field_name=field_name)
    if value is None:
        raise ValueError(f"{field_name} is required")
    return int(value)


def _as_non_negative_int(value: Any, *, field_name: str, default: int) -> int:
    parsed = coerce_optional_int(value, field_name=field_name)
    if parsed is None:
        return int(default)
    if parsed < 0:
        raise ValueError(f"{field_name} must be >= 0")
    return int(parsed)


def _as_positive_int(value: Any, *, field_name: str, default: int) -> int:
    parsed = coerce_optional_int(value, field_name=field_name)
    if parsed is None:
        return int(default)
    if parsed < 1:
        raise ValueError(f"{field_name} must be > 0")
    return int(parsed)


def _parse_date(value: Any, *, field_name: str) -> date:
    text = as_optional_string(value)
    if text is None:
        raise ValueError(f"{field_name} is required")
    try:
        return date.fromisoformat(text)
    except ValueError as exc:
        raise ValueError(f"{field_name} must be YYYY-MM-DD") from exc


def _optional_date(value: Any) -> Optional[date]:
    text = as_optional_string(value)
    if text is None:
        return None
    try:
        return date.fromisoformat(text)
    except ValueError:
        return None


def _normalize_provider_key(value: Any) -> str:
    provider_key = (as_optional_string(value) or "").strip().lower()
    if not provider_key:
        raise ValueError("provider_key is required")
    if not _PROVIDER_KEY_PATTERN.match(provider_key):
        raise ValueError("provider_key must match [a-z0-9-]+")
    return provider_key


def _normalize_listing_ids(value: Any) -> list[Any]:
    if not isinstance(value, list) or not value:
        raise ValueError("listing_ids must be a non-empty array")

    listing_ids: list[Any] = []
    for index, item in enumerate(value):
        if isinstance(item, bool):
            raise ValueError(f"listing_ids[{index}] must be a string or integer")
        if isinstance(item, int):
            listing_ids.append(int(item))
            continue
        text = as_optional_string(item)
        if text is None:
            raise ValueError(f"listing_ids[{index}] must be a string or integer")
        listing_ids.append(text)
    return listing_ids


def _fetch_listing_ids_for_platform(conn, *, platform_id: int) -> list[str]:
    with conn.cursor() as cur:
        try:
            # Preferred source: schema function in property_platform_sql.sql.
            cur.execute(
                """
                SELECT listing_id
                FROM get_all_properties_on_platform(%s)
                WHERE listing_id IS NOT NULL
                  AND BTRIM(listing_id) <> ''
                """,
                (int(platform_id),),
            )
            rows = cur.fetchall() or []
        except Exception:
            # Compatibility fallback when function is not installed in current DB.
            cur.execute(
                """
                SELECT listing_id
                FROM platform_property_lookup
                WHERE platform_id = %s
                  AND listing_id IS NOT NULL
                  AND BTRIM(listing_id) <> ''
                ORDER BY id ASC
                """,
                (int(platform_id),),
            )
            rows = cur.fetchall() or []
    return [str(row[0]) for row in rows if row and row[0] is not None]


def _extract_focus_window(payload: Dict[str, Any], fallback_payload: Optional[Dict[str, Any]] = None) -> tuple[Optional[date], Optional[date]]:
    provider_query = payload.get("provider_query") if isinstance(payload.get("provider_query"), dict) else {}

    focus_start = _optional_date(payload.get("focus_start"))
    focus_end = _optional_date(payload.get("focus_end"))
    if focus_start is None:
        focus_start = _optional_date(provider_query.get("from"))
    if focus_end is None:
        focus_end = _optional_date(provider_query.get("to"))

    if fallback_payload is not None:
        if focus_start is None:
            focus_start = _optional_date(fallback_payload.get("from_date"))
        if focus_end is None:
            focus_end = _optional_date(fallback_payload.get("to_date"))

    return focus_start, focus_end


def _booking_overlaps_focus(arrival: date, departure: date, *, focus_start: Optional[date], focus_end: Optional[date]) -> bool:
    if focus_start is None or focus_end is None:
        return True
    return arrival <= focus_end and departure > focus_start


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


def _is_cancelled_status(status: Optional[str]) -> bool:
    normalized = (status or "").strip().lower()
    if not normalized:
        return False
    if normalized in _CANCELLED_STATUSES:
        return True
    return "cancel" in normalized


def _extract_item_listing_id(item: Dict[str, Any]) -> Optional[str]:
    property_obj = item.get("property") if isinstance(item.get("property"), dict) else {}
    listing_id = (
        as_optional_string(item.get("listing_id"))
        or as_optional_string(item.get("property_id"))
        or as_optional_string(property_obj.get("id"))
    )
    return listing_id


def _extract_booked_at(item: Dict[str, Any], *, arrival: date) -> str:
    booked_at = (
        as_optional_string(item.get("booked_utc"))
        or as_optional_string(item.get("created_utc"))
        or as_optional_string(item.get("updated_utc"))
    )
    if booked_at is not None:
        return booked_at
    # Fallback keeps writes deterministic when provider omits booked timestamps.
    return datetime.combine(arrival, datetime.min.time(), tzinfo=timezone.utc).isoformat().replace("+00:00", "Z")


def _extract_thread_ids(item: Dict[str, Any]) -> list[int]:
    raw_thread_ids = item.get("thread_ids")
    if not isinstance(raw_thread_ids, list) or not raw_thread_ids:
        raise ValueError("thread_ids must be a non-empty array")

    thread_ids: list[int] = []
    for index, raw_value in enumerate(raw_thread_ids):
        thread_id = coerce_optional_int(raw_value, field_name=f"thread_ids[{index}]")
        if thread_id is None:
            raise ValueError(f"thread_ids[{index}] must be an integer")
        thread_ids.append(int(thread_id))
    return thread_ids


def _extract_cancellation_reason(item: Dict[str, Any]) -> Optional[str]:
    for field_name in ("cancellation_reason", "canceled_reason", "cancelled_reason", "notes", "title"):
        value = as_optional_string(item.get(field_name))
        if value:
            return value
    return None


def _parse_next_offset(next_page_url: Optional[str], *, fallback: int) -> int:
    if next_page_url is None:
        return int(fallback)

    try:
        parsed = urlparse(next_page_url)
        query = parse_qs(parsed.query)
        raw_offset = (query.get("offset") or [None])[0]
        parsed_offset = coerce_optional_int(raw_offset, field_name="next_page_url.offset")
        if parsed_offset is None or parsed_offset < 0:
            return int(fallback)
        return int(parsed_offset)
    except Exception:
        return int(fallback)


def _build_fetch_request_runtime_payload(
    payload: Dict[str, Any],
    *,
    listing_ids_override: Optional[list[Any]] = None,
) -> Dict[str, Any]:
    provider_key = _normalize_provider_key(payload.get("provider_key"))
    platform_id = _resolve_platform_id(payload, provider_key=provider_key)
    source_listing_ids = listing_ids_override if listing_ids_override is not None else payload.get("listing_ids")
    listing_ids = _normalize_listing_ids(source_listing_ids)
    timezone_name = as_optional_string(payload.get("timezone")) or DEFAULT_GET_BOOKINGS_DERIVATION_TIMEZONE
    from_date = (
        _parse_date(payload.get("from_date"), field_name="from_date")
        if payload.get("from_date") is not None
        else _today_in_timezone(timezone_name)
    )
    requested_n_days = _as_positive_int(payload.get("n_days"), field_name="n_days", default=DEFAULT_GET_BOOKINGS_N_DAYS)
    to_date = (
        _parse_date(payload.get("to_date"), field_name="to_date")
        if payload.get("to_date") is not None
        else (from_date + timedelta(days=int(requested_n_days)))
    )
    if to_date <= from_date:
        raise ValueError("to_date must be greater than from_date")

    offset = _as_non_negative_int(payload.get("offset"), field_name="offset", default=0)
    limit = _as_positive_int(payload.get("limit"), field_name="limit", default=GET_BOOKINGS_DEFAULT_LIMIT)
    n_days = (to_date - from_date).days
    request_kind = as_optional_string(payload.get("request_kind")) or "interval"

    raw_provider_query = payload.get("provider_query") if isinstance(payload.get("provider_query"), dict) else {}
    provider_query: Dict[str, Any] = dict(raw_provider_query)
    provider_query["from"] = from_date.isoformat()
    provider_query["to"] = to_date.isoformat()

    explicit_since = as_optional_string(raw_provider_query.get("since_utc"))
    if explicit_since is None:
        explicit_since = as_optional_string(payload.get("since_utc"))
    if explicit_since is not None:
        provider_query["since_utc"] = explicit_since
    elif "since_utc" in provider_query:
        provider_query.pop("since_utc", None)

    for key in ("next_cursor", "cursor", "page_token", "next_page_token", "next_page_url", "status", "statuses"):
        if key in payload and key not in provider_query:
            provider_query[key] = payload.get(key)

    return {
        "requested_action": GET_BOOKINGS_ACTION,
        "provider_key": provider_key,
        "platform_id": platform_id,
        "timezone": timezone_name,
        "n_days": n_days,
        "focus_start": from_date.isoformat(),
        "focus_end": to_date.isoformat(),
        "listing_ids": listing_ids,
        "page_size": limit,
        "offset": offset,
        "request_kind": request_kind,
        "provider_query": provider_query,
    }


def _fetch_bookings_page(conn, *, worker_id: str, scope: str, key: str) -> Dict[str, Any]:
    page_payload = get_runtime_variable(conn, worker_id=worker_id, scope=scope, key=key)
    if not isinstance(page_payload, dict):
        raise ValueError("BOOKING_PAGE_INVALID: fetched page runtime payload must be an object")
    items = page_payload.get("items")
    if not isinstance(items, list):
        raise ValueError("BOOKING_PAGE_INVALID: fetched page payload missing items array")
    return page_payload


def _normalize_provider_page_payload(page_payload: Dict[str, Any]) -> Dict[str, Any]:
    provider_key = _normalize_provider_key(page_payload.get("provider_key"))
    platform_id = _coerce_required_int(page_payload, "platform_id")
    listing_ids = _normalize_listing_ids(page_payload.get("listing_ids"))
    timezone_name = as_optional_string(page_payload.get("timezone")) or "UTC"
    provider_query = page_payload.get("provider_query") if isinstance(page_payload.get("provider_query"), dict) else {}
    focus_start, focus_end = _extract_focus_window(page_payload)
    items = page_payload.get("items") if isinstance(page_payload.get("items"), list) else []
    next_page_url = as_optional_string(page_payload.get("next_page_url"))
    provider_paging = page_payload.get("provider_paging") if isinstance(page_payload.get("provider_paging"), dict) else {}

    current_offset = _as_non_negative_int(
        provider_paging.get("offset", page_payload.get("offset")),
        field_name="offset",
        default=0,
    )
    current_limit = _as_positive_int(
        provider_paging.get("limit", page_payload.get("page_size")),
        field_name="limit",
        default=GET_BOOKINGS_DEFAULT_LIMIT,
    )

    return {
        "provider_key": provider_key,
        "platform_id": platform_id,
        "listing_ids": listing_ids,
        "timezone": timezone_name,
        "provider_query": dict(provider_query),
        "focus_start": focus_start.isoformat() if focus_start is not None else None,
        "focus_end": focus_end.isoformat() if focus_end is not None else None,
        "items": list(items),
        "next_page_url": next_page_url,
        "provider_paging": dict(provider_paging),
        "current_offset": current_offset,
        "current_limit": current_limit,
        "error": as_optional_string(page_payload.get("error")),
    }


def _should_enqueue_next_page(page_payload: Dict[str, Any], *, item_count: int, current_limit: int) -> bool:
    if item_count <= 0:
        return False

    provider_paging = page_payload.get("provider_paging") if isinstance(page_payload.get("provider_paging"), dict) else {}
    next_page_url = as_optional_string(page_payload.get("next_page_url"))
    has_more = provider_paging.get("has_more")
    if isinstance(has_more, bool) and has_more:
        return True

    for key in ("next_cursor", "cursor", "next_page_token", "page_token"):
        if provider_paging.get(key) is not None:
            return True

    if next_page_url is not None:
        return True

    if item_count < current_limit:
        return False

    return True


def _build_next_get_bookings_payload(page_payload: Dict[str, Any], *, item_count: int) -> Dict[str, Any]:
    normalized = _normalize_provider_page_payload(page_payload)
    provider_query = dict(normalized.get("provider_query") or {})
    provider_paging = normalized.get("provider_paging") if isinstance(normalized.get("provider_paging"), dict) else {}

    for key in ("next_cursor", "cursor", "next_page_token", "page_token"):
        if provider_paging.get(key) is not None:
            provider_query[key] = provider_paging.get(key)

    next_page_url = normalized.get("next_page_url")
    if next_page_url is not None:
        provider_query["next_page_url"] = next_page_url

    next_offset_fallback = int(normalized["current_offset"]) + int(item_count)
    next_offset = _parse_next_offset(next_page_url, fallback=next_offset_fallback)

    from_date = as_optional_string(provider_query.get("from")) or as_optional_string(normalized.get("focus_start"))
    to_date = as_optional_string(provider_query.get("to")) or as_optional_string(normalized.get("focus_end"))
    if from_date is None or to_date is None:
        raise ValueError("BOOKING_PAGE_INVALID: missing from/to context for continuation")

    payload: Dict[str, Any] = {
        "action": GET_BOOKINGS_ACTION,
        "provider_key": normalized["provider_key"],
        "platform_id": int(normalized["platform_id"]),
        "listing_ids": list(normalized["listing_ids"]),
        "from_date": from_date,
        "to_date": to_date,
        "timezone": normalized["timezone"],
        "offset": int(next_offset),
        "limit": int(normalized["current_limit"]),
    }
    request_kind = as_optional_string(page_payload.get("request_kind"))
    if request_kind:
        payload["request_kind"] = request_kind
    if provider_query:
        payload["provider_query"] = provider_query
    return payload


def _normalize_scanner_metadata(raw_value: Any) -> Dict[str, Any]:
    if isinstance(raw_value, dict):
        return dict(raw_value)
    if isinstance(raw_value, str):
        try:
            parsed = json.loads(raw_value)
        except json.JSONDecodeError:
            return {}
        if isinstance(parsed, dict):
            return parsed
    return {}


def _iso_date_value(value: Any) -> Optional[str]:
    if isinstance(value, date) and not isinstance(value, datetime):
        return value.isoformat()
    text = as_optional_string(value)
    return text


def _iso_datetime_value(value: Any) -> Optional[str]:
    if isinstance(value, datetime):
        return value.isoformat()
    text = as_optional_string(value)
    return text


def _metadata_int_value(metadata: Dict[str, Any], key: str) -> Optional[int]:
    if key not in metadata:
        return None
    return coerce_optional_int(metadata.get(key), field_name=f"metadata.{key}")


def _sum_json_int_array(value: Any) -> int:
    if not isinstance(value, list):
        return 0
    total = 0
    for item in value:
        # Skip bool explicitly because bool is a subclass of int.
        if isinstance(item, bool):
            continue
        try:
            total += int(item)
        except (TypeError, ValueError):
            continue
    return total


def _metadata_classes_value(metadata: Dict[str, Any]) -> list[str]:
    raw_classes = metadata.get("classes")
    classes: list[str] = []
    if isinstance(raw_classes, list):
        for item in raw_classes:
            value = as_optional_string(item)
            if value:
                classes.append(value)
    return sorted(set(classes))


def _build_booking_context_from_scan_row(row: Dict[str, Any]) -> Dict[str, Any]:
    metadata = _normalize_scanner_metadata(row.get("metadata"))
    booking_entry_id = int(row["booking_id"])
    ppl_id = int(row["ppl_id"])
    metadata_stay_length = _metadata_int_value(metadata, "stay_length")
    stay_extended_total = _sum_json_int_array(metadata.get("stay_extended"))
    stay_contracted_total = _sum_json_int_array(metadata.get("stay_contracted"))
    original_stay_length: Optional[int] = None
    if metadata_stay_length is not None:
        original_stay_length = metadata_stay_length - stay_extended_total + stay_contracted_total

    booking_context: Dict[str, Any] = {
        "booking_id": booking_entry_id,
        "booking_entry_id": booking_entry_id,
        "external_booking_id": as_optional_string(metadata.get("booking_id")),
        "property_id": int(row["property_id"]),
        "platform_id": int(row["platform_id"]),
        "ppl_id": ppl_id,
        "listing_id": as_optional_string(metadata.get("listing_id")),
        "arrival": _iso_date_value(row.get("arrival")),
        "departure": _iso_date_value(row.get("departure")),
        "booked_at": _iso_datetime_value(row.get("booked_at")),
        "stay_length": original_stay_length,
        "current_stay_length": metadata_stay_length,
        "stay_extended": stay_extended_total,
        "stay_contracted": stay_contracted_total,
        "booking_window": _metadata_int_value(metadata, "booking_window"),
        "classes": _metadata_classes_value(metadata),
        "metadata": metadata,
        "canonical_pair": {
            "platform_property_lookup_id": ppl_id,
        },
    }
    return {key: value for key, value in booking_context.items() if value is not None}


def _merge_classes_into_booking_context(booking_context: Dict[str, Any], classes: Sequence[str]) -> Dict[str, Any]:
    merged = dict(booking_context)
    merged["classes"] = sorted({str(value) for value in classes if as_optional_string(value)})
    return merged


def _persist_booking_classes(conn, *, booking_id: int, classes: Sequence[str]) -> None:
    normalized_classes = sorted({str(value) for value in classes if as_optional_string(value)})
    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE booking_registers
            SET metadata = jsonb_set(
                COALESCE(metadata, '{}'::jsonb),
                '{classes}',
                %s::jsonb,
                true
            )
            WHERE id = %s
            """,
            (json.dumps(normalized_classes), int(booking_id)),
        )


def _is_cancelled_booking_row(metadata: Dict[str, Any]) -> bool:
    status = as_optional_string(metadata.get("status"))
    if _is_cancelled_status(status):
        return True

    bso = metadata.get("bso") if isinstance(metadata.get("bso"), dict) else {}
    cancellation = bso.get("cancellation") if isinstance(bso.get("cancellation"), dict) else {}
    if bool(cancellation.get("cancelled")):
        return True
    if bool(bso.get("cancelled")):
        return True
    return False


def _scan_checkout_rows(conn, *, target_date: date, limit: int, cursor_id: int) -> list[Dict[str, Any]]:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT booking_id, arrival, departure, property_id, platform_id, guest_id, updated_at, metadata
            FROM scan_booking_registers_for_checkout(%s, %s, %s)
            """,
            (target_date.isoformat(), limit, cursor_id),
        )
        rows = cur.fetchall() or []

    result: list[Dict[str, Any]] = []
    for row in rows:
        result.append(
            {
                "booking_id": int(row[0]),
                "arrival": row[1],
                "departure": row[2],
                "property_id": int(row[3]),
                "platform_id": int(row[4]),
                "guest_id": int(row[5]) if row[5] is not None else None,
                "updated_at": row[6],
                "metadata": _normalize_scanner_metadata(row[7]),
            }
        )
    return result


def _open_process_checkout_lock_connection(dsn: str):
    return connect(dsn)


def _try_acquire_process_checkout_single_flight_lock(conn) -> bool:
    with conn.cursor() as cur:
        cur.execute("SELECT pg_try_advisory_lock(%s)", (PROCESS_CHECKOUT_SINGLE_FLIGHT_LOCK_KEY,))
        row = cur.fetchone()
    return bool(row and row[0])


def _release_process_checkout_single_flight_lock(conn) -> None:
    with conn.cursor() as cur:
        cur.execute("SELECT pg_advisory_unlock(%s)", (PROCESS_CHECKOUT_SINGLE_FLIGHT_LOCK_KEY,))


def _has_bso_metadata(row: Dict[str, Any]) -> bool:
    metadata = row.get("metadata")
    return isinstance(metadata, dict) and isinstance(metadata.get("bso"), dict)


def _scan_active_rows(conn, *, window_start: date, window_end: date, limit: int, cursor_id: int) -> list[Dict[str, Any]]:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT booking_id, arrival, departure, property_id, platform_id, guest_id, updated_at, metadata
            FROM scan_booking_registers_for_extension(%s, %s, %s, %s)
            """,
            (window_start.isoformat(), window_end.isoformat(), limit, cursor_id),
        )
        rows = cur.fetchall() or []

    result: list[Dict[str, Any]] = []
    for row in rows:
        result.append(
            {
                "booking_id": int(row[0]),
                "arrival": row[1],
                "departure": row[2],
                "property_id": int(row[3]),
                "platform_id": int(row[4]),
                "guest_id": int(row[5]) if row[5] is not None else None,
                "updated_at": row[6],
                "metadata": _normalize_scanner_metadata(row[7]),
            }
        )
    return result


def _fetch_booking_scan_context(conn, *, booking_ids: list[int]) -> Dict[int, Dict[str, Any]]:
    if not booking_ids:
        return {}

    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT
                id,
                platform_id,
                ppl_id,
                thread_ids_json,
                property_id,
                arrival,
                departure,
                booked_at,
                metadata
            FROM booking_registers
            WHERE id = ANY(%s)
            ORDER BY id ASC
            """,
            (booking_ids,),
        )
        rows = cur.fetchall() or []

    context_map: Dict[int, Dict[str, Any]] = {}
    for row in rows:
        raw_thread_ids = row[3]
        if isinstance(raw_thread_ids, str):
            try:
                raw_thread_ids = json.loads(raw_thread_ids)
            except json.JSONDecodeError:
                raw_thread_ids = []
        thread_ids: list[int] = []
        if isinstance(raw_thread_ids, list):
            for index, raw_value in enumerate(raw_thread_ids):
                thread_id = coerce_optional_int(raw_value, field_name=f"thread_ids_json[{index}]")
                if thread_id is not None:
                    thread_ids.append(int(thread_id))

        context_row = {
            "booking_id": int(row[0]),
            "platform_id": int(row[1]),
            "ppl_id": int(row[2]),
            "property_id": int(row[4]),
            "arrival": row[5],
            "departure": row[6],
            "booked_at": row[7],
            "metadata": _normalize_scanner_metadata(row[8]),
            "thread_ids": thread_ids,
        }
        context_row["booking_context"] = _build_booking_context_from_scan_row(context_row)
        context_map[int(row[0])] = context_row
    return context_map


def _parse_active_scan_inputs(payload: Dict[str, Any]) -> tuple[Optional[int], date, date, int, int]:
    platform_id_filter = coerce_optional_int(payload.get("platform_id"), field_name="platform_id")
    window_start = _parse_date(payload.get("window_start"), field_name="window_start") if payload.get("window_start") is not None else _local_today()
    window_end_raw = payload.get("window_end")
    if window_end_raw is None:
        n_days = coerce_optional_int(payload.get("n_days"), field_name="n_days")
        if n_days is None:
            raise ValueError("window_end is required when n_days is not provided")
        if n_days < 0:
            raise ValueError("n_days must be >= 0")
        window_end = window_start + timedelta(days=int(n_days))
    else:
        window_end = _parse_date(window_end_raw, field_name="window_end")
    if window_end < window_start:
        raise ValueError("window_end must be greater than or equal to window_start")

    limit = _as_positive_int(payload.get("limit"), field_name="limit", default=DEFAULT_LIMIT)
    cursor_id = _as_non_negative_int(payload.get("cursor_id"), field_name="cursor_id", default=0)
    return platform_id_filter, window_start, window_end, limit, cursor_id


def _build_active_targets(
    context: ManagedWorkerContext,
    *,
    rows: list[Dict[str, Any]],
    platform_id_filter: Optional[int],
) -> Dict[str, Any]:
    filtered_rows: list[Dict[str, Any]] = []
    platform_filtered_count = 0
    cancelled_count = 0
    for row in rows:
        if not isinstance(row, dict):
            continue
        row_platform_id = int(row.get("platform_id"))
        if platform_id_filter is not None and row_platform_id != int(platform_id_filter):
            platform_filtered_count += 1
            continue
        metadata = _normalize_scanner_metadata(row.get("metadata"))
        if _is_cancelled_booking_row(metadata):
            cancelled_count += 1
            continue
        filtered_rows.append(row)

    booking_ids = [int(item["booking_id"]) for item in filtered_rows]
    with context.connect_db() as conn:
        context_map = _fetch_booking_scan_context(conn, booking_ids=booking_ids)

    active_targets: list[Dict[str, Any]] = []
    for row in filtered_rows:
        booking_id = int(row["booking_id"])
        context_row = context_map.get(booking_id)
        if not isinstance(context_row, dict):
            continue
        thread_ids = context_row.get("thread_ids") if isinstance(context_row.get("thread_ids"), list) else []
        if not thread_ids:
            continue
        ppl_id = int(context_row["ppl_id"])
        platform_id = int(context_row["platform_id"])
        active_targets.append(
            {
                "booking_id": booking_id,
                "platform_id": platform_id,
                "ppl_id": ppl_id,
                "thread_ids": [int(value) for value in thread_ids],
                "booking_context": dict(context_row.get("booking_context") or {}),
            }
        )

    return {
        "targets": active_targets,
        "platform_filtered_count": platform_filtered_count,
        "cancelled_count": cancelled_count,
        "matched_count": len(active_targets),
    }


def _lookup_booking_entry_ids_by_external_ids(
    conn,
    *,
    platform_id: int,
    external_booking_ids: list[int],
) -> Dict[int, int]:
    if not external_booking_ids:
        return {}

    external_ids_text = [str(int(value)) for value in external_booking_ids]
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT
                br.id,
                br.metadata->>'booking_id' AS external_booking_id
            FROM booking_registers br
            WHERE br.platform_id = %s
              AND br.metadata->>'booking_id' = ANY(%s::text[])
            """,
            (int(platform_id), external_ids_text),
        )
        rows = cur.fetchall() or []

    mapping: Dict[int, int] = {}
    for row in rows:
        if not row or row[0] is None or row[1] is None:
            continue
        try:
            external_id = int(str(row[1]))
        except ValueError:
            continue
        mapping[external_id] = int(row[0])
    return mapping


def _prepare_booking_rows_for_upsert(
    *,
    items: list[Dict[str, Any]],
    provider_key: str,
    platform_id: int,
    focus_start: Optional[date],
    focus_end: Optional[date],
) -> Dict[str, Any]:
    prepared_rows: list[Dict[str, Any]] = []
    block_count = 0
    cancelled_count = 0
    dropped_out_of_focus = 0

    for index, raw_item in enumerate(items):
        if not isinstance(raw_item, dict):
            raise ValueError(f"items[{index}] must be an object")

        raw_type = as_optional_string(raw_item.get("type"))
        item_type = raw_type.lower() if raw_type is not None else None
        raw_is_block = raw_item.get("is_block")
        is_block = raw_is_block if isinstance(raw_is_block, bool) else None

        if is_block is True:
            block_count += 1
            continue
        if item_type is not None and item_type != "booking":
            block_count += 1
            continue
        if item_type is None and is_block is None:
            raise ValueError(f"items[{index}] cannot be classified as booking vs block")

        booking_id = coerce_optional_int(raw_item.get("id"), field_name=f"items[{index}].id")
        if booking_id is None:
            raise ValueError(f"items[{index}].id is required")

        arrival = _parse_date(raw_item.get("arrival"), field_name=f"items[{index}].arrival")
        departure = _parse_date(raw_item.get("departure"), field_name=f"items[{index}].departure")
        if departure <= arrival:
            raise ValueError(f"items[{index}] departure must be greater than arrival")

        if not _booking_overlaps_focus(arrival, departure, focus_start=focus_start, focus_end=focus_end):
            dropped_out_of_focus += 1
            continue

        guest_id = coerce_optional_int(raw_item.get("guest_id"), field_name=f"items[{index}].guest_id")
        if guest_id is None:
            raise ValueError(f"items[{index}].guest_id is required")

        listing_id = _extract_item_listing_id(raw_item)
        if listing_id is None:
            raise ValueError(f"items[{index}] listing_id/property_id is required")

        thread_ids = _extract_thread_ids(raw_item)
        status = as_optional_string(raw_item.get("status")) or "unknown"
        cancelled = _is_cancelled_status(status)
        if cancelled:
            cancelled_count += 1

        metadata: Dict[str, Any] = {
            "provider_key": provider_key,
            "booking_id": str(booking_id),
            "listing_id": listing_id,
            "status": status,
        }
        if cancelled:
            metadata["cancellation"] = {
                "cancelled": True,
                "reason": _extract_cancellation_reason(raw_item),
            }

        prepared_rows.append(
            {
                "booking_id": int(booking_id),
                "type": "booking",
                "arrival": arrival.isoformat(),
                "departure": departure.isoformat(),
                "booked_at": _extract_booked_at(raw_item, arrival=arrival),
                "guest_id": int(guest_id),
                "platform_id": int(platform_id),
                "listing_id": listing_id,
                "thread_ids": thread_ids,
                "status": status,
                "cancelled": cancelled,
                "reason_note": _extract_cancellation_reason(raw_item),
                "metadata": metadata,
            }
        )

    return {
        "rows": prepared_rows,
        "block_count": block_count,
        "cancelled_count": cancelled_count,
        "dropped_out_of_focus": dropped_out_of_focus,
    }


def _upsert_booking_register(conn, *, booking_row: Dict[str, Any]) -> int:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT (upsert_booking_register(
                p_id => %s,
                p_type => %s,
                p_arrival => %s,
                p_departure => %s,
                p_booked_at => %s::timestamptz,
                p_guest_id => %s,
                p_platform_id => %s,
                p_listing_id => %s,
                p_thread_ids_json => %s::jsonb,
                p_metadata => %s::jsonb
            )).id
            """,
            (
                None,
                str(booking_row["type"]),
                str(booking_row["arrival"]),
                str(booking_row["departure"]),
                str(booking_row["booked_at"]),
                int(booking_row["guest_id"]),
                int(booking_row["platform_id"]),
                str(booking_row["listing_id"]),
                json.dumps(list(booking_row["thread_ids"]), default=str),
                json.dumps(dict(booking_row["metadata"]), default=str),
            ),
        )
        row = cur.fetchone()
    if not row or row[0] is None:
        raise RuntimeError("upsert_booking_register did not return booking id")
    return int(row[0])


def _log_and_fail(
    *,
    queue,
    log,
    state: ActionStateManager,
    task,
    action_name: str,
    step_name: str,
    message: str,
    retry: bool,
    error_code: Optional[str] = None,
    exc: Optional[BaseException] = None,
) -> None:
    log.error(
        message,
        exc=exc,
        error_code=error_code,
        **task_log_kwargs(task, action_name),
    )
    state.record_failure(step_name, message)
    queue.fail_task(task, message, retry=retry)


def handle_get_bookings(context: ManagedWorkerContext, task) -> None:
    queue = context.main_queue
    step = default_step(context)
    log = default_app_logger(context)
    state = ActionStateManager.load(context, task)
    payload = task.payload

    log.info(
        "task started",
        metadata={"action": GET_BOOKINGS_ACTION},
        **task_log_kwargs(task, "handle_get_bookings"),
    )

    if not state.is_step_done("input_validated"):
        state.begin_step("input_validated")
        try:
            provider_key = _normalize_provider_key(payload.get("provider_key"))
            raw_listing_ids = payload.get("listing_ids")
            listing_ids_from_db = not isinstance(raw_listing_ids, list) or len(raw_listing_ids) == 0
            resolved_listing_ids: Optional[list[Any]] = None
            if listing_ids_from_db:
                platform_id = _resolve_platform_id(payload, provider_key=provider_key)
                with context.connect_db() as conn:
                    resolved_listing_ids = _fetch_listing_ids_for_platform(conn, platform_id=platform_id)
                if not resolved_listing_ids:
                    _log_and_fail(
                        queue=queue,
                        log=log,
                        state=state,
                        task=task,
                        action_name="handle_get_bookings",
                        step_name="input_validated",
                        message=f"BOOKING_FETCH_INPUT_INVALID: no listings found for platform_id={platform_id}",
                        retry=False,
                        error_code="BOOKING_FETCH_INPUT_INVALID",
                    )
                    return
            request_payload = _build_fetch_request_runtime_payload(payload, listing_ids_override=resolved_listing_ids)
        except ValueError as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_get_bookings",
                step_name="input_validated",
                message=f"BOOKING_FETCH_INPUT_INVALID: {exc}",
                retry=False,
                error_code="BOOKING_FETCH_INPUT_INVALID",
                exc=exc,
            )
            return

        state.checkpoint(
            "input_validated",
            {
                "request_payload": request_payload,
                "provider_key": request_payload["provider_key"],
                "platform_id": request_payload["platform_id"],
                "listing_count": len(request_payload["listing_ids"]),
                "offset": request_payload["offset"],
                "limit": request_payload["page_size"],
                "listing_ids_source": "db_lookup" if listing_ids_from_db else "payload",
            },
        )

    validated = state.get_step_data("input_validated")
    request_payload = validated.get("request_payload")
    if not isinstance(request_payload, dict):
        _log_and_fail(
            queue=queue,
            log=log,
            state=state,
            task=task,
            action_name="handle_get_bookings",
            step_name="input_validated",
            message="BOOKING_FETCH_INPUT_INVALID: request payload missing in state",
            retry=False,
            error_code="BOOKING_FETCH_INPUT_INVALID",
        )
        return

    lock_conn = None
    lock_acquired = False
    lock_key = 0
    try:
        lock_key = _get_bookings_single_flight_lock_key(request_payload=request_payload)
        lock_conn = _open_get_bookings_lock_connection(context.dsn)
        lock_acquired = _try_acquire_get_bookings_single_flight_lock(lock_conn, lock_key=lock_key)
    except Exception as exc:
        if lock_conn is not None:
            try:
                lock_conn.close()
            except Exception:
                pass
        _log_and_fail(
            queue=queue,
            log=log,
            state=state,
            task=task,
            action_name="handle_get_bookings",
            step_name="single_flight_lock",
            message=f"BOOKING_FETCH_SINGLE_FLIGHT_LOCK_FAILED: {exc}",
            retry=True,
            error_code="BOOKING_FETCH_SINGLE_FLIGHT_LOCK_FAILED",
            exc=exc,
        )
        return

    if not lock_acquired:
        result = {
            "status": "skipped_single_flight",
            "provider_key": str(validated["provider_key"]),
            "platform_id": int(validated["platform_id"]),
            "listing_count": int(validated["listing_count"]),
            "offset": int(validated["offset"]),
            "limit": int(validated["limit"]),
        }
        step.log("bookings fetch skipped due to single-flight lock", result)
        log.info("task completed", metadata=result, **task_log_kwargs(task, "handle_get_bookings"))
        queue.complete_task(task, result)
        if lock_conn is not None:
            try:
                lock_conn.close()
            except Exception:
                pass
        return

    try:
        if not state.is_step_done("request_written"):
            state.begin_step("request_written")
            request_key = generate_key("fetch_bookings_request")
            try:
                with context.connect_db() as conn:
                    set_runtime_variable(
                        conn,
                        worker_id=context.scheduler.worker_id,
                        scope=FETCH_REQUEST_SCOPE,
                        key=request_key,
                        value=request_payload,
                        ttl_minutes=_resolve_runtime_ttl(action=GET_BOOKINGS_ACTION, scope=FETCH_REQUEST_SCOPE),
                    )
            except Exception as exc:
                _log_and_fail(
                    queue=queue,
                    log=log,
                    state=state,
                    task=task,
                    action_name="handle_get_bookings",
                    step_name="request_written",
                    message=f"FETCH_REQUEST_WRITE_FAILED: {exc}",
                    retry=True,
                    error_code="FETCH_REQUEST_WRITE_FAILED",
                    exc=exc,
                )
                return

            state.checkpoint(
                "request_written",
                {
                    "request_worker_id": context.scheduler.worker_id,
                    "request_scope": FETCH_REQUEST_SCOPE,
                    "request_key": request_key,
                },
            )

        if not state.is_step_done("fetch_enqueued"):
            state.begin_step("fetch_enqueued")
            request_data = state.get_step_data("request_written")
            external_payload = {
                "action": f"get_{request_payload['provider_key']}_bookings",
                "data_ref": {
                    "worker_id": request_data["request_worker_id"],
                    "scope": request_data["request_scope"],
                    "key": request_data["request_key"],
                },
                "return_ref": {
                    "worker": WORKER,
                    "queue": PRIMARY_QUEUE,
                    "action": GET_BOOKINGS_RET_ACTION,
                },
            }
            try:
                downstream_task_uuid = enqueue_with_meta(
                    context.queue(EXTERNAL_SERVICES_QUEUE),
                    EXTERNAL_SERVICES_WORKER,
                    external_payload,
                    current_task=task,
                    current_worker=WORKER,
                    current_action=GET_BOOKINGS_ACTION,
                    next_worker=WORKER,
                    next_action=GET_BOOKINGS_RET_ACTION,
                )
            except Exception as exc:
                _log_and_fail(
                    queue=queue,
                    log=log,
                    state=state,
                    task=task,
                    action_name="handle_get_bookings",
                    step_name="fetch_enqueued",
                    message=f"FETCH_ENQUEUE_FAILED: {exc}",
                    retry=True,
                    error_code="FETCH_ENQUEUE_FAILED",
                    exc=exc,
                )
                return

            state.checkpoint("fetch_enqueued", {"downstream_task_uuid": downstream_task_uuid})

        enqueue_data = state.get_step_data("fetch_enqueued")
        result = {
            "status": "forwarded_to_external_service",
            "provider_key": str(validated["provider_key"]),
            "platform_id": int(validated["platform_id"]),
            "listing_count": int(validated["listing_count"]),
            "offset": int(validated["offset"]),
            "limit": int(validated["limit"]),
            "downstream_task_uuid": enqueue_data.get("downstream_task_uuid"),
        }
        step.log("bookings fetch request forwarded", result)
        log.info("task completed", metadata=result, **task_log_kwargs(task, "handle_get_bookings"))
        queue.complete_task(task, result)
    finally:
        if lock_conn is not None:
            try:
                if lock_acquired:
                    _release_get_bookings_single_flight_lock(lock_conn, lock_key=lock_key)
            except Exception as exc:
                log.warn(
                    "failed to release get_bookings single-flight lock",
                    exc=exc,
                    error_code="BOOKING_FETCH_SINGLE_FLIGHT_UNLOCK_FAILED",
                    **task_log_kwargs(task, "handle_get_bookings"),
                )
            try:
                lock_conn.close()
            except Exception as exc:
                log.warn(
                    "failed to close get_bookings lock connection",
                    exc=exc,
                    error_code="BOOKING_FETCH_SINGLE_FLIGHT_CONN_CLOSE_FAILED",
                    **task_log_kwargs(task, "handle_get_bookings"),
                )


def _handle_get_bookings_ret(context: ManagedWorkerContext, task, *, requested_action: str) -> None:
    queue = context.main_queue
    step = default_step(context)
    log = default_app_logger(context)
    state = ActionStateManager.load(context, task)
    payload = task.payload

    data_ref = _normalize_data_ref(payload, default_scope=FETCH_PAGE_SCOPE)
    source_worker_id = data_ref["worker_id"] or context.scheduler.worker_id
    source_scope = str(data_ref["scope"] or FETCH_PAGE_SCOPE)
    source_key = data_ref["key"]
    if source_key is None:
        _log_and_fail(
            queue=queue,
            log=log,
            state=state,
            task=task,
            action_name="handle_get_bookings_ret",
            step_name="page_loaded",
            message="BOOKING_PAGE_INVALID: missing data_ref.key",
            retry=False,
            error_code="BOOKING_PAGE_INVALID",
        )
        return

    if not state.is_step_done("page_loaded"):
        state.begin_step("page_loaded")
        try:
            with context.connect_db() as conn:
                page_payload = _fetch_bookings_page(
                    conn,
                    worker_id=source_worker_id,
                    scope=source_scope,
                    key=str(source_key),
                )
        except LookupError as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_get_bookings_ret",
                step_name="page_loaded",
                message=f"FETCH_RESPONSE_EXPIRED: {exc}",
                retry=False,
                error_code="FETCH_RESPONSE_EXPIRED",
                exc=exc,
            )
            return
        except ValueError as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_get_bookings_ret",
                step_name="page_loaded",
                message=str(exc),
                retry=False,
                error_code="BOOKING_PAGE_INVALID",
                exc=exc,
            )
            return
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_get_bookings_ret",
                step_name="page_loaded",
                message=f"BOOKING_PAGE_READ_FAILED: {exc}",
                retry=True,
                error_code="BOOKING_PAGE_READ_FAILED",
                exc=exc,
            )
            return

        try:
            normalized = _normalize_provider_page_payload(page_payload)
        except ValueError as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_get_bookings_ret",
                step_name="page_loaded",
                message=f"BOOKING_PAGE_INVALID: {exc}",
                retry=False,
                error_code="BOOKING_PAGE_INVALID",
                exc=exc,
            )
            return

        item_count = len(normalized["items"])
        should_continue = _should_enqueue_next_page(
            page_payload,
            item_count=item_count,
            current_limit=int(normalized["current_limit"]),
        )
        next_payload = None
        if should_continue:
            try:
                next_payload = _build_next_get_bookings_payload(page_payload, item_count=item_count)
            except ValueError as exc:
                _log_and_fail(
                    queue=queue,
                    log=log,
                    state=state,
                    task=task,
                    action_name="handle_get_bookings_ret",
                    step_name="page_loaded",
                    message=str(exc),
                    retry=False,
                    error_code="BOOKING_PAGE_INVALID",
                    exc=exc,
                )
                return

        state.checkpoint(
            "page_loaded",
            {
                "source_worker_id": source_worker_id,
                "source_scope": source_scope,
                "source_key": source_key,
                "provider_key": normalized["provider_key"],
                "platform_id": normalized["platform_id"],
                "item_count": item_count,
                "current_offset": normalized["current_offset"],
                "current_limit": normalized["current_limit"],
                "fetch_error": normalized["error"],
                "next_payload": next_payload,
            },
        )

    page_data = state.get_step_data("page_loaded")
    item_count = int(page_data.get("item_count") or 0)
    if item_count == 0:
        cleanup_error = None
        try:
            with context.connect_db() as conn:
                delete_runtime_variable(
                    conn,
                    worker_id=str(page_data["source_worker_id"]),
                    scope=str(page_data["source_scope"]),
                    key=str(page_data["source_key"]),
                )
        except Exception as exc:
            cleanup_error = str(exc)

        result = {
            "status": "no_work",
            "provider_key": page_data.get("provider_key"),
            "platform_id": page_data.get("platform_id"),
            "item_count": 0,
            "error": page_data.get("fetch_error"),
            "cleanup_error": cleanup_error,
        }
        step.log("bookings fetch page had no items", result)
        log.info("task completed", metadata=result, **task_log_kwargs(task, "handle_get_bookings_ret"))
        queue.complete_task(task, result)
        return

    if not state.is_step_done("registration_enqueued"):
        state.begin_step("registration_enqueued")
        register_payload = {
            "action": REGISTER_BOOKINGS_ACTION,
            "data_ref": {
                "worker_id": page_data["source_worker_id"],
                "scope": page_data["source_scope"],
                "key": page_data["source_key"],
            },
        }
        try:
            registration_task_uuid = enqueue_with_meta(
                queue,
                WORKER,
                register_payload,
                current_task=task,
                current_worker=WORKER,
                current_action=requested_action,
                next_worker=WORKER,
                next_action=REGISTER_BOOKINGS_ACTION,
            )
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_get_bookings_ret",
                step_name="registration_enqueued",
                message=f"BOOKING_REGISTER_ENQUEUE_FAILED: {exc}",
                retry=True,
                error_code="BOOKING_REGISTER_ENQUEUE_FAILED",
                exc=exc,
            )
            return
        state.checkpoint("registration_enqueued", {"registration_task_uuid": registration_task_uuid})

    if not state.is_step_done("continuation_enqueued"):
        next_payload = page_data.get("next_payload") if isinstance(page_data.get("next_payload"), dict) else None
        if next_payload is not None:
            state.begin_step("continuation_enqueued")
            try:
                next_page_task_uuid = enqueue_with_meta(
                    queue,
                    WORKER,
                    next_payload,
                    current_task=task,
                    current_worker=WORKER,
                    current_action=requested_action,
                    next_worker=WORKER,
                    next_action=GET_BOOKINGS_ACTION,
                )
            except Exception as exc:
                _log_and_fail(
                    queue=queue,
                    log=log,
                    state=state,
                    task=task,
                    action_name="handle_get_bookings_ret",
                    step_name="continuation_enqueued",
                    message=f"BOOKING_FETCH_CONTINUATION_ENQUEUE_FAILED: {exc}",
                    retry=True,
                    error_code="BOOKING_FETCH_CONTINUATION_ENQUEUE_FAILED",
                    exc=exc,
                )
                return
            state.checkpoint("continuation_enqueued", {"next_page_task_uuid": next_page_task_uuid})

    registration_task_uuid = state.get_step_data("registration_enqueued").get("registration_task_uuid")
    next_page_task_uuid = None
    if state.is_step_done("continuation_enqueued"):
        next_page_task_uuid = state.get_step_data("continuation_enqueued").get("next_page_task_uuid")

    result = {
        "status": "processed_fetch_page",
        "provider_key": page_data.get("provider_key"),
        "platform_id": page_data.get("platform_id"),
        "item_count": item_count,
        "registration_task_uuid": registration_task_uuid,
        "next_page_task_uuid": next_page_task_uuid,
    }
    step.log("bookings fetch page processed", result)
    log.info("task completed", metadata=result, **task_log_kwargs(task, "handle_get_bookings_ret"))
    queue.complete_task(task, result)


def handle_get_bookings_ret(context: ManagedWorkerContext, task) -> None:
    _handle_get_bookings_ret(context, task, requested_action=GET_BOOKINGS_RET_ACTION)


def handle_ret_get_bookings(context: ManagedWorkerContext, task) -> None:
    _handle_get_bookings_ret(context, task, requested_action="ret_get_bookings")


def handle_get_boogings_ret(context: ManagedWorkerContext, task) -> None:
    _handle_get_bookings_ret(context, task, requested_action="get_boogings_ret")


def handle_register_bookings(context: ManagedWorkerContext, task) -> None:
    queue = context.main_queue
    step = default_step(context)
    log = default_app_logger(context)
    state = ActionStateManager.load(context, task)
    payload = task.payload

    log.info(
        "task started",
        metadata={"action": REGISTER_BOOKINGS_ACTION},
        **task_log_kwargs(task, "handle_register_bookings"),
    )

    source_worker_id: str = context.scheduler.worker_id
    source_scope = FETCH_PAGE_SCOPE
    source_key: Optional[str] = None
    source_payload: Dict[str, Any] = {}

    if not state.is_step_done("page_loaded"):
        state.begin_step("page_loaded")
        data_ref = _normalize_data_ref(payload, default_scope=FETCH_PAGE_SCOPE)
        source_worker_id = data_ref["worker_id"] or context.scheduler.worker_id
        source_scope = str(data_ref["scope"] or FETCH_PAGE_SCOPE)
        source_key = data_ref["key"]

        inline_items = payload.get("items")
        if source_key:
            try:
                with context.connect_db() as conn:
                    source_payload = _fetch_bookings_page(
                        conn,
                        worker_id=source_worker_id,
                        scope=source_scope,
                        key=str(source_key),
                    )
            except LookupError as exc:
                _log_and_fail(
                    queue=queue,
                    log=log,
                    state=state,
                    task=task,
                    action_name="handle_register_bookings",
                    step_name="page_loaded",
                    message=f"FETCH_RESPONSE_EXPIRED: {exc}",
                    retry=False,
                    error_code="FETCH_RESPONSE_EXPIRED",
                    exc=exc,
                )
                return
            except ValueError as exc:
                _log_and_fail(
                    queue=queue,
                    log=log,
                    state=state,
                    task=task,
                    action_name="handle_register_bookings",
                    step_name="page_loaded",
                    message=str(exc),
                    retry=False,
                    error_code="BOOKING_PAGE_INVALID",
                    exc=exc,
                )
                return
            except Exception as exc:
                _log_and_fail(
                    queue=queue,
                    log=log,
                    state=state,
                    task=task,
                    action_name="handle_register_bookings",
                    step_name="page_loaded",
                    message=f"BOOKING_PAGE_READ_FAILED: {exc}",
                    retry=True,
                    error_code="BOOKING_PAGE_READ_FAILED",
                    exc=exc,
                )
                return
        else:
            if not isinstance(inline_items, list):
                _log_and_fail(
                    queue=queue,
                    log=log,
                    state=state,
                    task=task,
                    action_name="handle_register_bookings",
                    step_name="page_loaded",
                    message="BOOKING_PAGE_INVALID: data_ref.key or inline items are required",
                    retry=False,
                    error_code="BOOKING_PAGE_INVALID",
                )
                return
            source_payload = dict(payload)
            source_payload["items"] = list(inline_items)
            source_scope = REGISTER_REQUEST_SCOPE

        try:
            provider_key = _normalize_provider_key(source_payload.get("provider_key"))
            platform_id = _coerce_required_int(source_payload, "platform_id")
            items = source_payload.get("items")
            if not isinstance(items, list):
                raise ValueError("items must be an array")
        except ValueError as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_register_bookings",
                step_name="page_loaded",
                message=f"BOOKING_PAGE_INVALID: {exc}",
                retry=False,
                error_code="BOOKING_PAGE_INVALID",
                exc=exc,
            )
            return

        state.checkpoint(
            "page_loaded",
            {
                "source_worker_id": source_worker_id,
                "source_scope": source_scope,
                "source_key": source_key,
                "provider_key": provider_key,
                "platform_id": platform_id,
                "item_count": len(items),
            },
        )

    page_data = state.get_step_data("page_loaded")
    source_worker_id = str(page_data["source_worker_id"])
    source_scope = str(page_data["source_scope"])
    source_key = as_optional_string(page_data.get("source_key"))

    try:
        if source_key:
            with context.connect_db() as conn:
                source_payload = _fetch_bookings_page(
                    conn,
                    worker_id=source_worker_id,
                    scope=source_scope,
                    key=source_key,
                )
        else:
            inline_items = payload.get("items")
            source_payload = dict(payload)
            source_payload["items"] = list(inline_items) if isinstance(inline_items, list) else []
    except LookupError as exc:
        _log_and_fail(
            queue=queue,
            log=log,
            state=state,
            task=task,
            action_name="handle_register_bookings",
            step_name="page_loaded",
            message=f"FETCH_RESPONSE_EXPIRED: {exc}",
            retry=False,
            error_code="FETCH_RESPONSE_EXPIRED",
            exc=exc,
        )
        return
    except Exception as exc:
        _log_and_fail(
            queue=queue,
            log=log,
            state=state,
            task=task,
            action_name="handle_register_bookings",
            step_name="page_loaded",
            message=f"BOOKING_PAGE_READ_FAILED: {exc}",
            retry=True,
            error_code="BOOKING_PAGE_READ_FAILED",
            exc=exc,
        )
        return

    provider_key = str(page_data["provider_key"])
    platform_id = int(page_data["platform_id"])
    items = source_payload.get("items") if isinstance(source_payload.get("items"), list) else []
    focus_start, focus_end = _extract_focus_window(source_payload, payload)

    try:
        prepared = _prepare_booking_rows_for_upsert(
            items=items,
            provider_key=provider_key,
            platform_id=platform_id,
            focus_start=focus_start,
            focus_end=focus_end,
        )
    except ValueError as exc:
        _log_and_fail(
            queue=queue,
            log=log,
            state=state,
            task=task,
            action_name="handle_register_bookings",
            step_name="bookings_filtered",
            message=f"BOOKING_BLOCK_CLASSIFICATION_FAILED: {exc}",
            retry=False,
            error_code="BOOKING_BLOCK_CLASSIFICATION_FAILED",
            exc=exc,
        )
        return

    prepared_rows = list(prepared["rows"])
    block_count = int(prepared["block_count"])
    cancelled_count = int(prepared["cancelled_count"])
    dropped_out_of_focus = int(prepared["dropped_out_of_focus"])

    if not state.is_step_done("bookings_filtered"):
        state.checkpoint(
            "bookings_filtered",
            {
                "booking_count": len(prepared_rows),
                "block_count": block_count,
                "cancelled_count": cancelled_count,
                "dropped_out_of_focus": dropped_out_of_focus,
            },
        )

    stored_booking_ids: list[int] = []
    cancelled_booking_ids: list[int] = []
    cancelled_reason_map: Dict[str, Optional[str]] = {}
    if not state.is_step_done("bookings_upserted"):
        state.begin_step("bookings_upserted")
        pending_rows, processed = _pending_after_cursor(
            prepared_rows,
            state.get_resume_cursor(),
            key_name="booking_id",
        )

        try:
            external_to_entry_id: Dict[int, int] = {}
            with context.connect_db() as conn:
                for booking_row in pending_rows:
                    stored_booking_id = _upsert_booking_register(conn, booking_row=booking_row)
                    stored_booking_ids.append(stored_booking_id)
                    if bool(booking_row.get("cancelled")):
                        cancelled_booking_ids.append(stored_booking_id)
                    processed += 1
                    state.set_progress(
                        items_total=len(prepared_rows),
                        items_processed=processed,
                        last_processed_id=booking_row.get("booking_id"),
                    )
                external_to_entry_id = _lookup_booking_entry_ids_by_external_ids(
                    conn,
                    platform_id=platform_id,
                    external_booking_ids=[int(item["booking_id"]) for item in prepared_rows],
                )
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_register_bookings",
                step_name="bookings_upserted",
                message=f"BOOKING_REGISTER_UPSERT_FAILED: {exc}",
                retry=True,
                error_code="BOOKING_REGISTER_UPSERT_FAILED",
                exc=exc,
            )
            return

        stored_booking_ids = []
        cancelled_booking_ids = []
        cancelled_reason_map = {}
        for item in prepared_rows:
            external_booking_id = int(item["booking_id"])
            entry_id = external_to_entry_id.get(external_booking_id)
            if entry_id is None:
                continue
            if entry_id not in stored_booking_ids:
                stored_booking_ids.append(entry_id)
            if bool(item.get("cancelled")):
                if entry_id not in cancelled_booking_ids:
                    cancelled_booking_ids.append(entry_id)
                cancelled_reason_map[str(entry_id)] = as_optional_string(item.get("reason_note"))

        last_processed_id = state.get_resume_cursor()
        state.checkpoint(
            "bookings_upserted",
            {
                "processed_count": len(prepared_rows),
                "last_processed_id": last_processed_id,
                "stored_booking_ids": sorted({int(value) for value in stored_booking_ids}),
                "cancelled_booking_ids": sorted({int(value) for value in cancelled_booking_ids}),
                "cancelled_reason_map": cancelled_reason_map,
            },
        )

    upsert_data = state.get_step_data("bookings_upserted")
    stored_booking_ids = [int(value) for value in upsert_data.get("stored_booking_ids") or []]
    cancelled_booking_ids = [int(value) for value in upsert_data.get("cancelled_booking_ids") or []]
    cancelled_reason_map_raw = upsert_data.get("cancelled_reason_map")
    if isinstance(cancelled_reason_map_raw, dict):
        cancelled_reason_map = {str(key): as_optional_string(value) for key, value in cancelled_reason_map_raw.items()}
    else:
        cancelled_reason_map = {}

    if not state.is_step_done("cancellation_removals_enqueued"):
        state.begin_step("cancellation_removals_enqueued")
        removal_task_uuids: list[str] = []
        try:
            for booking_id in cancelled_booking_ids:
                removal_payload = {
                    "action": BSO_REMOVE_ACTION,
                    "booking_id": int(booking_id),
                    "reason_code": "booking_cancelled",
                    "reason_note": cancelled_reason_map.get(str(int(booking_id))) or "provider returned cancelled status",
                }
                task_uuid = enqueue_with_meta(
                    context.queue(BSO_QUEUE),
                    BSO_WORKER,
                    removal_payload,
                    current_task=task,
                    current_worker=WORKER,
                    current_action=REGISTER_BOOKINGS_ACTION,
                    next_worker=BSO_WORKER,
                    next_action=BSO_REMOVE_ACTION,
                )
                if task_uuid:
                    removal_task_uuids.append(str(task_uuid))
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_register_bookings",
                step_name="cancellation_removals_enqueued",
                message=f"BSO_REMOVAL_ENQUEUE_FAILED: {exc}",
                retry=True,
                error_code="BSO_REMOVAL_ENQUEUE_FAILED",
                exc=exc,
            )
            return

        state.checkpoint(
            "cancellation_removals_enqueued",
            {"removal_task_uuids": removal_task_uuids},
        )

    removal_task_uuids = [
        str(value)
        for value in state.get_step_data("cancellation_removals_enqueued").get("removal_task_uuids") or []
        if value
    ]

    cleanup_error = None
    if source_key is not None:
        try:
            with context.connect_db() as conn:
                delete_runtime_variable(
                    conn,
                    worker_id=source_worker_id,
                    scope=source_scope,
                    key=source_key,
                )
        except Exception as exc:
            cleanup_error = str(exc)

    result = {
        "status": "registered",
        "provider_key": provider_key,
        "platform_id": platform_id,
        "received_count": len(items),
        "stored_count": len(prepared_rows),
        "block_count": block_count,
        "cancelled_count": cancelled_count,
        "cancellation_removal_task_count": len(removal_task_uuids),
        "dropped_out_of_focus_count": dropped_out_of_focus,
        "cleanup_error": cleanup_error,
    }
    step.log("bookings registered", result)
    log.info("task completed", metadata=result, **task_log_kwargs(task, "handle_register_bookings"))
    queue.complete_task(task, result)


def handle_process_checkout(context: ManagedWorkerContext, task) -> None:
    queue = context.main_queue
    step = default_step(context)
    log = default_app_logger(context)
    state = ActionStateManager.load(context, task)
    payload = task.payload if isinstance(task.payload, dict) else {}

    target_date = _local_today()
    platform_id_filter = coerce_optional_int(payload.get("platform_id"), field_name="platform_id")
    try:
        if payload.get("target_date") is not None:
            target_date = _parse_date(payload.get("target_date"), field_name="target_date")
        limit = _as_positive_int(payload.get("limit"), field_name="limit", default=DEFAULT_LIMIT)
        cursor_id = _as_non_negative_int(payload.get("cursor_id"), field_name="cursor_id", default=0)
    except ValueError as exc:
        _log_and_fail(
            queue=queue,
            log=log,
            state=state,
            task=task,
            action_name="handle_process_checkout",
            step_name="scanner_rows_loaded",
            message=f"CHECKOUT_SCAN_INPUT_INVALID: {exc}",
            retry=False,
            error_code="CHECKOUT_SCAN_INPUT_INVALID",
            exc=exc,
        )
        return

    lock_conn = None
    lock_acquired = False
    try:
        lock_conn = _open_process_checkout_lock_connection(context.dsn)
        lock_acquired = _try_acquire_process_checkout_single_flight_lock(lock_conn)
    except Exception as exc:
        if lock_conn is not None:
            try:
                lock_conn.close()
            except Exception:
                pass
        _log_and_fail(
            queue=queue,
            log=log,
            state=state,
            task=task,
            action_name="handle_process_checkout",
            step_name="single_flight_lock",
            message=f"CHECKOUT_SINGLE_FLIGHT_LOCK_FAILED: {exc}",
            retry=True,
            error_code="CHECKOUT_SINGLE_FLIGHT_LOCK_FAILED",
            exc=exc,
        )
        return

    target_date_text = target_date.isoformat()
    try:
        if not lock_acquired:
            result = {
                "status": "skipped_single_flight",
                "target_date": target_date_text,
                "platform_id": platform_id_filter,
                "limit": limit,
                "cursor_id": cursor_id,
            }
            step.log("process_checkout skipped due to single-flight lock", result)
            log.info("task completed", metadata=result, **task_log_kwargs(task, "handle_process_checkout"))
            queue.complete_task(task, result)
            return

        if not state.is_step_done("scanner_rows_loaded"):
            state.begin_step("scanner_rows_loaded")
            try:
                with context.connect_db() as conn:
                    rows = _scan_checkout_rows(
                        conn,
                        target_date=target_date,
                        limit=limit,
                        cursor_id=cursor_id,
                    )
            except Exception as exc:
                _log_and_fail(
                    queue=queue,
                    log=log,
                    state=state,
                    task=task,
                    action_name="handle_process_checkout",
                    step_name="scanner_rows_loaded",
                    message=f"CHECKOUT_SCAN_FAILED: {exc}",
                    retry=True,
                    error_code="CHECKOUT_SCAN_FAILED",
                    exc=exc,
                )
                return

            state.checkpoint(
                "scanner_rows_loaded",
                {
                    "rows": rows,
                    "raw_count": len(rows),
                    "last_raw_booking_id": rows[-1]["booking_id"] if rows else None,
                    "target_date": target_date_text,
                    "limit": limit,
                    "cursor_id": cursor_id,
                    "platform_id_filter": platform_id_filter,
                },
            )

        scan_data = state.get_step_data("scanner_rows_loaded")
        rows = scan_data.get("rows") if isinstance(scan_data.get("rows"), list) else []
        raw_count = int(scan_data.get("raw_count") or 0)
        target_date_text = str(scan_data["target_date"])
        limit = int(scan_data["limit"])
        cursor_id = int(scan_data["cursor_id"])
        platform_id_filter = coerce_optional_int(scan_data.get("platform_id_filter"), field_name="platform_id")

        filtered_rows: list[Dict[str, Any]] = []
        for row in rows:
            if not isinstance(row, dict):
                continue
            if platform_id_filter is not None and int(row.get("platform_id")) != int(platform_id_filter):
                continue
            if not _has_bso_metadata(row):
                continue
            filtered_rows.append(row)

        if not state.is_step_done("removals_enqueued"):
            state.begin_step("removals_enqueued")
            removal_task_uuids: list[str] = []
            try:
                for row in filtered_rows:
                    booking_id = int(row["booking_id"])
                    removal_payload = {
                        "action": BSO_REMOVE_ACTION,
                        "booking_id": booking_id,
                        "reason_code": "checkout",
                        "reason_note": f"booking checked out on {target_date_text}",
                    }
                    task_uuid = enqueue_with_meta(
                        context.queue(BSO_QUEUE),
                        BSO_WORKER,
                        removal_payload,
                        current_task=task,
                        current_worker=WORKER,
                        current_action=PROCESS_CHECKOUT_ACTION,
                        next_worker=BSO_WORKER,
                        next_action=BSO_REMOVE_ACTION,
                    )
                    if task_uuid:
                        removal_task_uuids.append(str(task_uuid))
            except Exception as exc:
                _log_and_fail(
                    queue=queue,
                    log=log,
                    state=state,
                    task=task,
                    action_name="handle_process_checkout",
                    step_name="removals_enqueued",
                    message=f"BSO_REMOVAL_ENQUEUE_FAILED: {exc}",
                    retry=True,
                    error_code="BSO_REMOVAL_ENQUEUE_FAILED",
                    exc=exc,
                )
                return

            state.checkpoint("removals_enqueued", {"removal_task_uuids": removal_task_uuids})

        if not state.is_step_done("continuation_enqueued"):
            if raw_count == limit and scan_data.get("last_raw_booking_id") is not None:
                state.begin_step("continuation_enqueued")
                continuation_payload: Dict[str, Any] = {
                    "action": PROCESS_CHECKOUT_ACTION,
                    "target_date": target_date_text,
                    "limit": limit,
                    "cursor_id": int(scan_data["last_raw_booking_id"]),
                }
                if platform_id_filter is not None:
                    continuation_payload["platform_id"] = int(platform_id_filter)
                try:
                    continuation_task_uuid = enqueue_with_meta(
                        queue,
                        WORKER,
                        continuation_payload,
                        current_task=task,
                        current_worker=WORKER,
                        current_action=PROCESS_CHECKOUT_ACTION,
                        next_worker=WORKER,
                        next_action=PROCESS_CHECKOUT_ACTION,
                    )
                except Exception as exc:
                    _log_and_fail(
                        queue=queue,
                        log=log,
                        state=state,
                        task=task,
                        action_name="handle_process_checkout",
                        step_name="continuation_enqueued",
                        message=f"CHECKOUT_CONTINUATION_ENQUEUE_FAILED: {exc}",
                        retry=True,
                        error_code="CHECKOUT_CONTINUATION_ENQUEUE_FAILED",
                        exc=exc,
                    )
                    return
                state.checkpoint("continuation_enqueued", {"continuation_task_uuid": continuation_task_uuid})

        removal_task_uuids = [
            str(value)
            for value in state.get_step_data("removals_enqueued").get("removal_task_uuids") or []
            if value
        ]
        continuation_task_uuid = None
        if state.is_step_done("continuation_enqueued"):
            continuation_task_uuid = state.get_step_data("continuation_enqueued").get("continuation_task_uuid")

        status = "no_work" if raw_count == 0 else "scanned"
        result = {
            "status": status,
            "target_date": target_date_text,
            "platform_id": platform_id_filter,
            "limit": limit,
            "cursor_id": cursor_id,
            "raw_count": raw_count,
            "matched_count": len(filtered_rows),
            "removal_task_count": len(removal_task_uuids),
            "continuation_task_uuid": continuation_task_uuid,
        }
        step.log("process_checkout completed", result)
        log.info("task completed", metadata=result, **task_log_kwargs(task, "handle_process_checkout"))
        queue.complete_task(task, result)
    finally:
        if lock_conn is not None:
            try:
                if lock_acquired:
                    _release_process_checkout_single_flight_lock(lock_conn)
            except Exception as exc:
                log.warn(
                    "failed to release process_checkout single-flight lock",
                    exc=exc,
                    error_code="CHECKOUT_SINGLE_FLIGHT_UNLOCK_FAILED",
                    **task_log_kwargs(task, "handle_process_checkout"),
                )
            try:
                lock_conn.close()
            except Exception as exc:
                log.warn(
                    "failed to close process_checkout lock connection",
                    exc=exc,
                    error_code="CHECKOUT_SINGLE_FLIGHT_CONN_CLOSE_FAILED",
                    **task_log_kwargs(task, "handle_process_checkout"),
                )


def handle_scan_checked_out(context: ManagedWorkerContext, task) -> None:
    handle_process_checkout(context, task)


def handle_scan_actives(context: ManagedWorkerContext, task) -> None:
    queue = context.main_queue
    step = default_step(context)
    log = default_app_logger(context)
    state = ActionStateManager.load(context, task)
    payload = task.payload

    try:
        platform_id_filter, window_start, window_end, limit, cursor_id = _parse_active_scan_inputs(payload)
    except ValueError as exc:
        _log_and_fail(
            queue=queue,
            log=log,
            state=state,
            task=task,
            action_name="handle_scan_actives",
            step_name="scanner_rows_loaded",
            message=f"ACTIVE_SCAN_INPUT_INVALID: {exc}",
            retry=False,
            error_code="ACTIVE_SCAN_INPUT_INVALID",
            exc=exc,
        )
        return

    if not state.is_step_done("scanner_rows_loaded"):
        state.begin_step("scanner_rows_loaded")
        try:
            with context.connect_db() as conn:
                rows = _scan_active_rows(
                    conn,
                    window_start=window_start,
                    window_end=window_end,
                    limit=limit,
                    cursor_id=cursor_id,
                )
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_scan_actives",
                step_name="scanner_rows_loaded",
                message=f"ACTIVE_SCAN_FAILED: {exc}",
                retry=True,
                error_code="ACTIVE_SCAN_FAILED",
                exc=exc,
            )
            return

        state.checkpoint(
            "scanner_rows_loaded",
            {
                "rows": rows,
                "raw_count": len(rows),
                "last_raw_booking_id": rows[-1]["booking_id"] if rows else None,
                "window_start": window_start.isoformat(),
                "window_end": window_end.isoformat(),
                "limit": limit,
                "cursor_id": cursor_id,
                "platform_id_filter": platform_id_filter,
            },
        )

    scan_data = state.get_step_data("scanner_rows_loaded")
    rows = scan_data.get("rows") if isinstance(scan_data.get("rows"), list) else []
    raw_count = int(scan_data.get("raw_count") or 0)
    window_start_text = str(scan_data["window_start"])
    window_end_text = str(scan_data["window_end"])
    limit = int(scan_data["limit"])
    cursor_id = int(scan_data["cursor_id"])
    platform_id_filter = coerce_optional_int(scan_data.get("platform_id_filter"), field_name="platform_id")

    if not state.is_step_done("active_rows_filtered"):
        state.begin_step("active_rows_filtered")
        try:
            target_data = _build_active_targets(
                context,
                rows=rows,
                platform_id_filter=platform_id_filter,
            )
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_scan_actives",
                step_name="active_rows_filtered",
                message=f"ACTIVE_SCAN_CONTEXT_READ_FAILED: {exc}",
                retry=True,
                error_code="ACTIVE_SCAN_FAILED",
                exc=exc,
            )
            return

        state.checkpoint("active_rows_filtered", target_data)

    filtered_data = state.get_step_data("active_rows_filtered")
    targets = filtered_data.get("targets") if isinstance(filtered_data.get("targets"), list) else []

    if not state.is_step_done("active_enqueued"):
        state.begin_step("active_enqueued")
        downstream_task_uuids: list[str] = []
        try:
            for target in targets:
                if not isinstance(target, dict):
                    continue
                booking_id = int(target["booking_id"])
                platform_id = int(target["platform_id"])
                ppl_id = int(target["ppl_id"])
                thread_ids = [int(value) for value in target.get("thread_ids") or []]
                if not thread_ids:
                    continue
                booking_context = target.get("booking_context") if isinstance(target.get("booking_context"), dict) else {
                    "booking_id": booking_id,
                    "booking_entry_id": booking_id,
                    "platform_id": platform_id,
                    "ppl_id": ppl_id,
                    "canonical_pair": {
                        "platform_property_lookup_id": ppl_id,
                    },
                    "classes": [],
                }

                classification_payload = {
                    "action": MESSAGES_CHECK_CLASSIFICATION_ACTION,
                    "platform_id": platform_id,
                    "thread_ids": thread_ids,
                    "return_ref": {
                        "worker": WORKER,
                        "queue": PRIMARY_QUEUE,
                        "action": BSO_START_CHAIN_ACTION,
                    },
                    "booking_context": booking_context,
                }
                task_uuid = enqueue_with_meta(
                    context.queue(MESSAGES_QUEUE),
                    MESSAGES_WORKER,
                    classification_payload,
                    current_task=task,
                    current_worker=WORKER,
                    current_action=SCAN_ACTIVES_ACTION,
                    next_worker=WORKER,
                    next_action=BSO_START_CHAIN_ACTION,
                )
                if task_uuid:
                    downstream_task_uuids.append(str(task_uuid))
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_scan_actives",
                step_name="active_enqueued",
                message=f"BSO_ACTIVE_ENQUEUE_FAILED: {exc}",
                retry=True,
                error_code="BSO_ACTIVE_ENQUEUE_FAILED",
                exc=exc,
            )
            return

        state.checkpoint("active_enqueued", {"downstream_task_uuids": downstream_task_uuids})

    if not state.is_step_done("continuation_enqueued"):
        if raw_count == limit and scan_data.get("last_raw_booking_id") is not None:
            state.begin_step("continuation_enqueued")
            continuation_payload: Dict[str, Any] = {
                "action": SCAN_ACTIVES_ACTION,
                "window_start": window_start_text,
                "window_end": window_end_text,
                "limit": limit,
                "cursor_id": int(scan_data["last_raw_booking_id"]),
            }
            if platform_id_filter is not None:
                continuation_payload["platform_id"] = int(platform_id_filter)
            try:
                continuation_task_uuid = enqueue_with_meta(
                    queue,
                    WORKER,
                    continuation_payload,
                    current_task=task,
                    current_worker=WORKER,
                    current_action=SCAN_ACTIVES_ACTION,
                    next_worker=WORKER,
                    next_action=SCAN_ACTIVES_ACTION,
                )
            except Exception as exc:
                _log_and_fail(
                    queue=queue,
                    log=log,
                    state=state,
                    task=task,
                    action_name="handle_scan_actives",
                    step_name="continuation_enqueued",
                    message=f"ACTIVE_SCAN_CONTINUATION_ENQUEUE_FAILED: {exc}",
                    retry=True,
                    error_code="ACTIVE_SCAN_FAILED",
                    exc=exc,
                )
                return
            state.checkpoint("continuation_enqueued", {"continuation_task_uuid": continuation_task_uuid})

    downstream_task_uuids = [
        str(value)
        for value in state.get_step_data("active_enqueued").get("downstream_task_uuids") or []
        if value
    ]
    continuation_task_uuid = None
    if state.is_step_done("continuation_enqueued"):
        continuation_task_uuid = state.get_step_data("continuation_enqueued").get("continuation_task_uuid")

    status = "no_work" if raw_count == 0 else "scanned"
    result = {
        "status": status,
        "window_start": window_start_text,
        "window_end": window_end_text,
        "platform_id": platform_id_filter,
        "limit": limit,
        "cursor_id": cursor_id,
        "raw_count": raw_count,
        "matched_count": int(filtered_data.get("matched_count") or 0),
        "cancelled_count": int(filtered_data.get("cancelled_count") or 0),
        "platform_filtered_count": int(filtered_data.get("platform_filtered_count") or 0),
        "active_task_count": len(downstream_task_uuids),
        "continuation_task_uuid": continuation_task_uuid,
    }
    step.log("bookings active scan completed", result)
    log.info("task completed", metadata=result, **task_log_kwargs(task, "handle_scan_actives"))
    queue.complete_task(task, result)


def handle_update_message_threads(context: ManagedWorkerContext, task) -> None:
    queue = context.main_queue
    step = default_step(context)
    log = default_app_logger(context)
    state = ActionStateManager.load(context, task)
    payload = task.payload

    try:
        platform_id_filter, window_start, window_end, limit, cursor_id = _parse_active_scan_inputs(payload)
    except ValueError as exc:
        _log_and_fail(
            queue=queue,
            log=log,
            state=state,
            task=task,
            action_name="handle_update_message_threads",
            step_name="scanner_rows_loaded",
            message=f"UPDATE_MESSAGE_THREADS_INPUT_INVALID: {exc}",
            retry=False,
            error_code="UPDATE_MESSAGE_THREADS_INPUT_INVALID",
            exc=exc,
        )
        return

    if not state.is_step_done("scanner_rows_loaded"):
        state.begin_step("scanner_rows_loaded")
        try:
            with context.connect_db() as conn:
                rows = _scan_active_rows(
                    conn,
                    window_start=window_start,
                    window_end=window_end,
                    limit=limit,
                    cursor_id=cursor_id,
                )
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_update_message_threads",
                step_name="scanner_rows_loaded",
                message=f"UPDATE_MESSAGE_THREADS_SCAN_FAILED: {exc}",
                retry=True,
                error_code="UPDATE_MESSAGE_THREADS_SCAN_FAILED",
                exc=exc,
            )
            return

        state.checkpoint(
            "scanner_rows_loaded",
            {
                "rows": rows,
                "raw_count": len(rows),
                "last_raw_booking_id": rows[-1]["booking_id"] if rows else None,
                "window_start": window_start.isoformat(),
                "window_end": window_end.isoformat(),
                "limit": limit,
                "cursor_id": cursor_id,
                "platform_id_filter": platform_id_filter,
            },
        )

    scan_data = state.get_step_data("scanner_rows_loaded")
    rows = scan_data.get("rows") if isinstance(scan_data.get("rows"), list) else []
    raw_count = int(scan_data.get("raw_count") or 0)
    window_start_text = str(scan_data["window_start"])
    window_end_text = str(scan_data["window_end"])
    limit = int(scan_data["limit"])
    cursor_id = int(scan_data["cursor_id"])
    platform_id_filter = coerce_optional_int(scan_data.get("platform_id_filter"), field_name="platform_id")

    if not state.is_step_done("active_rows_filtered"):
        state.begin_step("active_rows_filtered")
        try:
            target_data = _build_active_targets(
                context,
                rows=rows,
                platform_id_filter=platform_id_filter,
            )
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_update_message_threads",
                step_name="active_rows_filtered",
                message=f"UPDATE_MESSAGE_THREADS_CONTEXT_READ_FAILED: {exc}",
                retry=True,
                error_code="UPDATE_MESSAGE_THREADS_SCAN_FAILED",
                exc=exc,
            )
            return

        state.checkpoint("active_rows_filtered", target_data)

    filtered_data = state.get_step_data("active_rows_filtered")
    targets = filtered_data.get("targets") if isinstance(filtered_data.get("targets"), list) else []

    if not state.is_step_done("message_fetch_enqueued"):
        state.begin_step("message_fetch_enqueued")
        downstream_task_uuids: list[str] = []
        try:
            for target in targets:
                if not isinstance(target, dict):
                    continue
                booking_id = int(target["booking_id"])
                platform_id = int(target["platform_id"])
                thread_ids = [int(value) for value in target.get("thread_ids") or []]
                if not thread_ids:
                    continue

                for thread_id in thread_ids:
                    fetch_payload = {
                        "action": MESSAGES_FETCH_ACTION,
                        "booking_id": booking_id,
                        "platform_id": platform_id,
                        "thread_id": int(thread_id),
                    }
                    task_uuid = enqueue_with_meta(
                        context.queue(MESSAGES_QUEUE),
                        MESSAGES_WORKER,
                        fetch_payload,
                        current_task=task,
                        current_worker=WORKER,
                        current_action=UPDATE_MESSAGE_THREADS_ACTION,
                        next_worker=MESSAGES_WORKER,
                        next_action=MESSAGES_FETCH_ACTION,
                    )
                    if task_uuid:
                        downstream_task_uuids.append(str(task_uuid))
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_update_message_threads",
                step_name="message_fetch_enqueued",
                message=f"UPDATE_MESSAGE_THREADS_ENQUEUE_FAILED: {exc}",
                retry=True,
                error_code="UPDATE_MESSAGE_THREADS_ENQUEUE_FAILED",
                exc=exc,
            )
            return

        state.checkpoint("message_fetch_enqueued", {"downstream_task_uuids": downstream_task_uuids})

    if not state.is_step_done("continuation_enqueued"):
        if raw_count == limit and scan_data.get("last_raw_booking_id") is not None:
            state.begin_step("continuation_enqueued")
            continuation_payload: Dict[str, Any] = {
                "action": UPDATE_MESSAGE_THREADS_ACTION,
                "window_start": window_start_text,
                "window_end": window_end_text,
                "limit": limit,
                "cursor_id": int(scan_data["last_raw_booking_id"]),
            }
            if platform_id_filter is not None:
                continuation_payload["platform_id"] = int(platform_id_filter)
            try:
                continuation_task_uuid = enqueue_with_meta(
                    queue,
                    WORKER,
                    continuation_payload,
                    current_task=task,
                    current_worker=WORKER,
                    current_action=UPDATE_MESSAGE_THREADS_ACTION,
                    next_worker=WORKER,
                    next_action=UPDATE_MESSAGE_THREADS_ACTION,
                )
            except Exception as exc:
                _log_and_fail(
                    queue=queue,
                    log=log,
                    state=state,
                    task=task,
                    action_name="handle_update_message_threads",
                    step_name="continuation_enqueued",
                    message=f"UPDATE_MESSAGE_THREADS_CONTINUATION_ENQUEUE_FAILED: {exc}",
                    retry=True,
                    error_code="UPDATE_MESSAGE_THREADS_SCAN_FAILED",
                    exc=exc,
                )
                return
            state.checkpoint("continuation_enqueued", {"continuation_task_uuid": continuation_task_uuid})

    downstream_task_uuids = [
        str(value)
        for value in state.get_step_data("message_fetch_enqueued").get("downstream_task_uuids") or []
        if value
    ]
    continuation_task_uuid = None
    if state.is_step_done("continuation_enqueued"):
        continuation_task_uuid = state.get_step_data("continuation_enqueued").get("continuation_task_uuid")

    status = "no_work" if raw_count == 0 else "scanned"
    result = {
        "status": status,
        "window_start": window_start_text,
        "window_end": window_end_text,
        "platform_id": platform_id_filter,
        "limit": limit,
        "cursor_id": cursor_id,
        "raw_count": raw_count,
        "matched_count": int(filtered_data.get("matched_count") or 0),
        "cancelled_count": int(filtered_data.get("cancelled_count") or 0),
        "platform_filtered_count": int(filtered_data.get("platform_filtered_count") or 0),
        "fetch_task_count": len(downstream_task_uuids),
        "continuation_task_uuid": continuation_task_uuid,
    }
    step.log("bookings message-thread update scan completed", result)
    log.info("task completed", metadata=result, **task_log_kwargs(task, "handle_update_message_threads"))
    queue.complete_task(task, result)


def _handle_bso_start_chain(context: ManagedWorkerContext, task, *, requested_action: str) -> None:
    queue = context.main_queue
    step = default_step(context)
    log = default_app_logger(context)
    state = ActionStateManager.load(context, task)
    payload = task.payload

    data_ref = _normalize_data_ref(payload, default_scope=CHECK_CLASSIFICATION_SCOPE)
    source_worker_id = data_ref["worker_id"] or context.scheduler.worker_id
    source_scope = str(data_ref["scope"] or CHECK_CLASSIFICATION_SCOPE)
    source_key = data_ref["key"]
    if source_key is None:
        _log_and_fail(
            queue=queue,
            log=log,
            state=state,
            task=task,
            action_name="handle_bso_start_chain",
            step_name="classification_loaded",
            message="CHECK_CLASSIFICATION_INVALID: missing data_ref.key",
            retry=False,
            error_code="CHECK_CLASSIFICATION_INVALID",
        )
        return

    if not state.is_step_done("classification_loaded"):
        state.begin_step("classification_loaded")
        try:
            with context.connect_db() as conn:
                result_payload = get_runtime_variable(
                    conn,
                    worker_id=source_worker_id,
                    scope=source_scope,
                    key=source_key,
                )
        except LookupError as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_bso_start_chain",
                step_name="classification_loaded",
                message=f"CHECK_CLASSIFICATION_EXPIRED: {exc}",
                retry=False,
                error_code="CHECK_CLASSIFICATION_EXPIRED",
                exc=exc,
            )
            return
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_bso_start_chain",
                step_name="classification_loaded",
                message=f"CHECK_CLASSIFICATION_READ_FAILED: {exc}",
                retry=True,
                error_code="CHECK_CLASSIFICATION_READ_FAILED",
                exc=exc,
            )
            return

        if not isinstance(result_payload, dict):
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_bso_start_chain",
                step_name="classification_loaded",
                message="CHECK_CLASSIFICATION_INVALID: runtime payload must be an object",
                retry=False,
                error_code="CHECK_CLASSIFICATION_INVALID",
            )
            return

        raw_classes = result_payload.get("classes")
        classes: list[str] = []
        if isinstance(raw_classes, list):
            for item in raw_classes:
                value = as_optional_string(item)
                if value:
                    classes.append(value)
        classes = sorted(set(classes))

        booking_context = result_payload.get("booking_context") if isinstance(result_payload.get("booking_context"), dict) else {}
        booking_id = coerce_optional_int(booking_context.get("booking_id"), field_name="booking_context.booking_id")
        platform_id = coerce_optional_int(booking_context.get("platform_id"), field_name="booking_context.platform_id")
        ppl_id = coerce_optional_int(booking_context.get("ppl_id"), field_name="booking_context.ppl_id")
        canonical_pair = booking_context.get("canonical_pair") if isinstance(booking_context.get("canonical_pair"), dict) else {}
        canonical_lookup_id = coerce_optional_int(
            canonical_pair.get("platform_property_lookup_id"),
            field_name="booking_context.canonical_pair.platform_property_lookup_id",
        )
        if ppl_id is None:
            ppl_id = canonical_lookup_id
        if canonical_lookup_id is None:
            canonical_lookup_id = ppl_id

        if booking_id is None or canonical_lookup_id is None:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_bso_start_chain",
                step_name="classification_loaded",
                message="CHECK_CLASSIFICATION_INVALID: booking_context.booking_id and canonical_pair.platform_property_lookup_id are required",
                retry=False,
                error_code="CHECK_CLASSIFICATION_INVALID",
            )
            return

        booking_context = _merge_classes_into_booking_context(booking_context, classes)
        raw_thread_class_details = result_payload.get("thread_class_details")
        if isinstance(raw_thread_class_details, list):
            booking_context["thread_class_details"] = raw_thread_class_details
        booking_context["booking_id"] = int(booking_id)
        booking_context["booking_entry_id"] = int(booking_id)
        booking_context["platform_id"] = int(platform_id) if platform_id is not None else booking_context.get("platform_id")
        booking_context["ppl_id"] = int(ppl_id) if ppl_id is not None else int(canonical_lookup_id)
        booking_context["canonical_pair"] = {
            **(booking_context.get("canonical_pair") if isinstance(booking_context.get("canonical_pair"), dict) else {}),
            "platform_property_lookup_id": int(canonical_lookup_id),
        }

        try:
            with context.connect_db() as conn:
                _persist_booking_classes(conn, booking_id=int(booking_id), classes=classes)
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_bso_start_chain",
                step_name="classification_loaded",
                message=f"CHECK_CLASSIFICATION_CLASSES_PERSIST_FAILED: {exc}",
                retry=True,
                error_code="CHECK_CLASSIFICATION_CLASSES_PERSIST_FAILED",
                exc=exc,
            )
            return

        state.checkpoint(
            "classification_loaded",
            {
                "source_worker_id": source_worker_id,
                "source_scope": source_scope,
                "source_key": source_key,
                "classes": classes,
                "booking_id": int(booking_id),
                "platform_id": int(platform_id) if platform_id is not None else None,
                "ppl_id": int(ppl_id) if ppl_id is not None else int(canonical_lookup_id),
                "canonical_lookup_id": int(canonical_lookup_id),
                "booking_context": booking_context,
            },
        )

    classification_data = state.get_step_data("classification_loaded")
    classes = [str(value) for value in classification_data.get("classes") or []]
    if not classes:
        cleanup_error = None
        try:
            with context.connect_db() as conn:
                delete_runtime_variable(
                    conn,
                    worker_id=str(classification_data["source_worker_id"]),
                    scope=str(classification_data["source_scope"]),
                    key=str(classification_data["source_key"]),
                )
        except Exception as exc:
            cleanup_error = str(exc)

        result = {
            "status": "no_work",
            "booking_id": int(classification_data["booking_id"]),
            "platform_id": classification_data.get("platform_id"),
            "categories": [],
            "cleanup_error": cleanup_error,
        }
        step.log("bookings bso chain skipped due to empty classes", result)
        log.info("task completed", metadata=result, **task_log_kwargs(task, "handle_bso_start_chain"))
        queue.complete_task(task, result)
        return

    if not state.is_step_done("downstream_enqueued"):
        state.begin_step("downstream_enqueued")
        downstream_payload = {
            "action": PROPERTY_PLATFORM_ACTION,
            "booking_id": int(classification_data["booking_id"]),
            "categories": classes,
            "booking_context": dict(classification_data.get("booking_context") or {}),
            "canonical_pair": {
                "platform_property_lookup_id": int(classification_data["canonical_lookup_id"]),
            },
        }
        try:
            downstream_task_uuid = enqueue_with_meta(
                context.queue(PROPERTY_PLATFORM_QUEUE),
                PROPERTY_PLATFORM_WORKER,
                downstream_payload,
                current_task=task,
                current_worker=WORKER,
                current_action=requested_action,
                next_worker=PROPERTY_PLATFORM_WORKER,
                next_action=PROPERTY_PLATFORM_ACTION,
            )
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_bso_start_chain",
                step_name="downstream_enqueued",
                message=f"BSO_ACTIVE_ENQUEUE_FAILED: {exc}",
                retry=True,
                error_code="BSO_ACTIVE_ENQUEUE_FAILED",
                exc=exc,
            )
            return

        state.checkpoint("downstream_enqueued", {"downstream_task_uuid": downstream_task_uuid})

    cleanup_error = None
    if not state.is_step_done("source_cleaned"):
        state.begin_step("source_cleaned")
        try:
            with context.connect_db() as conn:
                delete_runtime_variable(
                    conn,
                    worker_id=str(classification_data["source_worker_id"]),
                    scope=str(classification_data["source_scope"]),
                    key=str(classification_data["source_key"]),
                )
        except Exception as exc:
            cleanup_error = str(exc)
        state.checkpoint("source_cleaned", {"cleanup_error": cleanup_error})
    else:
        cleanup_error = as_optional_string(state.get_step_data("source_cleaned").get("cleanup_error"))

    result = {
        "status": "forwarded_to_property_platform",
        "booking_id": int(classification_data["booking_id"]),
        "platform_id": classification_data.get("platform_id"),
        "categories": classes,
        "downstream_task_uuid": state.get_step_data("downstream_enqueued").get("downstream_task_uuid"),
        "cleanup_error": cleanup_error,
    }
    step.log("bookings bso chain started", result)
    log.info("task completed", metadata=result, **task_log_kwargs(task, "handle_bso_start_chain"))
    queue.complete_task(task, result)


def handle_bso_start_chain(context: ManagedWorkerContext, task) -> None:
    _handle_bso_start_chain(context, task, requested_action=BSO_START_CHAIN_ACTION)


def handle_start_bso_chain(context: ManagedWorkerContext, task) -> None:
    _handle_bso_start_chain(context, task, requested_action="start_bso_chain")


def handle_task(context: ManagedWorkerContext, task) -> None:
    normalize_payload_meta(task.payload)
    action = as_optional_string(task.payload.get("action"))
    if action == GET_BOOKINGS_ACTION:
        handle_get_bookings(context, task)
        return
    if action == GET_BOOKINGS_RET_ACTION:
        handle_get_bookings_ret(context, task)
        return
    if action == "ret_get_bookings":
        handle_ret_get_bookings(context, task)
        return
    if action == "get_boogings_ret":
        handle_get_boogings_ret(context, task)
        return
    if action == REGISTER_BOOKINGS_ACTION:
        handle_register_bookings(context, task)
        return
    if action == SCAN_ACTIVES_ACTION:
        handle_scan_actives(context, task)
        return
    if action == UPDATE_MESSAGE_THREADS_ACTION:
        handle_update_message_threads(context, task)
        return
    if action == PROCESS_CHECKOUT_ACTION:
        handle_process_checkout(context, task)
        return
    if action == SCAN_CHECKED_OUT_ACTION:
        handle_scan_checked_out(context, task)
        return
    if action == BSO_START_CHAIN_ACTION:
        handle_bso_start_chain(context, task)
        return
    if action == "start_bso_chain":
        handle_start_bso_chain(context, task)
        return
    context.main_queue.fail_task(task, f"Unexpected action {action}", retry=False)


def run_task(context: ManagedWorkerContext, task) -> None:
    handle_task(context, task)


def main() -> None:
    global RUNTIME_VARIABLE_TTL_CONFIG
    args = parse_args()
    RUNTIME_VARIABLE_TTL_CONFIG = parse_runtime_variable_ttl_config(args.runtime_variable_ttl_config)
    logger, log_path = configure_worker_logger(WORKER, args.log_dir)
    step = NoOpStepLog()
    scheduler: Optional[ManagedSchedulerClient] = None
    app_logger: Any = NullAppLogger()

    try:
        dsn = build_dsn(args.dsn, args.auto_dsn, args.db_name)
        if not dsn:
            raise SystemExit("DSN is required (use --dsn or --auto-dsn with POSTGRES_PASSWORD set).")

        scheduler = ManagedSchedulerClient(
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
        context = ManagedWorkerContext(
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

        runner = ManagedWorkerRunner(context, run_task)
        app_logger.info(
            "bookings worker started",
            metadata={
                "worker_id": scheduler.worker_id,
                "primary_queue": PRIMARY_QUEUE,
                "subscribed_queues": list(SUBSCRIBED_QUEUES),
                "supported_actions": list(SUPPORTED_ACTIONS),
                "runtime_variable_ttl_config": RUNTIME_VARIABLE_TTL_CONFIG,
                "max_concurrent_tasks": args.max_concurrent_tasks,
                "heartbeat_interval": args.heartbeat_interval,
                "lease_duration": args.lease_duration,
                "log_file": str(log_path),
            },
            action_name="worker_startup",
        )
        runner.run()
    except SystemExit:
        raise
    except Exception as exc:
        if isinstance(app_logger, NullAppLogger):
            logger.exception("bookings worker failed")
        else:
            app_logger.error("bookings worker failed", exc=exc, action_name="worker_runtime")
        raise SystemExit(1)
    finally:
        if scheduler is not None:
            if not isinstance(app_logger, NullAppLogger):
                app_logger.info("bookings worker shutting down", action_name="worker_shutdown")
            try:
                scheduler.state_manager.shutdown()
            except Exception as exc:
                if isinstance(app_logger, NullAppLogger):
                    logger.exception("bookings worker clean shutdown checkpoint failed")
                else:
                    app_logger.error(
                        "bookings worker clean shutdown checkpoint failed",
                        exc=exc,
                        action_name="worker_shutdown",
                    )
            try:
                app_logger.close()
            except Exception:
                logger.exception("bookings worker app logger close failed")
            scheduler.close()


if __name__ == "__main__":
    main()
