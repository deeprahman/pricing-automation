#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any, Dict, Optional, Sequence

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


WORKER = "property-platform-worker"
PRIMARY_QUEUE = "property-platform"
SUBSCRIBED_QUEUES: Sequence[str] = (PRIMARY_QUEUE,)
SUPPORTED_ACTIONS = ("get_linked_listings",)

PRICING_ENGINE_WORKER = "pricing-engine-worker"
PRICING_ENGINE_QUEUE = "pricing-engine"
GET_LINKED_LISTINGS_ACTION = "get_linked_listings"
PRICING_ENGINE_ACTION = "get_cat_rule"
_PLATFORM_PROPERTY_LOOKUP_LISTING_COLUMN: Optional[str] = None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Property-platform worker")
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


def _normalize_categories(payload: Dict[str, Any]) -> list[str]:
    raw_categories = payload.get("categories")
    if not isinstance(raw_categories, list) or not raw_categories:
        raise ValueError("categories must be a non-empty array of strings")

    categories: list[str] = []
    for index, raw_value in enumerate(raw_categories):
        value = as_optional_string(raw_value)
        if not value:
            raise ValueError(f"categories[{index}] must be a non-empty string")
        categories.append(value)
    return categories


def _normalize_message_ids(payload: Dict[str, Any]) -> list[int]:
    raw_message_ids = payload.get("message_ids")
    if raw_message_ids is None:
        messages = payload.get("messages")
        if not isinstance(messages, list):
            return []
        raw_message_ids = []
        for item in messages:
            if isinstance(item, dict):
                raw_message_ids.append(item.get("id"))

    if not isinstance(raw_message_ids, list):
        raise ValueError("message_ids must be an array of integers when present")

    message_ids: list[int] = []
    for index, raw_value in enumerate(raw_message_ids):
        message_id = coerce_optional_int(raw_value, field_name=f"message_ids[{index}]")
        if message_id is None:
            raise ValueError(f"message_ids[{index}] must be an integer")
        message_ids.append(message_id)
    return message_ids


def _normalize_canonical_lookup_id(payload: Dict[str, Any]) -> int:
    canonical_pair = payload.get("canonical_pair")
    if not isinstance(canonical_pair, dict):
        raise ValueError("canonical_pair is required")

    lookup_id = coerce_optional_int(
        canonical_pair.get("platform_property_lookup_id"),
        field_name="canonical_pair.platform_property_lookup_id",
    )
    if lookup_id is None:
        raise ValueError("canonical_pair.platform_property_lookup_id is required")
    return int(lookup_id)


def _fetch_booking(conn, booking_id: int) -> Optional[Dict[str, int]]:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT id, property_id, platform_id
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
        "property_id": int(row[1]),
        "platform_id": int(row[2]),
    }


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


def _fetch_platform_property_lookup_row(conn, lookup_id: int) -> Optional[Dict[str, Any]]:
    listing_column = _resolve_platform_property_lookup_listing_column(conn)
    sql = f"""
        SELECT ppl.id, ppl.properties_ptr, ppl.platform_id, ppl.{listing_column}, p.name, p.type
        FROM platform_property_lookup ppl
        LEFT JOIN platforms p ON p.id = ppl.platform_id
        WHERE ppl.id = %s
        LIMIT 1
    """
    with conn.cursor() as cur:
        cur.execute(sql, (lookup_id,))
        row = cur.fetchone()
    if row is None:
        return None

    listing_id = as_optional_string(row[3])
    if not listing_id:
        raise ValueError(f"platform_property_lookup row {lookup_id} has no listing identifier")

    result: Dict[str, Any] = {
        "platform_property_lookup_id": int(row[0]),
        "property_id": int(row[1]),
        "platform_id": int(row[2]),
        "listing_id": listing_id,
    }
    platform_name = as_optional_string(row[4])
    if platform_name:
        result["platform_name"] = platform_name
    platform_type = as_optional_string(row[5])
    if platform_type:
        result["platform_type"] = platform_type
    return result


def _get_cross_platform_pairs(conn, platform_id: int, listing_id: str) -> list[Dict[str, Any]]:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT platform_id, listing_id, platform_name, platform_type
            FROM get_cross_platform_properties(%s, %s)
            """,
            (platform_id, listing_id),
        )
        rows = cur.fetchall() or []

    pairs: list[Dict[str, Any]] = []
    for row in rows:
        pair_listing_id = as_optional_string(row[1])
        if not pair_listing_id:
            continue
        pair: Dict[str, Any] = {
            "platform_id": int(row[0]),
            "listing_id": pair_listing_id,
        }
        platform_name = as_optional_string(row[2])
        if platform_name:
            pair["platform_name"] = platform_name
        platform_type = as_optional_string(row[3])
        if platform_type:
            pair["platform_type"] = platform_type
        pairs.append(pair)
    return pairs


def _normalize_platform_type(value: Any) -> Optional[str]:
    platform_type = as_optional_string(value)
    if not platform_type:
        return None
    normalized = platform_type.strip().lower()
    if normalized == "otp":
        normalized = "ota"
    return normalized


def _platform_pair_sort_key(pair: Dict[str, Any]) -> tuple[int, str]:
    return int(pair["platform_id"]), str(pair["listing_id"])


def _order_pairs_by_topology(
    *,
    canonical_pair: Dict[str, Any],
    linked_pairs: list[Dict[str, Any]],
) -> list[Dict[str, Any]]:
    if not linked_pairs:
        raise ValueError("topology invalid: canonical pair must have at least one linked external row")

    canonical_platform_type = _normalize_platform_type(canonical_pair.get("platform_type"))
    if canonical_platform_type and canonical_platform_type != "pms":
        raise ValueError(
            "topology invalid: canonical pair platform_type must be pms "
            f"(got {canonical_platform_type})"
        )

    canonical = dict(canonical_pair)
    canonical["platform_type"] = canonical_platform_type or "pms"

    dpt_pairs: list[Dict[str, Any]] = []
    ota_pairs: list[Dict[str, Any]] = []
    for pair in linked_pairs:
        normalized_pair = dict(pair)
        platform_type = _normalize_platform_type(normalized_pair.get("platform_type"))
        if platform_type is None:
            raise ValueError(
                "topology invalid: linked platform_type is required for "
                f"platform_id={normalized_pair.get('platform_id')}"
            )
        normalized_pair["platform_type"] = platform_type

        if platform_type == "dpt":
            dpt_pairs.append(normalized_pair)
            continue
        if platform_type == "ota":
            ota_pairs.append(normalized_pair)
            continue
        if platform_type == "pms":
            raise ValueError(
                "topology invalid: linked pairs must not contain an additional pms "
                f"row (platform_id={normalized_pair.get('platform_id')})"
            )
        raise ValueError(
            f"topology invalid: unsupported linked platform_type '{platform_type}' "
            f"for platform_id={normalized_pair.get('platform_id')}"
        )

    if len(dpt_pairs) > 1:
        raise ValueError("topology invalid: multiple dpt linked rows are not allowed")

    ordered_pairs: list[Dict[str, Any]] = []
    ordered_pairs.extend(sorted(dpt_pairs, key=_platform_pair_sort_key))
    ordered_pairs.append(canonical)
    ordered_pairs.extend(sorted(ota_pairs, key=_platform_pair_sort_key))
    return ordered_pairs


def _log_and_fail(
    *,
    queue,
    log,
    state: ActionStateManager,
    task,
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
        **task_log_kwargs(task, "handle_get_linked_listings"),
    )
    state.record_failure(step_name, message)
    queue.fail_task(task, message, retry=retry)


def handle_get_linked_listings(context: ManagedWorkerContext, task) -> None:
    queue = context.main_queue
    step = default_step(context)
    log = default_app_logger(context)
    state = ActionStateManager.load(context, task)
    payload = task.payload

    log.info(
        "task started",
        metadata={"action": GET_LINKED_LISTINGS_ACTION},
        **task_log_kwargs(task, "handle_get_linked_listings"),
    )

    try:
        booking_id = _normalize_booking_id(payload)
        categories = _normalize_categories(payload)
        message_ids = _normalize_message_ids(payload)
        canonical_lookup_id = _normalize_canonical_lookup_id(payload)
        booking_context = payload.get("booking_context") if isinstance(payload.get("booking_context"), dict) else {}
    except ValueError as exc:
        _log_and_fail(
            queue=queue,
            log=log,
            state=state,
            task=task,
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
                booking = _fetch_booking(conn, booking_id)
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
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
                step_name="booking_loaded",
                message=f"booking {booking_id} not found",
                retry=False,
                error_code="BOOKING_NOT_FOUND",
            )
            return

        booking_data = {
            "booking_id": booking["booking_id"],
            "property_id": booking["property_id"],
            "platform_id": booking["platform_id"],
            "categories": categories,
            "message_ids": message_ids,
            "canonical_lookup_id": int(canonical_lookup_id),
            "booking_context": dict(booking_context),
        }
        state.checkpoint("booking_loaded", booking_data)
    else:
        booking_data = state.get_step_data("booking_loaded")
        categories = [str(value) for value in booking_data.get("categories") or []]
        booking_context = booking_data.get("booking_context") if isinstance(booking_data.get("booking_context"), dict) else {}

    pairs_data: Dict[str, Any]
    if not state.is_step_done("pairs_resolved"):
        state.begin_step("pairs_resolved")
        try:
            with context.connect_db() as conn:
                property_id = int(booking_data["property_id"])
                canonical_lookup_id = int(booking_data["canonical_lookup_id"])
                canonical_lookup = _fetch_platform_property_lookup_row(conn, canonical_lookup_id)
                if canonical_lookup is None:
                    _log_and_fail(
                        queue=queue,
                        log=log,
                        state=state,
                        task=task,
                        step_name="pairs_resolved",
                        message=f"canonical platform_property_lookup row missing for id={canonical_lookup_id}",
                        retry=False,
                        error_code="LOOKUP_ID_MISSING",
                    )
                    return

                if int(canonical_lookup["property_id"]) != property_id:
                    _log_and_fail(
                        queue=queue,
                        log=log,
                        state=state,
                        task=task,
                        step_name="pairs_resolved",
                        message=(
                            "canonical pair property mismatch for booking "
                            f"{booking_id}: booking.property_id={property_id}, "
                            f"canonical_pair.property_id={canonical_lookup['property_id']}"
                        ),
                        retry=False,
                        error_code="LOOKUP_PROPERTY_MISMATCH",
                    )
                    return

                canonical_platform_id = int(canonical_lookup["platform_id"])
                canonical_listing_id = str(canonical_lookup["listing_id"])
                normalized_pairs = _get_cross_platform_pairs(conn, canonical_platform_id, canonical_listing_id)
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                step_name="pairs_resolved",
                message=f"failed to resolve platform pairs for booking {booking_id}: {exc}",
                retry=True,
                error_code="CROSS_PLATFORM_QUERY_FAILED",
                exc=exc,
            )
            return

        canonical_pair = next(
            (
                pair
                for pair in normalized_pairs
                if int(pair["platform_id"]) == int(canonical_lookup["platform_id"])
                and str(pair["listing_id"]) == str(canonical_lookup["listing_id"])
            ),
            None,
        )
        if canonical_pair is None:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                step_name="pairs_resolved",
                message=f"cross-platform query did not return a canonical pair for booking {booking_id}",
                retry=False,
                error_code="CANONICAL_PAIR_MISSING",
            )
            return

        canonical_pair = dict(canonical_pair)
        canonical_pair["is_canonical"] = True
        canonical_pair["platform_property_lookup_id"] = int(canonical_lookup["platform_property_lookup_id"])
        linked_pairs: list[Dict[str, Any]] = []
        for pair in normalized_pairs:
            if (
                int(pair["platform_id"]) == int(canonical_pair["platform_id"])
                and str(pair["listing_id"]) == str(canonical_pair["listing_id"])
            ):
                continue
            linked_pair = dict(pair)
            linked_pair["linked_from_platform_id"] = int(canonical_pair["platform_id"])
            linked_pairs.append(linked_pair)

        try:
            ordered_pairs = _order_pairs_by_topology(
                canonical_pair=canonical_pair,
                linked_pairs=linked_pairs,
            )
        except ValueError as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                step_name="pairs_resolved",
                message=str(exc),
                retry=False,
                error_code="TOPOLOGY_INVALID",
                exc=exc,
            )
            return

        ordered_canonical_pair = next(
            (dict(pair) for pair in ordered_pairs if bool(pair.get("is_canonical"))),
            dict(canonical_pair),
        )

        pairs_data = {
            "canonical_listing_id": canonical_listing_id,
            "canonical_pair": ordered_canonical_pair,
            "platform_pairs": ordered_pairs,
            "linked_pair_count": len(linked_pairs),
        }
        state.checkpoint("pairs_resolved", pairs_data)
    else:
        pairs_data = state.get_step_data("pairs_resolved")

    if not state.is_step_done("downstream_enqueued"):
        state.begin_step("downstream_enqueued")
        downstream_payload = {
            "action": PRICING_ENGINE_ACTION,
            "booking_id": int(booking_data["booking_id"]),
            "categories": list(categories),
            "canonical_pair": dict(pairs_data["canonical_pair"]),
            "platform_pairs": list(pairs_data["platform_pairs"]),
            "booking_context": dict(booking_context),
        }
        try:
            downstream_task_uuid = enqueue_with_meta(
                context.queue(PRICING_ENGINE_QUEUE),
                PRICING_ENGINE_WORKER,
                downstream_payload,
                current_task=task,
                current_worker=WORKER,
                current_action=GET_LINKED_LISTINGS_ACTION,
                next_worker=PRICING_ENGINE_WORKER,
                next_action=PRICING_ENGINE_ACTION,
            )
        except Exception as exc:
            _log_and_fail(
                queue=queue,
                log=log,
                state=state,
                task=task,
                step_name="downstream_enqueued",
                message=f"failed to enqueue pricing-engine task: {exc}",
                retry=True,
                error_code="ENQUEUE_FAILED",
                exc=exc,
            )
            return

        state.checkpoint(
            "downstream_enqueued",
            {
                "downstream_task_uuid": downstream_task_uuid,
                "platform_pair_count": len(pairs_data["platform_pairs"]),
            },
        )

    downstream_task_uuid = as_optional_string(
        state.get_step_data("downstream_enqueued").get("downstream_task_uuid")
    )
    result = {
        "status": "forwarded",
        "booking_id": int(booking_data["booking_id"]),
        "canonical_platform_id": int(pairs_data["canonical_pair"]["platform_id"]),
        "platform_pair_count": len(pairs_data["platform_pairs"]),
        "linked_pair_count": int(pairs_data["linked_pair_count"]),
        "downstream_task_uuid": downstream_task_uuid,
    }
    step.log("property-platform worker resolved platform pairs", result)
    log.info("task completed", metadata=result, **task_log_kwargs(task, "handle_get_linked_listings"))
    queue.complete_task(task, result)


def handle_task(context: ManagedWorkerContext, task) -> None:
    normalize_payload_meta(task.payload)
    action = task.payload.get("action")
    if action == GET_LINKED_LISTINGS_ACTION:
        handle_get_linked_listings(context, task)
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
            "property-platform worker started",
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
            logger.exception("property-platform worker failed")
        else:
            app_logger.error("property-platform worker failed", exc=exc, action_name="worker_runtime")
        raise SystemExit(1)
    finally:
        if scheduler is not None:
            if not isinstance(app_logger, NullAppLogger):
                app_logger.info("property-platform worker shutting down", action_name="worker_shutdown")
            try:
                scheduler.state_manager.shutdown()
            except Exception as exc:
                if isinstance(app_logger, NullAppLogger):
                    logger.exception("property-platform worker clean shutdown checkpoint failed")
                else:
                    app_logger.error(
                        "property-platform worker clean shutdown checkpoint failed",
                        exc=exc,
                        action_name="worker_shutdown",
                    )
            try:
                app_logger.close()
            except Exception:
                logger.exception("property-platform worker app logger close failed")
            scheduler.close()


if __name__ == "__main__":
    main()
