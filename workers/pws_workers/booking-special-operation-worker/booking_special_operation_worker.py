#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from datetime import date, timedelta
from pathlib import Path
from typing import Any, Dict, Optional, Sequence
from uuid import NAMESPACE_URL, uuid4, uuid5

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
    enqueue_with_meta,
    get_booking_id,
    task_log_kwargs,
)


WORKER = "booking-special-operation-worker"
PRIMARY_QUEUE = "booking-special-operation"
SUBSCRIBED_QUEUES: Sequence[str] = (PRIMARY_QUEUE,)

EXTERNAL_SERVICES_WORKER = "external-services-worker"
EXTERNAL_SERVICES_QUEUE = "external-services"
PROCESS_INSTRUCTION_ACTION = "process_instruction"
PROCESS_INSTRUCTION_CAPTURE_BASE_RATES_MODE = "capture_base_rates"
INSTRUCTION_RESULT_ACTION = "instruction_result"
GENERATE_CLASS_RULE_INSTURCTION_ACTION = "generate_class_rule_insturction"
REMOVE_BSO_ACTION = "remove-bso"
LEGACY_CATEGORY_ACTION_ALIASES = ("potential_extension", "generate_class_rule_insturctioni")
POTENTIAL_EXTENSION_ACTION = GENERATE_CLASS_RULE_INSTURCTION_ACTION
SUPPORTED_ACTIONS = (GENERATE_CLASS_RULE_INSTURCTION_ACTION, REMOVE_BSO_ACTION, INSTRUCTION_RESULT_ACTION)
REMOVE_BSO_REASON_POLICIES: Dict[str, Dict[str, Any]] = {
    # booking-cancelled removals should mark booking metadata for downstream consumers.
    "booking_cancelled": {"set_booking_cancelled_meta": True},
    # additional reasons are valid remove triggers but do not patch cancellation metadata.
    "booking_modified": {"set_booking_cancelled_meta": False},
    "manual_override": {"set_booking_cancelled_meta": False},
    "checkout": {"set_booking_cancelled_meta": False},
}
_BOOKING_APPLIED_RULES_LISTING_COLUMN: Optional[str] = None
SUPPORTED_TARGET_RATE_TYPES = {"base", "recommended", "minimum", "maximum"}


class BookingMetadataPatchError(RuntimeError):
    """Raised when booking metadata patching fails inside the callback transaction."""


class OverlapQueryError(RuntimeError):
    """Raised when overlap rows cannot be queried."""


class OverlapReserveError(RuntimeError):
    """Raised when overlap rows cannot be reserved."""


class InStayDatesNotAllowedError(ValueError):
    """Raised when generated instruction dates fall inside the booking stay window."""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Booking special operation worker")
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


def _normalize_booking_id(payload: Dict[str, Any]) -> Optional[int]:
    booking_id = get_booking_id(payload, required=False)
    if booking_id is not None:
        return booking_id
    booking_obj = payload.get("booking") if isinstance(payload.get("booking"), dict) else {}
    return coerce_optional_int(booking_obj.get("booking_entry_id"), field_name="booking.booking_entry_id")


def _normalize_category(payload: Dict[str, Any]) -> Optional[str]:
    return as_optional_string(payload.get("category")) or as_optional_string(payload.get("action"))


def _normalize_rule(payload: Dict[str, Any]) -> Dict[str, Any]:
    direct_rule = payload.get("rule")
    if isinstance(direct_rule, dict):
        return dict(direct_rule)

    rules = payload.get("rules")
    if isinstance(rules, list) and len(rules) == 1 and isinstance(rules[0], dict):
        return dict(rules[0])

    if isinstance(rules, list):
        raise ValueError("rules must contain exactly one object when used as a compatibility input")
    raise ValueError("rule is required")


def _normalize_linked_listing_entry(
    raw_entry: Dict[str, Any],
    *,
    default_category: Optional[str],
    index: int,
) -> Dict[str, Any]:
    raw_platform_pair = raw_entry.get("platform_pair")
    if not isinstance(raw_platform_pair, dict):
        raise ValueError(f"linked_listings_data[{index}].platform_pair is required")
    normalized_platform_pair = _normalize_pair(
        {"platform_pair": raw_platform_pair},
        "platform_pair",
        require_listing_id=True,
    )
    if isinstance(raw_platform_pair.get("is_canonical"), bool):
        normalized_platform_pair["is_canonical"] = bool(raw_platform_pair.get("is_canonical"))
    pair_platform_type = _normalize_platform_type(raw_platform_pair.get("platform_type"))
    if pair_platform_type:
        normalized_platform_pair["platform_type"] = pair_platform_type

    raw_rule = raw_entry.get("rule")
    if not isinstance(raw_rule, dict):
        raise ValueError(f"linked_listings_data[{index}].rule is required")

    category = (
        as_optional_string(raw_entry.get("category"))
        or as_optional_string(raw_entry.get("matched_category"))
        or default_category
    )

    normalized_entry: Dict[str, Any] = {
        "platform_pair": normalized_platform_pair,
        "rule": dict(raw_rule),
    }
    if category:
        normalized_entry["category"] = category

    rule_source = as_optional_string(raw_entry.get("rule_source"))
    if rule_source:
        normalized_entry["rule_source"] = rule_source
    normalized_entry.update(_normalize_chain_metadata(raw_entry, index=index))
    return normalized_entry


def _normalize_linked_listings_data(
    payload: Dict[str, Any],
    *,
    default_category: Optional[str],
) -> list[Dict[str, Any]]:
    raw_linked_listings = payload.get("linked_listings_data")
    if isinstance(raw_linked_listings, list):
        if not raw_linked_listings:
            raise ValueError("linked_listings_data must not be empty when provided")
        normalized_entries: list[Dict[str, Any]] = []
        for index, raw_entry in enumerate(raw_linked_listings):
            if not isinstance(raw_entry, dict):
                raise ValueError(f"linked_listings_data[{index}] must be an object")
            normalized_entries.append(
                _normalize_linked_listing_entry(raw_entry, default_category=default_category, index=index)
            )
        return _validate_and_order_chain_entries(normalized_entries)

    platform_pair = _normalize_pair(payload, "platform_pair", require_listing_id=True)
    rule = _normalize_rule(payload)
    normalized_entry: Dict[str, Any] = {
        "platform_pair": platform_pair,
        "rule": rule,
    }
    if default_category:
        normalized_entry["category"] = default_category
    return [normalized_entry]


def _canonicalize_instruction_operation(value: Any) -> Optional[str]:
    operation = as_optional_string(value)
    if operation == "override":
        return "set"
    return operation


def _canonicalize_instruction_type(value: Any, *, operation: Optional[str]) -> Optional[str]:
    instruction_type = as_optional_string(value)
    if instruction_type == "override":
        instruction_type = "fixed"
    if instruction_type is None and operation == "set":
        return "fixed"
    return instruction_type


def _normalize_target_rate_type(value: Any, *, default: str = "base") -> str:
    normalized = (as_optional_string(value) or "").strip().lower()
    if normalized in SUPPORTED_TARGET_RATE_TYPES:
        return normalized
    return default


def _normalize_pair(
    payload: Dict[str, Any],
    field_name: str,
    *,
    require_listing_id: bool,
) -> Dict[str, Any]:
    raw_pair = payload.get(field_name)
    if not isinstance(raw_pair, dict):
        raise ValueError(f"{field_name} is required")

    platform_id = coerce_optional_int(raw_pair.get("platform_id"), field_name=f"{field_name}.platform_id")
    if platform_id is None:
        raise ValueError(f"{field_name}.platform_id is required")

    pair: Dict[str, Any] = {"platform_id": platform_id}
    listing_id = as_optional_string(raw_pair.get("listing_id")) or as_optional_string(raw_pair.get("platform_property_id"))
    if require_listing_id and not listing_id:
        raise ValueError(f"{field_name}.listing_id is required")
    if listing_id:
        pair["listing_id"] = listing_id
    return pair


def _normalize_platform_type(value: Any) -> Optional[str]:
    platform_type = as_optional_string(value)
    if not platform_type:
        return None
    normalized = platform_type.strip().lower()
    if normalized == "otp":
        normalized = "ota"
    return normalized


def _normalize_chain_metadata(raw_entry: Dict[str, Any], *, index: int) -> Dict[str, Any]:
    chain_id = as_optional_string(raw_entry.get("chain_id"))
    if not chain_id:
        raise ValueError(f"linked_listings_data[{index}].chain_id is required")

    chain_position = coerce_optional_int(
        raw_entry.get("chain_position"),
        field_name=f"linked_listings_data[{index}].chain_position",
    )
    if chain_position is None or int(chain_position) < 1:
        raise ValueError(f"linked_listings_data[{index}].chain_position must be >= 1")

    platform_type = _normalize_platform_type(raw_entry.get("platform_type"))
    if platform_type not in {"dpt", "pms", "ota"}:
        raise ValueError(
            f"linked_listings_data[{index}].platform_type must be one of dpt|pms|ota"
        )

    depends_on_position_raw = raw_entry.get("depends_on_position")
    depends_on_position = (
        None
        if depends_on_position_raw is None
        else coerce_optional_int(
            depends_on_position_raw,
            field_name=f"linked_listings_data[{index}].depends_on_position",
        )
    )
    if depends_on_position is not None and int(depends_on_position) < 1:
        raise ValueError(f"linked_listings_data[{index}].depends_on_position must be >= 1 when provided")

    return {
        "chain_id": chain_id,
        "chain_position": int(chain_position),
        "platform_type": platform_type,
        "depends_on_position": None if depends_on_position is None else int(depends_on_position),
    }


def _validate_and_order_chain_entries(linked_listings_data: list[Dict[str, Any]]) -> list[Dict[str, Any]]:
    ordered = sorted(
        [dict(item) for item in linked_listings_data],
        key=lambda item: int(item.get("chain_position") or 0),
    )
    if not ordered:
        raise ValueError("linked_listings_data must not be empty")

    chain_ids = {str(item["chain_id"]) for item in ordered}
    if len(chain_ids) != 1:
        raise ValueError("linked_listings_data must use a single shared chain_id")

    positions = [int(item["chain_position"]) for item in ordered]
    expected_positions = list(range(1, len(ordered) + 1))
    if positions != expected_positions:
        raise ValueError("linked_listings_data.chain_position must be contiguous starting at 1")

    platform_types = [str(item["platform_type"]) for item in ordered]
    if platform_types.count("pms") != 1:
        raise ValueError("linked_listings_data must contain exactly one pms step")

    pms_index = platform_types.index("pms")
    prefix_types = platform_types[:pms_index]
    suffix_types = platform_types[pms_index + 1 :]
    if prefix_types not in ([], ["dpt"]):
        raise ValueError("chain order must be dpt? -> pms -> ota*")
    if any(platform_type != "ota" for platform_type in suffix_types):
        raise ValueError("chain order must be dpt? -> pms -> ota*")

    for index, item in enumerate(ordered):
        expected_depends = None if index == 0 else int(ordered[index - 1]["chain_position"])
        depends = item.get("depends_on_position")
        if depends is not None and int(depends) != expected_depends:
            raise ValueError(
                f"linked_listings_data[{index}].depends_on_position must reference prior chain position "
                f"{expected_depends}"
            )
        if depends is None and expected_depends is not None:
            item["depends_on_position"] = expected_depends
    return ordered


def _fetch_booking(conn, booking_id: int) -> Optional[Dict[str, Any]]:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT id, property_id, platform_id, arrival, departure
            FROM booking_registers
            WHERE id = %s
            LIMIT 1
            """,
            (booking_id,),
        )
        row = cur.fetchone()
    if row is None:
        return None
    return {
        "booking_id": int(row[0]),
        "booking_entry_id": int(row[0]),
        "property_id": int(row[1]),
        "platform_id": int(row[2]),
        "arrival": row[3],
        "departure": row[4],
    }


def _resolve_booking_applied_rules_listing_column(conn) -> str:
    global _BOOKING_APPLIED_RULES_LISTING_COLUMN
    if _BOOKING_APPLIED_RULES_LISTING_COLUMN is not None:
        return _BOOKING_APPLIED_RULES_LISTING_COLUMN

    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT column_name
            FROM information_schema.columns
            WHERE table_schema = 'public'
              AND table_name = 'booking_applied_rules'
              AND column_name IN ('listing_id', 'platform_property_id')
            ORDER BY CASE column_name WHEN 'listing_id' THEN 0 ELSE 1 END
            LIMIT 1
            """
        )
        row = cur.fetchone()

    column_name = as_optional_string(row[0] if row else None)
    if column_name is None:
        raise ValueError("booking_applied_rules listing identifier column is missing")

    _BOOKING_APPLIED_RULES_LISTING_COLUMN = column_name
    return column_name


def _normalized_dates(raw_dates: Any) -> list[str]:
    if not isinstance(raw_dates, list) or not raw_dates:
        raise ValueError("instruction.dates must be a non-empty array")
    dates: list[str] = []
    seen: set[str] = set()
    for index, raw_value in enumerate(raw_dates):
        value = as_optional_string(raw_value)
        if not value:
            raise ValueError(f"instruction.dates[{index}] must be a YYYY-MM-DD string")
        if value in seen:
            continue
        seen.add(value)
        dates.append(value)
    if not dates:
        raise ValueError("instruction.dates must contain at least one date")
    return dates


def _build_apply_instruction(
    rule: Dict[str, Any],
    booking: Dict[str, Any],
    canonical_pair: Dict[str, Any],
    platform_pair: Dict[str, Any],
    category: str,
    *,
    chain: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    rule_uuid = as_optional_string(rule.get("rule_uuid"))
    if not rule_uuid:
        raise ValueError("rule.rule_uuid is required")

    rule_config = rule.get("rule_config")
    if not isinstance(rule_config, dict):
        raise ValueError("rule.rule_config must be an object")

    apply_window = rule_config.get("apply_window") if isinstance(rule_config.get("apply_window"), dict) else {}
    applies_from = as_optional_string(apply_window.get("applies_from")) or "departure"
    if applies_from not in {"arrival", "departure"}:
        raise ValueError("rule.rule_config.apply_window.applies_from must be 'arrival' or 'departure'")

    default_direction = "before" if applies_from == "arrival" else "after"
    direction = as_optional_string(apply_window.get("direction")) or default_direction
    if direction not in {"before", "after"}:
        raise ValueError("rule.rule_config.apply_window.direction must be 'before' or 'after'")

    duration_days = coerce_optional_int(
        apply_window.get("duration_days"),
        field_name="rule.rule_config.apply_window.duration_days",
    )
    if duration_days is None:
        duration_days = 1
    if duration_days < 1:
        raise ValueError("rule.rule_config.apply_window.duration_days must be >= 1")

    offset_days = coerce_optional_int(
        apply_window.get("offset_days"),
        field_name="rule.rule_config.apply_window.offset_days",
    )
    if offset_days is None:
        offset_days = 0

    if applies_from == "departure":
        anchor_date = booking["departure"]
    else:
        anchor_date = booking["arrival"]

    allow_in_stay_dates_raw = apply_window.get("allow_in_stay_dates")
    if allow_in_stay_dates_raw is None:
        allow_in_stay_dates = False
    elif isinstance(allow_in_stay_dates_raw, bool):
        allow_in_stay_dates = allow_in_stay_dates_raw
    else:
        raise ValueError("rule.rule_config.apply_window.allow_in_stay_dates must be a boolean when provided")

    operation = rule_config.get("operation") if isinstance(rule_config.get("operation"), dict) else {}
    instruction_operation = _canonicalize_instruction_operation(rule.get("operation_code")) or "increase"
    instruction_type = _canonicalize_instruction_type(operation.get("type"), operation=instruction_operation) or "percentage"
    target_rate_type = _normalize_target_rate_type(
        operation.get("target_rate_type"),
        default="base",
    )
    if direction == "after":
        start_date = anchor_date + timedelta(days=offset_days)
        dates = [(start_date + timedelta(days=offset)).isoformat() for offset in range(duration_days)]
    else:
        end_date = anchor_date - timedelta(days=offset_days + 1)
        start_date = end_date - timedelta(days=duration_days - 1)
        dates = [(start_date + timedelta(days=offset)).isoformat() for offset in range(duration_days)]

    if not dates:
        raise ValueError("rule.rule_config.apply_window must produce at least one date")

    booking_arrival = booking["arrival"]
    booking_departure = booking["departure"]
    in_stay_dates = [
        date_value
        for date_value in dates
        if booking_arrival <= date.fromisoformat(date_value) < booking_departure
    ]
    if in_stay_dates and not allow_in_stay_dates:
        raise InStayDatesNotAllowedError(
            "generated instruction dates include in-stay booking nights: " + ", ".join(in_stay_dates)
        )

    instruction = {
        "instruction_uuid": str(uuid4()),
        "booking_entry_id": int(booking["booking_entry_id"]),
        "property_id": int(booking["property_id"]),
        "source_platform_id": int(canonical_pair["platform_id"]),
        "platform_id": int(platform_pair["platform_id"]),
        "listing_id": str(platform_pair["listing_id"]),
        "rule_uuid": rule_uuid,
        "trigger_category": category,
        "operation": instruction_operation,
        "subject": as_optional_string(rule_config.get("subject")) or "price",
        "type": instruction_type,
        "target_rate_type": target_rate_type,
        "amount": operation.get("amount", 0),
        "dates": dates,
        "remove": False,
    }
    if isinstance(chain, dict):
        instruction["chain"] = {
            "chain_id": str(chain["chain_id"]),
            "chain_position": int(chain["chain_position"]),
            "platform_type": str(chain["platform_type"]),
            "depends_on_position": chain.get("depends_on_position"),
        }
    return instruction


def _build_removal_instruction(
    existing_instruction: Dict[str, Any],
    source_instruction_id: int,
    *,
    dates: list[str],
    reason_code: Optional[str] = None,
    reason_note: Optional[str] = None,
) -> Dict[str, Any]:
    removal_instruction = dict(existing_instruction)
    removal_instruction["instruction_uuid"] = str(uuid4())
    removal_instruction["remove"] = True
    removal_instruction["target_rate_type"] = "base"
    removal_instruction["source_instruction_id"] = int(source_instruction_id)
    removal_instruction["dates"] = _normalized_dates(dates)
    if reason_code:
        removal_instruction["reason_code"] = str(reason_code)
    if reason_note:
        removal_instruction["reason_note"] = str(reason_note)
    return removal_instruction


def _get_remove_bso_reason_policy(reason_code: str) -> Optional[Dict[str, Any]]:
    return REMOVE_BSO_REASON_POLICIES.get(reason_code)


def _find_overlaps(
    conn,
    *,
    booking_id: int,
    property_id: int,
    platform_id: int,
    listing_id: str,
    dates: list[str],
) -> list[Dict[str, Any]]:
    requested_dates = set(_normalized_dates(dates))
    listing_column = _resolve_booking_applied_rules_listing_column(conn)
    with conn.cursor() as cur:
        cur.execute(
            f"""
            SELECT id, trigger_category, instruction
            FROM booking_applied_rules
            WHERE booking_entry_id = %s
              AND property_id = %s
              AND platform_id = %s
              AND {listing_column} = %s
              AND status IN ('applied', 'processing')
              AND COALESCE((instruction->>'remove')::boolean, FALSE) = FALSE
            ORDER BY id ASC
            """,
            (booking_id, property_id, platform_id, listing_id),
        )
        rows = cur.fetchall() or []

    overlaps: list[Dict[str, Any]] = []
    for row in rows:
        instruction = row[2]
        if isinstance(instruction, str):
            instruction = json.loads(instruction)
        if not isinstance(instruction, dict):
            continue
        source_dates = _normalized_dates(instruction.get("dates"))
        intersection_dates = [date_value for date_value in source_dates if date_value in requested_dates]
        if intersection_dates:
            overlaps.append(
                {
                    "id": int(row[0]),
                    "trigger_category": as_optional_string(row[1]) or as_optional_string(instruction.get("trigger_category")),
                    "instruction": instruction,
                    "intersection_dates": intersection_dates,
                }
            )
    return overlaps


def _reserve_overlap_rows(conn, overlap_ids: list[int]) -> None:
    if not overlap_ids:
        return
    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE booking_applied_rules
            SET status = 'processing'
            WHERE id = ANY(%s)
              AND status IN ('applied', 'processing')
            """,
            (overlap_ids,),
        )


def _fetch_instruction_row(conn, instruction_id: int) -> Optional[Dict[str, Any]]:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT id, booking_entry_id, platform_id, trigger_category, status::text, instruction
            FROM booking_applied_rules
            WHERE id = %s
            LIMIT 1
            """,
            (instruction_id,),
        )
        row = cur.fetchone()
    if row is None:
        return None
    instruction = row[5]
    if isinstance(instruction, str):
        instruction = json.loads(instruction)
    if not isinstance(instruction, dict):
        raise ValueError("booking_applied_rules.instruction must be a JSON object")
    return {
        "id": int(row[0]),
        "booking_entry_id": int(row[1]),
        "platform_id": int(row[2]),
        "trigger_category": as_optional_string(row[3]) or "",
        "status": str(row[4]),
        "instruction": instruction,
    }


def _extract_instruction_chain(instruction: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    chain = instruction.get("chain") if isinstance(instruction.get("chain"), dict) else {}
    chain_id = as_optional_string(chain.get("chain_id"))
    chain_position = coerce_optional_int(chain.get("chain_position"), field_name="instruction.chain.chain_position")
    platform_type = _normalize_platform_type(chain.get("platform_type"))
    depends_on_position_raw = chain.get("depends_on_position")
    depends_on_position = (
        None
        if depends_on_position_raw is None
        else coerce_optional_int(depends_on_position_raw, field_name="instruction.chain.depends_on_position")
    )
    if not chain_id or chain_position is None or platform_type not in {"dpt", "pms", "ota"}:
        return None
    return {
        "chain_id": chain_id,
        "chain_position": int(chain_position),
        "platform_type": platform_type,
        "depends_on_position": None if depends_on_position is None else int(depends_on_position),
    }


def _rollback_instruction_uuid(*, chain_id: str, source_instruction_id: int) -> str:
    return str(uuid5(NAMESPACE_URL, f"bso-rollback:{chain_id}:{int(source_instruction_id)}"))


def _fetch_chain_apply_rows(
    conn,
    *,
    booking_entry_id: int,
    chain_id: str,
) -> list[Dict[str, Any]]:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT id, platform_id, status::text, instruction
            FROM booking_applied_rules
            WHERE booking_entry_id = %s
              AND COALESCE((instruction->'chain'->>'chain_id'), '') = %s
              AND COALESCE((instruction->>'remove')::boolean, FALSE) = FALSE
            ORDER BY id ASC
            """,
            (int(booking_entry_id), str(chain_id)),
        )
        rows = cur.fetchall() or []

    chain_rows: list[Dict[str, Any]] = []
    for row in rows:
        instruction = row[3]
        if isinstance(instruction, str):
            instruction = json.loads(instruction)
        if not isinstance(instruction, dict):
            continue
        chain = _extract_instruction_chain(instruction)
        if chain is None:
            continue
        instruction_uuid = as_optional_string(instruction.get("instruction_uuid"))
        if not instruction_uuid:
            continue
        chain_rows.append(
            {
                "instruction_id": int(row[0]),
                "platform_id": int(row[1]),
                "status": str(row[2]),
                "instruction_uuid": instruction_uuid,
                "instruction": instruction,
                "chain": chain,
            }
        )

    return sorted(chain_rows, key=lambda item: int(item["chain"]["chain_position"]))


def _prepare_chain_rollback_blueprints(
    conn,
    *,
    booking_entry_id: int,
    chain_id: str,
    failed_chain_position: int,
) -> list[Dict[str, Any]]:
    rollback_blueprints: list[Dict[str, Any]] = []
    chain_rows = _fetch_chain_apply_rows(
        conn,
        booking_entry_id=int(booking_entry_id),
        chain_id=str(chain_id),
    )
    rollback_sources = [
        row
        for row in chain_rows
        if int(row["chain"]["chain_position"]) < int(failed_chain_position) and str(row["status"]) == "applied"
    ]

    for source in sorted(rollback_sources, key=lambda item: int(item["chain"]["chain_position"]), reverse=True):
        source_instruction = dict(source["instruction"])
        source_instruction_id = int(source["instruction_id"])
        source_dates = _normalized_dates(source_instruction.get("dates"))
        rollback_instruction = _build_removal_instruction(
            source_instruction,
            source_instruction_id,
            dates=source_dates,
        )
        rollback_instruction["instruction_uuid"] = _rollback_instruction_uuid(
            chain_id=str(chain_id),
            source_instruction_id=source_instruction_id,
        )
        source_chain = source.get("chain") if isinstance(source.get("chain"), dict) else {}
        if source_chain:
            rollback_instruction["chain"] = {
                "chain_id": str(source_chain["chain_id"]),
                "chain_position": int(source_chain["chain_position"]),
                "platform_type": str(source_chain["platform_type"]),
                "depends_on_position": source_chain.get("depends_on_position"),
            }
        rollback_blueprints.append(
            {
                "source_instruction_id": source_instruction_id,
                "chain_position": int(source["chain"]["chain_position"]),
                "platform_id": int(source["platform_id"]),
                "platform_type": str(source["chain"]["platform_type"]),
                "instruction": rollback_instruction,
                "category": as_optional_string(source_instruction.get("trigger_category")) or POTENTIAL_EXTENSION_ACTION,
            }
        )
    return rollback_blueprints


def _mark_dependency_failed_chain_rows(
    conn,
    *,
    booking_entry_id: int,
    chain_id: str,
    failed_chain_position: int,
) -> list[Dict[str, Any]]:
    dependency_failed_rows: list[Dict[str, Any]] = []
    chain_rows = _fetch_chain_apply_rows(
        conn,
        booking_entry_id=int(booking_entry_id),
        chain_id=str(chain_id),
    )
    for row in chain_rows:
        chain_position = int(row["chain"]["chain_position"])
        if chain_position <= int(failed_chain_position):
            continue
        if str(row["status"]) != "processing":
            continue
        _set_instruction_status(
            conn,
            instruction_id=int(row["instruction_id"]),
            status="failed",
            removed=False,
        )
        dependency_failed_rows.append(
            {
                "instruction_id": int(row["instruction_id"]),
                "instruction_uuid": str(row["instruction_uuid"]),
                "platform_id": int(row["platform_id"]),
                "platform_type": str(row["chain"]["platform_type"]),
                "chain_position": chain_position,
            }
        )
    return dependency_failed_rows


def _log_chain_failure(
    *,
    log,
    task,
    failure_type: str,
    booking_id: int,
    chain_id: Optional[str],
    platform_id: Optional[int],
    platform_type: Optional[str],
    instruction_id: Optional[int],
    failed_step: str,
    external_task_uuid: Optional[str] = None,
    error: Optional[str] = None,
) -> None:
    metadata = {
        "booking_id": int(booking_id),
        "chain_id": chain_id,
        "platform_id": platform_id,
        "platform_type": platform_type,
        "instruction_id": instruction_id,
        "task_uuid": as_optional_string(external_task_uuid) or as_optional_string(getattr(task, "task_uuid", None)),
        "failed_step": failed_step,
        "failure_type": failure_type,
    }
    if error:
        metadata["error"] = str(error)
    log.error(
        "chain execution failure",
        metadata=metadata,
        **task_log_kwargs(task, "handle_instruction_result"),
    )


def _find_instruction_row_by_uuid(conn, instruction_uuid: str) -> Optional[Dict[str, Any]]:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT id, instruction
            FROM booking_applied_rules
            WHERE instruction->>'instruction_uuid' = %s
            ORDER BY id DESC
            LIMIT 1
            """,
            (instruction_uuid,),
        )
        row = cur.fetchone()
    if row is None:
        return None
    instruction = row[1]
    if isinstance(instruction, str):
        instruction = json.loads(instruction)
    if not isinstance(instruction, dict):
        raise ValueError("booking_applied_rules.instruction must be a JSON object")
    return {"id": int(row[0]), "instruction": instruction}


def _ensure_instruction_row(
    conn,
    *,
    instruction: Dict[str, Any],
    category: str,
    applied_by_task_id: Optional[int],
) -> Dict[str, Any]:
    instruction_uuid = as_optional_string(instruction.get("instruction_uuid"))
    if not instruction_uuid:
        raise ValueError("instruction.instruction_uuid is required")

    listing_id = as_optional_string(instruction.get("listing_id")) or as_optional_string(
        instruction.get("platform_property_id")
    )
    if not listing_id:
        raise ValueError("instruction.listing_id is required")
    instruction["listing_id"] = listing_id

    existing = _find_instruction_row_by_uuid(conn, instruction_uuid)
    if existing is not None:
        return {
            "instruction_id": int(existing["id"]),
            "instruction_uuid": instruction_uuid,
            "source_instruction_id": coerce_optional_int(
                existing["instruction"].get("source_instruction_id"),
                field_name="instruction.source_instruction_id",
            ),
            "instruction": dict(existing["instruction"]),
        }

    listing_column = _resolve_booking_applied_rules_listing_column(conn)
    sql = f"""
        INSERT INTO booking_applied_rules (
            booking_entry_id,
            property_id,
            platform_id,
            {listing_column},
            rule_uuid,
            trigger_category,
            instruction,
            status,
            applied_by_task_id
        ) VALUES (%s, %s, %s, %s, %s::uuid, %s, %s::jsonb, 'processing', %s)
        RETURNING id
    """
    with conn.cursor() as cur:
        cur.execute(
            sql,
            (
                int(instruction["booking_entry_id"]),
                int(instruction["property_id"]),
                int(instruction["platform_id"]),
                str(instruction["listing_id"]),
                str(instruction["rule_uuid"]),
                category,
                json.dumps(instruction, default=str),
                applied_by_task_id,
            ),
        )
        row = cur.fetchone()
    if row is None or row[0] is None:
        raise RuntimeError("booking_applied_rules insert did not return an id")

    return {
        "instruction_id": int(row[0]),
        "instruction_uuid": instruction_uuid,
        "source_instruction_id": coerce_optional_int(
            instruction.get("source_instruction_id"),
            field_name="instruction.source_instruction_id",
        ),
        "instruction": dict(instruction),
    }


def _find_existing_external_task_uuid(conn, *, instruction_id: int, instruction_uuid: str) -> Optional[str]:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT task_uuid
            FROM task_queue
            WHERE task_name = %s
              AND queue_name = %s
              AND task_data->>'action' = %s
              AND task_data->>'instruction_id' = %s
              AND task_data->>'instruction_uuid' = %s
            ORDER BY id DESC
            LIMIT 1
            """,
            (
                EXTERNAL_SERVICES_WORKER,
                EXTERNAL_SERVICES_QUEUE,
                PROCESS_INSTRUCTION_ACTION,
                str(instruction_id),
                instruction_uuid,
            ),
        )
        row = cur.fetchone()
    return as_optional_string(row[0] if row else None)


def _find_existing_capture_base_rates_task_uuid(
    conn,
    *,
    booking_id: int,
    parent_task_uuid: Optional[str],
) -> Optional[str]:
    if parent_task_uuid:
        sql = """
            SELECT task_uuid
            FROM task_queue
            WHERE task_name = %s
              AND queue_name = %s
              AND task_data->>'action' = %s
              AND task_data->>'mode' = %s
              AND task_data->>'booking_id' = %s
              AND task_data->'meta'->>'parent_task_uuid' = %s
            ORDER BY id DESC
            LIMIT 1
        """
        params = (
            EXTERNAL_SERVICES_WORKER,
            EXTERNAL_SERVICES_QUEUE,
            PROCESS_INSTRUCTION_ACTION,
            PROCESS_INSTRUCTION_CAPTURE_BASE_RATES_MODE,
            str(booking_id),
            parent_task_uuid,
        )
    else:
        sql = """
            SELECT task_uuid
            FROM task_queue
            WHERE task_name = %s
              AND queue_name = %s
              AND task_data->>'action' = %s
              AND task_data->>'mode' = %s
              AND task_data->>'booking_id' = %s
            ORDER BY id DESC
            LIMIT 1
        """
        params = (
            EXTERNAL_SERVICES_WORKER,
            EXTERNAL_SERVICES_QUEUE,
            PROCESS_INSTRUCTION_ACTION,
            PROCESS_INSTRUCTION_CAPTURE_BASE_RATES_MODE,
            str(booking_id),
        )

    with conn.cursor() as cur:
        cur.execute(sql, params)
        row = cur.fetchone()
    return as_optional_string(row[0] if row else None)


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


def _set_instruction_status(conn, *, instruction_id: int, status: str, removed: bool = False) -> None:
    sql = """
        UPDATE booking_applied_rules
        SET status = %s::applied_rule_status
            {extra}
        WHERE id = %s
    """.format(extra=", removed_at = NOW()" if removed else "")
    with conn.cursor() as cur:
        cur.execute(sql, (status, instruction_id))


def _fetch_instruction_for_update(conn, instruction_id: int) -> Optional[Dict[str, Any]]:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT id, status::text, instruction
            FROM booking_applied_rules
            WHERE id = %s
            FOR UPDATE
            """,
            (instruction_id,),
        )
        row = cur.fetchone()
    if row is None:
        return None
    instruction = row[2]
    if isinstance(instruction, str):
        instruction = json.loads(instruction)
    if not isinstance(instruction, dict):
        raise ValueError("booking_applied_rules.instruction must be a JSON object")
    return {"id": int(row[0]), "status": str(row[1]), "instruction": instruction}


def _set_source_after_removal(
    conn,
    *,
    source_instruction_id: int,
    removal_dates: list[str],
    removed_by_task_id: Optional[int],
) -> None:
    source_row = _fetch_instruction_for_update(conn, source_instruction_id)
    if source_row is None:
        return

    current_status = str(source_row["status"])
    if current_status not in {"applied", "processing"}:
        return

    source_instruction = dict(source_row["instruction"])
    source_dates = _normalized_dates(source_instruction.get("dates"))
    removal_date_set = set(_normalized_dates(removal_dates))
    remaining_dates = [date_value for date_value in source_dates if date_value not in removal_date_set]

    if remaining_dates:
        source_instruction["dates"] = remaining_dates
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE booking_applied_rules
                SET status = 'applied',
                    instruction = %s::jsonb,
                    removed_at = NULL,
                    removed_by_task_id = NULL
                WHERE id = %s
                  AND status IN ('applied', 'processing')
                """,
                (json.dumps(source_instruction, default=str), source_instruction_id),
            )
        return

    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE booking_applied_rules
            SET status = 'removed',
                removed_at = NOW(),
                removed_by_task_id = %s
            WHERE id = %s
              AND status IN ('applied', 'processing')
            """,
            (removed_by_task_id, source_instruction_id),
        )


def _restore_source_applied(conn, *, source_instruction_id: int) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE booking_applied_rules
            SET status = 'applied',
                removed_at = NULL,
                removed_by_task_id = NULL
            WHERE id = %s
              AND status = 'processing'
            """,
            (source_instruction_id,),
        )


def _update_booking_last_extended(conn, *, booking_id: int) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE booking_registers
            SET metadata = jsonb_set(
                jsonb_set(
                    COALESCE(metadata, '{}'::jsonb),
                    '{bso}',
                    COALESCE(metadata->'bso', '{}'::jsonb),
                    TRUE
                ),
                '{bso,potential_extension}',
                COALESCE(metadata->'bso'->'potential_extension', '{}'::jsonb)
                    || jsonb_build_object('last_extended', to_jsonb(NOW())),
                TRUE
            )
            WHERE id = %s
            """,
            (booking_id,),
        )


def _clear_booking_needs_scan(conn, *, booking_id: int) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT mark_booking_register_extension_scanned(%s)
            """,
            (booking_id,),
        )
        cur.fetchone()


def _update_booking_bso_cancellation(conn, *, booking_id: int) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE booking_registers
            SET metadata = jsonb_set(
                jsonb_set(
                    COALESCE(metadata, '{}'::jsonb),
                    '{bso}',
                    COALESCE(metadata->'bso', '{}'::jsonb),
                    TRUE
                ),
                '{bso,cancellation}',
                COALESCE(metadata->'bso'->'cancellation', '{}'::jsonb)
                    || jsonb_build_object('cancelled', true),
                TRUE
            )
            WHERE id = %s
            """,
            (booking_id,),
        )


def _find_active_booking_instructions_for_booking(
    conn,
    *,
    booking_id: int,
    property_id: int,
) -> list[Dict[str, Any]]:
    listing_column = _resolve_booking_applied_rules_listing_column(conn)
    with conn.cursor() as cur:
        cur.execute(
            f"""
            SELECT
                id,
                booking_entry_id,
                property_id,
                platform_id,
                {listing_column} AS listing_id,
                trigger_category,
                status::text,
                instruction
            FROM find_booking_applied_instructions_active(%s, NULL, NULL)
            """,
            (property_id,),
        )
        rows = cur.fetchall() or []

    active_rows: list[Dict[str, Any]] = []
    for row in rows:
        if int(row[1]) != int(booking_id):
            continue
        instruction = row[7]
        if isinstance(instruction, str):
            instruction = json.loads(instruction)
        if not isinstance(instruction, dict):
            continue
        active_rows.append(
            {
                "id": int(row[0]),
                "booking_entry_id": int(row[1]),
                "property_id": int(row[2]),
                "platform_id": int(row[3]),
                "listing_id": str(row[4]),
                "trigger_category": as_optional_string(row[5]) or "",
                "status": str(row[6]),
                "instruction": instruction,
            }
        )
    return active_rows


def _external_task_payload(record: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "action": PROCESS_INSTRUCTION_ACTION,
        "instruction_id": int(record["instruction_id"]),
        "instruction_uuid": str(record["instruction_uuid"]),
        "source_instruction_id": record.get("source_instruction_id"),
        "instruction": dict(record["instruction"]),
        "return_ref": {
            "worker": WORKER,
            "queue": PRIMARY_QUEUE,
            "action": INSTRUCTION_RESULT_ACTION,
        },
    }


def _resolve_capture_required_rate_types(
    linked_listings_data: list[Dict[str, Any]],
) -> list[str]:
    required = {"base"}
    for item in linked_listings_data:
        rule = item.get("rule") if isinstance(item.get("rule"), dict) else {}
        rule_config = (
            rule.get("rule_config") if isinstance(rule.get("rule_config"), dict) else {}
        )
        operation = (
            rule_config.get("operation")
            if isinstance(rule_config.get("operation"), dict)
            else {}
        )
        required.add(
            _normalize_target_rate_type(
                operation.get("target_rate_type"),
                default="base",
            )
        )
    return sorted(required)


def _capture_base_rates_task_payload(
    *,
    booking_id: int,
    canonical_pair: Dict[str, Any],
    linked_listings_data: list[Dict[str, Any]],
    dates: list[str],
    required_rate_types: list[str],
) -> Dict[str, Any]:
    payload_linked_listings: list[Dict[str, Any]] = []
    for item in linked_listings_data:
        platform_pair = item.get("platform_pair") if isinstance(item.get("platform_pair"), dict) else {}
        rule = item.get("rule") if isinstance(item.get("rule"), dict) else {}
        entry: Dict[str, Any] = {
            "platform_pair": {
                "platform_id": int(platform_pair["platform_id"]),
                "listing_id": str(platform_pair["listing_id"]),
                "is_canonical": bool(platform_pair.get("is_canonical", False)),
            },
            "rule": dict(rule),
            "chain_id": as_optional_string(item.get("chain_id")),
            "chain_position": coerce_optional_int(item.get("chain_position"), field_name="chain_position"),
            "platform_type": _normalize_platform_type(item.get("platform_type")),
            "depends_on_position": coerce_optional_int(
                item.get("depends_on_position"),
                field_name="depends_on_position",
            ),
        }
        pair_platform_type = _normalize_platform_type(platform_pair.get("platform_type"))
        if pair_platform_type:
            entry["platform_pair"]["platform_type"] = pair_platform_type
        category = as_optional_string(item.get("category"))
        if category:
            entry["category"] = category
        rule_source = as_optional_string(item.get("rule_source"))
        if rule_source:
            entry["rule_source"] = rule_source
        payload_linked_listings.append(entry)

    return {
        "action": PROCESS_INSTRUCTION_ACTION,
        "mode": PROCESS_INSTRUCTION_CAPTURE_BASE_RATES_MODE,
        "booking_id": int(booking_id),
        "canonical_pair": {
            "platform_id": int(canonical_pair["platform_id"]),
            "listing_id": str(canonical_pair["listing_id"]),
        },
        "dates": sorted(set(str(value) for value in dates)),
        "required_rate_types": sorted(
            {
                _normalize_target_rate_type(value, default="base")
                for value in required_rate_types
                if as_optional_string(value) is not None
            }
            | {"base"}
        ),
        "linked_listings_data": payload_linked_listings,
    }


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
    log.error(message, exc=exc, error_code=error_code, **task_log_kwargs(task, action_name))
    state.record_failure(step_name, message)
    queue.fail_task(task, message, retry=retry)


def handle_remove_bso(context: ManagedWorkerContext, task) -> None:
    queue = context.main_queue
    step = default_step(context)
    log = default_app_logger(context)
    state = ActionStateManager.load(context, task)
    payload = task.payload if isinstance(task.payload, dict) else {}

    log.info(
        "task started",
        metadata={"action": REMOVE_BSO_ACTION},
        **task_log_kwargs(task, "handle_remove_bso"),
    )

    booking_id = _normalize_booking_id(payload)
    reason_code = as_optional_string(payload.get("reason_code"))
    reason_note = as_optional_string(payload.get("reason_note"))
    if booking_id is None:
        _log_and_fail(
            queue=queue,
            log=log,
            state=state,
            task=task,
            action_name="handle_remove_bso",
            step_name="remove_plan_prepared",
            message="booking_id is required",
            retry=False,
        )
        return
    if not reason_code:
        _log_and_fail(
            queue=queue,
            log=log,
            state=state,
            task=task,
            action_name="handle_remove_bso",
            step_name="remove_plan_prepared",
            message="reason_code is required",
            retry=False,
        )
        return
    policy = _get_remove_bso_reason_policy(reason_code)
    if policy is None:
        _log_and_fail(
            queue=queue,
            log=log,
            state=state,
            task=task,
            action_name="handle_remove_bso",
            step_name="remove_plan_prepared",
            message=f"unsupported reason_code: {reason_code}",
            retry=False,
        )
        return

    if not state.is_step_done("remove_plan_prepared"):
        state.begin_step("remove_plan_prepared")
        try:
            with context.connect_db() as conn:
                booking = _fetch_booking(conn, booking_id)
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_remove_bso",
                step_name="remove_plan_prepared",
                message=f"failed to read booking {booking_id}: {exc}",
                retry=True,
                error_code="BOOKING_READ_FAILED",
                exc=exc,
            )
            return

        if booking is None:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_remove_bso",
                step_name="remove_plan_prepared",
                message=f"booking {booking_id} not found",
                retry=False,
                error_code="BOOKING_NOT_FOUND",
            )
            return

        try:
            with context.connect_db() as conn:
                active_rows = _find_active_booking_instructions_for_booking(
                    conn,
                    booking_id=int(booking["booking_entry_id"]),
                    property_id=int(booking["property_id"]),
                )
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_remove_bso",
                step_name="remove_plan_prepared",
                message=f"failed to load active BSO instructions for booking {booking_id}: {exc}",
                retry=True,
                error_code="OVERLAP_QUERY_FAILED",
                exc=exc,
            )
            return

        removal_blueprints: list[Dict[str, Any]] = []
        source_instruction_ids: list[int] = []
        for row in active_rows:
            source_instruction = dict(row["instruction"])
            source_instruction_id = int(row["id"])
            source_instruction_ids.append(source_instruction_id)
            source_dates = _normalized_dates(source_instruction.get("dates"))
            removal_instruction = _build_removal_instruction(
                source_instruction,
                source_instruction_id,
                dates=source_dates,
                reason_code=reason_code,
                reason_note=reason_note,
            )
            if as_optional_string(row.get("trigger_category")):
                removal_instruction["trigger_category"] = str(row["trigger_category"])
            removal_blueprints.append(removal_instruction)

        state.checkpoint(
            "remove_plan_prepared",
            {
                "booking_id": int(booking_id),
                "reason_code": reason_code,
                "reason_note": reason_note,
                "set_booking_cancelled_meta": bool(policy.get("set_booking_cancelled_meta", False)),
                "source_instruction_ids": source_instruction_ids,
                "removal_blueprints": removal_blueprints,
            },
        )

    prepared = state.get_step_data("remove_plan_prepared")
    removal_blueprints = [dict(item) for item in prepared.get("removal_blueprints") or [] if isinstance(item, dict)]
    if not removal_blueprints:
        result = {
            "status": "no_active_bso_found",
            "booking_id": int(prepared["booking_id"]),
            "reason_code": str(prepared["reason_code"]),
            "queued_removals": 0,
            "source_instruction_ids": [],
            "removal_instruction_ids": [],
            "removal_task_uuids": [],
        }
        step.log("remove-bso found no active instructions", result)
        log.info("task completed", metadata=result, **task_log_kwargs(task, "handle_remove_bso"))
        queue.complete_task(task, result)
        return

    if not state.is_step_done("removal_rows_recorded"):
        state.begin_step("removal_rows_recorded")
        try:
            with context.connect_db() as conn:
                with conn.transaction():
                    removal_records = [
                        _ensure_instruction_row(
                            conn,
                            instruction=dict(blueprint),
                            category=as_optional_string(blueprint.get("trigger_category")) or POTENTIAL_EXTENSION_ACTION,
                            applied_by_task_id=getattr(task, "task_id", None),
                        )
                        for blueprint in removal_blueprints
                    ]
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_remove_bso",
                step_name="removal_rows_recorded",
                message=f"failed to record removal rows: {exc}",
                retry=True,
                error_code="REMOVAL_ROW_INSERT_FAILED",
                exc=exc,
            )
            return
        state.checkpoint("removal_rows_recorded", {"removal_records": removal_records})

    removal_records = list(state.get_step_data("removal_rows_recorded").get("removal_records") or [])
    if not state.is_step_done("removal_tasks_enqueued"):
        state.begin_step("removal_tasks_enqueued")
        removal_task_uuids: list[str] = []
        overlap_removal_task_by_source_id: Dict[int, str] = {}
        total = len(removal_records)
        pending, processed = _pending_after_cursor(removal_records, state.get_resume_cursor(), key_name="instruction_id")

        try:
            with context.connect_db() as conn:
                for record in removal_records[:processed]:
                    existing_uuid = _find_existing_external_task_uuid(
                        conn,
                        instruction_id=int(record["instruction_id"]),
                        instruction_uuid=str(record["instruction_uuid"]),
                    )
                    if existing_uuid:
                        removal_task_uuids.append(existing_uuid)
                        source_instruction_id = coerce_optional_int(
                            record.get("source_instruction_id"),
                            field_name="source_instruction_id",
                        )
                        if source_instruction_id is not None:
                            overlap_removal_task_by_source_id[int(source_instruction_id)] = str(existing_uuid)

            for record in pending:
                with context.connect_db() as conn:
                    task_uuid = _find_existing_external_task_uuid(
                        conn,
                        instruction_id=int(record["instruction_id"]),
                        instruction_uuid=str(record["instruction_uuid"]),
                    )
                if task_uuid is None:
                    task_uuid = enqueue_with_meta(
                        context.queue(EXTERNAL_SERVICES_QUEUE),
                        EXTERNAL_SERVICES_WORKER,
                        _external_task_payload(record),
                        current_task=task,
                        current_worker=WORKER,
                        current_action=REMOVE_BSO_ACTION,
                        next_worker=EXTERNAL_SERVICES_WORKER,
                        next_action=PROCESS_INSTRUCTION_ACTION,
                    )
                if task_uuid:
                    removal_task_uuids.append(task_uuid)
                processed += 1
                state.set_progress(
                    items_total=total,
                    items_processed=processed,
                    last_processed_id=int(record["instruction_id"]),
                )
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_remove_bso",
                step_name="removal_tasks_enqueued",
                message=f"failed to enqueue removal tasks: {exc}",
                retry=True,
                error_code="ENQUEUE_FAILED",
                exc=exc,
            )
            return
        state.checkpoint("removal_tasks_enqueued", {"removal_task_uuids": removal_task_uuids})

    removal_task_uuids = [
        str(value)
        for value in state.get_step_data("removal_tasks_enqueued").get("removal_task_uuids") or []
        if value
    ]
    result = {
        "status": "forwarded_to_external_service",
        "booking_id": int(prepared["booking_id"]),
        "reason_code": str(prepared["reason_code"]),
        "queued_removals": len(removal_records),
        "source_instruction_ids": [int(value) for value in prepared.get("source_instruction_ids") or []],
        "removal_instruction_ids": [int(record["instruction_id"]) for record in removal_records],
        "removal_task_uuids": list(removal_task_uuids),
    }
    step.log("remove-bso forwarded removal instructions", result)
    log.info("task completed", metadata=result, **task_log_kwargs(task, "handle_remove_bso"))
    queue.complete_task(task, result)


def handle_potential_extension(context: ManagedWorkerContext, task) -> None:
    queue = context.main_queue
    step = default_step(context)
    log = default_app_logger(context)
    state = ActionStateManager.load(context, task)
    payload = task.payload

    log.info(
        "task started",
        metadata={"action": POTENTIAL_EXTENSION_ACTION},
        **task_log_kwargs(task, "handle_potential_extension"),
    )

    try:
        booking_id = _normalize_booking_id(payload)
        category = _normalize_category(payload)
        canonical_pair = _normalize_pair(payload, "canonical_pair", require_listing_id=False)
        platform_pair = _normalize_pair(payload, "platform_pair", require_listing_id=True)
        rule = _normalize_rule(payload)
    except ValueError as exc:
        _log_and_fail(
            queue=queue,
            log=log,
            state=state,
            task=task,
            action_name="handle_potential_extension",
            step_name="instruction_prepared",
            message=str(exc),
            retry=False,
            exc=exc,
        )
        return

    if booking_id is None:
        _log_and_fail(
            queue=queue,
            log=log,
            state=state,
            task=task,
            action_name="handle_potential_extension",
            step_name="instruction_prepared",
            message="booking_id is required",
            retry=False,
        )
        return
    if not category:
        _log_and_fail(
            queue=queue,
            log=log,
            state=state,
            task=task,
            action_name="handle_potential_extension",
            step_name="instruction_prepared",
            message="category is required",
            retry=False,
        )
        return

    if not state.is_step_done("instruction_prepared"):
        state.begin_step("instruction_prepared")

        try:
            with context.connect_db() as conn:
                booking = _fetch_booking(conn, booking_id)
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_potential_extension",
                step_name="instruction_prepared",
                message=f"failed to read booking {booking_id}: {exc}",
                retry=True,
                error_code="BOOKING_READ_FAILED",
                exc=exc,
            )
            return

        if booking is None:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_potential_extension",
                step_name="instruction_prepared",
                message=f"booking {booking_id} not found",
                retry=False,
                error_code="BOOKING_NOT_FOUND",
            )
            return

        try:
            apply_instruction = _build_apply_instruction(
                rule,
                booking,
                canonical_pair,
                platform_pair,
                category,
            )
        except InStayDatesNotAllowedError as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_potential_extension",
                step_name="instruction_prepared",
                message=str(exc),
                retry=False,
                error_code="IN_STAY_DATES_NOT_ALLOWED",
                exc=exc,
            )
            return
        except ValueError as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_potential_extension",
                step_name="instruction_prepared",
                message=str(exc),
                retry=False,
                exc=exc,
            )
            return
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_potential_extension",
                step_name="instruction_prepared",
                message=f"failed to build apply instruction for booking {booking_id}: {exc}",
                retry=False,
                exc=exc,
            )
            return

        try:
            with context.connect_db() as conn:
                with conn.transaction():
                    try:
                        overlaps = _find_overlaps(
                            conn,
                            booking_id=int(booking["booking_entry_id"]),
                            property_id=int(booking["property_id"]),
                            platform_id=int(platform_pair["platform_id"]),
                            listing_id=str(platform_pair["listing_id"]),
                            dates=list(apply_instruction["dates"]),
                        )
                    except ValueError:
                        raise
                    except Exception as exc:
                        raise OverlapQueryError("failed to query overlapping instructions") from exc

                    overlap_ids = [int(item["id"]) for item in overlaps]
                    try:
                        _reserve_overlap_rows(conn, overlap_ids)
                    except Exception as exc:
                        raise OverlapReserveError("failed to reserve overlapping instructions") from exc
        except ValueError as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_potential_extension",
                step_name="instruction_prepared",
                message=str(exc),
                retry=False,
                exc=exc,
            )
            return
        except OverlapQueryError as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_potential_extension",
                step_name="instruction_prepared",
                message=f"failed to query overlaps for booking {booking_id}: {exc}",
                retry=True,
                error_code="OVERLAP_QUERY_FAILED",
                exc=exc,
            )
            return
        except OverlapReserveError as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_potential_extension",
                step_name="instruction_prepared",
                message=f"failed to reserve overlaps for booking {booking_id}: {exc}",
                retry=True,
                error_code="OVERLAP_RESERVE_FAILED",
                exc=exc,
            )
            return
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_potential_extension",
                step_name="instruction_prepared",
                message=f"failed to query overlaps for booking {booking_id}: {exc}",
                retry=True,
                error_code="OVERLAP_QUERY_FAILED",
                exc=exc,
            )
            return

        removal_blueprints = []
        for item in overlaps:
            removal_instruction = _build_removal_instruction(
                item["instruction"],
                int(item["id"]),
                dates=[str(value) for value in item.get("intersection_dates") or []],
            )
            removal_category = as_optional_string(item.get("trigger_category")) or as_optional_string(
                removal_instruction.get("trigger_category")
            )
            if removal_category:
                removal_instruction["trigger_category"] = removal_category
            removal_blueprints.append(removal_instruction)

        state.checkpoint(
            "instruction_prepared",
            {
                "booking_id": int(booking_id),
                "category": category,
                "platform_id": int(platform_pair["platform_id"]),
                "apply_instruction": apply_instruction,
                "overlap_ids": overlap_ids,
                "removal_blueprints": removal_blueprints,
            },
        )

    prepared = state.get_step_data("instruction_prepared")
    category = str(prepared["category"])

    if not state.is_step_done("removal_rows_recorded"):
        state.begin_step("removal_rows_recorded")
        try:
            with context.connect_db() as conn:
                with conn.transaction():
                    removal_records = [
                        _ensure_instruction_row(
                            conn,
                            instruction=dict(blueprint),
                            category=as_optional_string(blueprint.get("trigger_category")) or category,
                            applied_by_task_id=getattr(task, "task_id", None),
                        )
                        for blueprint in list(prepared.get("removal_blueprints") or [])
                    ]
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_potential_extension",
                step_name="removal_rows_recorded",
                message=f"failed to record removal rows: {exc}",
                retry=True,
                error_code="REMOVAL_ROW_INSERT_FAILED",
                exc=exc,
            )
            return

        state.checkpoint("removal_rows_recorded", {"removal_records": removal_records})

    removal_records = list(state.get_step_data("removal_rows_recorded").get("removal_records") or [])
    if not state.is_step_done("removal_tasks_enqueued"):
        state.begin_step("removal_tasks_enqueued")
        removal_task_uuids: list[str] = []
        overlap_removal_task_by_source_id: Dict[int, str] = {}
        total = len(removal_records)
        pending, processed = _pending_after_cursor(removal_records, state.get_resume_cursor(), key_name="instruction_id")

        try:
            with context.connect_db() as conn:
                for record in removal_records[:processed]:
                    existing_uuid = _find_existing_external_task_uuid(
                        conn,
                        instruction_id=int(record["instruction_id"]),
                        instruction_uuid=str(record["instruction_uuid"]),
                    )
                    if existing_uuid:
                        removal_task_uuids.append(existing_uuid)
                        source_instruction_id = coerce_optional_int(
                            record.get("source_instruction_id"),
                            field_name="source_instruction_id",
                        )
                        if source_instruction_id is not None:
                            overlap_removal_task_by_source_id[int(source_instruction_id)] = str(existing_uuid)

            for record in pending:
                with context.connect_db() as conn:
                    task_uuid = _find_existing_external_task_uuid(
                        conn,
                        instruction_id=int(record["instruction_id"]),
                        instruction_uuid=str(record["instruction_uuid"]),
                    )
                if task_uuid is None:
                    task_uuid = enqueue_with_meta(
                        context.queue(EXTERNAL_SERVICES_QUEUE),
                        EXTERNAL_SERVICES_WORKER,
                        _external_task_payload(record),
                        current_task=task,
                        current_worker=WORKER,
                        current_action=category,
                        next_worker=EXTERNAL_SERVICES_WORKER,
                        next_action=PROCESS_INSTRUCTION_ACTION,
                    )
                if task_uuid:
                    removal_task_uuids.append(task_uuid)
                processed += 1
                state.set_progress(
                    items_total=total,
                    items_processed=processed,
                    last_processed_id=int(record["instruction_id"]),
                )
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_potential_extension",
                step_name="removal_tasks_enqueued",
                message=f"failed to enqueue removal tasks: {exc}",
                retry=True,
                error_code="ENQUEUE_FAILED",
                exc=exc,
            )
            return

        state.checkpoint("removal_tasks_enqueued", {"removal_task_uuids": removal_task_uuids})

    removal_task_uuids = [
        str(value)
        for value in state.get_step_data("removal_tasks_enqueued").get("removal_task_uuids") or []
        if value
    ]

    if not state.is_step_done("apply_row_recorded"):
        state.begin_step("apply_row_recorded")
        try:
            with context.connect_db() as conn:
                with conn.transaction():
                    apply_row = _ensure_instruction_row(
                        conn,
                        instruction=dict(prepared["apply_instruction"]),
                        category=category,
                        applied_by_task_id=getattr(task, "task_id", None),
                    )
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_potential_extension",
                step_name="apply_row_recorded",
                message=f"failed to record apply row: {exc}",
                retry=True,
                error_code="APPLY_ROW_INSERT_FAILED",
                exc=exc,
            )
            return

        state.checkpoint(
            "apply_row_recorded",
            {
                "apply_instruction_id": int(apply_row["instruction_id"]),
                "apply_instruction_uuid": str(apply_row["instruction_uuid"]),
                "apply_instruction": dict(apply_row["instruction"]),
            },
        )

    apply_step_data = state.get_step_data("apply_row_recorded")
    apply_row = {
        "instruction_id": int(apply_step_data["apply_instruction_id"]),
        "instruction_uuid": str(apply_step_data["apply_instruction_uuid"]),
        "instruction": dict(apply_step_data["apply_instruction"]),
        "source_instruction_id": None,
    }

    if not state.is_step_done("apply_task_enqueued"):
        state.begin_step("apply_task_enqueued")
        apply_task_uuid = None
        try:
            with context.connect_db() as conn:
                apply_task_uuid = _find_existing_external_task_uuid(
                    conn,
                    instruction_id=int(apply_row["instruction_id"]),
                    instruction_uuid=str(apply_row["instruction_uuid"]),
                )
            if apply_task_uuid is None:
                apply_task_uuid = enqueue_with_meta(
                    context.queue(EXTERNAL_SERVICES_QUEUE),
                    EXTERNAL_SERVICES_WORKER,
                    _external_task_payload(apply_row),
                    current_task=task,
                    current_worker=WORKER,
                    current_action=category,
                    next_worker=EXTERNAL_SERVICES_WORKER,
                    next_action=PROCESS_INSTRUCTION_ACTION,
                )
            if removal_task_uuids and apply_task_uuid:
                context.scheduler.add_task_dependencies(apply_task_uuid, removal_task_uuids)
        except Exception as exc:
            error_code = "TASK_DEPENDENCY_FAILED" if removal_task_uuids and apply_task_uuid else "ENQUEUE_FAILED"
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_potential_extension",
                step_name="apply_task_enqueued",
                message=f"failed to enqueue apply task: {exc}",
                retry=True,
                error_code=error_code,
                exc=exc,
            )
            return

        state.checkpoint(
            "apply_task_enqueued",
            {"apply_task_uuid": apply_task_uuid, "dependency_count": len(removal_task_uuids)},
        )

    apply_task_uuid = as_optional_string(state.get_step_data("apply_task_enqueued").get("apply_task_uuid"))
    result = {
        "status": "forwarded_to_external_service",
        "booking_id": int(prepared["booking_id"]),
        "category": category,
        "platform_id": int(prepared["platform_id"]),
        "overlap_count": len(prepared.get("overlap_ids") or []),
        "removal_instruction_ids": [int(record["instruction_id"]) for record in removal_records],
        "apply_instruction_id": int(apply_row["instruction_id"]),
        "removal_task_uuids": list(removal_task_uuids),
        "apply_task_uuid": apply_task_uuid,
    }
    step.log("booking special operation forwarded instructions", result)
    log.info("task completed", metadata=result, **task_log_kwargs(task, "handle_potential_extension"))
    queue.complete_task(task, result)


def _handle_generate_class_rule_insturction_bulk(context: ManagedWorkerContext, task) -> None:
    queue = context.main_queue
    step = default_step(context)
    log = default_app_logger(context)
    state = ActionStateManager.load(context, task)
    payload = task.payload

    log.info(
        "task started",
        metadata={"action": GENERATE_CLASS_RULE_INSTURCTION_ACTION, "mode": "bulk"},
        **task_log_kwargs(task, "handle_generate_class_rule_insturction"),
    )

    try:
        booking_id = _normalize_booking_id(payload)
        default_category = _normalize_category(payload)
        canonical_pair = _normalize_pair(payload, "canonical_pair", require_listing_id=False)
        linked_listings_data = _normalize_linked_listings_data(payload, default_category=default_category)
    except ValueError as exc:
        _log_and_fail(
            queue=queue,
            log=log,
            state=state,
            task=task,
            action_name="handle_generate_class_rule_insturction",
            step_name="instruction_plan_prepared",
            message=str(exc),
            retry=False,
            exc=exc,
        )
        return

    if booking_id is None:
        _log_and_fail(
            queue=queue,
            log=log,
            state=state,
            task=task,
            action_name="handle_generate_class_rule_insturction",
            step_name="instruction_plan_prepared",
            message="booking_id is required",
            retry=False,
        )
        return

    missing_category_index = next(
        (
            index
            for index, item in enumerate(linked_listings_data)
            if not as_optional_string(item.get("category"))
        ),
        None,
    )
    if missing_category_index is not None:
        _log_and_fail(
            queue=queue,
            log=log,
            state=state,
            task=task,
            action_name="handle_generate_class_rule_insturction",
            step_name="instruction_plan_prepared",
            message=f"linked_listings_data[{missing_category_index}].category is required",
            retry=False,
        )
        return

    if not state.is_step_done("instruction_plan_prepared"):
        state.begin_step("instruction_plan_prepared")

        try:
            with context.connect_db() as conn:
                booking = _fetch_booking(conn, booking_id)
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_generate_class_rule_insturction",
                step_name="instruction_plan_prepared",
                message=f"failed to read booking {booking_id}: {exc}",
                retry=True,
                error_code="BOOKING_READ_FAILED",
                exc=exc,
            )
            return

        if booking is None:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_generate_class_rule_insturction",
                step_name="instruction_plan_prepared",
                message=f"booking {booking_id} not found",
                retry=False,
                error_code="BOOKING_NOT_FOUND",
            )
            return

        instruction_plans: list[Dict[str, Any]] = []
        try:
            for index, item in enumerate(linked_listings_data):
                category = as_optional_string(item.get("category"))
                platform_pair = item.get("platform_pair") if isinstance(item.get("platform_pair"), dict) else {}
                rule = item.get("rule") if isinstance(item.get("rule"), dict) else {}
                apply_instruction = _build_apply_instruction(
                    rule,
                    booking,
                    canonical_pair,
                    platform_pair,
                    str(category),
                    chain={
                        "chain_id": str(item["chain_id"]),
                        "chain_position": int(item["chain_position"]),
                        "platform_type": str(item["platform_type"]),
                        "depends_on_position": item.get("depends_on_position"),
                    },
                )
                instruction_plans.append(
                    {
                        "index": index,
                        "category": str(category),
                        "rule_source": as_optional_string(item.get("rule_source")) or "direct",
                        "platform_pair": dict(platform_pair),
                        "chain_id": str(item["chain_id"]),
                        "chain_position": int(item["chain_position"]),
                        "platform_type": str(item["platform_type"]),
                        "depends_on_position": item.get("depends_on_position"),
                        "rule": dict(rule),
                        "apply_instruction": apply_instruction,
                    }
                )
        except InStayDatesNotAllowedError as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_generate_class_rule_insturction",
                step_name="instruction_plan_prepared",
                message=str(exc),
                retry=False,
                error_code="IN_STAY_DATES_NOT_ALLOWED",
                exc=exc,
            )
            return
        except ValueError as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_generate_class_rule_insturction",
                step_name="instruction_plan_prepared",
                message=str(exc),
                retry=False,
                exc=exc,
            )
            return
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_generate_class_rule_insturction",
                step_name="instruction_plan_prepared",
                message=f"failed to build apply instructions for booking {booking_id}: {exc}",
                retry=False,
                exc=exc,
            )
            return

        try:
            with context.connect_db() as conn:
                with conn.transaction():
                    overlap_ids_to_reserve: list[int] = []
                    overlaps_by_index: Dict[int, list[Dict[str, Any]]] = {}
                    for plan in instruction_plans:
                        apply_instruction = plan["apply_instruction"]
                        platform_pair = plan["platform_pair"]
                        overlaps = _find_overlaps(
                            conn,
                            booking_id=int(booking["booking_entry_id"]),
                            property_id=int(booking["property_id"]),
                            platform_id=int(platform_pair["platform_id"]),
                            listing_id=str(platform_pair["listing_id"]),
                            dates=list(apply_instruction["dates"]),
                        )
                        overlaps_by_index[int(plan["index"])] = overlaps
                        overlap_ids_to_reserve.extend(int(item["id"]) for item in overlaps)

                    _reserve_overlap_rows(conn, sorted(set(overlap_ids_to_reserve)))
        except ValueError as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_generate_class_rule_insturction",
                step_name="instruction_plan_prepared",
                message=str(exc),
                retry=False,
                exc=exc,
            )
            return
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_generate_class_rule_insturction",
                step_name="instruction_plan_prepared",
                message=f"failed to query overlaps for booking {booking_id}: {exc}",
                retry=True,
                error_code="OVERLAP_QUERY_FAILED",
                exc=exc,
            )
            return

        overlap_dates_by_source_id: Dict[int, set[str]] = {}
        source_instruction_by_id: Dict[int, Dict[str, Any]] = {}
        source_category_by_id: Dict[int, str] = {}
        for plan in instruction_plans:
            overlaps = overlaps_by_index.get(int(plan["index"]), [])
            overlap_ids: list[int] = []
            for item in overlaps:
                source_instruction_id = int(item["id"])
                overlap_ids.append(source_instruction_id)
                source_instruction_by_id.setdefault(source_instruction_id, dict(item["instruction"]))
                source_category = as_optional_string(item.get("trigger_category"))
                if source_category:
                    source_category_by_id.setdefault(source_instruction_id, source_category)
                overlap_dates = overlap_dates_by_source_id.setdefault(source_instruction_id, set())
                overlap_dates.update(str(value) for value in item.get("intersection_dates") or [])
            plan["overlap_ids"] = overlap_ids

        removal_blueprints: list[Dict[str, Any]] = []
        for source_instruction_id in sorted(overlap_dates_by_source_id):
            source_instruction = dict(source_instruction_by_id[source_instruction_id])
            source_dates = _normalized_dates(source_instruction.get("dates"))
            source_overlap_date_set = overlap_dates_by_source_id[source_instruction_id]
            source_overlap_dates = [date_value for date_value in source_dates if date_value in source_overlap_date_set]
            if not source_overlap_dates:
                continue
            removal_instruction = _build_removal_instruction(
                source_instruction,
                source_instruction_id,
                dates=source_overlap_dates,
            )
            source_category = source_category_by_id.get(source_instruction_id)
            if source_category:
                removal_instruction["trigger_category"] = source_category
            removal_blueprints.append(removal_instruction)

        capture_dates = sorted(
            {
                str(date_value)
                for plan in instruction_plans
                for date_value in list(plan["apply_instruction"].get("dates") or [])
            }
        )
        required_rate_types = _resolve_capture_required_rate_types(linked_listings_data)

        state.checkpoint(
            "instruction_plan_prepared",
            {
                "booking_id": int(booking_id),
                "canonical_pair": dict(canonical_pair),
                "instruction_plans": instruction_plans,
                "linked_listings_data": linked_listings_data,
                "capture_dates": capture_dates,
                "required_rate_types": required_rate_types,
                "overlap_ids": sorted(overlap_dates_by_source_id),
                "removal_blueprints": removal_blueprints,
            },
        )

    prepared = state.get_step_data("instruction_plan_prepared")
    instruction_plans = [dict(item) for item in prepared.get("instruction_plans") or [] if isinstance(item, dict)]
    capture_dates = [str(value) for value in prepared.get("capture_dates") or []]

    if not state.is_step_done("removal_rows_recorded"):
        state.begin_step("removal_rows_recorded")
        removal_blueprints = [dict(item) for item in prepared.get("removal_blueprints") or [] if isinstance(item, dict)]
        try:
            with context.connect_db() as conn:
                with conn.transaction():
                    removal_records = []
                    for blueprint in removal_blueprints:
                        category = as_optional_string(blueprint.get("trigger_category")) or POTENTIAL_EXTENSION_ACTION
                        removal_records.append(
                            _ensure_instruction_row(
                                conn,
                                instruction=dict(blueprint),
                                category=category,
                                applied_by_task_id=getattr(task, "task_id", None),
                            )
                        )
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_generate_class_rule_insturction",
                step_name="removal_rows_recorded",
                message=f"failed to record removal rows: {exc}",
                retry=True,
                error_code="REMOVAL_ROW_INSERT_FAILED",
                exc=exc,
            )
            return

        state.checkpoint("removal_rows_recorded", {"removal_records": removal_records})

    removal_records = list(state.get_step_data("removal_rows_recorded").get("removal_records") or [])

    if not state.is_step_done("apply_rows_recorded"):
        state.begin_step("apply_rows_recorded")
        try:
            with context.connect_db() as conn:
                with conn.transaction():
                    apply_records = []
                    for plan in instruction_plans:
                        apply_row = _ensure_instruction_row(
                            conn,
                            instruction=dict(plan["apply_instruction"]),
                            category=str(plan["category"]),
                            applied_by_task_id=getattr(task, "task_id", None),
                        )
                        apply_records.append(
                            {
                                "instruction_id": int(apply_row["instruction_id"]),
                                "instruction_uuid": str(apply_row["instruction_uuid"]),
                                "instruction": dict(apply_row["instruction"]),
                                "source_instruction_id": None,
                                "platform_id": int(plan["platform_pair"]["platform_id"]),
                                "platform_type": _normalize_platform_type(plan.get("platform_type")),
                                "chain_id": as_optional_string(plan.get("chain_id")),
                                "chain_position": coerce_optional_int(
                                    plan.get("chain_position"),
                                    field_name="chain_position",
                                ),
                                "depends_on_position": coerce_optional_int(
                                    plan.get("depends_on_position"),
                                    field_name="depends_on_position",
                                ),
                                "category": str(plan["category"]),
                                "rule_source": as_optional_string(plan.get("rule_source")) or "direct",
                                "overlap_ids": [int(value) for value in plan.get("overlap_ids") or []],
                            }
                        )
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_generate_class_rule_insturction",
                step_name="apply_rows_recorded",
                message=f"failed to record apply rows: {exc}",
                retry=True,
                error_code="APPLY_ROW_INSERT_FAILED",
                exc=exc,
            )
            return

        state.checkpoint("apply_rows_recorded", {"apply_records": apply_records})

    apply_records = list(state.get_step_data("apply_rows_recorded").get("apply_records") or [])

    if not state.is_step_done("capture_task_enqueued"):
        state.begin_step("capture_task_enqueued")
        capture_task_uuid = None
        try:
            with context.connect_db() as conn:
                capture_task_uuid = _find_existing_capture_base_rates_task_uuid(
                    conn,
                    booking_id=int(prepared["booking_id"]),
                    parent_task_uuid=as_optional_string(getattr(task, "task_uuid", None)),
                )
            if capture_task_uuid is None:
                capture_task_uuid = enqueue_with_meta(
                    context.queue(EXTERNAL_SERVICES_QUEUE),
                    EXTERNAL_SERVICES_WORKER,
                    _capture_base_rates_task_payload(
                        booking_id=int(prepared["booking_id"]),
                        canonical_pair=dict(prepared["canonical_pair"]),
                        linked_listings_data=[
                            dict(item)
                            for item in prepared.get("linked_listings_data") or []
                            if isinstance(item, dict)
                        ],
                        dates=capture_dates,
                        required_rate_types=[
                            str(value)
                            for value in prepared.get("required_rate_types") or []
                        ],
                    ),
                    current_task=task,
                    current_worker=WORKER,
                    current_action=GENERATE_CLASS_RULE_INSTURCTION_ACTION,
                    next_worker=EXTERNAL_SERVICES_WORKER,
                    next_action=PROCESS_INSTRUCTION_ACTION,
                )
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_generate_class_rule_insturction",
                step_name="capture_task_enqueued",
                message=f"failed to enqueue base-rate capture task: {exc}",
                retry=True,
                error_code="ENQUEUE_FAILED",
                exc=exc,
            )
            return

        state.checkpoint("capture_task_enqueued", {"capture_task_uuid": capture_task_uuid})

    capture_task_uuid = as_optional_string(state.get_step_data("capture_task_enqueued").get("capture_task_uuid"))

    if not state.is_step_done("removal_tasks_enqueued"):
        state.begin_step("removal_tasks_enqueued")
        removal_task_uuids: list[str] = []
        overlap_removal_task_by_source_id: Dict[int, str] = {}
        total = len(removal_records)
        pending, processed = _pending_after_cursor(removal_records, state.get_resume_cursor(), key_name="instruction_id")

        try:
            with context.connect_db() as conn:
                for record in removal_records[:processed]:
                    existing_uuid = _find_existing_external_task_uuid(
                        conn,
                        instruction_id=int(record["instruction_id"]),
                        instruction_uuid=str(record["instruction_uuid"]),
                    )
                    if existing_uuid:
                        removal_task_uuids.append(existing_uuid)
                        source_instruction_id = coerce_optional_int(
                            record.get("source_instruction_id"),
                            field_name="source_instruction_id",
                        )
                        if source_instruction_id is not None:
                            overlap_removal_task_by_source_id[int(source_instruction_id)] = str(existing_uuid)

            for record in pending:
                with context.connect_db() as conn:
                    task_uuid = _find_existing_external_task_uuid(
                        conn,
                        instruction_id=int(record["instruction_id"]),
                        instruction_uuid=str(record["instruction_uuid"]),
                    )
                if task_uuid is None:
                    task_uuid = enqueue_with_meta(
                        context.queue(EXTERNAL_SERVICES_QUEUE),
                        EXTERNAL_SERVICES_WORKER,
                        _external_task_payload(record),
                        current_task=task,
                        current_worker=WORKER,
                        current_action=GENERATE_CLASS_RULE_INSTURCTION_ACTION,
                        next_worker=EXTERNAL_SERVICES_WORKER,
                        next_action=PROCESS_INSTRUCTION_ACTION,
                    )
                if task_uuid:
                    if capture_task_uuid:
                        context.scheduler.add_task_dependencies(task_uuid, [capture_task_uuid])
                    removal_task_uuids.append(task_uuid)
                    source_instruction_id = coerce_optional_int(
                        record.get("source_instruction_id"),
                        field_name="source_instruction_id",
                    )
                    if source_instruction_id is not None:
                        overlap_removal_task_by_source_id[int(source_instruction_id)] = str(task_uuid)
                processed += 1
                state.set_progress(
                    items_total=total,
                    items_processed=processed,
                    last_processed_id=int(record["instruction_id"]),
                )
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_generate_class_rule_insturction",
                step_name="removal_tasks_enqueued",
                message=f"failed to enqueue removal tasks: {exc}",
                retry=True,
                error_code="ENQUEUE_FAILED",
                exc=exc,
            )
            return

        state.checkpoint(
            "removal_tasks_enqueued",
            {
                "removal_task_uuids": removal_task_uuids,
                "overlap_removal_task_by_source_id": overlap_removal_task_by_source_id,
            },
        )

    removal_task_uuids = [
        str(value)
        for value in state.get_step_data("removal_tasks_enqueued").get("removal_task_uuids") or []
        if value
    ]
    overlap_removal_task_by_source_id = {
        int(key): str(value)
        for key, value in dict(
            state.get_step_data("removal_tasks_enqueued").get("overlap_removal_task_by_source_id") or {}
        ).items()
    }

    if not state.is_step_done("apply_tasks_enqueued"):
        state.begin_step("apply_tasks_enqueued")
        apply_task_uuids: list[str] = []
        previous_apply_task_uuid: Optional[str] = None

        try:
            ordered_apply_records = sorted(
                [dict(record) for record in apply_records],
                key=lambda record: int(record.get("chain_position") or 0),
            )
            for record in ordered_apply_records:
                with context.connect_db() as conn:
                    task_uuid = _find_existing_external_task_uuid(
                        conn,
                        instruction_id=int(record["instruction_id"]),
                        instruction_uuid=str(record["instruction_uuid"]),
                    )
                if task_uuid is None:
                    task_uuid = enqueue_with_meta(
                        context.queue(EXTERNAL_SERVICES_QUEUE),
                        EXTERNAL_SERVICES_WORKER,
                        _external_task_payload(record),
                        current_task=task,
                        current_worker=WORKER,
                        current_action=GENERATE_CLASS_RULE_INSTURCTION_ACTION,
                        next_worker=EXTERNAL_SERVICES_WORKER,
                        next_action=PROCESS_INSTRUCTION_ACTION,
                    )
                if task_uuid:
                    dependencies: list[str] = []
                    if capture_task_uuid:
                        dependencies.append(capture_task_uuid)
                    for overlap_source_id in [int(value) for value in record.get("overlap_ids") or []]:
                        overlap_task_uuid = overlap_removal_task_by_source_id.get(overlap_source_id)
                        if overlap_task_uuid and overlap_task_uuid not in dependencies:
                            dependencies.append(overlap_task_uuid)
                    if previous_apply_task_uuid and previous_apply_task_uuid not in dependencies:
                        dependencies.append(previous_apply_task_uuid)
                    if dependencies:
                        context.scheduler.add_task_dependencies(task_uuid, dependencies)
                    apply_task_uuids.append(task_uuid)
                    previous_apply_task_uuid = str(task_uuid)
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_generate_class_rule_insturction",
                step_name="apply_tasks_enqueued",
                message=f"failed to enqueue apply tasks: {exc}",
                retry=True,
                error_code="ENQUEUE_FAILED",
                exc=exc,
            )
            return

        state.checkpoint("apply_tasks_enqueued", {"apply_task_uuids": apply_task_uuids})

    apply_task_uuids = [
        str(value)
        for value in state.get_step_data("apply_tasks_enqueued").get("apply_task_uuids") or []
        if value
    ]

    overlap_ids = [int(value) for value in prepared.get("overlap_ids") or []]
    categories = sorted({str(item.get("category")) for item in apply_records if as_optional_string(item.get("category"))})
    platform_ids = sorted({int(item.get("platform_id")) for item in apply_records})
    result = {
        "status": "forwarded_to_external_service",
        "booking_id": int(prepared["booking_id"]),
        "category": categories[0] if len(categories) == 1 else None,
        "categories": categories,
        "platform_id": platform_ids[0] if len(platform_ids) == 1 else None,
        "platform_ids": platform_ids,
        "linked_listing_count": len(apply_records),
        "overlap_count": len(overlap_ids),
        "overlap_ids": overlap_ids,
        "removal_instruction_ids": [int(record["instruction_id"]) for record in removal_records],
        "apply_instruction_ids": [int(record["instruction_id"]) for record in apply_records],
        "capture_base_rates_task_uuid": capture_task_uuid,
        "removal_task_uuids": list(removal_task_uuids),
        "apply_task_uuids": list(apply_task_uuids),
    }
    if len(apply_records) == 1:
        result["apply_instruction_id"] = int(apply_records[0]["instruction_id"])
    if len(apply_task_uuids) == 1:
        result["apply_task_uuid"] = str(apply_task_uuids[0])

    step.log("booking special operation forwarded bulk instructions", result)
    log.info("task completed", metadata=result, **task_log_kwargs(task, "handle_generate_class_rule_insturction"))
    queue.complete_task(task, result)


def handle_generate_class_rule_insturction(context: ManagedWorkerContext, task) -> None:
    payload = task.payload if isinstance(task.payload, dict) else {}
    if isinstance(payload.get("linked_listings_data"), list):
        _handle_generate_class_rule_insturction_bulk(context, task)
        return
    handle_potential_extension(context, task)


def handle_instruction_result(context: ManagedWorkerContext, task) -> None:
    queue = context.main_queue
    step = default_step(context)
    log = default_app_logger(context)
    state = ActionStateManager.load(context, task)
    payload = task.payload

    log.info(
        "task started",
        metadata={"action": INSTRUCTION_RESULT_ACTION},
        **task_log_kwargs(task, "handle_instruction_result"),
    )

    instruction_id = coerce_optional_int(payload.get("instruction_id"), field_name="instruction_id")
    instruction_uuid = as_optional_string(payload.get("instruction_uuid"))
    remove_flag = payload.get("remove")
    result = as_optional_string(payload.get("result"))
    callback_error = as_optional_string(payload.get("error"))

    if instruction_id is None:
        _log_and_fail(
            queue=queue,
            log=log,
            state=state,
            task=task,
            action_name="handle_instruction_result",
            step_name="instruction_row_loaded",
            message="instruction_id is required",
            retry=False,
        )
        return
    if not instruction_uuid:
        _log_and_fail(
            queue=queue,
            log=log,
            state=state,
            task=task,
            action_name="handle_instruction_result",
            step_name="instruction_row_loaded",
            message="instruction_uuid is required",
            retry=False,
        )
        return
    if not isinstance(remove_flag, bool):
        _log_and_fail(
            queue=queue,
            log=log,
            state=state,
            task=task,
            action_name="handle_instruction_result",
            step_name="instruction_row_loaded",
            message="remove must be a boolean",
            retry=False,
        )
        return
    if result not in {"success", "failed"}:
        _log_and_fail(
            queue=queue,
            log=log,
            state=state,
            task=task,
            action_name="handle_instruction_result",
            step_name="instruction_row_loaded",
            message="result must be 'success' or 'failed'",
            retry=False,
        )
        return

    if not state.is_step_done("instruction_row_loaded"):
        state.begin_step("instruction_row_loaded")
        try:
            with context.connect_db() as conn:
                row = _fetch_instruction_row(conn, instruction_id)
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_instruction_result",
                step_name="instruction_row_loaded",
                message=f"failed to load instruction row {instruction_id}: {exc}",
                retry=True,
                error_code="INSTRUCTION_ROW_READ_FAILED",
                exc=exc,
            )
            return

        if row is None:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_instruction_result",
                step_name="instruction_row_loaded",
                message=f"instruction row {instruction_id} not found",
                retry=False,
            )
            return

        instruction = dict(row["instruction"])
        stored_uuid = as_optional_string(instruction.get("instruction_uuid"))
        if stored_uuid != instruction_uuid:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_instruction_result",
                step_name="instruction_row_loaded",
                message=(
                    f"instruction UUID mismatch for row {instruction_id}: "
                    f"expected {stored_uuid}, got {instruction_uuid}"
                ),
                retry=False,
                error_code="INSTRUCTION_UUID_MISMATCH",
            )
            return

        stored_remove = bool(instruction.get("remove", False))
        if stored_remove != remove_flag:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_instruction_result",
                step_name="instruction_row_loaded",
                message=f"instruction remove flag mismatch for row {instruction_id}",
                retry=False,
            )
            return

        state.checkpoint(
            "instruction_row_loaded",
            {
                "instruction_id": int(row["id"]),
                "instruction_uuid": instruction_uuid,
                "current_status": str(row["status"]),
                "remove": stored_remove,
                "instruction_dates": _normalized_dates(instruction.get("dates")),
                "reason_code": as_optional_string(instruction.get("reason_code")),
                "platform_id": int(row["platform_id"]),
                "platform_type": _normalize_platform_type(
                    ((instruction.get("chain") or {}).get("platform_type"))
                ),
                "chain": _extract_instruction_chain(instruction),
                "source_instruction_id": coerce_optional_int(
                    payload.get("source_instruction_id")
                    if payload.get("source_instruction_id") is not None
                    else instruction.get("source_instruction_id"),
                    field_name="source_instruction_id",
                ),
                "booking_entry_id": int(row["booking_entry_id"]),
                "trigger_category": str(row["trigger_category"]),
                "callback_error": callback_error,
            },
        )

    row_data = state.get_step_data("instruction_row_loaded")
    current_status = str(row_data["current_status"])
    if current_status in {"applied", "removed", "failed"}:
        result_payload = {
            "status": "noop",
            "instruction_id": int(row_data["instruction_id"]),
            "current_status": current_status,
        }
        log.info("task completed", metadata=result_payload, **task_log_kwargs(task, "handle_instruction_result"))
        queue.complete_task(task, result_payload)
        return

    if current_status != "processing":
        _log_and_fail(
            queue=queue,
            log=log,
            state=state,
            task=task,
            action_name="handle_instruction_result",
            step_name="instruction_row_loaded",
            message=f"instruction {instruction_id} is not in a mutable state (current_status={current_status})",
            retry=False,
        )
        return

    if not state.is_step_done("status_updated"):
        state.begin_step("status_updated")
        try:
            with context.connect_db() as conn:
                with conn.transaction():
                    booking_metadata_updated = False
                    dependency_failed_rows: list[Dict[str, Any]] = []
                    if result == "success" and not bool(row_data["remove"]):
                        _set_instruction_status(
                            conn,
                            instruction_id=int(row_data["instruction_id"]),
                            status="applied",
                            removed=False,
                        )
                        try:
                            _update_booking_last_extended(conn, booking_id=int(row_data["booking_entry_id"]))
                            _clear_booking_needs_scan(conn, booking_id=int(row_data["booking_entry_id"]))
                        except Exception as exc:
                            raise BookingMetadataPatchError(
                                f"failed to update booking metadata/scan flag for booking "
                                f"{row_data['booking_entry_id']}: {exc}"
                            ) from exc
                        booking_metadata_updated = True
                        new_status = "applied"
                    elif result == "success" and bool(row_data["remove"]):
                        _set_instruction_status(
                            conn,
                            instruction_id=int(row_data["instruction_id"]),
                            status="removed",
                            removed=True,
                        )
                        if row_data.get("source_instruction_id") is not None:
                            _set_source_after_removal(
                                conn,
                                source_instruction_id=int(row_data["source_instruction_id"]),
                                removal_dates=[str(value) for value in row_data.get("instruction_dates") or []],
                                removed_by_task_id=getattr(task, "task_id", None),
                            )
                        reason_code = as_optional_string(row_data.get("reason_code"))
                        if reason_code:
                            reason_policy = _get_remove_bso_reason_policy(reason_code)
                            if bool((reason_policy or {}).get("set_booking_cancelled_meta", False)):
                                try:
                                    _update_booking_bso_cancellation(conn, booking_id=int(row_data["booking_entry_id"]))
                                except Exception as exc:
                                    raise BookingMetadataPatchError(
                                        f"failed to update booking cancellation metadata for booking "
                                        f"{row_data['booking_entry_id']}: {exc}"
                                    ) from exc
                                booking_metadata_updated = True
                        new_status = "removed"
                    else:
                        _set_instruction_status(
                            conn,
                            instruction_id=int(row_data["instruction_id"]),
                            status="failed",
                            removed=False,
                        )
                        if bool(row_data["remove"]) and row_data.get("source_instruction_id") is not None:
                            _restore_source_applied(
                                conn,
                                source_instruction_id=int(row_data["source_instruction_id"]),
                            )
                        if bool(row_data["remove"]):
                            chain = row_data.get("chain") if isinstance(row_data.get("chain"), dict) else None
                            _log_chain_failure(
                                log=log,
                                task=task,
                                failure_type="rollback_failure",
                                booking_id=int(row_data["booking_entry_id"]),
                                chain_id=as_optional_string((chain or {}).get("chain_id")),
                                platform_id=int(row_data["platform_id"]),
                                platform_type=as_optional_string(
                                    row_data.get("platform_type") or (chain or {}).get("platform_type")
                                ),
                                instruction_id=int(row_data["instruction_id"]),
                                failed_step="rollback_apply",
                                error=as_optional_string(row_data.get("callback_error")),
                            )
                        if not bool(row_data["remove"]):
                            chain = row_data.get("chain") if isinstance(row_data.get("chain"), dict) else None
                            if chain is not None:
                                dependency_failed_rows = _mark_dependency_failed_chain_rows(
                                    conn,
                                    booking_entry_id=int(row_data["booking_entry_id"]),
                                    chain_id=str(chain["chain_id"]),
                                    failed_chain_position=int(chain["chain_position"]),
                                )
                                for dep in dependency_failed_rows:
                                    dep_external_task_uuid = _find_existing_external_task_uuid(
                                        conn,
                                        instruction_id=int(dep["instruction_id"]),
                                        instruction_uuid=str(dep["instruction_uuid"]),
                                    )
                                    _log_chain_failure(
                                        log=log,
                                        task=task,
                                        failure_type="dependency_failure",
                                        booking_id=int(row_data["booking_entry_id"]),
                                        chain_id=str(chain["chain_id"]),
                                        platform_id=int(dep["platform_id"]),
                                        platform_type=as_optional_string(dep.get("platform_type")),
                                        instruction_id=int(dep["instruction_id"]),
                                        external_task_uuid=dep_external_task_uuid,
                                        failed_step=f"dependency_blocked_chain_position_{int(dep['chain_position'])}",
                                        error="blocked by failed dependency",
                                    )
                                _log_chain_failure(
                                    log=log,
                                    task=task,
                                    failure_type="apply_failure",
                                    booking_id=int(row_data["booking_entry_id"]),
                                    chain_id=str(chain["chain_id"]),
                                    platform_id=int(row_data["platform_id"]),
                                    platform_type=as_optional_string(
                                        row_data.get("platform_type") or chain.get("platform_type")
                                    ),
                                    instruction_id=int(row_data["instruction_id"]),
                                    failed_step=f"apply_chain_position_{int(chain['chain_position'])}",
                                    error=as_optional_string(row_data.get("callback_error")),
                                )
                            else:
                                _log_chain_failure(
                                    log=log,
                                    task=task,
                                    failure_type="apply_failure",
                                    booking_id=int(row_data["booking_entry_id"]),
                                    chain_id=None,
                                    platform_id=int(row_data["platform_id"]),
                                    platform_type=as_optional_string(row_data.get("platform_type")),
                                    instruction_id=int(row_data["instruction_id"]),
                                    failed_step="apply_unknown_chain_position",
                                    error=as_optional_string(row_data.get("callback_error")),
                                )
                        new_status = "failed"
        except BookingMetadataPatchError as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_instruction_result",
                step_name="status_updated",
                message=str(exc),
                retry=True,
                error_code="BOOKING_METADATA_PATCH_FAILED",
                exc=exc,
            )
            return
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_instruction_result",
                step_name="status_updated",
                message=f"failed to update instruction status for row {instruction_id}: {exc}",
                retry=True,
                error_code="INSTRUCTION_STATUS_UPDATE_FAILED",
                exc=exc,
            )
            return

        state.checkpoint(
            "status_updated",
            {
                "new_status": new_status,
                "booking_metadata_updated": booking_metadata_updated,
                "dependency_failed_rows": dependency_failed_rows,
            },
        )

    status_data = state.get_step_data("status_updated")
    chain_data = row_data.get("chain") if isinstance(row_data.get("chain"), dict) else None
    should_rollback = (
        str(status_data.get("new_status")) == "failed"
        and not bool(row_data.get("remove"))
        and chain_data is not None
    )
    if should_rollback and not state.is_step_done("rollback_plan_prepared"):
        state.begin_step("rollback_plan_prepared")
        try:
            with context.connect_db() as conn:
                rollback_blueprints = _prepare_chain_rollback_blueprints(
                    conn,
                    booking_entry_id=int(row_data["booking_entry_id"]),
                    chain_id=str(chain_data["chain_id"]),
                    failed_chain_position=int(chain_data["chain_position"]),
                )
        except Exception as exc:
            _log_chain_failure(
                log=log,
                task=task,
                failure_type="rollback_failure",
                booking_id=int(row_data["booking_entry_id"]),
                chain_id=as_optional_string(chain_data.get("chain_id")),
                platform_id=int(row_data["platform_id"]),
                platform_type=as_optional_string(
                    row_data.get("platform_type") or chain_data.get("platform_type")
                ),
                instruction_id=int(row_data["instruction_id"]),
                failed_step="rollback_plan_prepared",
                error=str(exc),
            )
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_instruction_result",
                step_name="rollback_plan_prepared",
                message=f"failed to prepare rollback plan: {exc}",
                retry=True,
                error_code="ROLLBACK_PLAN_FAILED",
                exc=exc,
            )
            return

        state.checkpoint(
            "rollback_plan_prepared",
            {
                "chain_id": str(chain_data["chain_id"]),
                "failed_chain_position": int(chain_data["chain_position"]),
                "rollback_source_instruction_ids": [
                    int(item["source_instruction_id"]) for item in rollback_blueprints
                ],
                "rollback_blueprints": rollback_blueprints,
            },
        )

    if should_rollback and not state.is_step_done("rollback_tasks_enqueued"):
        rollback_plan = state.get_step_data("rollback_plan_prepared")
        rollback_blueprints = [
            dict(item)
            for item in rollback_plan.get("rollback_blueprints") or []
            if isinstance(item, dict)
        ]
        state.begin_step("rollback_tasks_enqueued")
        rollback_task_uuids: list[str] = []
        try:
            with context.connect_db() as conn:
                with conn.transaction():
                    rollback_records: list[Dict[str, Any]] = []
                    for blueprint in rollback_blueprints:
                        rollback_row = _ensure_instruction_row(
                            conn,
                            instruction=dict(blueprint["instruction"]),
                            category=str(blueprint["category"]),
                            applied_by_task_id=getattr(task, "task_id", None),
                        )
                        rollback_records.append(
                            {
                                **blueprint,
                                "instruction_id": int(rollback_row["instruction_id"]),
                                "instruction_uuid": str(rollback_row["instruction_uuid"]),
                                "instruction": dict(rollback_row["instruction"]),
                                "source_instruction_id": coerce_optional_int(
                                    rollback_row.get("source_instruction_id"),
                                    field_name="source_instruction_id",
                                ),
                            }
                        )

                previous_rollback_task_uuid: Optional[str] = None
                for rollback_record in rollback_records:
                    task_uuid = _find_existing_external_task_uuid(
                        conn,
                        instruction_id=int(rollback_record["instruction_id"]),
                        instruction_uuid=str(rollback_record["instruction_uuid"]),
                    )
                    if task_uuid is None:
                        task_uuid = enqueue_with_meta(
                            context.queue(EXTERNAL_SERVICES_QUEUE),
                            EXTERNAL_SERVICES_WORKER,
                            _external_task_payload(rollback_record),
                            current_task=task,
                            current_worker=WORKER,
                            current_action=INSTRUCTION_RESULT_ACTION,
                            next_worker=EXTERNAL_SERVICES_WORKER,
                            next_action=PROCESS_INSTRUCTION_ACTION,
                        )
                    if task_uuid:
                        if previous_rollback_task_uuid:
                            context.scheduler.add_task_dependencies(task_uuid, [previous_rollback_task_uuid])
                        rollback_task_uuids.append(str(task_uuid))
                        previous_rollback_task_uuid = str(task_uuid)
        except Exception as exc:
            _log_chain_failure(
                log=log,
                task=task,
                failure_type="rollback_failure",
                booking_id=int(row_data["booking_entry_id"]),
                chain_id=as_optional_string((chain_data or {}).get("chain_id")),
                platform_id=int(row_data["platform_id"]),
                platform_type=as_optional_string(
                    row_data.get("platform_type") or (chain_data or {}).get("platform_type")
                ),
                instruction_id=int(row_data["instruction_id"]),
                failed_step="rollback_tasks_enqueued",
                error=str(exc),
            )
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_instruction_result",
                step_name="rollback_tasks_enqueued",
                message=f"failed to enqueue rollback tasks: {exc}",
                retry=True,
                error_code="ROLLBACK_ENQUEUE_FAILED",
                exc=exc,
            )
            return

        state.checkpoint("rollback_tasks_enqueued", {"rollback_task_uuids": rollback_task_uuids})

    result_payload = {
        "status": str(status_data["new_status"]),
        "instruction_id": int(row_data["instruction_id"]),
        "instruction_uuid": str(row_data["instruction_uuid"]),
    }
    dependency_failed_rows = [
        dict(item)
        for item in status_data.get("dependency_failed_rows") or []
        if isinstance(item, dict)
    ]
    if dependency_failed_rows:
        result_payload["dependency_failed_instruction_ids"] = [
            int(item["instruction_id"]) for item in dependency_failed_rows
        ]
    if should_rollback:
        rollback_task_uuids = [
            str(value)
            for value in state.get_step_data("rollback_tasks_enqueued").get("rollback_task_uuids") or []
            if value
        ]
        result_payload["rollback_task_uuids"] = rollback_task_uuids
    step.log("booking special operation callback processed", result_payload)
    log.info("task completed", metadata=result_payload, **task_log_kwargs(task, "handle_instruction_result"))
    queue.complete_task(task, result_payload)


def handle_task(context: ManagedWorkerContext, task) -> None:
    normalize_payload_meta(task.payload)
    action = as_optional_string(task.payload.get("action"))
    if action == POTENTIAL_EXTENSION_ACTION or action in LEGACY_CATEGORY_ACTION_ALIASES:
        handle_generate_class_rule_insturction(context, task)
        return
    if action == REMOVE_BSO_ACTION:
        handle_remove_bso(context, task)
        return
    if action == INSTRUCTION_RESULT_ACTION:
        handle_instruction_result(context, task)
        return
    context.main_queue.fail_task(task, f"Unexpected action {action}", retry=False)


def run_task(context: ManagedWorkerContext, task) -> None:
    handle_task(context, task)


def main() -> None:
    args = parse_args()
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
            "booking special operation worker started",
            metadata={
                "worker_id": scheduler.worker_id,
                "primary_queue": PRIMARY_QUEUE,
                "subscribed_queues": list(SUBSCRIBED_QUEUES),
                "supported_actions": list(SUPPORTED_ACTIONS),
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
            logger.exception("booking special operation worker failed")
        else:
            app_logger.error("booking special operation worker failed", exc=exc, action_name="worker_runtime")
        raise SystemExit(1)
    finally:
        if scheduler is not None:
            if not isinstance(app_logger, NullAppLogger):
                app_logger.info("booking special operation worker shutting down", action_name="worker_shutdown")
            try:
                scheduler.state_manager.shutdown()
            except Exception as exc:
                if isinstance(app_logger, NullAppLogger):
                    logger.exception("booking special operation worker clean shutdown checkpoint failed")
                else:
                    app_logger.error(
                        "booking special operation worker clean shutdown checkpoint failed",
                        exc=exc,
                        action_name="worker_shutdown",
                    )
            try:
                app_logger.close()
            except Exception:
                logger.exception("booking special operation worker app logger close failed")
            scheduler.close()


if __name__ == "__main__":
    main()
