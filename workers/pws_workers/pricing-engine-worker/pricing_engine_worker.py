#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Dict, Optional, Sequence
from uuid import uuid4

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
    delete_runtime_variable,
    enqueue_with_meta,
    generate_key,
    get_booking_id,
    get_runtime_variable,
    parse_runtime_variable_ttl_config,
    resolve_runtime_variable_ttl,
    set_runtime_variable,
    task_log_kwargs,
)


WORKER = "pricing-engine-worker"
PRIMARY_QUEUE = "pricing-engine"
SUBSCRIBED_QUEUES: Sequence[str] = (PRIMARY_QUEUE,)
SUPPORTED_ACTIONS = ("get_cat_rule",)

GET_CAT_RULE_ACTION = "get_cat_rule"
BOOKING_SPECIAL_OPERATION_WORKER = "booking-special-operation-worker"
BOOKING_SPECIAL_OPERATION_QUEUE = "booking-special-operation"
BOOKING_SPECIAL_OPERATION_ACTION = "generate_class_rule_insturction"
LONGER_STAY_CATEGORY = "longer_stay"
RUNTIME_SCOPE_PLAN = "pricing-engine-plan"
RUNTIME_TTL_MINUTES = 60
RUNTIME_VARIABLE_TTL_CONFIG: Optional[Dict[str, Any]] = None
_PLATFORM_PROPERTY_LOOKUP_LISTING_COLUMN: Optional[str] = None
_GET_RULES_SUPPORTS_STAY_PARAMS: Optional[bool] = None
_GET_RULES_SUPPORTS_STAY_ADJUSTMENT_PARAMS: Optional[bool] = None
_GET_RULES_SUPPORTS_CLASS_POSITION_PARAMS: Optional[bool] = None
SUPPORTED_TARGET_RATE_TYPES = {"base", "recommended", "minimum", "maximum"}


def _normalize_target_rate_type(value: Any, *, default: str = "base") -> str:
    normalized = (as_optional_string(value) or "").strip().lower()
    if normalized in SUPPORTED_TARGET_RATE_TYPES:
        return normalized
    return default


def _canonicalize_operation_code(value: Any) -> Optional[str]:
    operation_code = as_optional_string(value)
    if operation_code == "override":
        return "set"
    return operation_code


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Pricing-engine worker")
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


def _normalize_booking_id(payload: Dict[str, Any]) -> Optional[int]:
    booking_id = get_booking_id(payload, required=False)
    if booking_id is not None:
        return booking_id
    booking_obj = payload.get("booking") if isinstance(payload.get("booking"), dict) else {}
    return coerce_optional_int(booking_obj.get("booking_entry_id"), field_name="booking.booking_entry_id")


def _normalize_categories(payload: Dict[str, Any]) -> list[str]:
    raw_categories = payload.get("categories")
    if not isinstance(raw_categories, list) or not raw_categories:
        raise ValueError("categories must be a non-empty array of strings")
    categories: list[str] = []
    for index, raw_value in enumerate(raw_categories):
        category = as_optional_string(raw_value)
        if not category:
            raise ValueError(f"categories[{index}] must be a non-empty string")
        categories.append(category)
    return categories


def _normalize_string_list(raw_values: Any) -> list[str]:
    if not isinstance(raw_values, list):
        return []
    values: list[str] = []
    for raw_value in raw_values:
        value = as_optional_string(raw_value)
        if value:
            values.append(value)
    return sorted(set(values))


def _normalize_booking_context(payload: Dict[str, Any]) -> Dict[str, Any]:
    raw_context = payload.get("booking_context")
    return dict(raw_context) if isinstance(raw_context, dict) else {}


def _coerce_stay_delta_value(value: Any, *, field_name: str) -> Optional[int]:
    if isinstance(value, list):
        total = 0
        for item in value:
            if isinstance(item, bool):
                continue
            try:
                total += int(item)
            except (TypeError, ValueError):
                continue
        return total
    return coerce_optional_int(value, field_name=field_name)


def _normalize_pair(raw_pair: Any, *, field_name: str) -> Dict[str, Any]:
    if not isinstance(raw_pair, dict):
        raise ValueError(f"{field_name} is required")

    platform_id = coerce_optional_int(raw_pair.get("platform_id"), field_name=f"{field_name}.platform_id")
    if platform_id is None:
        raise ValueError(f"{field_name}.platform_id is required")

    listing_id = as_optional_string(raw_pair.get("listing_id")) or as_optional_string(raw_pair.get("platform_property_id"))
    if not listing_id:
        raise ValueError(f"{field_name}.listing_id is required")

    pair: Dict[str, Any] = {
        "platform_id": int(platform_id),
        "listing_id": listing_id,
    }

    lookup_id = coerce_optional_int(
        raw_pair.get("platform_property_lookup_id"),
        field_name=f"{field_name}.platform_property_lookup_id",
    )
    if lookup_id is not None:
        pair["platform_property_lookup_id"] = int(lookup_id)

    platform_name = as_optional_string(raw_pair.get("platform_name"))
    if platform_name:
        pair["platform_name"] = platform_name

    platform_type = as_optional_string(raw_pair.get("platform_type"))
    if platform_type:
        pair["platform_type"] = platform_type

    linked_from_platform_id = coerce_optional_int(
        raw_pair.get("linked_from_platform_id"),
        field_name=f"{field_name}.linked_from_platform_id",
    )
    if linked_from_platform_id is not None:
        pair["linked_from_platform_id"] = int(linked_from_platform_id)

    if isinstance(raw_pair.get("is_canonical"), bool):
        pair["is_canonical"] = bool(raw_pair.get("is_canonical"))

    return pair


def _normalize_platform_type(value: Any) -> Optional[str]:
    platform_type = as_optional_string(value)
    if not platform_type:
        return None
    normalized = platform_type.strip().lower()
    if normalized == "otp":
        normalized = "ota"
    return normalized


def _pair_is_same_listing(left: Dict[str, Any], right: Dict[str, Any]) -> bool:
    return int(left["platform_id"]) == int(right["platform_id"]) and str(left["listing_id"]) == str(right["listing_id"])


def _derive_platform_type(*, pair: Dict[str, Any], canonical_pair: Dict[str, Any]) -> str:
    pair_platform_type = _normalize_platform_type(pair.get("platform_type"))
    if pair_platform_type:
        return pair_platform_type
    if _pair_is_same_listing(pair, canonical_pair):
        return "pms"
    return "ota"


def _normalize_canonical_pair(payload: Dict[str, Any]) -> Dict[str, Any]:
    return _normalize_pair(payload.get("canonical_pair"), field_name="canonical_pair")


def _normalize_platform_pairs(payload: Dict[str, Any]) -> list[Dict[str, Any]]:
    raw_pairs = payload.get("platform_pairs")
    if isinstance(raw_pairs, list) and raw_pairs:
        pairs: list[Dict[str, Any]] = []
        for index, raw_pair in enumerate(raw_pairs):
            pairs.append(_normalize_pair(raw_pair, field_name=f"platform_pairs[{index}]"))
        return pairs

    if isinstance(payload.get("platform_pair"), dict):
        return [_normalize_pair(payload.get("platform_pair"), field_name="platform_pair")]

    raise ValueError("platform_pairs is required and must be a non-empty array")


def _resolve_platform_property_lookup_listing_column(conn) -> str:
    global _PLATFORM_PROPERTY_LOOKUP_LISTING_COLUMN
    if _PLATFORM_PROPERTY_LOOKUP_LISTING_COLUMN is not None:
        return _PLATFORM_PROPERTY_LOOKUP_LISTING_COLUMN

    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT column_name
            FROM information_schema.columns
            WHERE table_schema = 'public'
              AND table_name = 'platform_property_lookup'
              AND column_name IN ('listing_id', 'platform_property_id')
            ORDER BY CASE column_name WHEN 'listing_id' THEN 0 ELSE 1 END
            LIMIT 1
            """
        )
        row = cur.fetchone()

    column_name = as_optional_string(row[0] if row else None)
    if column_name is None:
        raise ValueError("platform_property_lookup listing identifier column is missing")

    _PLATFORM_PROPERTY_LOOKUP_LISTING_COLUMN = column_name
    return column_name


def _fetch_booking(conn, booking_id: int) -> Optional[Dict[str, Any]]:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT id, property_id, platform_id, ppl_id, arrival, departure, booked_at, metadata
            FROM booking_registers
            WHERE id = %s
            LIMIT 1
            """,
            (booking_id,),
        )
        row = cur.fetchone()
    if row is None:
        return None
    metadata = _normalize_json(row[7]) if row[7] is not None else {}
    if not isinstance(metadata, dict):
        metadata = {}
    return {
        "booking_id": int(row[0]),
        "property_id": int(row[1]),
        "platform_id": int(row[2]),
        "ppl_id": int(row[3]),
        "arrival": row[4],
        "departure": row[5],
        "booked_at": row[6],
        "metadata": metadata,
    }


def _resolve_lookup_id_for_pair(conn, *, property_id: int, pair: Dict[str, Any]) -> int:
    lookup_id = coerce_optional_int(
        pair.get("platform_property_lookup_id"),
        field_name="platform_pair.platform_property_lookup_id",
    )
    if lookup_id is not None:
        return int(lookup_id)

    listing_column = _resolve_platform_property_lookup_listing_column(conn)
    sql = f"""
        SELECT id
        FROM platform_property_lookup
        WHERE properties_ptr = %s
          AND platform_id = %s
          AND {listing_column} = %s
        LIMIT 1
    """
    with conn.cursor() as cur:
        cur.execute(
            sql,
            (
                int(property_id),
                int(pair["platform_id"]),
                str(pair["listing_id"]),
            ),
        )
        row = cur.fetchone()

    if row is None or row[0] is None:
        raise LookupError(
            "platform_property_lookup row not found for property_id="
            f"{property_id}, platform_id={pair['platform_id']}, "
            f"listing_id={pair['listing_id']}"
        )
    return int(row[0])


def _normalize_json(value: Any) -> Any:
    if isinstance(value, str):
        return json.loads(value)
    return value


def _get_rules_supports_stay_params(conn) -> bool:
    global _GET_RULES_SUPPORTS_STAY_PARAMS
    if _GET_RULES_SUPPORTS_STAY_PARAMS is not None:
        return bool(_GET_RULES_SUPPORTS_STAY_PARAMS)

    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT EXISTS(
                SELECT 1
                FROM pg_proc
                WHERE proname = 'get_applicable_pricing_rules'
                  AND proargnames IS NOT NULL
                  AND %s = ANY(proargnames)
            )
            """,
            ("p_stay_length",),
        )
        row = cur.fetchone()
    _GET_RULES_SUPPORTS_STAY_PARAMS = bool(row and row[0])
    return bool(_GET_RULES_SUPPORTS_STAY_PARAMS)


def _get_rules_supports_stay_adjustment_params(conn) -> bool:
    global _GET_RULES_SUPPORTS_STAY_ADJUSTMENT_PARAMS
    if _GET_RULES_SUPPORTS_STAY_ADJUSTMENT_PARAMS is not None:
        return bool(_GET_RULES_SUPPORTS_STAY_ADJUSTMENT_PARAMS)

    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT EXISTS(
                SELECT 1
                FROM pg_proc
                WHERE proname = 'get_applicable_pricing_rules'
                  AND proargnames IS NOT NULL
                  AND %s = ANY(proargnames)
                  AND %s = ANY(proargnames)
            )
            """,
            ("p_stay_extended", "p_stay_contracted"),
        )
        row = cur.fetchone()
    _GET_RULES_SUPPORTS_STAY_ADJUSTMENT_PARAMS = bool(row and row[0])
    return bool(_GET_RULES_SUPPORTS_STAY_ADJUSTMENT_PARAMS)


def _get_rules_supports_class_position_params(conn) -> bool:
    global _GET_RULES_SUPPORTS_CLASS_POSITION_PARAMS
    if _GET_RULES_SUPPORTS_CLASS_POSITION_PARAMS is not None:
        return bool(_GET_RULES_SUPPORTS_CLASS_POSITION_PARAMS)

    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT EXISTS(
                SELECT 1
                FROM pg_proc
                WHERE proname = 'get_applicable_pricing_rules'
                  AND proargnames IS NOT NULL
                  AND %s = ANY(proargnames)
            )
            """,
            ("p_booking_class_positions",),
        )
        row = cur.fetchone()
    _GET_RULES_SUPPORTS_CLASS_POSITION_PARAMS = bool(row and row[0])
    return bool(_GET_RULES_SUPPORTS_CLASS_POSITION_PARAMS)


def _extract_booking_class_positions(booking_context: Dict[str, Any]) -> Dict[str, list[int]]:
    """Build a class -> sorted unique positions map from booking_context."""

    position_map: dict[str, set[int]] = {}

    def add_pair(raw_class: Any, raw_pos: Any) -> None:
        class_name = as_optional_string(raw_class)
        if not class_name or raw_pos is None or raw_pos == "":
            return
        try:
            position = int(raw_pos)
        except (TypeError, ValueError):
            return
        if position < 0:
            return
        position_map.setdefault(class_name, set()).add(position)

    def add_aligned(raw_classes: Any, raw_positions: Any) -> None:
        if not isinstance(raw_classes, list) or not isinstance(raw_positions, list):
            return
        for raw_class, raw_pos in zip(raw_classes, raw_positions):
            add_pair(raw_class, raw_pos)

    # Backward-compatible top-level shape, useful for tests and simple callers.
    add_aligned(booking_context.get("classes"), booking_context.get("class_pos"))

    # Preferred shape produced by check_classification / bso_start_chain.
    raw_thread_details = booking_context.get("thread_class_details")
    if isinstance(raw_thread_details, list):
        for detail in raw_thread_details:
            if not isinstance(detail, dict):
                continue
            add_aligned(detail.get("classes"), detail.get("class_pos"))

    return {class_name: sorted(positions) for class_name, positions in sorted(position_map.items()) if positions}


def _fetch_applicable_rules(
    conn,
    *,
    property_id: int,
    platform_id: int,
    arrival_date: Any,
    departure_date: Any,
    platform_property_lookup_id: int,
    stay_length: Optional[int],
    stay_extended: Optional[int],
    stay_contracted: Optional[int],
    booking_classes: Sequence[str],
    booking_class_positions: Optional[Dict[str, list[int]]],
    supports_stay_params: bool,
    supports_stay_adjustment_params: bool,
    supports_class_position_params: bool,
) -> list[Dict[str, Any]]:
    normalized_classes = [str(value) for value in booking_classes if as_optional_string(value)]
    booking_classes_param = normalized_classes if normalized_classes else None
    booking_class_positions_param = json.dumps(booking_class_positions or {}, default=str)

    with conn.cursor() as cur:
        if supports_class_position_params:
            cur.execute(
                """
                SELECT rule_id, rule_uuid, operation_code, priority, scope, rule_json
                FROM get_applicable_pricing_rules(
                    p_property_id => %s,
                    p_platform_id => %s,
                    p_target_date => %s,
                    p_operation_code => NULL,
                    p_check_gaps => TRUE,
                    p_platform_property_lookup_id => %s,
                    p_stay_length => %s,
                    p_booking_classes => %s::text[],
                    p_stay_extended => %s,
                    p_stay_contracted => %s,
                    p_arrival_date => %s,
                    p_departure_date => %s,
                    p_booking_class_positions => %s::jsonb
                )
                """,
                (
                    int(property_id),
                    int(platform_id),
                    departure_date,
                    int(platform_property_lookup_id),
                    stay_length,
                    booking_classes_param,
                    stay_extended,
                    stay_contracted,
                    arrival_date,
                    departure_date,
                    booking_class_positions_param,
                ),
            )
        elif supports_stay_adjustment_params:
            cur.execute(
                """
                SELECT rule_id, rule_uuid, operation_code, priority, scope, rule_json
                FROM get_applicable_pricing_rules(
                    p_property_id => %s,
                    p_platform_id => %s,
                    p_target_date => %s,
                    p_operation_code => NULL,
                    p_check_gaps => TRUE,
                    p_platform_property_lookup_id => %s,
                    p_stay_length => %s,
                    p_booking_classes => %s::text[],
                    p_stay_extended => %s,
                    p_stay_contracted => %s
                )
                """,
                (
                    int(property_id),
                    int(platform_id),
                    departure_date,
                    int(platform_property_lookup_id),
                    stay_length,
                    booking_classes_param,
                    stay_extended,
                    stay_contracted,
                ),
            )
        elif supports_stay_params:
            cur.execute(
                """
                SELECT rule_id, rule_uuid, operation_code, priority, scope, rule_json
                FROM get_applicable_pricing_rules(
                    p_property_id => %s,
                    p_platform_id => %s,
                    p_target_date => %s,
                    p_operation_code => NULL,
                    p_check_gaps => TRUE,
                    p_platform_property_lookup_id => %s,
                    p_stay_length => %s,
                    p_booking_classes => %s::text[]
                )
                """,
                (
                    int(property_id),
                    int(platform_id),
                    departure_date,
                    int(platform_property_lookup_id),
                    stay_length,
                    booking_classes_param,
                ),
            )
        else:
            cur.execute(
                """
                SELECT rule_id, rule_uuid, operation_code, priority, scope, rule_json
                FROM get_applicable_pricing_rules(%s, %s, %s, NULL, TRUE, %s)
                """,
                (
                    int(property_id),
                    int(platform_id),
                    departure_date,
                    int(platform_property_lookup_id),
                ),
            )
        rows = cur.fetchall() or []

    rules: list[Dict[str, Any]] = []
    for row in rows:
        rules.append(
            {
                "rule_id": int(row[0]),
                "rule_uuid": str(row[1]),
                "operation_code": as_optional_string(row[2]),
                "priority": int(row[3]) if row[3] is not None else 0,
                "scope": as_optional_string(row[4]) or "global",
                "rule_json": _normalize_json(row[5]) if row[5] is not None else {},
            }
        )
    return rules


def _fetch_rule_hydrated(conn, *, rule_id: int) -> Optional[Dict[str, Any]]:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT pr.rule_uuid, pot.operation_code, pr.priority, pr.scope, pr.rule_config
            FROM pricing_rules pr
            JOIN pricing_operation_types pot ON pot.id = pr.operation_id
            WHERE pr.id = %s
            LIMIT 1
            """,
            (int(rule_id),),
        )
        row = cur.fetchone()
    if row is None:
        return None
    return {
        "rule_uuid": str(row[0]),
        "operation_code": as_optional_string(row[1]),
        "priority": int(row[2]) if row[2] is not None else 0,
        "scope": as_optional_string(row[3]) or "global",
        "rule_config": _normalize_json(row[4]) if row[4] is not None else {},
    }


def _walk_condition_tree(node: Any) -> list[Dict[str, Any]]:
    if not isinstance(node, dict):
        return []

    node_type = as_optional_string(node.get("type"))
    if node_type:
        node_type = node_type.lower()
    if node_type == "condition":
        return [node]
    if node_type != "group":
        return []

    members = node.get("members")
    if not isinstance(members, list):
        return []

    conditions: list[Dict[str, Any]] = []
    for member in members:
        conditions.extend(_walk_condition_tree(member))
    return conditions


def _extract_condition_value_strings(raw_values: Any) -> list[str]:
    if not isinstance(raw_values, list):
        return []
    values: list[str] = []
    for raw_value in raw_values:
        value = as_optional_string(raw_value)
        if value:
            values.append(value)
    return values


def _extract_categories_from_condition_tree(rule_config: Any) -> list[str]:
    if not isinstance(rule_config, dict):
        return []

    categories: list[str] = []
    for node in _walk_condition_tree(rule_config.get("condition_tree")):
        condition_name = as_optional_string(node.get("condition_name"))
        operator = as_optional_string(node.get("comparison_operator"))
        if condition_name:
            condition_name = condition_name.lower()
        if operator:
            operator = operator.lower()
        if condition_name not in ("booking_category", "booking_class"):
            continue
        if operator not in ("any_of", "all_of"):
            continue
        categories.extend(_extract_condition_value_strings(node.get("value")))
    return categories


def _extract_categories_from_rule_config(rule_config: Any) -> list[str]:
    if not isinstance(rule_config, dict):
        return []

    categories: list[str] = []
    conditions = rule_config.get("conditions")
    if isinstance(conditions, dict):
        booking_category = conditions.get("booking_category")
        if isinstance(booking_category, dict):
            categories.extend(_extract_condition_value_strings(booking_category.get("in")))
            categories.extend(_extract_condition_value_strings(booking_category.get("any_of")))

        booking_class = conditions.get("booking_class")
        if isinstance(booking_class, dict):
            categories.extend(_extract_condition_value_strings(booking_class.get("any_of")))
            categories.extend(_extract_condition_value_strings(booking_class.get("all_of")))

    categories.extend(_extract_categories_from_condition_tree(rule_config))

    seen: set[str] = set()
    ordered: list[str] = []
    for category in categories:
        if category not in seen:
            ordered.append(category)
            seen.add(category)
    return ordered


def _condition_tree_has_any_condition(rule_config: Any, condition_names: set[str]) -> bool:
    if not isinstance(rule_config, dict):
        return False
    for node in _walk_condition_tree(rule_config.get("condition_tree")):
        condition_name = as_optional_string(node.get("condition_name"))
        if condition_name and condition_name.lower() in condition_names:
            return True
    return False


def _has_stay_length_condition(rule_config: Any) -> bool:
    if not isinstance(rule_config, dict):
        return False
    conditions = rule_config.get("conditions")
    if isinstance(conditions, dict):
        stay_length = conditions.get("stay_length")
        if isinstance(stay_length, dict) and bool(stay_length):
            return True
    return _condition_tree_has_any_condition(rule_config, {"stay_length"})


def _has_stay_adjustment_condition(rule_config: Any) -> bool:
    if not isinstance(rule_config, dict):
        return False
    return any(
        key in rule_config for key in ("stay_length", "stay_extended", "stay_contracted", "net_stay")
    ) or _condition_tree_has_any_condition(
        rule_config,
        {"stay_length", "stay_extended", "stay_contracted", "net_stay"},
    )


def _selectable_rule_config(rule_config: Any) -> bool:
    return bool(
        _extract_categories_from_rule_config(rule_config)
        or _has_stay_length_condition(rule_config)
        or _has_stay_adjustment_condition(rule_config)
    )


def _canonicalize_rule_config(rule_config: Any, *, operation_code: Optional[str]) -> Dict[str, Any]:
    if not isinstance(rule_config, dict):
        return {}

    normalized = dict(rule_config)
    operation = normalized.get("operation")
    if not isinstance(operation, dict):
        if operation_code == "set":
            normalized["operation"] = {
                "type": "fixed",
                "do": "set",
                "target_rate_type": "base",
            }
        return normalized

    normalized_operation = dict(operation)
    operation_type = as_optional_string(normalized_operation.get("type"))
    if operation_type == "override":
        normalized_operation["type"] = "fixed"
    elif operation_type is None and operation_code == "set":
        normalized_operation["type"] = "fixed"

    operation_do = as_optional_string(normalized_operation.get("do"))
    if operation_do == "override":
        normalized_operation["do"] = "set"
    elif operation_do is None and operation_code == "set":
        normalized_operation["do"] = "set"

    normalized_operation["target_rate_type"] = _normalize_target_rate_type(
        normalized_operation.get("target_rate_type"),
        default="base",
    )

    normalized["operation"] = normalized_operation
    return normalized


def _derive_rule_config(rule_json: Any) -> Dict[str, Any]:
    if not isinstance(rule_json, dict):
        return {}

    if isinstance(rule_json.get("rule_config"), dict):
        return dict(rule_json["rule_config"])

    rule_config: Dict[str, Any] = {}
    for field in ("subject", "operation", "apply_window", "conditions", "conditions_version", "condition_tree", "metadata"):
        value = rule_json.get(field)
        if value is not None:
            rule_config[field] = value
    return rule_config


def _build_rule_payload(row: Dict[str, Any], hydrated: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    rule_config = _derive_rule_config(row.get("rule_json"))
    hydrated_config = hydrated.get("rule_config") if isinstance(hydrated, dict) else None
    if not _selectable_rule_config(rule_config) and isinstance(hydrated_config, dict):
        rule_config = dict(hydrated_config)
    elif isinstance(hydrated_config, dict):
        rule_config = {**dict(hydrated_config), **rule_config}

    operation_code = _canonicalize_operation_code(row.get("operation_code")) or _canonicalize_operation_code(
        (hydrated or {}).get("operation_code")
    )
    rule_config = _canonicalize_rule_config(rule_config, operation_code=operation_code)

    return {
        "rule_uuid": as_optional_string(row.get("rule_uuid"))
        or as_optional_string((hydrated or {}).get("rule_uuid")),
        "operation_code": operation_code or "increase",
        "priority": int(row.get("priority") if row.get("priority") is not None else (hydrated or {}).get("priority") or 0),
        "scope": as_optional_string(row.get("scope")) or as_optional_string((hydrated or {}).get("scope")) or "global",
        "rule_config": rule_config,
    }


def _select_pair_rule(
    conn,
    *,
    property_id: int,
    departure_date: Any,
    categories: Sequence[str],
    pair: Dict[str, Any],
    lookup_id: int,
    arrival_date: Any = None,
    stay_length: Optional[int] = None,
    stay_extended: Optional[int] = None,
    stay_contracted: Optional[int] = None,
    booking_classes: Sequence[str] = (),
    booking_class_positions: Optional[Dict[str, list[int]]] = None,
) -> Optional[Dict[str, Any]]:
    supports_stay_params = _get_rules_supports_stay_params(conn)
    supports_stay_adjustment_params = _get_rules_supports_stay_adjustment_params(conn)
    supports_class_position_params = _get_rules_supports_class_position_params(conn)
    rules = _fetch_applicable_rules(
        conn,
        property_id=property_id,
        platform_id=int(pair["platform_id"]),
        arrival_date=arrival_date,
        departure_date=departure_date,
        platform_property_lookup_id=int(lookup_id),
        stay_length=stay_length,
        stay_extended=stay_extended,
        stay_contracted=stay_contracted,
        booking_classes=booking_classes,
        booking_class_positions=booking_class_positions,
        supports_stay_params=supports_stay_params,
        supports_stay_adjustment_params=supports_stay_adjustment_params,
        supports_class_position_params=supports_class_position_params,
    )

    for row in rules:
        hydrated: Optional[Dict[str, Any]] = None
        rule_config = _derive_rule_config(row.get("rule_json"))
        rule_categories = _extract_categories_from_rule_config(rule_config)
        has_stay_length_condition = _has_stay_length_condition(rule_config)
        has_stay_adjustment_condition = _has_stay_adjustment_condition(rule_config)
        if not rule_categories and not has_stay_length_condition and not has_stay_adjustment_condition:
            hydrated = _fetch_rule_hydrated(conn, rule_id=int(row["rule_id"]))
            hydrated_config = (hydrated or {}).get("rule_config")
            rule_categories = _extract_categories_from_rule_config(hydrated_config)
            has_stay_length_condition = _has_stay_length_condition(hydrated_config)
            has_stay_adjustment_condition = _has_stay_adjustment_condition(hydrated_config)
            if not rule_categories and not has_stay_length_condition and not has_stay_adjustment_condition:
                continue

        if has_stay_length_condition and not supports_stay_params:
            continue

        if has_stay_adjustment_condition and not supports_stay_adjustment_params:
            continue

        if has_stay_length_condition or has_stay_adjustment_condition:
            rule = _build_rule_payload(row, hydrated)
            if not as_optional_string(rule.get("rule_uuid")):
                continue
            return {"matched_category": LONGER_STAY_CATEGORY, "rule": rule}

        matched_category = next((category for category in categories if category in rule_categories), None)
        if not matched_category:
            continue

        rule = _build_rule_payload(row, hydrated)
        if not as_optional_string(rule.get("rule_uuid")):
            continue
        return {"matched_category": matched_category, "rule": rule}
    return None


def _pending_after_cursor(items: list[Dict[str, Any]], cursor: Optional[Any]) -> tuple[list[Dict[str, Any]], int]:
    if cursor is None:
        return list(items), 0

    cursor_value = coerce_optional_int(cursor, field_name="progress.last_processed_id")
    if cursor_value is None:
        return list(items), 0

    processed = 0
    pending: list[Dict[str, Any]] = []
    skipping = True
    for item in items:
        platform_pair = item.get("platform_pair") if isinstance(item.get("platform_pair"), dict) else {}
        current_platform_id = coerce_optional_int(platform_pair.get("platform_id"), field_name="platform_pair.platform_id")
        if skipping:
            processed += 1
            if current_platform_id == cursor_value:
                skipping = False
            continue
        pending.append(item)

    if skipping:
        return [], len(items)
    return pending, processed


def _pair_identity(pair: Dict[str, Any]) -> tuple[int, str]:
    return int(pair["platform_id"]), str(pair["listing_id"])


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


def handle_get_cat_rule(context: ManagedWorkerContext, task) -> None:
    queue = context.main_queue
    step = default_step(context)
    log = default_app_logger(context)
    state = ActionStateManager.load(context, task)
    payload = task.payload

    log.info(
        "task started",
        metadata={"action": GET_CAT_RULE_ACTION},
        **task_log_kwargs(task, "handle_get_cat_rule"),
    )

    try:
        booking_id = _normalize_booking_id(payload)
        categories = _normalize_categories(payload)
        canonical_pair = _normalize_canonical_pair(payload)
        platform_pairs = _normalize_platform_pairs(payload)
        booking_context = _normalize_booking_context(payload)
    except ValueError as exc:
        _log_and_fail(
            queue=queue,
            log=log,
            state=state,
            task=task,
            action_name="handle_get_cat_rule",
            step_name="booking_loaded",
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
            action_name="handle_get_cat_rule",
            step_name="booking_loaded",
            message="booking_id is required",
            retry=False,
        )
        return

    booking_data: Dict[str, Any]
    if not state.is_step_done("booking_loaded"):
        state.begin_step("booking_loaded")
        try:
            with context.connect_db() as conn:
                booking = _fetch_booking(conn, int(booking_id))
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_get_cat_rule",
                step_name="booking_loaded",
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
                action_name="handle_get_cat_rule",
                step_name="booking_loaded",
                message=f"booking {booking_id} not found",
                retry=False,
                error_code="BOOKING_NOT_FOUND",
            )
            return

        metadata = booking.get("metadata") if isinstance(booking.get("metadata"), dict) else {}
        context_stay_length = coerce_optional_int(
            booking_context.get("stay_length"),
            field_name="booking_context.stay_length",
        )
        if context_stay_length is None:
            context_stay_length = coerce_optional_int(metadata.get("stay_length"), field_name="metadata.stay_length")
        context_stay_extended = _coerce_stay_delta_value(
            booking_context.get("stay_extended"),
            field_name="booking_context.stay_extended",
        )
        if context_stay_extended is None:
            context_stay_extended = _coerce_stay_delta_value(
                metadata.get("stay_extended"),
                field_name="metadata.stay_extended",
            )
        context_stay_contracted = _coerce_stay_delta_value(
            booking_context.get("stay_contracted"),
            field_name="booking_context.stay_contracted",
        )
        if context_stay_contracted is None:
            context_stay_contracted = _coerce_stay_delta_value(
                metadata.get("stay_contracted"),
                field_name="metadata.stay_contracted",
            )

        booking_classes = _normalize_string_list(booking_context.get("classes"))
        if not booking_classes:
            booking_classes = list(categories)
        booking_class_positions = _extract_booking_class_positions(booking_context)
        stay_length = context_stay_length
        stay_extended = context_stay_extended
        stay_contracted = context_stay_contracted

        normalized_booking_context = {
            **dict(booking_context),
            "booking_id": int(booking["booking_id"]),
            "booking_entry_id": int(booking["booking_id"]),
            "property_id": int(booking["property_id"]),
            "platform_id": int(booking["platform_id"]),
            "ppl_id": int(booking["ppl_id"]),
            "arrival": as_optional_string(booking_context.get("arrival")) or booking["arrival"].isoformat(),
            "departure": as_optional_string(booking_context.get("departure")) or booking["departure"].isoformat(),
            "booked_at": as_optional_string(booking_context.get("booked_at")) or booking["booked_at"].isoformat(),
            "stay_length": context_stay_length,
            "booking_window": coerce_optional_int(
                booking_context.get("booking_window"),
                field_name="booking_context.booking_window",
            )
            if booking_context.get("booking_window") is not None
            else coerce_optional_int(metadata.get("booking_window"), field_name="metadata.booking_window"),
            "classes": list(booking_classes),
            "booking_class_positions": booking_class_positions,
            "stay_extended": context_stay_extended,
            "stay_contracted": context_stay_contracted,
        }
        booking_context = normalized_booking_context

        booking_data = {
            "booking_id": int(booking["booking_id"]),
            "property_id": int(booking["property_id"]),
            "arrival": booking["arrival"],
            "departure": booking["departure"],
            "categories": list(categories),
            "booking_classes": list(booking_classes),
            "booking_class_positions": booking_class_positions,
            "stay_length": context_stay_length,
            "stay_extended": context_stay_extended,
            "stay_contracted": context_stay_contracted,
            "booking_context": normalized_booking_context,
            "canonical_pair": dict(canonical_pair),
            "platform_pairs": list(platform_pairs),
            "platform_pair_count": len(platform_pairs),
        }
        state.checkpoint("booking_loaded", booking_data)
    else:
        booking_data = state.get_step_data("booking_loaded")
        categories = [str(value) for value in booking_data.get("categories") or []]
        booking_classes = [str(value) for value in booking_data.get("booking_classes") or categories]
        raw_booking_class_positions = booking_data.get("booking_class_positions")
        booking_class_positions = (
            dict(raw_booking_class_positions)
            if isinstance(raw_booking_class_positions, dict)
            else _extract_booking_class_positions(
                booking_data.get("booking_context") if isinstance(booking_data.get("booking_context"), dict) else {}
            )
        )
        stay_length = coerce_optional_int(booking_data.get("stay_length"), field_name="stay_length")
        stay_extended = coerce_optional_int(booking_data.get("stay_extended"), field_name="stay_extended")
        stay_contracted = coerce_optional_int(booking_data.get("stay_contracted"), field_name="stay_contracted")
        booking_context = booking_data.get("booking_context") if isinstance(booking_data.get("booking_context"), dict) else {}
        canonical_pair = dict(booking_data.get("canonical_pair") or {})
        platform_pairs = [dict(value) for value in booking_data.get("platform_pairs") or []]

    dispatch_state: Dict[str, Any]
    plan_payload: Dict[str, Any]
    if not state.is_step_done("dispatch_plan_written"):
        state.begin_step("dispatch_plan_written")
        plan_items: list[Dict[str, Any]] = []
        skipped_platform_ids: list[int] = []
        try:
            with context.connect_db() as conn:
                normalized_pairs: list[Dict[str, Any]] = []
                for pair in platform_pairs:
                    lookup_id = _resolve_lookup_id_for_pair(
                        conn,
                        property_id=int(booking_data["property_id"]),
                        pair=pair,
                    )
                    normalized_pair = dict(pair)
                    normalized_pair["platform_property_lookup_id"] = int(lookup_id)
                    normalized_pair["is_canonical"] = (
                        int(normalized_pair["platform_id"]) == int(canonical_pair["platform_id"])
                        and str(normalized_pair["listing_id"]) == str(canonical_pair["listing_id"])
                    )
                    normalized_pairs.append(normalized_pair)

                selected_by_pair: Dict[tuple[int, str], Optional[Dict[str, Any]]] = {}
                for normalized_pair in normalized_pairs:
                    selected_by_pair[_pair_identity(normalized_pair)] = _select_pair_rule(
                        conn,
                        property_id=int(booking_data["property_id"]),
                        arrival_date=booking_data["arrival"],
                        departure_date=booking_data["departure"],
                        categories=categories,
                        pair=normalized_pair,
                        lookup_id=int(normalized_pair["platform_property_lookup_id"]),
                        stay_length=stay_length,
                        stay_extended=stay_extended,
                        stay_contracted=stay_contracted,
                        booking_classes=booking_classes,
                        booking_class_positions=booking_class_positions,
                    )

                canonical_selected = selected_by_pair.get((int(canonical_pair["platform_id"]), str(canonical_pair["listing_id"])))
                chain_id = f"pricing_chain_{int(booking_data['booking_id'])}_{uuid4().hex[:8]}"
                matched_items: list[Dict[str, Any]] = []

                for normalized_pair in normalized_pairs:
                    selected = selected_by_pair.get(_pair_identity(normalized_pair))
                    rule_source = "direct"
                    if selected is None and not bool(normalized_pair.get("is_canonical")) and canonical_selected is not None:
                        selected = {
                            "matched_category": str(canonical_selected["matched_category"]),
                            "rule": dict(canonical_selected["rule"]),
                        }
                        rule_source = "canonical_fallback"

                    if selected is None:
                        skipped_platform_ids.append(int(normalized_pair["platform_id"]))
                        continue

                    matched_items.append(
                        {
                            "platform_pair": normalized_pair,
                            "matched_category": str(selected["matched_category"]),
                            "downstream_action": BOOKING_SPECIAL_OPERATION_ACTION,
                            "rule_source": rule_source,
                            "platform_type": _derive_platform_type(
                                pair=normalized_pair,
                                canonical_pair=canonical_pair,
                            ),
                            "rule": dict(selected["rule"]),
                        }
                    )

                for chain_position, matched_item in enumerate(matched_items, start=1):
                    plan_items.append(
                        {
                            **matched_item,
                            "chain_id": chain_id,
                            "chain_position": chain_position,
                            "depends_on_position": None if chain_position == 1 else chain_position - 1,
                        }
                    )
        except LookupError as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_get_cat_rule",
                step_name="dispatch_plan_written",
                message=f"failed to resolve platform lookup: {exc}",
                retry=True,
                error_code="PLATFORM_LOOKUP_FAILED",
                exc=exc,
            )
            return
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_get_cat_rule",
                step_name="dispatch_plan_written",
                message=f"rule query failed for booking {booking_id}: {exc}",
                retry=True,
                error_code="RULE_QUERY_FAILED",
                exc=exc,
            )
            return

        plan_key = generate_key("pricing_plan")
        plan_payload = {
            "booking_id": int(booking_data["booking_id"]),
            "categories": list(categories),
            "canonical_pair": dict(canonical_pair),
            "booking_context": dict(booking_context),
            "linked_listings_data": plan_items,
        }
        try:
            with context.connect_db() as conn:
                set_runtime_variable(
                    conn,
                    worker_id=context.scheduler.worker_id,
                    scope=RUNTIME_SCOPE_PLAN,
                    key=plan_key,
                    value=plan_payload,
                    ttl_minutes=_resolve_runtime_ttl(action=GET_CAT_RULE_ACTION, scope=RUNTIME_SCOPE_PLAN),
                )
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_get_cat_rule",
                step_name="dispatch_plan_written",
                message=f"failed to persist pricing dispatch plan: {exc}",
                retry=True,
                error_code="PLAN_WRITE_FAILED",
                exc=exc,
            )
            return

        dispatch_state = {
            "plan_worker_id": context.scheduler.worker_id,
            "plan_scope": RUNTIME_SCOPE_PLAN,
            "plan_key": plan_key,
            "matched_count": len(plan_items),
            "skipped_platform_ids": skipped_platform_ids,
        }
        state.checkpoint("dispatch_plan_written", dispatch_state)
    else:
        dispatch_state = state.get_step_data("dispatch_plan_written")
        try:
            with context.connect_db() as conn:
                plan_payload = get_runtime_variable(
                    conn,
                    worker_id=str(dispatch_state["plan_worker_id"]),
                    scope=str(dispatch_state["plan_scope"]),
                    key=str(dispatch_state["plan_key"]),
                )
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_get_cat_rule",
                step_name="dispatch_plan_written",
                message=f"failed to load pricing dispatch plan: {exc}",
                retry=True,
                error_code="PLAN_WRITE_FAILED",
                exc=exc,
            )
            return

    dispatch_state = state.get_step_data("dispatch_plan_written")
    if "plan_payload" not in locals():
        try:
            with context.connect_db() as conn:
                plan_payload = get_runtime_variable(
                    conn,
                    worker_id=str(dispatch_state["plan_worker_id"]),
                    scope=str(dispatch_state["plan_scope"]),
                    key=str(dispatch_state["plan_key"]),
                )
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_get_cat_rule",
                step_name="dispatch_plan_written",
                message=f"failed to load pricing dispatch plan: {exc}",
                retry=True,
                error_code="PLAN_WRITE_FAILED",
                exc=exc,
            )
            return

    linked_listings_data = [
        dict(item)
        for item in plan_payload.get("linked_listings_data") or []
        if isinstance(item, dict)
    ]
    forwarded_task_uuid: Optional[str] = None
    if not state.is_step_done("downstream_enqueued"):
        state.begin_step("downstream_enqueued")
        try:
            if linked_listings_data:
                normalized_linked_listings_data = []
                matched_categories: list[str] = []
                fallback_chain_id = f"pricing_chain_{int(booking_data['booking_id'])}_{uuid4().hex[:8]}"
                for index, item in enumerate(linked_listings_data, start=1):
                    platform_pair = item.get("platform_pair") if isinstance(item.get("platform_pair"), dict) else {}
                    matched_category = as_optional_string(item.get("matched_category"))
                    rule = item.get("rule") if isinstance(item.get("rule"), dict) else {}
                    if not matched_category:
                        continue
                    matched_categories.append(matched_category)
                    chain_position = coerce_optional_int(
                        item.get("chain_position"),
                        field_name="linked_listings_data.chain_position",
                    ) or index
                    depends_on_position = coerce_optional_int(
                        item.get("depends_on_position"),
                        field_name="linked_listings_data.depends_on_position",
                    )
                    if chain_position > 1 and depends_on_position is None:
                        depends_on_position = chain_position - 1
                    normalized_linked_listings_data.append(
                        {
                            "booking": {
                                "booking_id": int(booking_data["booking_id"]),
                                "booking_entry_id": int(booking_data["booking_id"]),
                                "property_id": int(booking_data["property_id"]),
                            },
                            "platform_pair": {
                                "platform_id": int(platform_pair["platform_id"]),
                                "listing_id": str(platform_pair["listing_id"]),
                                "is_canonical": bool(platform_pair.get("is_canonical", False)),
                            },
                            "matched_category": matched_category,
                            "rule_source": as_optional_string(item.get("rule_source")) or "direct",
                            "chain_id": as_optional_string(item.get("chain_id")) or fallback_chain_id,
                            "chain_position": chain_position,
                            "platform_type": _normalize_platform_type(item.get("platform_type"))
                            or ("pms" if bool(platform_pair.get("is_canonical")) else "ota"),
                            "depends_on_position": depends_on_position,
                            "rule": dict(rule),
                        }
                    )

                downstream_payload: Dict[str, Any] = {
                    "action": BOOKING_SPECIAL_OPERATION_ACTION,
                    "booking_id": int(booking_data["booking_id"]),
                    "categories": list(categories),
                    "canonical_pair": {
                        "platform_id": int(canonical_pair["platform_id"]),
                        "listing_id": str(canonical_pair["listing_id"]),
                    },
                    "booking_context": dict(booking_context),
                    "linked_listings_data": normalized_linked_listings_data,
                }
                unique_matched_categories = sorted(set(matched_categories))
                if len(unique_matched_categories) == 1:
                    downstream_payload["category"] = unique_matched_categories[0]

                forwarded_task_uuid = enqueue_with_meta(
                    context.queue(BOOKING_SPECIAL_OPERATION_QUEUE),
                    BOOKING_SPECIAL_OPERATION_WORKER,
                    downstream_payload,
                    current_task=task,
                    current_worker=WORKER,
                    current_action=GET_CAT_RULE_ACTION,
                    next_worker=BOOKING_SPECIAL_OPERATION_WORKER,
                    next_action=BOOKING_SPECIAL_OPERATION_ACTION,
                )
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                action_name="handle_get_cat_rule",
                step_name="downstream_enqueued",
                message=f"failed to enqueue booking-special-operation task: {exc}",
                retry=True,
                error_code="ENQUEUE_FAILED",
                exc=exc,
            )
            return

        state.checkpoint(
            "downstream_enqueued",
            {
                "forwarded_count": 1 if forwarded_task_uuid else 0,
                "downstream_task_uuids": [str(forwarded_task_uuid)] if forwarded_task_uuid else [],
            },
        )

    downstream_state = state.get_step_data("downstream_enqueued")
    forwarded_count = int(downstream_state.get("forwarded_count") or 0)
    downstream_task_uuids = [str(value) for value in downstream_state.get("downstream_task_uuids") or []]

    cleanup_error = None
    try:
        with context.connect_db() as conn:
            delete_runtime_variable(
                conn,
                worker_id=str(dispatch_state["plan_worker_id"]),
                scope=str(dispatch_state["plan_scope"]),
                key=str(dispatch_state["plan_key"]),
            )
    except Exception as exc:  # pragma: no cover - runtime path
        cleanup_error = str(exc)

    matched_pairs = int(dispatch_state.get("matched_count") or 0)
    skipped_platform_ids = [int(value) for value in dispatch_state.get("skipped_platform_ids") or []]
    if matched_pairs == 0:
        result = {
            "status": "no_rules",
            "booking_id": int(booking_data["booking_id"]),
            "matched_pairs": 0,
            "forwarded_count": 0,
            "skipped_platform_ids": skipped_platform_ids,
        }
    else:
        result = {
            "status": "forwarded",
            "booking_id": int(booking_data["booking_id"]),
            "matched_pairs": matched_pairs,
            "forwarded_count": forwarded_count,
            "skipped_platform_ids": skipped_platform_ids,
            "downstream_task_uuids": downstream_task_uuids,
            "cleanup_error": cleanup_error,
        }

    step.log("pricing engine worker resolved dispatch plan", result)
    log.info("task completed", metadata=result, **task_log_kwargs(task, "handle_get_cat_rule"))
    queue.complete_task(task, result)


def handle_task(context: ManagedWorkerContext, task) -> None:
    normalize_payload_meta(task.payload)
    action = task.payload.get("action")
    if action == GET_CAT_RULE_ACTION:
        handle_get_cat_rule(context, task)
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
            "pricing engine worker started",
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
            logger.exception("pricing engine worker failed")
        else:
            app_logger.error("pricing engine worker failed", exc=exc, action_name="worker_runtime")
        raise SystemExit(1)
    finally:
        if scheduler is not None:
            if not isinstance(app_logger, NullAppLogger):
                app_logger.info("pricing engine worker shutting down", action_name="worker_shutdown")
            try:
                scheduler.state_manager.shutdown()
            except Exception as exc:
                if isinstance(app_logger, NullAppLogger):
                    logger.exception("pricing engine worker clean shutdown checkpoint failed")
                else:
                    app_logger.error(
                        "pricing engine worker clean shutdown checkpoint failed",
                        exc=exc,
                        action_name="worker_shutdown",
                    )
            try:
                app_logger.close()
            except Exception:
                logger.exception("pricing engine worker app logger close failed")
            scheduler.close()


if __name__ == "__main__":
    main()
