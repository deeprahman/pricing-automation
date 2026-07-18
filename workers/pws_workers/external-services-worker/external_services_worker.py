#!/usr/bin/env python3
from __future__ import annotations

import argparse
import inspect
import json
import os
import random
import re
import sys
from contextvars import ContextVar
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path
from typing import Any, Dict, Optional, Sequence

import httpx

CURRENT_DIR = Path(__file__).resolve().parent
WORKERS_ROOT = Path(__file__).resolve().parents[2]
REPO_ROOT = Path(__file__).resolve().parents[3]
for candidate in (CURRENT_DIR, WORKERS_ROOT, REPO_ROOT):
    if str(candidate) not in sys.path:
        sys.path.insert(0, str(candidate))

from pws_workers.shared.dummy_messages import DummyMessages
from pws_workers.shared.mock_message_classifier import MockMessageClassifier
from pws_workers.shared.ollama_classifier import (
    DEFAULT_MODEL as DEFAULT_OLLAMA_CLASSIFIER_MODEL,
    OllamaClassificationError,
    OllamaMessageClassifier,
)
from pws_workers.shared.openai_message_classifier import (
    DEFAULT_MODEL as DEFAULT_LLM_CLASSIFIER_MODEL,
    LLMUsage,
    OpenAIClassificationError,
    OpenAIMessageClassifier,
)
from pws_workers.shared.worker_runtime import (
    NoOpStepLog,
    Task,
    add_common_worker_args,
    build_dsn,
    configure_worker_logger,
    normalize_payload_meta,
)
from pws_workers.shared import (
    ActionStateManager,
    AppLogger,
    DEFAULT_OWNERREZ_API_BASE_URL,
    ManagedSchedulerClient,
    ManagedWorkerContext,
    ManagedWorkerRunner,
    NullAppLogger,
    OwnerRezClient,
    OwnerRezConfigError,
    OwnerRezPermanentError,
    OwnerRezResponseShapeError,
    OwnerRezRetryableError,
    PriceLabsClient,
    PriceLabsUnexpectedStatusError,
    WheelhouseClient,
    as_optional_string,
    coerce_optional_int,
    coerce_required_int,
    default_app_logger,
    default_step,
    delete_runtime_variable,
    enqueue_with_meta,
    generate_key,
    get_booking_id,
    get_runtime_variable,
    normalize_json_value,
    normalize_return_ref,
    parse_runtime_variable_ttl_config,
    reset_default_ownerrez_client,
    resolve_runtime_variable_ttl,
    set_runtime_variable,
    task_log_kwargs,
)
from pws_workers.shared.http_logging import sanitize_http_metadata
from providers.base import ProviderHelpers
from providers.pricelabs_metadata import resolve_pricelabs_pms
from providers.wheelhouse_metadata import resolve_wheelhouse_channel
from providers.registry import get_provider_adapter


WORKER = "external-services-worker"
PRIMARY_QUEUE = "external-services"
SUBSCRIBED_QUEUES: Sequence[str] = (PRIMARY_QUEUE,)

FETCH_ACTION = "get_ownerrez_messages"
FETCH_DUMMY_ACTION = "get_dummy_messages"
CLASSIFY_ACTION = "classify_messages"
CLASSIFY_DUMMY_ACTION = "classify_dummy_messages"
PROCESS_INSTRUCTION_ACTION = "process_instruction"
PROCESS_INSTRUCTION_CAPTURE_BASE_RATES_MODE = "capture_base_rates"
LEGACY_PROCESS_INSTRUCTION_ACTION = "handle_instruction"
FETCH_SCOPE_IN = "fetch-extsvc-request"
FETCH_RUNTIME_SCOPE = "extsvc-fetch-response"
FETCH_BOOKINGS_REQUEST_SCOPE = "fetch-bookings-request"
FETCH_BOOKINGS_PAGE_SCOPE = "fetch-bookings-page"
CLASSIFY_SCOPE_IN = "classifier-extsvc"
CLASSIFY_SCOPE_OUT = "extsvc-classifier"
RUNTIME_TTL_MINUTES = 15
REQUIRED_FALLBACK_CLASS = "unclassified"
CLASSIFIER_PROVIDER_ENV = "PWS_MESSAGE_CLASSIFIER_PROVIDER"
CLASSIFIER_PROVIDER_OPENAI = "openai"
CLASSIFIER_PROVIDER_OLLAMA = "ollama"
DEFAULT_LIVE_CLASSIFIER_PROVIDER = CLASSIFIER_PROVIDER_OPENAI
RUNTIME_VARIABLE_TTL_CONFIG: Optional[Dict[str, Any]] = None
_PROCESS_INSTRUCTION_DB_CONN: ContextVar[Any | None] = ContextVar(
    "external_services_process_instruction_db_conn",
    default=None,
)
_PLATFORM_PROPERTY_LOOKUP_LISTING_COLUMN: Optional[str] = None
_NIGHTLYRATES_HAS_RATE_TYPE_COLUMN: Optional[bool] = None
PROCESS_INSTRUCTION_RETRYABLE_STATUS_CODES = {429, 500, 502, 503, 504}
PROCESS_INSTRUCTION_PERMANENT_STATUS_CODES = {400, 401, 403, 404, 406, 422, 424}
SUPPORTED_INSTRUCTION_OPERATIONS = {"increase", "decrease", "set"}
SUPPORTED_INSTRUCTION_TYPES = {"percentage", "flat", "fixed"}
INSTRUCTION_OPERATION_ALIASES = {"override": "set"}
INSTRUCTION_TYPE_ALIASES = {"override": "fixed"}
PROVIDER_BOOKINGS_ACTION_PATTERN = re.compile(r"^get_([a-z0-9-]+)_bookings$")
PROCESS_INSTRUCTION_MOCK_REQUEST_FAILURE_RATE = 0.1
PROCESS_INSTRUCTION_MOCK_PROVIDERS = frozenset({"ownerrez", "pricelabs", "wheelhouse"})
PRICELABS_STRICT_API_CONTRACT_ENV = "PRICELABS_STRICT_API_CONTRACT"
BASE_RATE_PLATFORM_PRIORITY = {"dpt": 0, "otp": 1, "ota": 1, "pms": 2}
SUPPORTED_RATE_TYPES = {"base", "recommended", "minimum", "maximum"}
RECOMMENDED_LIKE_RATE_TYPES = {"base", "recommended"}
MINMAX_RATE_TYPES = {"minimum", "maximum"}
PROVIDER_FALLBACKS: Dict[str, Dict[str, Any]] = {
    "ownerrez": {
        "base_url": "https://api.ownerrez.com",
        "endpoints": {
            "spotrates": {
                "path": "/v2/spotrates",
                "transport_path": "/v2/spotrates",
            }
        },
        "env_secrets": {
            "Authorization": {
                "env_var": "OWNERREZ_BEARER_TOKEN",
                "type": "Bearer Token",
            }
        },
    },
    "pricelabs": {
        "base_url": "https://api.pricelabs.co",
        "endpoints": {
            "apply": {
                "path": "/v1/listings/{listing_id}/overrides",
                "transport_path": "/v1/listings/{listing_id}/overrides",
            },
            "remove": {
                "path": "/v1/listings/{listing_id}/overrides",
                "transport_path": "/v1/listings/{listing_id}/overrides",
            },
        },
        "env_secrets": {
            "X-API-Key": {
                "env_var": "PRICELABS_API_KEY",
                "type": "API Key",
            }
        },
    },
    "wheelhouse": {
        "base_url": "https://api.usewheelhouse.com",
        "endpoints": {
            "apply": {
                "path": "/listings/{listing_id}/bulk_custom_rates",
                "transport_path": "/ss_api/v1/listings/{listing_id}/bulk_custom_rates",
            },
            "remove": {
                "path": "/listings/{listing_id}/bulk_custom_rates",
                "transport_path": "/ss_api/v1/listings/{listing_id}/bulk_custom_rates",
            },
        },
        "env_secrets": {
            "X-Integration-Api-Key": {
                "env_var": "WHEELHOUSE_RM_API_KEY",
                "env_var_aliases": [
                    "WHEELHOUSE_INTEGRATION_KEY",
                    "WHEELHOUSE_ACCESS_KEY",
                    "WHEELHOUSE_API_KEY",
                    "WHEELHOUSE_USER_ACCESS_TOKEN",
                    "WHEELHOUSE_USER_API_KEY",
                    "WHEELHOUSE_X_USER_ACCESS_KEY",
                ],
                "type": "API Key",
            },
        },
    },
}


def _load_process_instruction_env() -> Dict[str, str]:
    env: Dict[str, str] = {}
    for env_path in (
        REPO_ROOT / ".env",
        REPO_ROOT / ".env.prod",
        REPO_ROOT / ".env.local",
    ):
        if not env_path.exists():
            continue
        try:
            lines = env_path.read_text(encoding="utf-8").splitlines()
        except OSError:
            continue
        for raw_line in lines:
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            env[key.strip()] = value.strip().strip('"').strip("'")
    env.update(os.environ)
    return env


def _process_instruction_mock_mode_enabled(provider_key: str) -> bool:
    if provider_key not in PROCESS_INSTRUCTION_MOCK_PROVIDERS:
        return False
    source = _load_process_instruction_env()
    return str(source.get("LOG_LEVEL") or "INFO").strip().upper() == "DEBUG"


def _pricelabs_strict_api_contract_enabled() -> bool:
    source = _load_process_instruction_env()
    raw_value = as_optional_string(source.get(PRICELABS_STRICT_API_CONTRACT_ENV))
    if raw_value is None:
        return True
    normalized = raw_value.strip().lower()
    return normalized not in {"0", "false", "no", "off"}


def _normalize_rate_type(value: Any, *, default: str = "base") -> str:
    normalized = (as_optional_string(value) or "").strip().lower()
    if normalized in SUPPORTED_RATE_TYPES:
        return normalized
    return default


def _provider_helpers() -> ProviderHelpers:
    return ProviderHelpers(
        canonical_provider_key=_canonical_provider_key,
        as_optional_string=as_optional_string,
        coerce_required_int=coerce_required_int,
        provider_endpoint_spec=lambda provider_key, remove: _provider_endpoint_spec(
            provider_key, remove=remove
        ),
        resolve_instruction_currency=_resolve_instruction_currency,
        resolve_execution_prices=lambda instruction, dates: _resolve_execution_prices(
            instruction, dates=dates
        ),
        compress_iso_dates=_compress_iso_dates,
        decimal_to_json_number=_decimal_to_json_number,
        round_currency=_round_currency,
        normalize_domain=lambda value, provider_key: _normalize_domain(
            value, provider_key=provider_key
        ),
        process_instruction_error_result=_process_instruction_error_result,
        extract_provider_request_id=_extract_provider_request_id,
        response_error_message=lambda response, provider_key, method, path: _response_error_message(
            response,
            provider_key=provider_key,
            method=method,
            path=path,
        ),
        process_instruction_mock_mode_enabled=_process_instruction_mock_mode_enabled,
        execute_plan_mock=lambda provider_key, http_calls, affected_dates: _execute_plan_mock(
            provider_key=provider_key,
            http_calls=http_calls,
            affected_dates=affected_dates,
        ),
        retryable_status_codes=PROCESS_INSTRUCTION_RETRYABLE_STATUS_CODES,
        permanent_status_codes=PROCESS_INSTRUCTION_PERMANENT_STATUS_CODES,
        permanent_error_cls=ProcessInstructionPermanentError,
        retryable_error_cls=ProcessInstructionRetryableError,
        httpx=httpx,
        pricelabs_client_cls=PriceLabsClient,
        wheelhouse_client_cls=WheelhouseClient,
    )


class ProcessInstructionError(Exception):
    def __init__(
        self,
        message: str,
        *,
        error_code: str,
        retryable: bool,
        callback_safe: bool,
    ) -> None:
        super().__init__(message)
        self.error_code = error_code
        self.retryable = bool(retryable)
        self.callback_safe = bool(callback_safe)


class InstructionValidationError(ProcessInstructionError):
    def __init__(
        self, message: str, *, error_code: str = "INSTRUCTION_INVALID"
    ) -> None:
        super().__init__(
            message, error_code=error_code, retryable=False, callback_safe=False
        )


class ProcessInstructionPermanentError(ProcessInstructionError):
    def __init__(self, message: str, *, error_code: str) -> None:
        super().__init__(
            message, error_code=error_code, retryable=False, callback_safe=True
        )


class ProcessInstructionRetryableError(ProcessInstructionError):
    def __init__(
        self, message: str, *, error_code: str = "PROVIDER_REQUEST_FAILED"
    ) -> None:
        super().__init__(
            message, error_code=error_code, retryable=True, callback_safe=False
        )


def _normalize_process_instruction_dates(raw_dates: Any) -> list[str]:
    if not isinstance(raw_dates, list) or not raw_dates:
        raise InstructionValidationError("instruction.dates must be a non-empty array")

    normalized: list[str] = []
    seen: set[str] = set()
    for raw_value in raw_dates:
        value = as_optional_string(raw_value)
        if value is None:
            raise InstructionValidationError(
                "instruction.dates must contain YYYY-MM-DD strings"
            )
        try:
            date.fromisoformat(value)
        except ValueError as exc:
            raise InstructionValidationError(
                "instruction.dates must contain YYYY-MM-DD strings"
            ) from exc
        if value in seen:
            raise InstructionValidationError("instruction.dates must be unique")
        seen.add(value)
        normalized.append(value)
    return normalized


def _coerce_decimal(value: Any, *, field_name: str) -> Decimal:
    if value is None or value == "":
        raise ProcessInstructionPermanentError(
            f"{field_name} is required", error_code="UNSUPPORTED_INSTRUCTION"
        )
    try:
        return Decimal(str(value))
    except Exception as exc:
        raise ProcessInstructionPermanentError(
            f"{field_name} must be numeric",
            error_code="UNSUPPORTED_INSTRUCTION",
        ) from exc


def _normalize_instruction_operation(value: Any) -> Optional[str]:
    operation = as_optional_string(value)
    if operation is None:
        return None
    return INSTRUCTION_OPERATION_ALIASES.get(operation, operation)


def _normalize_instruction_type(
    value: Any, *, operation: Optional[str]
) -> Optional[str]:
    instruction_type = as_optional_string(value)
    if instruction_type is not None:
        instruction_type = INSTRUCTION_TYPE_ALIASES.get(
            instruction_type, instruction_type
        )
    if instruction_type is None and operation == "set":
        return "fixed"
    return instruction_type


def _validate_instruction_operation_type(
    *, operation: str, instruction_type: str
) -> None:
    if instruction_type == "fixed":
        if operation != "set":
            raise ProcessInstructionPermanentError(
                f"unsupported instruction combination operation='{operation}' type='{instruction_type}'",
                error_code="UNSUPPORTED_INSTRUCTION",
            )
        return
    if operation not in {"increase", "decrease"}:
        raise ProcessInstructionPermanentError(
            f"unsupported instruction combination operation='{operation}' type='{instruction_type}'",
            error_code="UNSUPPORTED_INSTRUCTION",
        )


def _decimal_to_json_number(value: Decimal) -> int | float:
    normalized = value.normalize()
    if normalized == normalized.to_integral():
        return int(normalized)
    return float(normalized)


def _round_currency(value: Decimal) -> float:
    return float(value.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP))


def _process_instruction_error_result(
    *,
    provider_key: Optional[str],
    affected_dates: list[str],
    error: str,
    partial_success: bool = False,
    http_statuses: Optional[list[int]] = None,
    provider_request_ids: Optional[list[str]] = None,
) -> Dict[str, Any]:
    return {
        "provider_key": provider_key,
        "success": False,
        "partial_success": bool(partial_success),
        "http_statuses": list(http_statuses or []),
        "provider_request_ids": list(provider_request_ids or []),
        "affected_dates": list(affected_dates),
        "error": str(error),
    }


def _normalize_execution_result(
    plan: Dict[str, Any], result: Dict[str, Any]
) -> Dict[str, Any]:
    affected_dates = result.get("affected_dates")
    if not isinstance(affected_dates, list):
        affected_dates = (
            plan.get("affected_dates")
            if isinstance(plan.get("affected_dates"), list)
            else []
        )

    http_statuses_raw = result.get("http_statuses")
    http_statuses: list[int] = []
    if isinstance(http_statuses_raw, list):
        for raw_value in http_statuses_raw:
            try:
                http_statuses.append(int(raw_value))
            except (TypeError, ValueError):
                continue

    request_ids_raw = result.get("provider_request_ids")
    provider_request_ids: list[str] = []
    if isinstance(request_ids_raw, list):
        for raw_value in request_ids_raw:
            value = as_optional_string(raw_value)
            if value is not None:
                provider_request_ids.append(value)

    return {
        "provider_key": as_optional_string(result.get("provider_key"))
        or as_optional_string(plan.get("provider_key")),
        "success": bool(result.get("success")),
        "partial_success": bool(result.get("partial_success")),
        "http_statuses": http_statuses,
        "provider_request_ids": provider_request_ids,
        "affected_dates": [str(value) for value in affected_dates],
        "error": as_optional_string(result.get("error")),
    }


def _execution_result_is_retryable(result: Dict[str, Any]) -> bool:
    if bool(result.get("success")) or bool(result.get("partial_success")):
        return False
    http_statuses = result.get("http_statuses")
    if not isinstance(http_statuses, list) or not http_statuses:
        return False
    normalized_statuses: list[int] = []
    for raw_value in http_statuses:
        try:
            normalized_statuses.append(int(raw_value))
        except (TypeError, ValueError):
            return False
    return all(
        status in PROCESS_INSTRUCTION_RETRYABLE_STATUS_CODES
        for status in normalized_statuses
    )


def _canonical_provider_key(value: Any) -> Optional[str]:
    raw = as_optional_string(value)
    if raw is None:
        return None
    normalized = "".join(ch for ch in raw.lower() if ch.isalnum())
    mapping = {
        "ownerrez": "ownerrez",
        "pricelabs": "pricelabs",
        "wheelhouse": "wheelhouse",
    }
    return mapping.get(normalized)


def _normalize_domain(value: Any, *, provider_key: str) -> str:
    raw_value = as_optional_string(value) or as_optional_string(
        PROVIDER_FALLBACKS.get(provider_key, {}).get("base_url")
    )
    if raw_value is None:
        raise ProcessInstructionPermanentError(
            f"{provider_key} base URL is not configured",
            error_code="PROVIDER_CONFIG_MISSING",
        )
    if "://" not in raw_value:
        raw_value = f"https://{raw_value}"
    return raw_value.rstrip("/")


def _process_instruction_db_conn():
    conn = _PROCESS_INSTRUCTION_DB_CONN.get()
    if conn is None:
        raise ProcessInstructionPermanentError(
            "process_instruction database connection is unavailable",
            error_code="PROVIDER_CONFIG_MISSING",
        )
    return conn


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
        raise ProcessInstructionPermanentError(
            "platform_property_lookup listing identifier column is missing",
            error_code="PROVIDER_CONFIG_MISSING",
        )

    _PLATFORM_PROPERTY_LOOKUP_LISTING_COLUMN = column_name
    return column_name


def _load_ownerrez_platform_metadata(conn, *, platform_id: int) -> Dict[str, Any]:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT name, metadata, is_active
            FROM platforms
            WHERE id = %s
            LIMIT 1
            """,
            (int(platform_id),),
        )
        row = cur.fetchone()

    if row is None:
        raise OwnerRezConfigError(
            f"OwnerRez platform binding missing for platform_id={platform_id}",
            failure_classification="missing_platform_binding",
        )

    platform_name = as_optional_string(row[0])
    provider_key = _canonical_provider_key(platform_name)
    if provider_key != "ownerrez":
        raise OwnerRezConfigError(
            f"platform_id={platform_id} is not an OwnerRez platform binding",
            failure_classification="invalid_platform_binding",
        )

    is_active = bool(row[2])
    if not is_active:
        raise OwnerRezConfigError(
            f"OwnerRez platform_id={platform_id} is inactive",
            failure_classification="inactive_platform_binding",
        )

    metadata = normalize_json_value(row[1]) or {}
    if not isinstance(metadata, dict):
        metadata = {}
    return metadata


def _resolve_ownerrez_secret_slot(metadata: Dict[str, Any]) -> Dict[str, Any] | None:
    secret_section = metadata.get("secret")
    if not isinstance(secret_section, dict):
        return None

    fallback_slot: Dict[str, Any] | None = None
    for token_key, token_config in secret_section.items():
        if not isinstance(token_config, dict):
            continue
        header_name = (
            as_optional_string(token_config.get("Name"))
            or as_optional_string(token_config.get("name"))
            or as_optional_string(token_key)
        )
        if header_name is None:
            continue
        slot = {
            "token_key": as_optional_string(token_key) or str(token_key),
            "header_name": header_name,
            "auth_type": as_optional_string(token_config.get("type")) or "API Key",
            "required": bool(token_config.get("required", True)),
            "secret_table_ptr": coerce_optional_int(
                token_config.get("secret_table_ptr"),
                field_name=f"secret_table_ptr[{header_name}]",
            ),
        }
        if fallback_slot is None:
            fallback_slot = slot
        if header_name.strip().lower() == "authorization":
            return slot
    return fallback_slot


def _resolve_ownerrez_platform_token(
    conn,
    *,
    platform_id: int,
    platform_metadata: Dict[str, Any] | None = None,
    allow_env_fallback: bool = False,
) -> str:
    metadata = (
        platform_metadata
        if platform_metadata is not None
        else _load_ownerrez_platform_metadata(conn, platform_id=platform_id)
    )
    secret_slot = _resolve_ownerrez_secret_slot(metadata)
    env_token = (
        as_optional_string(os.getenv("OWNERREZ_BEARER_TOKEN"))
        if allow_env_fallback
        else None
    )

    if secret_slot is None:
        if env_token:
            return env_token
        raise OwnerRezConfigError(
            f"OwnerRez platform_id={platform_id} is missing platform secret binding "
            "(platforms.metadata.secret.*.secret_table_ptr)",
            failure_classification="missing_platform_secret_binding",
        )

    token_key = as_optional_string(secret_slot.get("token_key")) or "Authorization"
    secret_ptr = coerce_optional_int(
        secret_slot.get("secret_table_ptr"), field_name=f"secret_table_ptr[{token_key}]"
    )
    if secret_ptr is None:
        if env_token:
            return env_token
        raise OwnerRezConfigError(
            f"OwnerRez platform_id={platform_id} missing secret_table_ptr at "
            f"platforms.metadata.secret.{token_key}.secret_table_ptr",
            failure_classification="missing_platform_secret_binding",
        )

    with conn.cursor() as cur:
        cur.execute("SELECT id FROM secrets WHERE id = %s", (int(secret_ptr),))
        secret_row = cur.fetchone()
    if secret_row is None:
        raise OwnerRezConfigError(
            f"OwnerRez platform_id={platform_id} token slot '{token_key}' points to missing secrets.id={secret_ptr}",
            failure_classification="missing_platform_secret_row",
        )

    try:
        with conn.cursor() as cur:
            cur.execute("SELECT get_secret(%s)", (int(secret_ptr),))
            row = cur.fetchone()
    except Exception as exc:
        raise OwnerRezConfigError(
            f"OwnerRez platform_id={platform_id} failed to resolve token from secrets.id={secret_ptr}",
            failure_classification="secret_resolution_failed",
        ) from exc

    secret_value = as_optional_string(row[0] if row else None)
    if secret_value is None:
        raise OwnerRezConfigError(
            f"OwnerRez platform_id={platform_id} token slot '{token_key}' resolved empty secret for secrets.id={secret_ptr}",
            failure_classification="missing_platform_secret_value",
        )

    if secret_value.lower().startswith("bearer "):
        secret_value = secret_value[7:].strip()
    if not secret_value:
        raise OwnerRezConfigError(
            f"OwnerRez platform_id={platform_id} token slot '{token_key}' resolved blank bearer token",
            failure_classification="missing_platform_secret_value",
        )
    return secret_value


def _resolve_ownerrez_fetch_base_url(*, platform_metadata: Dict[str, Any]) -> str:
    candidate = as_optional_string(
        os.getenv("OWNERREZ_API_BASE_URL")
    ) or as_optional_string(platform_metadata.get("domain"))
    if candidate is None:
        return DEFAULT_OWNERREZ_API_BASE_URL
    if "://" not in candidate:
        candidate = f"https://{candidate}"
    normalized = candidate.rstrip("/")
    if not normalized.lower().endswith("/v2"):
        normalized = f"{normalized}/v2"
    return normalized


def _build_ownerrez_client_for_platform(
    conn,
    *,
    platform_id: int,
    allow_env_fallback: bool = False,
) -> OwnerRezClient:
    metadata = _load_ownerrez_platform_metadata(conn, platform_id=platform_id)
    token = _resolve_ownerrez_platform_token(
        conn,
        platform_id=platform_id,
        platform_metadata=metadata,
        allow_env_fallback=allow_env_fallback,
    )
    return OwnerRezClient(
        token=token,
        base_url=_resolve_ownerrez_fetch_base_url(platform_metadata=metadata),
        ca_bundle=os.getenv("OWNERREZ_CA_BUNDLE"),
    )


def _get_ownerrez_fetch_client(*, connect_db, platform_id: int) -> OwnerRezClient:
    with connect_db() as conn:
        return _build_ownerrez_client_for_platform(
            conn, platform_id=platform_id, allow_env_fallback=False
        )


def _close_ownerrez_client(client: Any) -> None:
    close_fn = getattr(client, "close", None)
    if callable(close_fn):
        close_fn()


def _resolve_secret_from_env_fallback(fallback: Dict[str, Any]) -> Optional[str]:
    env_candidates: list[str] = []
    primary_env_var = as_optional_string(fallback.get("env_var"))
    if primary_env_var is not None:
        env_candidates.append(primary_env_var)
    for raw_env_var in fallback.get("env_var_aliases") or []:
        env_var = as_optional_string(raw_env_var)
        if env_var is not None:
            env_candidates.append(env_var)
    for env_var in env_candidates:
        value = as_optional_string(os.getenv(env_var))
        if value is not None:
            return value
    return None


def _wheelhouse_secret_role(config_key: Any, raw_config: Dict[str, Any]) -> str:
    header_name = (
        as_optional_string(raw_config.get("Name"))
        or as_optional_string(raw_config.get("name"))
        or as_optional_string(config_key)
        or ""
    ).strip().lower()
    token_key = (as_optional_string(config_key) or "").strip().lower()
    if header_name in {"x-integration-api-key", "x-integration-apikey"}:
        return "integration"
    if header_name in {"x-user-access-key", "x-user-accesskey"}:
        return "access"
    if header_name in {"x-user-api-key", "x-user-apikey"}:
        return "user"
    if "integration" in token_key or "rm api key" in token_key:
        return "integration"
    if "access key" in token_key:
        return "access"
    if token_key in {"api key", "user api key"} or "user api" in token_key:
        return "user"
    return "other"


def _canonicalize_wheelhouse_secret_objects(
    listing_metadata: Dict[str, Any],
    platform_metadata: Dict[str, Any],
) -> list[Dict[str, Any]]:
    candidates: list[Dict[str, Any]] = []
    for source_index, source in enumerate(
        (listing_metadata.get("secret"), platform_metadata.get("secret"))
    ):
        if not isinstance(source, dict):
            continue
        item_index = 0
        for config_key, raw_config in source.items():
            if not isinstance(raw_config, dict):
                continue
            role = _wheelhouse_secret_role(config_key, raw_config)
            has_configured_secret = (
                as_optional_string(raw_config.get("value")) is not None
                or coerce_optional_int(
                    raw_config.get("secret_table_ptr"),
                    field_name=f"secret_table_ptr[{config_key}]",
                )
                is not None
            )
            role_priority = {"integration": 0, "access": 1, "user": 2, "other": 3}.get(
                role, 3
            )
            candidates.append(
                {
                    "config_key": config_key,
                    "raw_config": raw_config,
                    "role_priority": role_priority,
                    "has_configured_secret": has_configured_secret,
                    "source_index": source_index,
                    "item_index": item_index,
                }
            )
            item_index += 1

    if not candidates:
        return []

    candidates.sort(
        key=lambda item: (
            0 if item["has_configured_secret"] else 1,
            int(item["role_priority"]),
            int(item["source_index"]),
            int(item["item_index"]),
        )
    )
    selected = candidates[0]["raw_config"]
    canonical_config: Dict[str, Any] = {
        "Name": "X-Integration-Api-Key",
        "type": as_optional_string(selected.get("type")) or "API Key",
        "required": True,
        "secret_table_ptr": selected.get("secret_table_ptr"),
    }
    raw_value = as_optional_string(selected.get("value"))
    if raw_value is not None:
        canonical_config["value"] = raw_value
    return [{"RM API Key": canonical_config}]


def _resolve_secret_headers(
    conn,
    *,
    provider_key: str,
    platform_metadata: Dict[str, Any],
    listing_metadata: Dict[str, Any],
) -> Dict[str, str]:
    headers: Dict[str, str] = {}
    if provider_key == "wheelhouse":
        secret_objects = _canonicalize_wheelhouse_secret_objects(
            listing_metadata, platform_metadata
        )
    else:
        secret_objects: list[Dict[str, Any]] = []
        for source in (listing_metadata.get("secret"), platform_metadata.get("secret")):
            if isinstance(source, dict):
                secret_objects.append(source)

    for secret_object in secret_objects:
        for config_key, raw_config in secret_object.items():
            if not isinstance(raw_config, dict):
                continue

            header_name = as_optional_string(
                raw_config.get("Name")
            ) or as_optional_string(raw_config.get("name"))
            if header_name is None:
                header_name = as_optional_string(config_key)
            if header_name is None or header_name in headers:
                continue

            secret_type = as_optional_string(raw_config.get("type")) or "API Key"
            required = bool(raw_config.get("required", True))
            raw_secret = as_optional_string(raw_config.get("value"))
            secret_ptr = coerce_optional_int(
                raw_config.get("secret_table_ptr"),
                field_name=f"secret_table_ptr[{header_name}]",
            )

            if raw_secret is None and secret_ptr is not None:
                try:
                    with conn.cursor() as cur:
                        cur.execute("SELECT get_secret(%s)", (int(secret_ptr),))
                        row = cur.fetchone()
                except Exception as exc:
                    raise ProcessInstructionPermanentError(
                        f"failed to resolve secret for header {header_name}",
                        error_code="SECRET_RESOLUTION_FAILED",
                    ) from exc
                raw_secret = as_optional_string(row[0] if row else None)

            if raw_secret is None:
                fallback = (
                    PROVIDER_FALLBACKS.get(provider_key, {})
                    .get("env_secrets", {})
                    .get(header_name, {})
                )
                raw_secret = _resolve_secret_from_env_fallback(fallback)
                if raw_secret is not None:
                    if raw_secret is not None and not secret_type:
                        secret_type = (
                            as_optional_string(fallback.get("type")) or "API Key"
                        )

            if raw_secret is None:
                if required:
                    raise ProcessInstructionPermanentError(
                        f"missing secret for header {header_name}",
                        error_code="SECRET_RESOLUTION_FAILED",
                    )
                continue

            if "bearer" in secret_type.lower() and not raw_secret.lower().startswith(
                "bearer "
            ):
                headers[header_name] = f"Bearer {raw_secret}"
            else:
                headers[header_name] = raw_secret

    if not headers:
        fallback_headers = PROVIDER_FALLBACKS.get(provider_key, {}).get(
            "env_secrets", {}
        )
        for header_name, fallback in fallback_headers.items():
            raw_secret = _resolve_secret_from_env_fallback(fallback)
            if raw_secret is None:
                continue
            secret_type = as_optional_string(fallback.get("type")) or "API Key"
            if "bearer" in secret_type.lower() and not raw_secret.lower().startswith(
                "bearer "
            ):
                headers[header_name] = f"Bearer {raw_secret}"
            else:
                headers[header_name] = raw_secret

    if not headers:
        raise ProcessInstructionPermanentError(
            f"{provider_key} credentials are not configured",
            error_code="SECRET_RESOLUTION_FAILED",
        )
    return headers


def resolve_instruction_target(
    payload: Dict[str, Any], instruction: Dict[str, Any]
) -> Dict[str, Any]:
    direct_target = payload.get("resolved_target")
    if isinstance(direct_target, dict):
        return dict(direct_target)

    conn = _process_instruction_db_conn()
    listing_column = _resolve_platform_property_lookup_listing_column(conn)
    platform_id = coerce_required_int(instruction, "platform_id")
    instruction_listing_id = as_optional_string(
        instruction.get("listing_id")
    ) or as_optional_string(instruction.get("platform_property_id"))
    if instruction_listing_id is None:
        raise ProcessInstructionPermanentError(
            "instruction.listing_id is required",
            error_code="LISTING_BINDING_NOT_FOUND",
        )

    sql = f"""
        SELECT
            p.id,
            p.name,
            p.metadata,
            ppl.{listing_column} AS listing_id,
            ppl.metadata,
            ppl.properties_ptr,
            ppl.self,
            ppl.id
        FROM platforms p
        LEFT JOIN platform_property_lookup ppl
               ON ppl.platform_id = p.id
              AND ppl.{listing_column} = %s
        WHERE p.id = %s
          AND p.is_active = TRUE
        LIMIT 1
    """
    with conn.cursor() as cur:
        cur.execute(sql, (instruction_listing_id, platform_id))
        row = cur.fetchone()

    if row is None:
        raise ProcessInstructionPermanentError(
            f"active platform {platform_id} was not found",
            error_code="TARGET_PLATFORM_NOT_FOUND",
        )

    platform_name = as_optional_string(row[1])
    provider_key = _canonical_provider_key(platform_name)
    if provider_key is None:
        raise ProcessInstructionPermanentError(
            f"unsupported provider platform '{platform_name or platform_id}'",
            error_code="UNSUPPORTED_INSTRUCTION",
        )

    listing_id = as_optional_string(row[3])
    if listing_id is None:
        raise ProcessInstructionPermanentError(
            f"listing binding not found for platform_id={platform_id} listing_id={instruction_listing_id}",
            error_code="LISTING_BINDING_NOT_FOUND",
        )

    platform_metadata = normalize_json_value(row[2]) or {}
    if not isinstance(platform_metadata, dict):
        platform_metadata = {}
    listing_metadata = normalize_json_value(row[4]) or {}
    if not isinstance(listing_metadata, dict):
        listing_metadata = {}
    _backfill_listing_currency_from_lookup_rows(
        conn,
        listing_metadata=listing_metadata,
        self_lookup_id=coerce_optional_int(row[6], field_name="lookup_self_id"),
        properties_ptr=coerce_optional_int(row[5], field_name="properties_ptr"),
        current_lookup_id=coerce_optional_int(row[7], field_name="lookup_id"),
    )

    if _process_instruction_mock_mode_enabled(provider_key):
        secret_headers: Dict[str, str] = {}
    else:
        secret_headers = _resolve_secret_headers(
            conn,
            provider_key=provider_key,
            platform_metadata=platform_metadata,
            listing_metadata=listing_metadata,
        )

    return {
        "provider_key": provider_key,
        "platform_id": int(row[0]),
        "platform_name": platform_name or provider_key,
        "platform_metadata": platform_metadata,
        "listing_id": listing_id,
        "listing_metadata": listing_metadata,
        "secret_headers": secret_headers,
        "properties_ptr": coerce_optional_int(row[5], field_name="properties_ptr"),
        "lookup_id": coerce_optional_int(row[7], field_name="lookup_id"),
    }


def _extract_listing_currency(metadata: Dict[str, Any]) -> Optional[str]:
    for key in ("currency_code", "currency"):
        value = as_optional_string(metadata.get(key))
        if value is not None:
            return value
    raw_metadata = metadata.get("raw")
    if isinstance(raw_metadata, dict):
        for key in ("currency_code", "currency"):
            value = as_optional_string(raw_metadata.get(key))
            if value is not None:
                return value
    return None


def _backfill_listing_currency_from_lookup_rows(
    conn,
    *,
    listing_metadata: Dict[str, Any],
    self_lookup_id: Optional[int],
    properties_ptr: Optional[int],
    current_lookup_id: Optional[int],
) -> None:
    if _extract_listing_currency(listing_metadata) is not None:
        return

    def _load_lookup_metadata(lookup_id: int) -> Optional[Dict[str, Any]]:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT metadata
                FROM platform_property_lookup
                WHERE id = %s
                LIMIT 1
                """,
                (int(lookup_id),),
            )
            row = cur.fetchone()
        candidate = normalize_json_value(row[0]) if row else None
        return candidate if isinstance(candidate, dict) else None

    if self_lookup_id is not None:
        self_metadata = _load_lookup_metadata(self_lookup_id)
        if isinstance(self_metadata, dict):
            derived = _extract_listing_currency(self_metadata)
            if derived is not None:
                listing_metadata["currency_code"] = derived
                return

    if properties_ptr is None:
        return

    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT id
            FROM platform_property_lookup
            WHERE properties_ptr = %s
              AND (%s IS NULL OR id <> %s)
            ORDER BY id ASC
            LIMIT 25
            """,
            (int(properties_ptr), current_lookup_id, current_lookup_id),
        )
        candidate_rows = cur.fetchall() or []

    for candidate_row in candidate_rows:
        candidate_id = coerce_optional_int(
            candidate_row[0], field_name="currency_lookup_candidate_id"
        )
        if candidate_id is None:
            continue
        candidate_metadata = _load_lookup_metadata(candidate_id)
        if not isinstance(candidate_metadata, dict):
            continue
        derived = _extract_listing_currency(candidate_metadata)
        if derived is not None:
            listing_metadata["currency_code"] = derived
            return


def _resolve_instruction_currency(
    instruction: Dict[str, Any], listing_metadata: Dict[str, Any]
) -> Optional[str]:
    execution_context = instruction.get("execution_context")
    if isinstance(execution_context, dict):
        for key in ("currency", "currency_code"):
            value = as_optional_string(execution_context.get(key))
            if value is not None:
                return value
    return _extract_listing_currency(listing_metadata)


def _resolve_execution_prices(
    instruction: Dict[str, Any], *, dates: list[str]
) -> Dict[str, Decimal]:
    execution_context = instruction.get("execution_context")
    if not isinstance(execution_context, dict):
        raise ProcessInstructionPermanentError(
            "instruction.execution_context.resolved_prices is required for this provider mapping",
            error_code="INSTRUCTION_UNMAPPABLE",
        )
    raw_prices = execution_context.get("resolved_prices")
    if not isinstance(raw_prices, dict):
        raise ProcessInstructionPermanentError(
            "instruction.execution_context.resolved_prices is required for this provider mapping",
            error_code="INSTRUCTION_UNMAPPABLE",
        )

    prices: Dict[str, Decimal] = {}
    for date_value in dates:
        if date_value not in raw_prices:
            raise ProcessInstructionPermanentError(
                f"resolved nightly price missing for {date_value}",
                error_code="INSTRUCTION_UNMAPPABLE",
            )
        prices[date_value] = _coerce_decimal(
            raw_prices.get(date_value),
            field_name=f"execution_context.resolved_prices[{date_value}]",
        )
    return prices


def _compress_iso_dates(dates: list[str]) -> list[tuple[str, str]]:
    if not dates:
        return []

    ordered = sorted(date.fromisoformat(value) for value in dates)
    ranges: list[tuple[str, str]] = []
    range_start = ordered[0]
    previous = ordered[0]

    for current in ordered[1:]:
        if current == previous + timedelta(days=1):
            previous = current
            continue
        ranges.append((range_start.isoformat(), previous.isoformat()))
        range_start = current
        previous = current

    ranges.append((range_start.isoformat(), previous.isoformat()))
    return ranges


def _provider_endpoint_spec(provider_key: str, *, remove: bool) -> Dict[str, str]:
    fallback = PROVIDER_FALLBACKS.get(provider_key, {})
    endpoint_key = (
        "spotrates" if provider_key == "ownerrez" else ("remove" if remove else "apply")
    )
    endpoint = fallback.get("endpoints", {}).get(endpoint_key) or {}
    return {
        "path": as_optional_string(endpoint.get("path")) or "",
        "transport_path": as_optional_string(endpoint.get("transport_path"))
        or as_optional_string(endpoint.get("path"))
        or "",
    }


def _normalize_baserates(value: Any) -> Dict[str, Decimal]:
    if not isinstance(value, list):
        return {}
    normalized: Dict[str, Decimal] = {}
    for index, row in enumerate(value):
        if not isinstance(row, dict):
            continue
        date_value = as_optional_string(row.get("date"))
        if date_value is None:
            continue
        try:
            date.fromisoformat(date_value)
        except ValueError:
            continue
        baserate_raw = row.get("baserate")
        if baserate_raw is None:
            baserate_raw = row.get("rate")
        if baserate_raw is None:
            continue
        try:
            normalized[date_value] = _coerce_decimal(
                baserate_raw,
                field_name=f"rates[{index}].rate",
            )
        except ProcessInstructionPermanentError:
            continue
    return normalized


def _resolve_platform_listing_lookup_id(
    conn,
    *,
    platform_id: int,
    listing_id: str,
) -> Optional[int]:
    listing_column = _resolve_platform_property_lookup_listing_column(conn)
    sql = f"""
        SELECT id
        FROM platform_property_lookup
        WHERE platform_id = %s
          AND {listing_column} = %s
        LIMIT 1
    """
    with conn.cursor() as cur:
        cur.execute(sql, (platform_id, listing_id))
        row = cur.fetchone()
    if row is None or row[0] is None:
        return None
    return int(row[0])


def _nightlyrates_has_rate_type_column(conn) -> bool:
    global _NIGHTLYRATES_HAS_RATE_TYPE_COLUMN
    if _NIGHTLYRATES_HAS_RATE_TYPE_COLUMN is not None:
        return bool(_NIGHTLYRATES_HAS_RATE_TYPE_COLUMN)
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT EXISTS (
                SELECT 1
                FROM information_schema.columns
                WHERE table_schema = 'public'
                  AND table_name = 'nightlyrates_listing'
                  AND column_name = 'rate_type'
            )
            """
        )
        row = cur.fetchone()
    _NIGHTLYRATES_HAS_RATE_TYPE_COLUMN = bool(row and row[0])
    return bool(_NIGHTLYRATES_HAS_RATE_TYPE_COLUMN)


def _load_original_nightly_rates(
    conn,
    *,
    ppl_id: int,
    start_date: Optional[str] = None,
    end_date: Optional[str] = None,
    rate_type: str = "base",
) -> Dict[str, Decimal]:
    normalized_rate_type = _normalize_rate_type(rate_type, default="base")
    params: list[Any] = [int(ppl_id)]
    sql = """
        SELECT date::text, rate
        FROM nightlyrates_listing
        WHERE ppl_id = %s
    """
    if _nightlyrates_has_rate_type_column(conn):
        sql += " AND rate_type = %s"
        params.append(normalized_rate_type)
    if start_date is not None:
        sql += " AND date >= %s::date"
        params.append(start_date)
    if end_date is not None:
        sql += " AND date <= %s::date"
        params.append(end_date)
    sql += " ORDER BY date ASC"

    with conn.cursor() as cur:
        cur.execute(sql, tuple(params))
        rows = cur.fetchall() or []

    normalized: Dict[str, Decimal] = {}
    for date_value, rate_value in rows:
        iso_date = as_optional_string(date_value)
        if iso_date is None:
            continue
        try:
            date.fromisoformat(iso_date)
        except ValueError:
            continue
        try:
            normalized[iso_date] = _coerce_decimal(
                rate_value,
                field_name=f"nightlyrates_listing[{ppl_id},{iso_date}]",
            )
        except ProcessInstructionPermanentError:
            continue
    return normalized


def _store_original_nightly_rates(
    conn,
    *,
    ppl_ids: list[int],
    rates: Dict[str, Decimal],
    rate_type: str = "base",
    metadata: Optional[Dict[str, Any]] = None,
) -> None:
    if not ppl_ids or not rates:
        return

    normalized_rate_type = _normalize_rate_type(rate_type, default="base")
    normalized_ppl_ids = sorted({int(value) for value in ppl_ids})
    normalized_metadata = dict(metadata) if isinstance(metadata, dict) else {}
    serialized_metadata = json.dumps(normalized_metadata, default=str)
    use_rate_type_column = _nightlyrates_has_rate_type_column(conn)

    rows_with_rate_type: list[tuple[int, str, float, str, str]] = []
    rows_legacy: list[tuple[int, str, float, str]] = []
    for ppl_id in normalized_ppl_ids:
        for date_value, amount in sorted(rates.items()):
            if use_rate_type_column:
                rows_with_rate_type.append(
                    (
                        ppl_id,
                        date_value,
                        _round_currency(amount),
                        normalized_rate_type,
                        serialized_metadata,
                    )
                )
            else:
                rows_legacy.append(
                    (
                        ppl_id,
                        date_value,
                        _round_currency(amount),
                        serialized_metadata,
                    )
                )

    with conn.cursor() as cur:
        if use_rate_type_column:
            cur.executemany(
                """
                INSERT INTO nightlyrates_listing (ppl_id, date, rate, rate_type, metadata)
                VALUES (%s, %s::date, %s, %s, %s::jsonb)
                ON CONFLICT (ppl_id, date, rate_type)
                DO NOTHING
                """,
                rows_with_rate_type,
            )
        else:
            cur.executemany(
                """
                INSERT INTO nightlyrates_listing (ppl_id, date, rate, metadata)
                VALUES (%s, %s::date, %s, %s::jsonb)
                ON CONFLICT (ppl_id, date)
                DO NOTHING
                """,
                rows_legacy,
            )


def _hydrate_instruction_execution_context_from_original_nightly_rates(
    conn,
    instruction: Dict[str, Any],
) -> Dict[str, Any]:
    platform_id = coerce_optional_int(
        instruction.get("platform_id"),
        field_name="instruction.platform_id",
    )
    listing_id = as_optional_string(
        instruction.get("listing_id")
    ) or as_optional_string(instruction.get("platform_property_id"))
    if platform_id is None or listing_id is None:
        raise ProcessInstructionPermanentError(
            "instruction.platform_id and instruction.listing_id are required for nightly rate hydration",
            error_code="BASELINE_RESOLUTION_FAILED",
        )

    ppl_id = _resolve_platform_listing_lookup_id(
        conn, platform_id=int(platform_id), listing_id=listing_id
    )
    if ppl_id is None:
        raise ProcessInstructionPermanentError(
            f"platform/listing mapping not found for platform_id={platform_id} listing_id={listing_id}",
            error_code="BASELINE_RESOLUTION_FAILED",
        )

    dates = _normalize_process_instruction_dates(instruction.get("dates"))
    target_rate_type = "base" if bool(instruction.get("remove")) else _normalize_rate_type(
        instruction.get("target_rate_type"),
        default="base",
    )
    original_rates = _load_original_nightly_rates(
        conn,
        ppl_id=int(ppl_id),
        start_date=min(dates),
        end_date=max(dates),
        rate_type=target_rate_type,
    )
    if not original_rates:
        raise ProcessInstructionPermanentError(
            f"original nightly rates not found for ppl_id {ppl_id} rate_type={target_rate_type}",
            error_code="BASELINE_RESOLUTION_FAILED",
        )

    missing_dates = [
        date_value for date_value in dates if date_value not in original_rates
    ]
    if missing_dates:
        raise ProcessInstructionPermanentError(
            "original nightly rates missing for rate_type="
            + target_rate_type
            + " dates: "
            + ", ".join(missing_dates),
            error_code="BASELINE_RESOLUTION_FAILED",
        )

    execution_context = instruction.get("execution_context")
    if not isinstance(execution_context, dict):
        execution_context = {}
    resolved_prices = execution_context.get("resolved_prices")
    if not isinstance(resolved_prices, dict):
        resolved_prices = {}

    for date_value in dates:
        if date_value not in resolved_prices:
            resolved_prices[date_value] = _round_currency(original_rates[date_value])

    execution_context["resolved_prices"] = resolved_prices
    execution_context["target_rate_type"] = target_rate_type
    if as_optional_string(execution_context.get("baseline_source")) is None:
        execution_context["baseline_source"] = "nightlyrates_listing"

    instruction["execution_context"] = execution_context
    return {
        "platform_id": int(platform_id),
        "listing_id": listing_id,
        "ppl_id": int(ppl_id),
        "target_rate_type": target_rate_type,
        "dates": dates,
        "hydrated_dates_count": len(dates),
    }


def _resolve_capture_payload_lookup_ids(
    conn, capture_payload: Dict[str, Any]
) -> list[int]:
    lookup_ids: set[int] = set()

    pairs: list[Dict[str, Any]] = []
    canonical_pair = capture_payload.get("canonical_pair")
    if isinstance(canonical_pair, dict):
        pairs.append(canonical_pair)
    for item in capture_payload.get("linked_listings_data") or []:
        if not isinstance(item, dict):
            continue
        platform_pair = item.get("platform_pair")
        if isinstance(platform_pair, dict):
            pairs.append(platform_pair)

    for raw_pair in pairs:
        platform_id = coerce_optional_int(
            raw_pair.get("platform_id"), field_name="platform_id"
        )
        listing_id = as_optional_string(raw_pair.get("listing_id"))
        if platform_id is None or listing_id is None:
            continue
        lookup_id = _resolve_platform_listing_lookup_id(
            conn,
            platform_id=int(platform_id),
            listing_id=listing_id,
        )
        if lookup_id is not None:
            lookup_ids.add(int(lookup_id))

    return sorted(lookup_ids)


def _resolve_platform_type(conn, platform_id: int) -> Optional[str]:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT type
            FROM platforms
            WHERE id = %s
            LIMIT 1
            """,
            (platform_id,),
        )
        row = cur.fetchone()
    return as_optional_string(row[0] if row else None)


def _parse_capture_base_rates_payload(payload: Dict[str, Any]) -> Dict[str, Any]:
    booking_id = coerce_optional_int(payload.get("booking_id"), field_name="booking_id")
    if booking_id is None:
        raise InstructionValidationError(
            "booking_id is required for capture_base_rates"
        )
    dates = _normalize_process_instruction_dates(payload.get("dates"))
    raw_required_rate_types = payload.get("required_rate_types")
    required_rate_types: list[str] = []
    if raw_required_rate_types is None:
        required_rate_types = ["base"]
    elif isinstance(raw_required_rate_types, list):
        seen_rate_types: set[str] = set()
        for index, raw_value in enumerate(raw_required_rate_types):
            normalized_rate_type = _normalize_rate_type(raw_value, default="")
            if normalized_rate_type not in SUPPORTED_RATE_TYPES:
                raise InstructionValidationError(
                    f"required_rate_types[{index}] must be one of: base, recommended, minimum, maximum"
                )
            if normalized_rate_type in seen_rate_types:
                continue
            seen_rate_types.add(normalized_rate_type)
            required_rate_types.append(normalized_rate_type)
        if not required_rate_types:
            required_rate_types = ["base"]
    else:
        raise InstructionValidationError("required_rate_types must be an array when provided")
    if "base" not in required_rate_types:
        required_rate_types.append("base")
    required_rate_types = sorted(set(required_rate_types))

    canonical_pair: Optional[Dict[str, Any]] = None
    raw_canonical_pair = payload.get("canonical_pair")
    if isinstance(raw_canonical_pair, dict):
        canonical_platform_id = coerce_optional_int(
            raw_canonical_pair.get("platform_id"),
            field_name="canonical_pair.platform_id",
        )
        canonical_listing_id = as_optional_string(raw_canonical_pair.get("listing_id"))
        if canonical_platform_id is not None and canonical_listing_id is not None:
            canonical_pair = {
                "platform_id": int(canonical_platform_id),
                "listing_id": canonical_listing_id,
            }

    raw_linked_listings = payload.get("linked_listings_data")
    if not isinstance(raw_linked_listings, list) or not raw_linked_listings:
        raise InstructionValidationError(
            "linked_listings_data must be a non-empty array"
        )

    linked_listings_data: list[Dict[str, Any]] = []
    for index, raw_item in enumerate(raw_linked_listings):
        if not isinstance(raw_item, dict):
            raise InstructionValidationError(
                f"linked_listings_data[{index}] must be an object"
            )
        raw_platform_pair = raw_item.get("platform_pair")
        if not isinstance(raw_platform_pair, dict):
            raise InstructionValidationError(
                f"linked_listings_data[{index}].platform_pair is required"
            )

        platform_id = coerce_optional_int(
            raw_platform_pair.get("platform_id"),
            field_name=f"linked_listings_data[{index}].platform_pair.platform_id",
        )
        if platform_id is None:
            raise InstructionValidationError(
                f"linked_listings_data[{index}].platform_pair.platform_id is required"
            )

        listing_id = as_optional_string(
            raw_platform_pair.get("listing_id")
        ) or as_optional_string(raw_platform_pair.get("platform_property_id"))
        if listing_id is None:
            raise InstructionValidationError(
                f"linked_listings_data[{index}].platform_pair.listing_id is required"
            )

        linked_listings_data.append(
            {
                "platform_pair": {
                    "platform_id": int(platform_id),
                    "listing_id": listing_id,
                    "platform_type": as_optional_string(
                        raw_platform_pair.get("platform_type")
                    ),
                    "is_canonical": bool(raw_platform_pair.get("is_canonical", False)),
                },
                "category": as_optional_string(raw_item.get("category"))
                or as_optional_string(raw_item.get("matched_category")),
                "rule_source": as_optional_string(raw_item.get("rule_source")),
                "base_rates": raw_item.get("base_rates"),
            }
        )

    return {
        "booking_id": int(booking_id),
        "canonical_pair": canonical_pair,
        "dates": dates,
        "required_rate_types": required_rate_types,
        "linked_listings_data": linked_listings_data,
    }


def _extract_first_candidate_value(
    payload: Any,
    *,
    candidate_fields: Sequence[str],
) -> Any:
    if not isinstance(payload, dict):
        return None
    for field_name in candidate_fields:
        if payload.get(field_name) is not None:
            return payload.get(field_name)
    return None


def _extract_date_rate_rows(
    payload: Any,
    *,
    candidate_fields: Sequence[str],
    depth: int = 0,
) -> list[tuple[str, Any]]:
    if depth > 6:
        return []

    rows: list[tuple[str, Any]] = []
    if isinstance(payload, list):
        for item in payload:
            rows.extend(
                _extract_date_rate_rows(
                    item,
                    candidate_fields=candidate_fields,
                    depth=depth + 1,
                )
            )
        return rows

    if not isinstance(payload, dict):
        return rows

    date_value = as_optional_string(payload.get("date")) or as_optional_string(
        payload.get("stay_date")
    )
    if date_value is not None:
        raw_rate = _extract_first_candidate_value(
            payload,
            candidate_fields=candidate_fields,
        )
        reason = payload.get("reason")
        if raw_rate is None and isinstance(reason, dict):
            for listing_info_key in ("listing_info", "listings_info"):
                raw_rate = _extract_first_candidate_value(
                    reason.get(listing_info_key),
                    candidate_fields=candidate_fields,
                )
                if raw_rate is not None:
                    break
        if raw_rate is not None:
            rows.append((date_value, raw_rate))

    for nested in payload.values():
        if isinstance(nested, (list, dict)):
            rows.extend(
                _extract_date_rate_rows(
                    nested,
                    candidate_fields=candidate_fields,
                    depth=depth + 1,
                )
            )
    return rows


def _extract_uniform_price(
    payload: Any, *, candidate_fields: Sequence[str]
) -> Optional[Decimal]:
    if not isinstance(payload, dict):
        return None
    for field_name in candidate_fields:
        if payload.get(field_name) is None:
            continue
        try:
            return _coerce_decimal(payload.get(field_name), field_name=field_name)
        except ProcessInstructionPermanentError:
            return None
    return None


def _candidate_fields_for_rate_type(rate_type: str) -> tuple[str, ...]:
    normalized_rate_type = _normalize_rate_type(rate_type, default="base")
    if normalized_rate_type == "minimum":
        return (
            "minimum_price",
            "min_price",
            "minimum_nightly_rate",
            "min_nightly_rate",
            "minimum",
            "min",
        )
    if normalized_rate_type == "maximum":
        return (
            "maximum_price",
            "max_price",
            "maximum_nightly_rate",
            "max_nightly_rate",
            "maximum",
            "max",
        )
    if normalized_rate_type == "recommended":
        return (
            "recommended_price",
            "price",
            "recommended",
            "recommended_base_price",
            "base_price",
            "base",
            "nightly_rate",
            "amount",
        )
    return (
        "base_price",
        "base",
        "price",
        "recommended_price",
        "recommended_base_price",
        "nightly_rate",
        "amount",
    )


def _extract_rates_for_dates(
    payload: Any,
    *,
    dates: list[str],
    rate_type: str,
    allow_uniform_fallback: bool,
) -> Dict[str, Decimal]:
    candidate_fields = _candidate_fields_for_rate_type(rate_type)
    requested = set(dates)
    rates: Dict[str, Decimal] = {}
    for date_value, raw_rate in _extract_date_rate_rows(
        payload,
        candidate_fields=candidate_fields,
    ):
        if date_value not in requested or date_value in rates:
            continue
        rates[date_value] = _coerce_decimal(raw_rate, field_name=f"rate[{date_value}]")

    if len(rates) == len(requested):
        return rates

    if allow_uniform_fallback:
        uniform_rate = _extract_uniform_price(
            payload, candidate_fields=candidate_fields
        )
    else:
        uniform_rate = None
    if uniform_rate is not None:
        for date_value in dates:
            rates.setdefault(date_value, uniform_rate)
    return rates


def _raise_for_provider_read_status(
    response: httpx.Response,
    *,
    provider_key: str,
    method: str,
    path: str,
) -> None:
    if response.status_code in PROCESS_INSTRUCTION_RETRYABLE_STATUS_CODES:
        raise ProcessInstructionRetryableError(
            _response_error_message(
                response, provider_key=provider_key, method=method, path=path
            ),
            error_code="BASELINE_RESOLUTION_FAILED",
        )
    if (
        response.status_code in PROCESS_INSTRUCTION_PERMANENT_STATUS_CODES
        or response.is_error
    ):
        raise ProcessInstructionPermanentError(
            _response_error_message(
                response, provider_key=provider_key, method=method, path=path
            ),
            error_code="BASELINE_RESOLUTION_FAILED",
        )


def _fetch_pricelabs_rates(
    target: Dict[str, Any],
    *,
    dates: list[str],
    rate_type: str,
    log_event=None,
) -> Dict[str, Decimal]:
    listing_id = str(target["listing_id"])
    start_date = min(dates)
    end_date = max(dates)
    listing_metadata = (
        target.get("listing_metadata")
        if isinstance(target.get("listing_metadata"), dict)
        else {}
    )
    pms = resolve_pricelabs_pms(listing_metadata, as_optional_string)
    strict_contract = _pricelabs_strict_api_contract_enabled()
    legacy_body: Dict[str, Any] = {
        "listing_ids": [listing_id],
        "start_date": start_date,
        "end_date": end_date,
    }
    if pms is not None:
        legacy_body["pms"] = pms

    with PriceLabsClient(
        base_url=str(target["base_url"]),
        headers=(
            target.get("headers") if isinstance(target.get("headers"), dict) else {}
        ),
        timeout=target.get("timeout"),
        verify=target.get("verify", True),
        transport=target.get("transport"),
    ) as client:
        if strict_contract:
            if pms is None:
                raise ProcessInstructionPermanentError(
                    "PriceLabs listing metadata is missing pms",
                    error_code="BASELINE_RESOLUTION_FAILED",
                )
            try:
                response = client.get_listing_prices(
                    listing_id=listing_id,
                    pms=pms,
                    date_from=start_date,
                    date_to=end_date,
                    reason=True,
                    log_event=log_event,
                )
            except (ValueError, PriceLabsUnexpectedStatusError) as exc:
                raise ProcessInstructionPermanentError(
                    str(exc),
                    error_code="BASELINE_RESOLUTION_FAILED",
                ) from exc
        else:
            response = client.request(
                "POST", "/v1/listing_prices", json=legacy_body, log_event=log_event
            )
            _raise_for_provider_read_status(
                response,
                provider_key="pricelabs",
                method="POST",
                path="/v1/listing_prices",
            )
        try:
            payload = response.json()
        except ValueError as exc:
            raise ProcessInstructionPermanentError(
                "pricelabs listing_prices returned invalid JSON",
                error_code="BASELINE_RESOLUTION_FAILED",
            ) from exc
    normalized_rate_type = _normalize_rate_type(rate_type, default="base")
    return _extract_rates_for_dates(
        payload,
        dates=dates,
        rate_type=normalized_rate_type,
        allow_uniform_fallback=normalized_rate_type in RECOMMENDED_LIKE_RATE_TYPES,
    )


def _fetch_pricelabs_overrides(
    target: Dict[str, Any],
    *,
    log_event=None,
) -> Dict[str, Any]:
    listing_id = str(target["listing_id"])
    listing_metadata = (
        target.get("listing_metadata")
        if isinstance(target.get("listing_metadata"), dict)
        else {}
    )
    pms = resolve_pricelabs_pms(listing_metadata, as_optional_string)
    if pms is None:
        raise ProcessInstructionPermanentError(
            "PriceLabs listing metadata is missing pms",
            error_code="BASELINE_RESOLUTION_FAILED",
        )

    with PriceLabsClient(
        base_url=str(target["base_url"]),
        headers=(
            target.get("headers") if isinstance(target.get("headers"), dict) else {}
        ),
        timeout=target.get("timeout"),
        verify=target.get("verify", True),
        transport=target.get("transport"),
    ) as client:
        try:
            response = client.get_listing_overrides(
                listing_id=listing_id,
                pms=pms,
                log_event=log_event,
            )
        except (ValueError, PriceLabsUnexpectedStatusError) as exc:
            raise ProcessInstructionPermanentError(
                str(exc),
                error_code="BASELINE_RESOLUTION_FAILED",
            ) from exc
        try:
            payload = response.json()
        except ValueError as exc:
            raise ProcessInstructionPermanentError(
                "pricelabs overrides returned invalid JSON",
                error_code="BASELINE_RESOLUTION_FAILED",
            ) from exc
    return payload


def _wheelhouse_rate_query_params(listing_metadata: Dict[str, Any]) -> Dict[str, Any]:
    params: Dict[str, Any] = {}
    currency = as_optional_string(
        listing_metadata.get("currency")
    ) or as_optional_string(listing_metadata.get("currency_code"))
    channel = resolve_wheelhouse_channel(listing_metadata, as_optional_string)
    attribution_raw = listing_metadata.get("attribution")
    price_model = as_optional_string(listing_metadata.get("price_model"))
    if currency is not None:
        params["currency"] = currency
    if channel is not None:
        params["channel"] = channel
    if isinstance(attribution_raw, bool):
        params["attribution"] = "true" if attribution_raw else "false"
    else:
        attribution_text = as_optional_string(attribution_raw)
        if attribution_text is not None and attribution_text.lower() in {
            "true",
            "false",
        }:
            params["attribution"] = attribution_text.lower()
    if price_model is not None:
        params["price_model"] = price_model
    return params


def _fetch_wheelhouse_rates(
    target: Dict[str, Any],
    *,
    dates: list[str],
    rate_type: str,
    log_event=None,
) -> Dict[str, Decimal]:
    listing_id = str(target["listing_id"])
    listing_metadata = (
        target.get("listing_metadata")
        if isinstance(target.get("listing_metadata"), dict)
        else {}
    )
    params = _wheelhouse_rate_query_params(listing_metadata)
    normalized_rate_type = _normalize_rate_type(rate_type, default="base")
    if normalized_rate_type in MINMAX_RATE_TYPES:
        path = f"/ss_api/v1/listings/{listing_id}/min_max_prices"
    else:
        path = f"/ss_api/v1/listings/{listing_id}/price_recommendations"

    with WheelhouseClient(
        base_url=str(target["base_url"]),
        headers=(
            target.get("headers") if isinstance(target.get("headers"), dict) else {}
        ),
        timeout=target.get("timeout"),
        verify=target.get("verify", True),
        transport=target.get("transport"),
    ) as client:
        response = client.request("GET", path, params=params, log_event=log_event)
        _raise_for_provider_read_status(
            response, provider_key="wheelhouse", method="GET", path=path
        )
        try:
            payload = response.json()
        except ValueError as exc:
            raise ProcessInstructionPermanentError(
                "wheelhouse nightly rates endpoint returned invalid JSON",
                error_code="BASELINE_RESOLUTION_FAILED",
            ) from exc
        return _extract_rates_for_dates(
            payload,
            dates=dates,
            rate_type=normalized_rate_type,
            allow_uniform_fallback=False,
        )

    return {}


def _fetch_wheelhouse_override_nightly_rates(
    target: Dict[str, Any],
    *,
    dates: Optional[list[str]] = None,
    log_event=None,
) -> list[Dict[str, Any]]:
    listing_id = str(target["listing_id"])
    listing_metadata = (
        target.get("listing_metadata")
        if isinstance(target.get("listing_metadata"), dict)
        else {}
    )
    params = _wheelhouse_rate_query_params(listing_metadata)
    path = f"/ss_api/v1/listings/{listing_id}/price_recommendations"
    requested_dates = set(str(value) for value in (dates or []))

    with WheelhouseClient(
        base_url=str(target["base_url"]),
        headers=(
            target.get("headers") if isinstance(target.get("headers"), dict) else {}
        ),
        timeout=target.get("timeout"),
        verify=target.get("verify", True),
        transport=target.get("transport"),
    ) as client:
        response = client.request("GET", path, params=params, log_event=log_event)
        _raise_for_provider_read_status(
            response, provider_key="wheelhouse", method="GET", path=path
        )
        try:
            payload = response.json()
        except ValueError as exc:
            raise ProcessInstructionPermanentError(
                "wheelhouse price_recommendations returned invalid JSON",
                error_code="BASELINE_RESOLUTION_FAILED",
            ) from exc

        data_rows = payload.get("data") if isinstance(payload, dict) else None
        if not isinstance(data_rows, list):
            return []

        result: list[Dict[str, Any]] = []
        for row in data_rows:
            if not isinstance(row, dict):
                continue
            stay_date = as_optional_string(row.get("stay_date")) or as_optional_string(
                row.get("date")
            )
            if stay_date is None:
                continue
            if requested_dates and stay_date not in requested_dates:
                continue
            custom_type = as_optional_string(row.get("custom_type"))
            normalized_custom_type = (
                custom_type.lower() if custom_type is not None else ""
            )
            result.append(
                {
                    "date": stay_date,
                    "price": row.get("price"),
                    "currency": as_optional_string(row.get("currency")),
                    "custom_type": custom_type,
                    "is_overridden": normalized_custom_type
                    in {"fixed", "adjusted", "adjustment"},
                }
            )
        return sorted(result, key=lambda item: str(item.get("date") or ""))

    return []


def _resolve_rates_from_provider(
    target: Dict[str, Any],
    *,
    dates: list[str],
    rate_type: str,
    log_event=None,
) -> Dict[str, Decimal]:
    provider_key = _canonical_provider_key(target.get("provider_key"))
    if provider_key is None:
        raise ProcessInstructionPermanentError(
            "provider_key is required for nightly rate capture",
            error_code="BASELINE_RESOLUTION_FAILED",
        )

    if _process_instruction_mock_mode_enabled(provider_key):
        return {date_value: Decimal("100.00") for date_value in dates}

    if provider_key == "pricelabs":
        return _fetch_pricelabs_rates(
            target, dates=dates, rate_type=rate_type, log_event=log_event
        )
    if provider_key == "wheelhouse":
        return _fetch_wheelhouse_rates(
            target, dates=dates, rate_type=rate_type, log_event=log_event
        )

    raise ProcessInstructionPermanentError(
        f"{provider_key} does not provide a supported nightly-rate retrieval method",
        error_code="BASELINE_RESOLUTION_FAILED",
    )


def _fetch_pricelabs_base_rates(
    target: Dict[str, Any],
    *,
    dates: list[str],
    log_event=None,
) -> Dict[str, Decimal]:
    return _fetch_pricelabs_rates(
        target, dates=dates, rate_type="base", log_event=log_event
    )


def _fetch_wheelhouse_base_rates(
    target: Dict[str, Any],
    *,
    dates: list[str],
    log_event=None,
) -> Dict[str, Decimal]:
    return _fetch_wheelhouse_rates(
        target, dates=dates, rate_type="base", log_event=log_event
    )


def _resolve_base_rates_from_provider(
    target: Dict[str, Any],
    *,
    dates: list[str],
    log_event=None,
) -> Dict[str, Decimal]:
    return _resolve_rates_from_provider(
        target, dates=dates, rate_type="base", log_event=log_event
    )


def _resolve_rates_for_capture_payload(
    conn,
    capture_payload: Dict[str, Any],
    *,
    rate_type: str,
    log_event=None,
) -> Dict[str, Any]:
    normalized_rate_type = _normalize_rate_type(rate_type, default="base")
    dates = [str(value) for value in capture_payload.get("dates") or []]
    linked_listings_data = [
        dict(item)
        for item in capture_payload.get("linked_listings_data") or []
        if isinstance(item, dict)
    ]
    if not linked_listings_data:
        raise ProcessInstructionPermanentError(
            "linked_listings_data is required for capture_base_rates",
            error_code="BASELINE_RESOLUTION_FAILED",
        )

    sorted_candidates = sorted(
        linked_listings_data,
        key=lambda item: (
            BASE_RATE_PLATFORM_PRIORITY.get(
                as_optional_string(
                    (item.get("platform_pair") or {}).get("platform_type")
                )
                or "",
                99,
            ),
            0 if bool((item.get("platform_pair") or {}).get("is_canonical")) else 1,
            int((item.get("platform_pair") or {}).get("platform_id") or 0),
        ),
    )

    resolved_rates: Dict[str, Decimal] = {}
    source_provider_key: Optional[str] = None
    source_platform_id: Optional[int] = None

    for candidate in sorted_candidates:
        platform_pair = (
            candidate.get("platform_pair")
            if isinstance(candidate.get("platform_pair"), dict)
            else {}
        )
        platform_id = coerce_optional_int(
            platform_pair.get("platform_id"), field_name="platform_id"
        )
        listing_id = as_optional_string(platform_pair.get("listing_id"))
        if platform_id is None or listing_id is None:
            continue

        inline_base_rates = None
        if normalized_rate_type == "recommended":
            inline_base_rates = candidate.get("recommended_rates") or candidate.get(
                "base_rates"
            )
        elif normalized_rate_type in {"minimum", "maximum"}:
            inline_base_rates = candidate.get(f"{normalized_rate_type}_rates")
        else:
            inline_base_rates = candidate.get("base_rates")
        inline_rates: Dict[str, Decimal] = {}
        if isinstance(inline_base_rates, dict):
            for date_value in dates:
                if date_value not in inline_base_rates:
                    continue
                inline_rates[date_value] = _coerce_decimal(
                    inline_base_rates.get(date_value),
                    field_name=f"base_rates[{date_value}]",
                )
        elif isinstance(inline_base_rates, list):
            inline_rates = _normalize_baserates(inline_base_rates)

        if inline_rates:
            for date_value in dates:
                if date_value in inline_rates and date_value not in resolved_rates:
                    resolved_rates[date_value] = inline_rates[date_value]
            if resolved_rates and source_provider_key is None:
                source_provider_key = "inline"
                source_platform_id = int(platform_id)
            if len(resolved_rates) == len(dates):
                break
            continue

        platform_type = as_optional_string(
            platform_pair.get("platform_type")
        ) or _resolve_platform_type(conn, int(platform_id))
        if platform_type is not None:
            platform_pair["platform_type"] = platform_type

        if (
            platform_type is not None
            and BASE_RATE_PLATFORM_PRIORITY.get(platform_type, 99) > 1
        ):
            continue

        try:
            token = _PROCESS_INSTRUCTION_DB_CONN.set(conn)
            try:
                target = resolve_instruction_target(
                    {},
                    {"platform_id": int(platform_id), "listing_id": listing_id},
                )
            finally:
                _PROCESS_INSTRUCTION_DB_CONN.reset(token)
            target["base_url"] = _normalize_domain(
                (target.get("platform_metadata") or {}).get("domain"),
                provider_key=str(target["provider_key"]),
            )
            target["headers"] = (
                target.get("secret_headers")
                if isinstance(target.get("secret_headers"), dict)
                else {}
            )
            rates = _resolve_rates_from_provider(
                target,
                dates=dates,
                rate_type=normalized_rate_type,
                log_event=log_event,
            )
        except ProcessInstructionRetryableError:
            raise
        except ProcessInstructionPermanentError:
            continue
        except Exception as exc:
            raise ProcessInstructionRetryableError(
                f"failed to capture rate_type={normalized_rate_type} for platform_id={platform_id}: {exc}",
                error_code="BASELINE_RESOLUTION_FAILED",
            ) from exc

        if not rates:
            continue

        for date_value in dates:
            if date_value in rates and date_value not in resolved_rates:
                resolved_rates[date_value] = rates[date_value]

        if resolved_rates and source_provider_key is None:
            source_provider_key = _canonical_provider_key(target.get("provider_key"))
            source_platform_id = int(platform_id)

        if len(resolved_rates) == len(dates):
            break

    missing_dates = [
        date_value for date_value in dates if date_value not in resolved_rates
    ]
    if missing_dates:
        raise ProcessInstructionPermanentError(
            "failed to resolve rate_type="
            + normalized_rate_type
            + " for dates: "
            + ", ".join(missing_dates),
            error_code="BASELINE_RESOLUTION_FAILED",
        )

    return {
        "rates": resolved_rates,
        "rate_type": normalized_rate_type,
        "source_provider_key": source_provider_key,
        "source_platform_id": source_platform_id,
    }


def _resolve_base_rates_for_capture_payload(
    conn,
    capture_payload: Dict[str, Any],
    *,
    log_event=None,
) -> Dict[str, Any]:
    # Compatibility wrapper for existing tests/patch points.
    return _resolve_rates_for_capture_payload(
        conn,
        capture_payload,
        rate_type="base",
        log_event=log_event,
    )


def build_execution_plan(
    target: Dict[str, Any], instruction: Dict[str, Any]
) -> Dict[str, Any]:
    provider_key = _canonical_provider_key(
        target.get("provider_key")
    ) or _canonical_provider_key(target.get("platform_name"))
    if provider_key is None:
        raise ProcessInstructionPermanentError(
            "instruction target provider is unsupported",
            error_code="UNSUPPORTED_INSTRUCTION",
        )

    subject = as_optional_string(instruction.get("subject"))
    if subject != "price":
        raise ProcessInstructionPermanentError(
            f"unsupported instruction subject '{subject or ''}'".strip(),
            error_code="UNSUPPORTED_INSTRUCTION",
        )

    operation = _normalize_instruction_operation(instruction.get("operation"))
    if operation not in SUPPORTED_INSTRUCTION_OPERATIONS:
        raise ProcessInstructionPermanentError(
            f"unsupported instruction operation '{operation or ''}'".strip(),
            error_code="UNSUPPORTED_INSTRUCTION",
        )

    instruction_type = _normalize_instruction_type(
        instruction.get("type"), operation=operation
    )
    if instruction_type not in SUPPORTED_INSTRUCTION_TYPES:
        raise ProcessInstructionPermanentError(
            f"unsupported instruction type '{instruction_type or ''}'".strip(),
            error_code="UNSUPPORTED_INSTRUCTION",
        )
    _validate_instruction_operation_type(
        operation=operation, instruction_type=instruction_type
    )

    remove = bool(instruction.get("remove"))
    target_rate_type = "base" if remove else _normalize_rate_type(
        instruction.get("target_rate_type"),
        default="base",
    )
    dates = _normalize_process_instruction_dates(instruction.get("dates"))
    amount = (
        Decimal("0")
        if remove
        else _coerce_decimal(instruction.get("amount"), field_name="instruction.amount")
    )
    listing_id = (
        as_optional_string(target.get("listing_id"))
        or as_optional_string(instruction.get("listing_id"))
        or as_optional_string(instruction.get("platform_property_id"))
    )
    if listing_id is None:
        if provider_key == "ownerrez":
            raise ProcessInstructionPermanentError(
                "OwnerRez property_id must come from listing_id/platform_property_id (not internal property_id)",
                error_code="LISTING_BINDING_NOT_FOUND",
            )
        raise ProcessInstructionPermanentError(
            "instruction target listing_id is missing",
            error_code="LISTING_BINDING_NOT_FOUND",
        )

    platform_metadata = (
        target.get("platform_metadata")
        if isinstance(target.get("platform_metadata"), dict)
        else {}
    )
    listing_metadata = (
        target.get("listing_metadata")
        if isinstance(target.get("listing_metadata"), dict)
        else {}
    )
    base_url = _normalize_domain(
        platform_metadata.get("domain"), provider_key=provider_key
    )
    headers = {
        str(key): str(value)
        for key, value in (target.get("secret_headers") or {}).items()
        if as_optional_string(key) is not None and as_optional_string(value) is not None
    }

    normalized_target: Dict[str, Any] = dict(target)
    normalized_target.update(
        {
            "provider_key": provider_key,
            "listing_id": listing_id,
            "platform_metadata": platform_metadata,
            "listing_metadata": listing_metadata,
            "base_url": base_url,
            "headers": headers,
        }
    )
    normalized_instruction: Dict[str, Any] = dict(instruction)
    normalized_instruction.update(
        {
            "operation": operation,
            "type": instruction_type,
            "remove": remove,
            "target_rate_type": target_rate_type,
            "dates": list(dates),
            "amount": amount,
        }
    )

    provider = get_provider_adapter(provider_key)
    if provider is None:
        raise ProcessInstructionPermanentError(
            f"unsupported provider '{provider_key}'",
            error_code="UNSUPPORTED_INSTRUCTION",
        )
    return provider.build_execution_plan(
        normalized_target, normalized_instruction, _provider_helpers()
    )


def _extract_provider_request_id(response: httpx.Response) -> Optional[str]:
    for header_name in (
        "x-request-id",
        "request-id",
        "x-amzn-requestid",
        "x-correlation-id",
    ):
        value = as_optional_string(response.headers.get(header_name))
        if value is not None:
            return value

    try:
        payload = response.json()
    except ValueError:
        payload = None
    if isinstance(payload, dict):
        for field_name in (
            "request_id",
            "requestId",
            "correlation_id",
            "correlationId",
        ):
            value = as_optional_string(payload.get(field_name))
            if value is not None:
                return value
    return None


def _response_error_message(
    response: httpx.Response, *, provider_key: str, method: str, path: str
) -> str:
    detail: Optional[str] = None
    try:
        payload = response.json()
    except ValueError:
        payload = None
    if isinstance(payload, dict):
        for field_name in ("message", "detail", "error", "errors"):
            candidate = payload.get(field_name)
            if isinstance(candidate, list):
                candidate = "; ".join(str(item) for item in candidate)
            detail = as_optional_string(candidate)
            if detail is not None:
                break
    if detail is None:
        detail = as_optional_string(response.text)
    if detail is not None and len(detail) > 240:
        detail = f"{detail[:237]}..."
    status_text = f"{response.status_code} {response.reason_phrase}".strip()
    if detail is not None:
        return f"{provider_key} {method} {path} returned {status_text}: {detail}"
    return f"{provider_key} {method} {path} returned {status_text}"


def _execute_plan_mock(
    *,
    provider_key: str,
    http_calls: list[Any],
    affected_dates: list[str],
) -> Dict[str, Any]:
    http_statuses: list[int] = []
    provider_request_ids: list[str] = []

    for index, raw_call in enumerate(http_calls, start=1):
        if not isinstance(raw_call, dict):
            raise ProcessInstructionPermanentError(
                "provider execution plan contains an invalid http_call entry",
                error_code="PROVIDER_CONFIG_MISSING",
            )
        method = (as_optional_string(raw_call.get("method")) or "").upper()
        path = as_optional_string(raw_call.get("path"))
        transport_path = as_optional_string(raw_call.get("transport_path")) or path
        if not method or path is None or transport_path is None:
            raise ProcessInstructionPermanentError(
                "provider execution plan contains an incomplete http_call entry",
                error_code="PROVIDER_CONFIG_MISSING",
            )

        provider_request_ids.append(f"mock-{provider_key}-{index}")
        if random.random() < PROCESS_INSTRUCTION_MOCK_REQUEST_FAILURE_RATE:
            http_statuses.append(503)
            raise ProcessInstructionRetryableError(
                f"mocked {provider_key} {method} {path} returned 503 Service Unavailable (debug mode)"
            )

        http_statuses.append(200)

    return {
        "provider_key": provider_key,
        "success": True,
        "partial_success": False,
        "http_statuses": http_statuses,
        "provider_request_ids": provider_request_ids,
        "affected_dates": affected_dates,
        "error": None,
    }


def execute_plan(
    plan: Dict[str, Any],
    *,
    log_event=None,
) -> Dict[str, Any]:
    provider_key = _canonical_provider_key(plan.get("provider_key"))
    if provider_key is None:
        raise ProcessInstructionPermanentError(
            "provider execution plan is missing provider_key",
            error_code="PROVIDER_CONFIG_MISSING",
        )
    provider = get_provider_adapter(provider_key)
    if provider is None:
        raise ProcessInstructionPermanentError(
            f"unsupported provider '{provider_key}'",
            error_code="UNSUPPORTED_INSTRUCTION",
        )
    return _call_with_optional_log_event(
        provider.execute_plan, plan, _provider_helpers(), log_event=log_event
    )


def _handle_process_instruction_capture_base_rates(
    context: ManagedWorkerContext,
    task: Task,
    *,
    source_action: Optional[str],
    log_event=None,
) -> None:
    queue = context.main_queue
    step = default_step(context)
    log = default_app_logger(context)
    state = ActionStateManager.load(context, task)
    payload = task.payload if isinstance(task.payload, dict) else {}
    action_name = source_action or PROCESS_INSTRUCTION_ACTION

    try:
        capture_payload = _parse_capture_base_rates_payload(payload)
    except InstructionValidationError as exc:
        log.error(
            "invalid capture_base_rates payload",
            exc=exc,
            error_code=exc.error_code,
            **task_log_kwargs(task, "handle_process_instruction_capture_base_rates"),
        )
        state.record_failure("capture_payload_validated", str(exc))
        queue.fail_task(task, str(exc), retry=False)
        return

    if not state.is_step_done("capture_payload_validated"):
        state.begin_step("capture_payload_validated")
        state.checkpoint(
            "capture_payload_validated",
            {
                "booking_id": int(capture_payload["booking_id"]),
                "date_count": len(capture_payload["dates"]),
                "linked_listing_count": len(capture_payload["linked_listings_data"]),
            },
        )

    if not state.is_step_done("capture_completed"):
        state.begin_step("capture_completed")
        try:
            with context.connect_db() as conn:
                required_rate_types = [
                    _normalize_rate_type(value, default="base")
                    for value in capture_payload.get("required_rate_types") or []
                ]
                if not required_rate_types:
                    required_rate_types = ["base"]
                lookup_ids = _resolve_capture_payload_lookup_ids(conn, capture_payload)
                if not lookup_ids:
                    raise ProcessInstructionPermanentError(
                        "failed to resolve target platform/listing lookup ids for capture_base_rates",
                        error_code="BASELINE_RESOLUTION_FAILED",
                    )
                resolutions: Dict[str, Dict[str, Any]] = {}
                for rate_type in sorted(set(required_rate_types)):
                    resolved = _call_with_optional_log_event(
                        _resolve_rates_for_capture_payload,
                        conn,
                        capture_payload,
                        rate_type=rate_type,
                        log_event=log_event,
                    )
                    resolutions[rate_type] = dict(resolved)
                    _store_original_nightly_rates(
                        conn,
                        ppl_ids=lookup_ids,
                        rates=dict(resolved["rates"]),
                        rate_type=rate_type,
                        metadata={
                            "booking_id": int(capture_payload["booking_id"]),
                            "source_provider_key": as_optional_string(
                                resolved.get("source_provider_key")
                            ),
                            "source_platform_id": resolved.get("source_platform_id"),
                        },
                    )
            state.checkpoint(
                "capture_completed",
                {
                    "booking_id": int(capture_payload["booking_id"]),
                    "dates": list(capture_payload["dates"]),
                    "required_rate_types": sorted(set(required_rate_types)),
                    "resolved_dates_count": sum(
                        len((resolutions.get(rate_type) or {}).get("rates") or {})
                        for rate_type in sorted(set(required_rate_types))
                    ),
                    "target_lookup_count": len(lookup_ids),
                    "target_lookup_ids": list(lookup_ids),
                    "resolution_sources_by_rate_type": {
                        rate_type: {
                            "source_provider_key": as_optional_string(
                                (resolutions.get(rate_type) or {}).get(
                                    "source_provider_key"
                                )
                            ),
                            "source_platform_id": (
                                resolutions.get(rate_type) or {}
                            ).get("source_platform_id"),
                        }
                        for rate_type in sorted(set(required_rate_types))
                    },
                },
            )
        except ProcessInstructionRetryableError as exc:
            log.error(
                "capture_base_rates failed transiently",
                exc=exc,
                error_code=exc.error_code,
                **task_log_kwargs(
                    task, "handle_process_instruction_capture_base_rates"
                ),
            )
            state.record_failure("capture_completed", str(exc))
            queue.fail_task(task, str(exc), retry=True)
            return
        except ProcessInstructionPermanentError as exc:
            log.error(
                "capture_base_rates failed permanently",
                exc=exc,
                error_code=exc.error_code,
                **task_log_kwargs(
                    task, "handle_process_instruction_capture_base_rates"
                ),
            )
            state.record_failure("capture_completed", str(exc))
            queue.fail_task(task, str(exc), retry=False)
            return
        except Exception as exc:
            log.error(
                "capture_base_rates failed",
                exc=exc,
                error_code="BASELINE_RESOLUTION_FAILED",
                **task_log_kwargs(
                    task, "handle_process_instruction_capture_base_rates"
                ),
            )
            state.record_failure("capture_completed", str(exc))
            queue.fail_task(task, str(exc), retry=True)
            return

    captured = state.get_step_data("capture_completed")
    result = {
        "status": "base_rates_captured",
        "booking_id": int(captured["booking_id"]),
        "dates": list(captured.get("dates") or []),
        "required_rate_types": [
            str(value) for value in captured.get("required_rate_types") or []
        ],
        "resolved_dates_count": int(captured.get("resolved_dates_count") or 0),
        "target_lookup_count": int(captured.get("target_lookup_count") or 0),
        "resolution_sources_by_rate_type": captured.get(
            "resolution_sources_by_rate_type"
        ),
    }
    step.log("external services capture_base_rates completed", result)
    log.info("task completed", metadata=result, **task_log_kwargs(task, action_name))
    queue.complete_task(task, result)


def _validate_process_instruction_payload(task: Task) -> Dict[str, Any]:
    payload = task.payload if isinstance(task.payload, dict) else {}
    instruction_id = coerce_required_int(payload, "instruction_id")
    instruction_uuid = as_optional_string(payload.get("instruction_uuid"))
    if instruction_uuid is None:
        raise InstructionValidationError("instruction_uuid is required")

    instruction = payload.get("instruction")
    if not isinstance(instruction, dict):
        raise InstructionValidationError("instruction is required")

    nested_instruction_uuid = as_optional_string(instruction.get("instruction_uuid"))
    if nested_instruction_uuid is None:
        raise InstructionValidationError("instruction.instruction_uuid is required")
    if nested_instruction_uuid != instruction_uuid:
        raise InstructionValidationError(
            "instruction_uuid must match instruction.instruction_uuid"
        )

    remove = instruction.get("remove")
    if not isinstance(remove, bool):
        raise InstructionValidationError("instruction.remove must be boolean")

    instruction_listing_id = as_optional_string(
        instruction.get("listing_id")
    ) or as_optional_string(instruction.get("platform_property_id"))
    if instruction_listing_id is None:
        raise InstructionValidationError("instruction.listing_id is required")

    dates = _normalize_process_instruction_dates(instruction.get("dates"))
    return_ref = normalize_return_ref(
        payload,
        default_queue=as_optional_string(getattr(task, "queue_name", None))
        or PRIMARY_QUEUE,
    )
    if return_ref is None:
        raise InstructionValidationError("return_ref is required")
    if as_optional_string(return_ref.get("action")) != "instruction_result":
        raise InstructionValidationError("return_ref.action must be instruction_result")

    return {
        "instruction_id": instruction_id,
        "instruction_uuid": instruction_uuid,
        "source_instruction_id": coerce_optional_int(
            payload.get("source_instruction_id"),
            field_name="source_instruction_id",
        ),
        "instruction": instruction,
        "return_ref": return_ref,
        "remove": remove,
        "dates": dates,
        "platform_id": coerce_required_int(instruction, "platform_id"),
    }


def handle_process_instruction(
    context: ManagedWorkerContext,
    task: Task,
    *,
    source_action: Optional[str] = None,
) -> None:
    queue = context.main_queue
    step = default_step(context)
    log = default_app_logger(context)
    state = ActionStateManager.load(context, task)
    payload = task.payload if isinstance(task.payload, dict) else {}
    action_name = source_action or PROCESS_INSTRUCTION_ACTION
    provider_http_log_event = _make_provider_http_log_event(
        log=log,
        task=task,
        action_name="handle_process_instruction",
    )
    mode = as_optional_string(payload.get("mode"))
    if mode == PROCESS_INSTRUCTION_CAPTURE_BASE_RATES_MODE:
        _handle_process_instruction_capture_base_rates(
            context,
            task,
            source_action=source_action,
            log_event=_make_provider_http_log_event(
                log=log,
                task=task,
                action_name="handle_process_instruction_capture_base_rates",
            ),
        )
        return

    try:
        validated = _validate_process_instruction_payload(task)
    except InstructionValidationError as exc:
        log.error(
            "invalid process_instruction payload",
            exc=exc,
            error_code=exc.error_code,
            **task_log_kwargs(task, "handle_process_instruction"),
        )
        state.record_failure("instruction_validated", str(exc))
        queue.fail_task(task, str(exc), retry=False)
        return

    if not state.is_step_done("instruction_validated"):
        state.begin_step("instruction_validated")
        state.checkpoint(
            "instruction_validated",
            {
                "instruction_id": validated["instruction_id"],
                "instruction_uuid": validated["instruction_uuid"],
                "remove": validated["remove"],
                "provider_platform_id": validated["platform_id"],
                "date_count": len(validated["dates"]),
            },
        )

    if not state.is_step_done("instruction_hydrated"):
        state.begin_step("instruction_hydrated")
        hydrated_instruction = dict(validated["instruction"])
        try:
            with context.connect_db() as conn:
                hydration = (
                    _hydrate_instruction_execution_context_from_original_nightly_rates(
                        conn, hydrated_instruction
                    )
                )
        except ProcessInstructionPermanentError as exc:
            log.error(
                "instruction nightly rate hydration failed permanently",
                exc=exc,
                error_code=exc.error_code,
                **task_log_kwargs(task, "handle_process_instruction"),
            )
            state.record_failure("instruction_hydrated", str(exc))
            queue.fail_task(task, str(exc), retry=False)
            return
        except Exception as exc:
            log.error(
                "instruction nightly rate hydration failed",
                exc=exc,
                error_code="BASELINE_RESOLUTION_FAILED",
                **task_log_kwargs(task, "handle_process_instruction"),
            )
            state.record_failure("instruction_hydrated", str(exc))
            queue.fail_task(task, str(exc), retry=True)
            return

        validated["instruction"] = hydrated_instruction
        state.checkpoint(
            "instruction_hydrated",
            {
                "platform_id": int(hydration["platform_id"]),
                "listing_id": str(hydration["listing_id"]),
                "ppl_id": int(hydration["ppl_id"]),
                "target_rate_type": str(hydration["target_rate_type"]),
                "hydrated_dates_count": int(hydration["hydrated_dates_count"]),
                "instruction": hydrated_instruction,
            },
        )
    else:
        hydrated_data = state.get_step_data("instruction_hydrated")
        hydrated_instruction = hydrated_data.get("instruction")
        if isinstance(hydrated_instruction, dict):
            validated["instruction"] = dict(hydrated_instruction)

    execution_result: Optional[Dict[str, Any]] = None
    if state.is_step_done("provider_executed"):
        checkpoint_result = state.get_step_data("provider_executed").get(
            "execution_result"
        )
        if isinstance(checkpoint_result, dict):
            execution_result = dict(checkpoint_result)

    if execution_result is None:
        target: Optional[Dict[str, Any]] = None
        try:
            state.begin_step("target_bound")
            with context.connect_db() as conn:
                token = _PROCESS_INSTRUCTION_DB_CONN.set(conn)
                try:
                    target = resolve_instruction_target(
                        payload, validated["instruction"]
                    )
                finally:
                    _PROCESS_INSTRUCTION_DB_CONN.reset(token)
            if not state.is_step_done("target_bound"):
                state.checkpoint(
                    "target_bound",
                    {
                        "provider_key": as_optional_string(target.get("provider_key")),
                        "listing_id": as_optional_string(target.get("listing_id")),
                        "binding_fields_present": sorted(
                            str(key)
                            for key in (target.get("listing_metadata") or {}).keys()
                            if as_optional_string(key) is not None
                        ),
                    },
                )
        except ProcessInstructionPermanentError as exc:
            log.error(
                "instruction target resolution failed",
                exc=exc,
                error_code=exc.error_code,
                **task_log_kwargs(task, "handle_process_instruction"),
            )
            state.record_failure("target_bound", str(exc))
            execution_result = _process_instruction_error_result(
                provider_key=None,
                affected_dates=validated["dates"],
                error=str(exc),
            )
        except Exception as exc:
            log.error(
                "instruction target resolution failed",
                exc=exc,
                error_code="TARGET_PLATFORM_NOT_FOUND",
                **task_log_kwargs(task, "handle_process_instruction"),
            )
            state.record_failure("target_bound", str(exc))
            execution_result = _process_instruction_error_result(
                provider_key=None,
                affected_dates=validated["dates"],
                error=str(exc),
            )

        plan: Optional[Dict[str, Any]] = None
        if execution_result is None:
            try:
                state.begin_step("execution_planned")
                plan = build_execution_plan(target or {}, validated["instruction"])
                if not state.is_step_done("execution_planned"):
                    state.checkpoint(
                        "execution_planned",
                        {
                            "provider_key": as_optional_string(
                                plan.get("provider_key")
                            ),
                            "http_call_count": len(plan.get("http_calls") or []),
                            "baseline_required": bool(plan.get("baseline_required")),
                            "baseline_source": as_optional_string(
                                plan.get("baseline_source")
                            ),
                        },
                    )
            except ProcessInstructionPermanentError as exc:
                log.error(
                    "instruction planning failed",
                    exc=exc,
                    error_code=exc.error_code,
                    **task_log_kwargs(task, "handle_process_instruction"),
                )
                state.record_failure("execution_planned", str(exc))
                execution_result = _process_instruction_error_result(
                    provider_key=as_optional_string((target or {}).get("provider_key")),
                    affected_dates=validated["dates"],
                    error=str(exc),
                )
            except Exception as exc:
                log.error(
                    "instruction planning failed",
                    exc=exc,
                    error_code="INSTRUCTION_UNMAPPABLE",
                    **task_log_kwargs(task, "handle_process_instruction"),
                )
                state.record_failure("execution_planned", str(exc))
                execution_result = _process_instruction_error_result(
                    provider_key=as_optional_string((target or {}).get("provider_key")),
                    affected_dates=validated["dates"],
                    error=str(exc),
                )

        if execution_result is None:
            assert plan is not None
            try:
                state.begin_step("provider_executed")
                execution_result = _normalize_execution_result(
                    plan,
                    _call_with_optional_log_event(
                        execute_plan,
                        plan,
                        log_event=provider_http_log_event,
                    ),
                )
                if _execution_result_is_retryable(execution_result):
                    raise ProcessInstructionRetryableError(
                        as_optional_string(execution_result.get("error"))
                        or "provider execution failed transiently"
                    )
            except ProcessInstructionRetryableError as exc:
                log.error(
                    "instruction execution failed transiently",
                    exc=exc,
                    error_code=exc.error_code,
                    **task_log_kwargs(task, "handle_process_instruction"),
                )
                state.record_failure("provider_executed", str(exc))
                queue.fail_task(task, str(exc), retry=True)
                return
            except ProcessInstructionPermanentError as exc:
                log.error(
                    "instruction execution failed permanently",
                    exc=exc,
                    error_code=exc.error_code,
                    **task_log_kwargs(task, "handle_process_instruction"),
                )
                state.record_failure("provider_executed", str(exc))
                execution_result = _process_instruction_error_result(
                    provider_key=as_optional_string(plan.get("provider_key")),
                    affected_dates=list(plan.get("affected_dates") or []),
                    error=str(exc),
                )
            except Exception as exc:
                log.error(
                    "instruction execution failed",
                    exc=exc,
                    error_code="PROVIDER_REQUEST_FAILED",
                    **task_log_kwargs(task, "handle_process_instruction"),
                )
                state.record_failure("provider_executed", str(exc))
                queue.fail_task(task, str(exc), retry=True)
                return

            state.checkpoint(
                "provider_executed",
                {
                    "provider_key": as_optional_string(
                        execution_result.get("provider_key")
                    ),
                    "success": bool(execution_result.get("success")),
                    "partial_success": bool(execution_result.get("partial_success")),
                    "http_statuses": list(execution_result.get("http_statuses") or []),
                    "affected_dates": list(
                        execution_result.get("affected_dates") or []
                    ),
                    "execution_result": execution_result,
                },
            )

    execution_result = execution_result or _process_instruction_error_result(
        provider_key=None,
        affected_dates=validated["dates"],
        error="instruction execution did not produce a result",
    )
    callback_result = (
        "success"
        if bool(execution_result.get("success"))
        and not bool(execution_result.get("partial_success"))
        else "failed"
    )
    callback_error = as_optional_string(execution_result.get("error"))

    callback_task_uuid: Optional[str] = None
    if not state.is_step_done("callback_enqueued"):
        state.begin_step("callback_enqueued")
        callback_payload = {
            "action": validated["return_ref"]["action"],
            "instruction_id": validated["instruction_id"],
            "instruction_uuid": validated["instruction_uuid"],
            "source_instruction_id": validated["source_instruction_id"],
            "remove": validated["remove"],
            "result": callback_result,
            "error": None if callback_result == "success" else callback_error,
        }
        try:
            callback_task_uuid = enqueue_with_meta(
                context.queue(str(validated["return_ref"]["queue"] or PRIMARY_QUEUE)),
                str(validated["return_ref"]["worker"]),
                callback_payload,
                current_task=task,
                current_worker=WORKER,
                current_action=action_name,
                next_worker=str(validated["return_ref"]["worker"]),
                next_action=str(validated["return_ref"]["action"]),
            )
        except Exception as exc:
            log.error(
                "failed to enqueue instruction_result callback",
                exc=exc,
                error_code="CALLBACK_ENQUEUE_FAILED",
                **task_log_kwargs(task, "handle_process_instruction"),
            )
            state.record_failure("callback_enqueued", str(exc))
            queue.fail_task(
                task, f"enqueue instruction_result callback failed: {exc}", retry=True
            )
            return
        state.checkpoint(
            "callback_enqueued",
            {
                "callback_task_uuid": callback_task_uuid,
                "callback_result": callback_result,
            },
        )
    else:
        callback_task_uuid = as_optional_string(
            state.get_step_data("callback_enqueued").get("callback_task_uuid")
        )

    result = {
        "status": "processed",
        "instruction_id": validated["instruction_id"],
        "instruction_uuid": validated["instruction_uuid"],
        "provider_key": as_optional_string(execution_result.get("provider_key")),
        "result": callback_result,
        "remove": validated["remove"],
        "partial_success": bool(execution_result.get("partial_success")),
        "http_statuses": list(execution_result.get("http_statuses") or []),
        "callback_task_uuid": callback_task_uuid,
    }
    if callback_result != "success":
        result["status"] = "failed"
        result["error"] = callback_error

    step.log("external services process_instruction completed", result)
    if callback_result != "success":
        log.error(
            "task failed after callback enqueue",
            metadata=result,
            error_code="PROCESS_INSTRUCTION_FAILED",
            **task_log_kwargs(task, "handle_process_instruction"),
        )
        queue.fail_task(
            task,
            callback_error or "process_instruction failed permanently",
            retry=False,
        )
        return

    log.info(
        "task completed",
        metadata=result,
        **task_log_kwargs(task, "handle_process_instruction"),
    )
    queue.complete_task(task, result)


def _warn_runtime_variable_unavailable(
    log: AppLogger,
    task: Task,
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
        **task_log_kwargs(task, action_name),
    )


def _resolve_dummy_messages_dir() -> Path:
    candidates: list[Path] = []
    env_dir = os.getenv("PWS_DUMMY_MESSAGES_DIR")
    if env_dir:
        candidates.append(Path(env_dir))
    candidates.extend(
        [
            REPO_ROOT / "data" / "dummy_messages",
            WORKERS_ROOT.parent / "data" / "dummy_messages",
        ]
    )

    seen: set[str] = set()
    unique_candidates: list[Path] = []
    for candidate in candidates:
        key = str(candidate)
        if key in seen:
            continue
        seen.add(key)
        unique_candidates.append(candidate)

    for candidate in unique_candidates:
        if candidate.exists():
            return candidate

    return unique_candidates[0]


LOCAL_DUMMY_MESSAGES_DIR = _resolve_dummy_messages_dir()
LOCAL_CLASSIFIER_CSV = LOCAL_DUMMY_MESSAGES_DIR / "thread-category-summary.csv"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="External services worker")
    parser.add_argument("--dsn", default=None, help="Postgres DSN")
    parser.add_argument(
        "--auto-dsn", action="store_true", help="Build DSN from .env/env vars"
    )
    parser.add_argument(
        "--db-name", default=None, help="DB name override when auto-building DSN"
    )
    parser.add_argument(
        "--log-dir",
        default=str(CURRENT_DIR / "logs"),
        help="Directory for worker log files",
    )
    parser.add_argument(
        "--poll-interval", type=float, default=1.0, help="Seconds between polls"
    )
    add_common_worker_args(parser)
    return parser.parse_args()


def _normalize_data_ref(
    payload: Dict[str, Any], *, default_scope: str
) -> Dict[str, Optional[str]]:
    data_ref = (
        payload.get("data_ref") if isinstance(payload.get("data_ref"), dict) else {}
    )
    return {
        "worker_id": as_optional_string(data_ref.get("worker_id")),
        "scope": as_optional_string(data_ref.get("scope")) or default_scope,
        "key": as_optional_string(data_ref.get("key")),
    }


def _resolve_runtime_ttl(
    *, action: str, scope: str, default_ttl_minutes: int = RUNTIME_TTL_MINUTES
) -> int:
    return resolve_runtime_variable_ttl(
        RUNTIME_VARIABLE_TTL_CONFIG,
        action=action,
        scope=scope,
        default_ttl_minutes=default_ttl_minutes,
    )


def _classify_items_dummy(
    items: list[Dict[str, Any]], *, dsn: str
) -> list[Dict[str, Any]]:
    classifier = MockMessageClassifier(dsn=dsn, csv_path=LOCAL_CLASSIFIER_CSV)
    results: list[Dict[str, Any]] = []
    for row in classifier.classify_messages(items):
        record = json.loads(row) if isinstance(row, str) else row
        if not isinstance(record, dict):
            raise ValueError("classifier response must be a JSON object")
        pk = coerce_optional_int(record.get("pk"), field_name="pk")
        category = as_optional_string(record.get("category"))
        if pk is None:
            raise ValueError("classifier response missing pk")
        if not category:
            raise ValueError("classifier response missing category")
        results.append({"pk": pk, "class": category})
    return results


def _classify_items_live(
    items: list[Dict[str, Any]],
    *,
    conn: Any | None = None,
    allowed_categories: list[str],
    category_descriptions: Optional[Dict[str, str]] = None,
    app_logger: Optional[Any] = None,
    app_log_kwargs: Optional[Dict[str, Any]] = None,
) -> tuple[list[Dict[str, Any]], Any]:
    config = _resolve_live_classifier_config(conn)
    provider = config["provider"]
    if provider == CLASSIFIER_PROVIDER_OLLAMA:
        try:
            classifier = OllamaMessageClassifier(
                api_url=config.get("api_base_url"),
                model=config.get("model"),
                timeout_seconds=config.get("timeout_seconds"),
                category_descriptions=category_descriptions,
                app_logger=app_logger,
                app_log_kwargs=app_log_kwargs,
            )
        except RuntimeError as exc:
            raise OllamaClassificationError(
                str(exc),
                error_code="OLLAMA_UNAVAILABLE",
                retryable=True,
            ) from exc
    else:
        classifier = OpenAIMessageClassifier(
            api_key=config.get("api_key"),
            api_base_url=config.get("api_base_url"),
            model=config.get("model"),
            timeout_seconds=config.get("timeout_seconds"),
            category_descriptions=category_descriptions,
            app_logger=app_logger,
            app_log_kwargs=app_log_kwargs,
        )
    return classifier.classify_messages(items, allowed_categories=allowed_categories)


def _resolve_db_llm_classifier_config(conn) -> Optional[Dict[str, Any]]:
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT to_regclass('public.llm_providers')")
            table_row = cur.fetchone()
            if not table_row or table_row[0] is None:
                return None
            cur.execute(
                """
                SELECT
                    provider_key,
                    display_name,
                    api_key_secret_id,
                    selected_model,
                    timeout_seconds,
                    api_base_url,
                    metadata
                FROM llm_providers
                WHERE is_active = TRUE
                  AND enabled = TRUE
                  AND use_case = 'message_classifier'
                ORDER BY updated_at DESC, id DESC
                LIMIT 1
                """
            )
            row = cur.fetchone()
    except Exception:
        try:
            conn.rollback()
        except Exception:
            pass
        return None

    if not row:
        return None

    provider = as_optional_string(
        row[0] if len(row) > 0 else None
    ) or as_optional_string(row[1] if len(row) > 1 else None)
    if provider is None:
        return None
    provider = provider.lower()

    secret_ptr = coerce_optional_int(
        row[2] if len(row) > 2 else None, field_name="api_key_secret_id"
    )
    selected_model = as_optional_string(row[3] if len(row) > 3 else None)
    timeout_seconds = coerce_optional_int(
        row[4] if len(row) > 4 else None, field_name="timeout_seconds"
    )

    api_key: Optional[str] = None
    if secret_ptr is not None:
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT get_secret(%s)", (int(secret_ptr),))
                secret_row = cur.fetchone()
        except Exception:
            secret_row = None
        api_key = as_optional_string(secret_row[0] if secret_row else None)

    return {
        "provider": provider,
        "api_key": api_key,
        "model": selected_model,
        "api_base_url": as_optional_string(row[5] if len(row) > 5 else None),
        "timeout_seconds": (
            float(timeout_seconds) if timeout_seconds is not None else None
        ),
        "source": "database",
    }


def _resolve_live_classifier_config(conn: Any | None = None) -> Dict[str, Any]:
    env_provider = _resolve_explicit_live_classifier_provider_from_env()
    if env_provider is None and conn is not None:
        db_config = _resolve_db_llm_classifier_config(conn)
        if db_config and db_config.get("provider"):
            provider = as_optional_string(db_config.get("provider"))
            if provider in {CLASSIFIER_PROVIDER_OPENAI, CLASSIFIER_PROVIDER_OLLAMA}:
                if provider == CLASSIFIER_PROVIDER_OPENAI:
                    model = (
                        as_optional_string(db_config.get("model"))
                        or as_optional_string(os.getenv("PWS_MESSAGE_CLASSIFIER_MODEL"))
                        or as_optional_string(os.getenv("OPENAI_LLM_MODEL"))
                        or DEFAULT_LLM_CLASSIFIER_MODEL
                    )
                else:
                    model = (
                        as_optional_string(db_config.get("model"))
                        or as_optional_string(os.getenv("OLLAMA_MODEL"))
                        or as_optional_string(os.getenv("PWS_MESSAGE_CLASSIFIER_MODEL"))
                        or DEFAULT_OLLAMA_CLASSIFIER_MODEL
                    )
                return {
                    "provider": provider,
                    "api_key": as_optional_string(db_config.get("api_key")),
                    "model": model,
                    "api_base_url": as_optional_string(db_config.get("api_base_url")),
                    "timeout_seconds": db_config.get("timeout_seconds"),
                    "source": "database",
                }

    provider = env_provider or _resolve_live_classifier_provider()
    if provider == CLASSIFIER_PROVIDER_OLLAMA:
        model = (
            as_optional_string(os.getenv("OLLAMA_MODEL"))
            or as_optional_string(os.getenv("PWS_MESSAGE_CLASSIFIER_MODEL"))
            or DEFAULT_OLLAMA_CLASSIFIER_MODEL
        )
        return {
            "provider": provider,
            "api_key": None,
            "model": model,
            "api_base_url": as_optional_string(os.getenv("OLLAMA_API_URL"))
            or as_optional_string(os.getenv("OLLAMA_BASE_URL")),
            "timeout_seconds": None,
            "source": "env",
        }

    model = (
        as_optional_string(os.getenv("PWS_MESSAGE_CLASSIFIER_MODEL"))
        or as_optional_string(os.getenv("OPENAI_LLM_MODEL"))
        or DEFAULT_LLM_CLASSIFIER_MODEL
    )
    return {
        "provider": provider,
        "api_key": as_optional_string(os.getenv("OPENAI_API_KEY")),
        "model": model,
        "api_base_url": as_optional_string(os.getenv("OPENAI_API_BASE_URL")),
        "timeout_seconds": None,
        "source": "env",
    }


def _resolve_explicit_live_classifier_provider_from_env() -> Optional[str]:
    raw_provider = as_optional_string(os.getenv(CLASSIFIER_PROVIDER_ENV))
    if raw_provider is None:
        return None

    provider = raw_provider.strip().lower()
    if provider in {CLASSIFIER_PROVIDER_OPENAI, CLASSIFIER_PROVIDER_OLLAMA}:
        return provider

    raise ValueError(
        f"Unsupported {CLASSIFIER_PROVIDER_ENV} value '{raw_provider}'. "
        f"Expected '{CLASSIFIER_PROVIDER_OPENAI}' or '{CLASSIFIER_PROVIDER_OLLAMA}'."
    )


def _resolve_live_classifier_provider() -> str:
    provider = _resolve_explicit_live_classifier_provider_from_env()
    if provider is None:
        return DEFAULT_LIVE_CLASSIFIER_PROVIDER

    return provider


def _resolve_live_classifier_model() -> str:
    provider = _resolve_live_classifier_provider()
    if provider == CLASSIFIER_PROVIDER_OLLAMA:
        return (
            as_optional_string(os.getenv("OLLAMA_MODEL"))
            or as_optional_string(os.getenv("PWS_MESSAGE_CLASSIFIER_MODEL"))
            or DEFAULT_OLLAMA_CLASSIFIER_MODEL
        )
    return (
        as_optional_string(os.getenv("PWS_MESSAGE_CLASSIFIER_MODEL"))
        or as_optional_string(os.getenv("OPENAI_LLM_MODEL"))
        or DEFAULT_LLM_CLASSIFIER_MODEL
    )


def _fetch_active_message_classes(conn) -> list[Dict[str, str]]:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT name, description
            FROM message_classes
            WHERE is_active = TRUE
            ORDER BY name
            """
        )
        rows = cur.fetchall() or []
    categories: list[Dict[str, str]] = []
    for row in rows:
        name = as_optional_string(
            row[0] if isinstance(row, (list, tuple)) and row else None
        )
        description = as_optional_string(
            row[1] if isinstance(row, (list, tuple)) and len(row) > 1 else None
        )
        if name:
            categories.append(
                {
                    "name": name,
                    "description": description or f"Message category '{name}'.",
                }
            )
    return categories


def _has_required_fallback_class(categories: list[str]) -> bool:
    required = REQUIRED_FALLBACK_CLASS.lower()
    for category in categories:
        value = as_optional_string(category)
        if value and value.lower() == required:
            return True
    return False


def _normalize_live_results(
    raw_results: list[Dict[str, Any]],
    *,
    allowed_categories: list[str],
    log: AppLogger,
    task: Task,
) -> list[Dict[str, Any]]:
    if not isinstance(raw_results, list):
        raise ValueError("classifier response must be a list")

    allowed_map: dict[str, str] = {}
    for category in allowed_categories:
        value = as_optional_string(category)
        if value:
            allowed_map[value.lower()] = value

    fallback_category = allowed_map.get(REQUIRED_FALLBACK_CLASS.lower())
    normalized: list[Dict[str, Any]] = []
    for row in raw_results:
        if not isinstance(row, dict):
            raise ValueError("classifier response items must be objects")
        pk = coerce_optional_int(row.get("pk"), field_name="pk")
        category = as_optional_string(row.get("class"))
        if pk is None:
            raise ValueError("classifier response missing pk")
        if not category:
            raise ValueError("classifier response missing class")
        mapped = allowed_map.get(category.lower())
        if mapped is None:
            if not fallback_category:
                raise ValueError(
                    "classifier returned unknown category and 'unclassified' is missing from message_classes"
                )
            log.warn(
                "classifier returned unknown category; mapped to unclassified",
                metadata={
                    "pk": pk,
                    "returned_category": category,
                    "mapped_category": fallback_category,
                },
                **task_log_kwargs(task, "handle_classify_messages"),
            )
            mapped = fallback_category
        normalized.append({"pk": pk, "class": mapped})
    return normalized


def _record_llm_usage(
    conn,
    *,
    action_name: str,
    task: Task,
    usage: LLMUsage,
    success: bool,
    error_code: Optional[str] = None,
    error_message: Optional[str] = None,
) -> None:
    metadata = usage.metadata if isinstance(usage.metadata, dict) else {}
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO llm_model_usage (
                worker_name,
                action_name,
                task_uuid,
                provider,
                model,
                prompt_tokens,
                completion_tokens,
                total_tokens,
                success,
                error_code,
                error_message,
                latency_ms,
                response_id,
                metadata
            ) VALUES (
                %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s::jsonb
            )
            """,
            (
                WORKER,
                action_name,
                as_optional_string(getattr(task, "task_uuid", None)),
                as_optional_string(usage.provider) or "openai",
                as_optional_string(usage.model) or DEFAULT_LLM_CLASSIFIER_MODEL,
                usage.prompt_tokens,
                usage.completion_tokens,
                usage.total_tokens,
                bool(success),
                as_optional_string(error_code),
                as_optional_string(error_message),
                usage.latency_ms,
                as_optional_string(usage.response_id),
                json.dumps(metadata, default=str),
            ),
        )


def _fetch_dummy_messages(
    *, thread_id: int, offset: Optional[int], limit: Optional[int], **_kwargs: Any
) -> Dict[str, Any]:
    if not LOCAL_DUMMY_MESSAGES_DIR.exists():
        raise FileNotFoundError(
            f"Dummy messages directory not found: {LOCAL_DUMMY_MESSAGES_DIR}. "
            "Set PWS_DUMMY_MESSAGES_DIR or ensure data/dummy_messages is available in the worker runtime."
        )
    client = DummyMessages(base_dir=LOCAL_DUMMY_MESSAGES_DIR)
    return client.get(thread_id=thread_id, offset=offset, limit=limit)


def _provider_http_log_event(
    *,
    log: AppLogger,
    task: Task,
    action_name: str,
    level: str,
    message: str,
    metadata: Dict[str, Any],
) -> None:
    event_metadata = sanitize_http_metadata(
        metadata if isinstance(metadata, dict) else {}
    )
    event_metadata.setdefault("provider_key", "unknown")

    kwargs = task_log_kwargs(task, action_name)
    normalized_level = str(level or "").strip().lower()
    if normalized_level == "debug":
        log.debug(message, metadata=event_metadata, **kwargs)
        return
    if normalized_level == "warn":
        log.warn(message, metadata=event_metadata, **kwargs)
        return
    if normalized_level == "error":
        log.error(message, metadata=event_metadata, **kwargs)
        return
    log.info(message, metadata=event_metadata, **kwargs)


def _call_with_optional_log_event(func, *args, log_event=None, **kwargs):
    if log_event is None:
        return func(*args, **kwargs)

    try:
        signature = inspect.signature(func)
    except (TypeError, ValueError):
        signature = None

    supports_log_event = False
    if signature is not None:
        for parameter in signature.parameters.values():
            if (
                parameter.kind == inspect.Parameter.VAR_KEYWORD
                or parameter.name == "log_event"
            ):
                supports_log_event = True
                break

    if supports_log_event:
        return func(*args, log_event=log_event, **kwargs)
    return func(*args, **kwargs)


def _make_provider_http_log_event(
    *,
    log: AppLogger,
    task: Task,
    action_name: str,
):
    return lambda level, message, metadata: _provider_http_log_event(
        log=log,
        task=task,
        action_name=action_name,
        level=level,
        message=message,
        metadata=metadata if isinstance(metadata, dict) else {},
    )


def _message_date_utc(item: Dict[str, Any]) -> Optional[str]:
    return as_optional_string(item.get("date_utc")) or as_optional_string(
        item.get("sent_date_utc")
    )


def _parse_message_datetime(value: Any) -> Optional[datetime]:
    raw_value = as_optional_string(value)
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


def _drop_last_seen_ownerrez_duplicates(
    items: list[Dict[str, Any]],
    *,
    since_utc: Optional[str],
    last_seen_mid: Optional[int],
    thread_id: Optional[int] = None,
    platform_id: Optional[int] = None,
    log_event=None,
) -> list[Dict[str, Any]]:
    """
    Keep only messages strictly newer than the local cursor.

    Cursor rule:
      keep if item.date_utc > since_utc
      OR keep if item.date_utc == since_utc AND item.id > last_seen_mid

    OwnerRez may return older messages even when since_utc is provided.
    Those older messages must be dropped so message_thread_progress never moves backward.
    """

    if since_utc is None:
        if log_event is not None:
            log_event(
                "debug",
                "ownerrez cursor filter skipped because since_utc is missing",
                {
                    "provider_key": "ownerrez",
                    "thread_id": thread_id,
                    "platform_id": platform_id,
                    "input_count": len(items),
                    "reason": "since_utc_missing",
                },
            )
        return items

    since_dt = _parse_message_datetime(since_utc)
    filtered: list[Dict[str, Any]] = []

    dropped_older_count = 0
    dropped_same_cursor_count = 0
    unparseable_count = 0

    dropped_older_samples: list[Dict[str, Any]] = []
    dropped_same_cursor_samples: list[Dict[str, Any]] = []
    unparseable_samples: list[Dict[str, Any]] = []

    for item in items:
        item_mid = coerce_optional_int(item.get("id"), field_name="id")
        item_date_raw = _message_date_utc(item)
        item_dt = _parse_message_datetime(item_date_raw)

        sample = {
            "message_id": item_mid,
            "message_date_utc": item_date_raw,
            "since_utc": since_utc,
            "last_seen_mid": last_seen_mid,
        }

        # If dates cannot be parsed, keep the item to avoid accidental data loss.
        # But log it, because this means cursor safety could not be enforced.
        if item_dt is None or since_dt is None:
            unparseable_count += 1
            if len(unparseable_samples) < 10:
                unparseable_samples.append(sample)
            filtered.append(item)
            continue

        # OwnerRez may return messages older than since_utc.
        # Never keep them, because they can move message_thread_progress backward.
        if item_dt < since_dt:
            dropped_older_count += 1
            if len(dropped_older_samples) < 10:
                dropped_older_samples.append(sample)
            continue

        # Same timestamp needs message ID as a tie-breaker.
        # If the message ID is <= last_seen_mid, it is already seen.
        if item_dt == since_dt and last_seen_mid is not None and item_mid is not None:
            if item_mid <= last_seen_mid:
                dropped_same_cursor_count += 1
                if len(dropped_same_cursor_samples) < 10:
                    dropped_same_cursor_samples.append(sample)
                continue

        filtered.append(item)

    if log_event is not None:
        log_event(
            "info",
            "ownerrez message cursor filter applied",
            {
                "provider_key": "ownerrez",
                "thread_id": thread_id,
                "platform_id": platform_id,
                "since_utc": since_utc,
                "last_seen_mid": last_seen_mid,
                "input_count": len(items),
                "kept_count": len(filtered),
                "dropped_older_count": dropped_older_count,
                "dropped_same_cursor_count": dropped_same_cursor_count,
                "unparseable_count": unparseable_count,
            },
        )

        if dropped_older_count > 0:
            log_event(
                "warn",
                "ownerrez returned messages older than since_utc; dropped to prevent cursor regression",
                {
                    "provider_key": "ownerrez",
                    "thread_id": thread_id,
                    "platform_id": platform_id,
                    "since_utc": since_utc,
                    "last_seen_mid": last_seen_mid,
                    "dropped_older_count": dropped_older_count,
                    "samples": dropped_older_samples,
                },
            )

        if dropped_same_cursor_count > 0:
            log_event(
                "debug",
                "ownerrez returned already-seen cursor messages; dropped duplicates",
                {
                    "provider_key": "ownerrez",
                    "thread_id": thread_id,
                    "platform_id": platform_id,
                    "since_utc": since_utc,
                    "last_seen_mid": last_seen_mid,
                    "dropped_same_cursor_count": dropped_same_cursor_count,
                    "samples": dropped_same_cursor_samples,
                },
            )

        if unparseable_count > 0:
            log_event(
                "warn",
                "ownerrez message cursor comparison skipped for unparseable dates",
                {
                    "provider_key": "ownerrez",
                    "thread_id": thread_id,
                    "platform_id": platform_id,
                    "since_utc": since_utc,
                    "last_seen_mid": last_seen_mid,
                    "unparseable_count": unparseable_count,
                    "samples": unparseable_samples,
                },
            )

    return filtered


def _fetch_ownerrez_messages(
    *,
    thread_id: int,
    platform_id: int,
    offset: Optional[int] = None,
    limit: Optional[int] = None,
    since_utc: Optional[str] = None,
    last_seen_mid: Optional[int] = None,
    connect_db,
    log: AppLogger,
    task: Task,
    **_kwargs: Any,
) -> Dict[str, Any]:
    client = _get_ownerrez_fetch_client(connect_db=connect_db, platform_id=platform_id)
    log_event = _make_provider_http_log_event(
        log=log,
        task=task,
        action_name="handle_fetch_messages",
    )
    try:
        first_page = client.get_messages(
            thread_id=thread_id,
            offset=offset,
            limit=limit,
            since_utc=since_utc,
            log_event=log_event,
        )
        items = (
            first_page.get("items") if isinstance(first_page.get("items"), list) else []
        )
        all_items: list[Dict[str, Any]] = [
            dict(item) for item in items if isinstance(item, dict)
        ]
        next_page_url = as_optional_string(first_page.get("next_page_url"))
        seen_page_urls: set[str] = set()
        page_count = 1
        while next_page_url:
            if next_page_url in seen_page_urls:
                raise OwnerRezResponseShapeError(
                    "OwnerRez messages pagination returned a repeated next_page_url",
                    failure_classification="invalid_response_shape",
                )
            seen_page_urls.add(next_page_url)
            page = client.get_messages_page_url(
                page_url=next_page_url,
                thread_id=thread_id,
                log_event=log_event,
            )
            page_items = (
                page.get("items") if isinstance(page.get("items"), list) else []
            )
            all_items.extend(
                dict(item) for item in page_items if isinstance(item, dict)
            )
            next_page_url = as_optional_string(page.get("next_page_url"))
            page_count += 1

        filtered_items = _drop_last_seen_ownerrez_duplicates(
            all_items,
            since_utc=as_optional_string(since_utc),
            last_seen_mid=last_seen_mid,
            thread_id=thread_id,
            platform_id=platform_id,
            log_event=log_event,
        )
        aggregated = dict(first_page)
        aggregated["items"] = filtered_items
        aggregated["next_page_url"] = None
        aggregated["offset"] = 0
        aggregated["limit"] = len(filtered_items)
        aggregated["page_count"] = page_count
        aggregated["since_utc"] = as_optional_string(since_utc)
        return aggregated
    finally:
        _close_ownerrez_client(client)


def _resolve_fetch_handler(fetch_action: str):
    if fetch_action == FETCH_DUMMY_ACTION:
        return _fetch_dummy_messages
    if fetch_action == FETCH_ACTION:
        return _fetch_ownerrez_messages
    raise ValueError(f"Unexpected fetch action {fetch_action}")


def _fetch_callback_payload(
    *,
    response_worker_id: str,
    response_scope: str,
    response_key: str,
    source_action: str,
    action: str,
) -> Dict[str, Any]:
    return {
        "action": action,
        "source_worker": WORKER,
        "source_action": source_action,
        "data_ref": {
            "worker_id": response_worker_id,
            "scope": response_scope,
            "key": response_key,
        },
    }


def _extract_provider_key_from_bookings_action(action: str) -> Optional[str]:
    normalized = as_optional_string(action)
    if not normalized:
        return None
    match = PROVIDER_BOOKINGS_ACTION_PATTERN.match(normalized.strip().lower())
    if not match:
        return None
    return match.group(1)


def _as_non_negative_int(value: Any, *, field_name: str, default: int) -> int:
    parsed = coerce_optional_int(value, field_name=field_name)
    if parsed is None:
        return int(default)
    if parsed < 0:
        raise ValueError(f"{field_name} must be >= 0")
    return int(parsed)


def _normalize_ownerrez_statuses(provider_query: Dict[str, Any]) -> tuple[str, ...]:
    statuses_value = provider_query.get("statuses")
    statuses: list[str] = []
    if isinstance(statuses_value, (list, tuple)):
        for item in statuses_value:
            status = as_optional_string(item)
            if status:
                statuses.append(status.strip().lower())
    single_status = as_optional_string(provider_query.get("status"))
    if single_status:
        statuses.append(single_status.strip().lower())
    deduped: list[str] = []
    for status in statuses:
        if status and status not in deduped:
            deduped.append(status)
    return tuple(deduped)


def _normalize_ownerrez_property_ids(
    *, listing_ids: Any, provider_query: Dict[str, Any]
) -> tuple[int, ...]:
    property_ids = provider_query.get("property_ids")
    raw_ids = property_ids if isinstance(property_ids, (list, tuple)) else listing_ids
    if not isinstance(raw_ids, (list, tuple)):
        return tuple()
    normalized: list[int] = []
    for item in raw_ids:
        value = coerce_optional_int(item, field_name="property_ids")
        if value is not None:
            normalized.append(int(value))
    return tuple(normalized)


def _build_ownerrez_bookings_page_result(
    *,
    fetched: Dict[str, Any],
    offset: int,
    page_size: int,
) -> Dict[str, Any]:
    all_items = fetched.get("items")
    if not isinstance(all_items, list):
        all_items = []
    page_items = all_items[:page_size]
    next_page_url = as_optional_string(fetched.get("next_page_url"))
    if next_page_url is None and len(all_items) > len(page_items):
        next_offset = offset + len(page_items)
        next_page_url = f"/v2/bookings?offset={next_offset}&limit={page_size}"
    provider_paging = {
        "offset": int(offset),
        "limit": int(page_size),
        "page_count": coerce_optional_int(
            fetched.get("page_count"), field_name="page_count"
        ),
    }
    return {
        "items": page_items,
        "next_page_url": next_page_url,
        "provider_paging": provider_paging,
    }


def _resolve_ownerrez_single_request_limit(*, requested_limit: int, offset: int) -> int:
    # Product rule: bootstrap fetch asks for one extra record to reduce immediate follow-up fetches.
    if requested_limit == 2 and offset == 0:
        return 3
    return requested_limit


def handle_fetch_messages(
    context: ManagedWorkerContext,
    task: Task,
    *,
    source_action: Optional[str] = None,
) -> None:
    queue = context.main_queue
    step = default_step(context)
    log = default_app_logger(context)
    state = ActionStateManager.load(context, task)
    payload = task.payload
    fetch_action = (
        source_action or as_optional_string(payload.get("action")) or FETCH_ACTION
    )
    data_ref = _normalize_data_ref(payload, default_scope=FETCH_SCOPE_IN)
    source_worker_id = data_ref["worker_id"] or context.scheduler.worker_id
    source_scope = str(data_ref["scope"])
    source_key = data_ref["key"]
    using_data_ref = bool(source_key)

    booking_id: Optional[int]
    thread_id: int
    platform_id: int
    offset: Optional[int]
    limit: Optional[int]
    since_utc: Optional[str]
    last_seen_mid: Optional[int]
    if source_key:
        if not state.is_step_done("request_loaded"):
            state.begin_step("request_loaded")
            try:
                with context.connect_db() as conn:
                    log.db_before_read(
                        "read fetch request runtime variable",
                        params={"scope": source_scope, "key": source_key},
                        **task_log_kwargs(task, "handle_fetch_messages"),
                    )
                    request_payload = get_runtime_variable(
                        conn,
                        worker_id=source_worker_id,
                        scope=source_scope,
                        key=str(source_key),
                    )
                    log.db_after_read(
                        "read fetch request runtime variable",
                        result={
                            "has_thread_id": isinstance(request_payload, dict)
                            and request_payload.get("thread_id") is not None,
                            "has_platform_id": isinstance(request_payload, dict)
                            and request_payload.get("platform_id") is not None,
                        },
                        **task_log_kwargs(task, "handle_fetch_messages"),
                    )
            except Exception as exc:
                if isinstance(exc, LookupError):
                    _warn_runtime_variable_unavailable(
                        log,
                        task,
                        action_name="handle_fetch_messages",
                        worker_id=source_worker_id,
                        scope=source_scope,
                        key=str(source_key),
                        reason=exc,
                    )
                log.error(
                    "failed to read fetch request runtime variable",
                    exc=exc,
                    error_code="FETCH_REQUEST_READ_FAILED",
                    **task_log_kwargs(task, "handle_fetch_messages"),
                )
                state.record_failure("request_loaded", str(exc))
                queue.fail_task(task, f"read fetch request failed: {exc}", retry=True)
                return

            if not isinstance(request_payload, dict):
                queue.fail_task(
                    task, "fetch request runtime payload missing", retry=False
                )
                return

            try:
                booking_id = get_booking_id(request_payload, required=False)
                thread_id = coerce_required_int(request_payload, "thread_id")
                platform_id = coerce_required_int(request_payload, "platform_id")
                offset = coerce_optional_int(
                    request_payload.get("offset"), field_name="offset"
                )
                limit = coerce_optional_int(
                    request_payload.get("limit"), field_name="limit"
                )
                since_utc = as_optional_string(request_payload.get("since_utc"))
                last_seen_mid = coerce_optional_int(
                    request_payload.get("last_seen_mid"), field_name="last_seen_mid"
                )
            except Exception as exc:
                queue.fail_task(
                    task, f"invalid fetch request runtime payload: {exc}", retry=False
                )
                return

            state.checkpoint(
                "request_loaded",
                {
                    "source_worker_id": source_worker_id,
                    "source_scope": source_scope,
                    "source_key": source_key,
                    "booking_id": booking_id,
                    "thread_id": thread_id,
                    "platform_id": platform_id,
                    "offset": offset,
                    "limit": limit,
                    "since_utc": since_utc,
                    "last_seen_mid": last_seen_mid,
                },
            )
        request_data = state.get_step_data("request_loaded")
        source_worker_id = str(request_data["source_worker_id"])
        source_scope = str(request_data["source_scope"])
        source_key = str(request_data["source_key"])
        booking_id = coerce_optional_int(
            request_data.get("booking_id"), field_name="booking_id"
        )
        thread_id = int(request_data["thread_id"])
        platform_id = int(request_data["platform_id"])
        offset = coerce_optional_int(request_data.get("offset"), field_name="offset")
        limit = coerce_optional_int(request_data.get("limit"), field_name="limit")
        since_utc = as_optional_string(request_data.get("since_utc"))
        last_seen_mid = coerce_optional_int(
            request_data.get("last_seen_mid"), field_name="last_seen_mid"
        )
    else:
        booking_id = get_booking_id(payload, required=False)
        thread_id = coerce_required_int(payload, "thread_id")
        platform_id = coerce_required_int(payload, "platform_id")
        offset = coerce_optional_int(payload.get("offset"), field_name="offset")
        limit = coerce_optional_int(payload.get("limit"), field_name="limit")
        since_utc = as_optional_string(payload.get("since_utc"))
        last_seen_mid = coerce_optional_int(
            payload.get("last_seen_mid"), field_name="last_seen_mid"
        )

    return_ref = normalize_return_ref(
        payload,
        default_queue=as_optional_string(getattr(task, "queue_name", None))
        or PRIMARY_QUEUE,
    )
    try:
        fetch_handler = _resolve_fetch_handler(fetch_action)
    except ValueError as exc:
        queue.fail_task(task, str(exc), retry=False)
        return

    log.info(
        "task started",
        metadata={
            "source_action": fetch_action,
            "thread_id": thread_id,
            "platform_id": platform_id,
            "booking_id": booking_id,
            "offset": offset,
            "limit": limit,
            "since_utc": since_utc,
            "last_seen_mid": last_seen_mid,
            "has_return_ref": return_ref is not None,
            "using_data_ref": using_data_ref,
        },
        **task_log_kwargs(task, "handle_fetch_messages"),
    )

    if not state.is_step_done("fetch_completed"):
        state.begin_step("fetch_completed")
        error: Optional[str] = None
        result: Optional[Dict[str, Any]] = None
        try:
            result = fetch_handler(
                thread_id=thread_id,
                platform_id=platform_id,
                offset=offset,
                limit=limit,
                since_utc=since_utc,
                last_seen_mid=last_seen_mid,
                connect_db=context.connect_db,
                log=log,
                task=task,
            )
            if isinstance(result, dict) and bool(
                result.get("_items_missing_treated_as_empty")
            ):
                log.warn(
                    "ownerrez messages response missing items; treated as empty list",
                    metadata={
                        "provider": "ownerrez",
                        "reason_code": "ownerrez_items_missing_treated_as_empty",
                        "thread_id": thread_id,
                        "offset": offset,
                        "limit": limit,
                        "since_utc": since_utc,
                    },
                    **task_log_kwargs(task, "handle_fetch_messages"),
                )
            log.after_processing(
                "external fetch completed",
                summary={
                    "thread_id": thread_id,
                    "items": len(result.get("items", [])),
                    "error": None,
                },
                **task_log_kwargs(task, "handle_fetch_messages"),
            )
        except OwnerRezRetryableError as exc:
            log.warn(
                "ownerrez fetch failed with retryable error",
                metadata={
                    "thread_id": thread_id,
                    "offset": offset,
                    "limit": limit,
                    "since_utc": since_utc,
                    "status_code": exc.status_code,
                    "retry_attempt": exc.attempts,
                    "failure_classification": exc.failure_classification,
                    "error": str(exc),
                },
                **task_log_kwargs(task, "handle_fetch_messages"),
            )
            state.record_failure("fetch_completed", str(exc))
            queue.fail_task(task, str(exc), retry=True, retry_delay="2 minutes")
            return
        except (OwnerRezConfigError, OwnerRezResponseShapeError) as exc:
            log.error(
                "ownerrez fetch failed with non-retryable worker error",
                exc=exc,
                error_code="OWNERREZ_FETCH_WORKER_ERROR",
                metadata={
                    "thread_id": thread_id,
                    "offset": offset,
                    "limit": limit,
                    "since_utc": since_utc,
                    "status_code": exc.status_code,
                    "retry_attempt": exc.attempts,
                    "failure_classification": exc.failure_classification,
                },
                **task_log_kwargs(task, "handle_fetch_messages"),
            )
            state.record_failure("fetch_completed", str(exc))
            queue.fail_task(task, str(exc), retry=False)
            return
        except OwnerRezPermanentError as exc:
            error = str(exc)
            log.warn(
                "ownerrez fetch returned permanent upstream error",
                metadata={
                    "thread_id": thread_id,
                    "offset": offset,
                    "limit": limit,
                    "since_utc": since_utc,
                    "status_code": exc.status_code,
                    "retry_attempt": exc.attempts,
                    "failure_classification": exc.failure_classification,
                    "error": error,
                },
                **task_log_kwargs(task, "handle_fetch_messages"),
            )
        except Exception as exc:  # pragma: no cover - runtime path
            error = str(exc)
            log.warn(
                "external fetch returned error",
                metadata={"thread_id": thread_id, "error": error},
                **task_log_kwargs(task, "handle_fetch_messages"),
            )

        response_key = generate_key("extsvc_fetch")
        try:
            with context.connect_db() as conn:
                log.db_before_write(
                    "write fetch response runtime variable",
                    data={"scope": FETCH_RUNTIME_SCOPE, "key": response_key},
                    **task_log_kwargs(task, "handle_fetch_messages"),
                )
                set_runtime_variable(
                    conn,
                    worker_id=context.scheduler.worker_id,
                    scope=FETCH_RUNTIME_SCOPE,
                    key=response_key,
                    value={
                        "source_action": fetch_action,
                        "booking_id": booking_id,
                        "platform_id": platform_id,
                        "thread_id": thread_id,
                        "offset": offset,
                        "limit": limit,
                        "since_utc": since_utc,
                        "last_seen_mid": last_seen_mid,
                        "result": result,
                        "error": error,
                    },
                    ttl_minutes=_resolve_runtime_ttl(
                        action=fetch_action, scope=FETCH_RUNTIME_SCOPE
                    ),
                )
                log.db_after_write(
                    "write fetch response runtime variable",
                    result={"scope": FETCH_RUNTIME_SCOPE, "key": response_key},
                    **task_log_kwargs(task, "handle_fetch_messages"),
                )
        except Exception as exc:
            log.error(
                "failed to persist fetch response",
                exc=exc,
                error_code="FETCH_RESPONSE_STORE_FAILED",
                **task_log_kwargs(task, "handle_fetch_messages"),
            )
            state.record_failure("fetch_completed", str(exc))
            queue.fail_task(task, f"store fetch response failed: {exc}", retry=True)
            return

        state.checkpoint(
            "fetch_completed",
            {
                "response_worker_id": context.scheduler.worker_id,
                "response_scope": FETCH_RUNTIME_SCOPE,
                "response_key": response_key,
                "result_present": result is not None,
                "error": error,
            },
        )

    fetch_data = state.get_step_data("fetch_completed")
    callback_task_uuid = None
    if return_ref is not None:
        if not state.is_step_done("callback_enqueued"):
            state.begin_step("callback_enqueued")
            callback_payload = _fetch_callback_payload(
                response_worker_id=str(fetch_data["response_worker_id"]),
                response_scope=str(fetch_data["response_scope"]),
                response_key=str(fetch_data["response_key"]),
                source_action=fetch_action,
                action=str(return_ref["action"]),
            )
            try:
                log.db_before_write(
                    "enqueue fetch callback",
                    data={
                        "worker": return_ref["worker"],
                        "queue": return_ref["queue"],
                        "action": return_ref["action"],
                    },
                    **task_log_kwargs(task, "handle_fetch_messages"),
                )
                callback_task_uuid = enqueue_with_meta(
                    context.queue(str(return_ref["queue"] or PRIMARY_QUEUE)),
                    str(return_ref["worker"]),
                    callback_payload,
                    current_task=task,
                    current_worker=WORKER,
                    current_action=fetch_action,
                    next_worker=str(return_ref["worker"]),
                    next_action=str(return_ref["action"]),
                )
                log.db_after_write(
                    "enqueue fetch callback",
                    result={"callback_task_uuid": callback_task_uuid},
                    **task_log_kwargs(task, "handle_fetch_messages"),
                )
            except Exception as exc:
                log.error(
                    "failed to enqueue fetch callback",
                    exc=exc,
                    error_code="FETCH_CALLBACK_ENQUEUE_FAILED",
                    **task_log_kwargs(task, "handle_fetch_messages"),
                )
                state.record_failure("callback_enqueued", str(exc))
                queue.fail_task(
                    task, f"enqueue fetch callback failed: {exc}", retry=True
                )
                return
            state.checkpoint(
                "callback_enqueued", {"callback_task_uuid": callback_task_uuid}
            )
        callback_task_uuid = state.get_step_data("callback_enqueued").get(
            "callback_task_uuid"
        )

    cleanup_error = None
    if source_key:
        try:
            with context.connect_db() as conn:
                delete_runtime_variable(
                    conn,
                    worker_id=source_worker_id,
                    scope=source_scope,
                    key=str(source_key),
                )
        except Exception as exc:  # pragma: no cover - runtime path
            cleanup_error = str(exc)

    result = {
        "status": "success",
        "booking_id": booking_id,
        "thread_id": thread_id,
        "platform_id": platform_id,
        "source_action": fetch_action,
        "offset": offset,
        "limit": limit,
        "since_utc": since_utc,
        "result_present": bool(fetch_data.get("result_present")),
        "error": fetch_data.get("error"),
        "response_key": fetch_data.get("response_key"),
        "callback_task_uuid": callback_task_uuid,
        "cleanup_error": cleanup_error,
    }
    step.log("external services fetch completed", result)
    log.info(
        "task completed",
        metadata=result,
        **task_log_kwargs(task, "handle_fetch_messages"),
    )
    queue.complete_task(task, result)


def handle_get_provider_bookings(
    context: ManagedWorkerContext,
    task: Task,
    *,
    source_action: Optional[str] = None,
) -> None:
    queue = context.main_queue
    step = default_step(context)
    log = default_app_logger(context)
    state = ActionStateManager.load(context, task)
    payload = task.payload
    action_name = source_action or as_optional_string(payload.get("action")) or ""
    provider_key = _extract_provider_key_from_bookings_action(action_name)
    if not provider_key:
        queue.fail_task(task, f"Unexpected action {action_name}", retry=False)
        return

    data_ref = _normalize_data_ref(payload, default_scope=FETCH_BOOKINGS_REQUEST_SCOPE)
    source_worker_id = data_ref["worker_id"] or context.scheduler.worker_id
    source_scope = str(data_ref["scope"])
    source_key = data_ref["key"]
    if not source_key:
        queue.fail_task(
            task, "BOOKINGS_REQUEST_INVALID: missing data_ref.key", retry=False
        )
        return

    return_ref = normalize_return_ref(
        payload,
        default_queue=as_optional_string(getattr(task, "queue_name", None))
        or PRIMARY_QUEUE,
    )
    if return_ref is None:
        queue.fail_task(
            task, "BOOKINGS_REQUEST_INVALID: missing return_ref", retry=False
        )
        return

    if not state.is_step_done("request_loaded"):
        state.begin_step("request_loaded")
        try:
            with context.connect_db() as conn:
                request_payload = get_runtime_variable(
                    conn,
                    worker_id=source_worker_id,
                    scope=source_scope,
                    key=str(source_key),
                )
        except Exception as exc:
            if isinstance(exc, LookupError):
                queue.fail_task(task, f"FETCH_REQUEST_EXPIRED: {exc}", retry=False)
                return
            state.record_failure("request_loaded", str(exc))
            queue.fail_task(task, f"read fetch request failed: {exc}", retry=True)
            return

        if not isinstance(request_payload, dict):
            queue.fail_task(
                task,
                "BOOKINGS_REQUEST_INVALID: fetch request runtime payload missing",
                retry=False,
            )
            return

        try:
            provider_in_request = (
                (as_optional_string(request_payload.get("provider_key")) or "")
                .strip()
                .lower()
            )
            if provider_in_request and provider_in_request != provider_key:
                raise ValueError("provider_key mismatch between action and request")
            request_platform_id = coerce_optional_int(
                request_payload.get("platform_id"), field_name="platform_id"
            )
            if request_platform_id is None or int(request_platform_id) < 1:
                raise ValueError("platform_id is required")
            provider_query = request_payload.get("provider_query")
            if not isinstance(provider_query, dict):
                provider_query = {}
            from_date = as_optional_string(provider_query.get("from"))
            to_date = as_optional_string(provider_query.get("to"))
            requested_page_size = _as_non_negative_int(
                request_payload.get("page_size"), field_name="page_size", default=100
            )
            if requested_page_size < 1:
                raise ValueError("page_size must be > 0")
            offset = _as_non_negative_int(
                request_payload.get("offset"), field_name="offset", default=0
            )
            page_size = _resolve_ownerrez_single_request_limit(
                requested_limit=requested_page_size, offset=offset
            )
            listing_ids = request_payload.get("listing_ids")
            normalized_statuses = _normalize_ownerrez_statuses(provider_query)
            property_ids = _normalize_ownerrez_property_ids(
                listing_ids=listing_ids, provider_query=provider_query
            )
            since_utc = as_optional_string(provider_query.get("since_utc"))
            if not since_utc and not property_ids:
                raise ValueError(
                    "provider_query.since_utc or ownerrez property_ids is required"
                )
        except Exception as exc:
            queue.fail_task(task, f"BOOKINGS_REQUEST_INVALID: {exc}", retry=False)
            return

        state.checkpoint(
            "request_loaded",
            {
                "source_worker_id": source_worker_id,
                "source_scope": source_scope,
                "source_key": source_key,
                "request_payload": request_payload,
                "platform_id": int(request_platform_id),
                "since_utc": since_utc,
                "from_date": from_date,
                "to_date": to_date,
                "offset": offset,
                "page_size": page_size,
                "requested_page_size": requested_page_size,
                "statuses": list(normalized_statuses),
                "property_ids": list(property_ids),
            },
        )

    request_data = state.get_step_data("request_loaded")
    request_payload = request_data.get("request_payload")
    if not isinstance(request_payload, dict):
        queue.fail_task(
            task,
            "BOOKINGS_REQUEST_INVALID: request payload not found in state",
            retry=False,
        )
        return
    source_worker_id = str(request_data["source_worker_id"])
    source_scope = str(request_data["source_scope"])
    source_key = str(request_data["source_key"])
    request_platform_id = int(request_data["platform_id"])
    since_utc = as_optional_string(request_data.get("since_utc"))
    from_date = as_optional_string(request_data.get("from_date"))
    to_date = as_optional_string(request_data.get("to_date"))
    offset = int(request_data["offset"])
    page_size = int(request_data["page_size"])
    requested_page_size = int(request_data.get("requested_page_size") or page_size)
    statuses_raw = request_data.get("statuses")
    property_ids_raw = request_data.get("property_ids")
    statuses = tuple(
        str(item) for item in (statuses_raw or []) if as_optional_string(item)
    )
    property_ids = tuple(
        int(item)
        for item in (property_ids_raw or [])
        if coerce_optional_int(item, field_name="property_ids") is not None
    )

    if provider_key != "ownerrez":
        queue.fail_task(
            task,
            f"BOOKINGS_REQUEST_INVALID: unsupported provider_key '{provider_key}'",
            retry=False,
        )
        return

    if not state.is_step_done("bookings_fetched"):
        state.begin_step("bookings_fetched")
        bookings_error: Optional[str] = None
        bookings_page: Optional[Dict[str, Any]] = None
        try:
            client = _get_ownerrez_fetch_client(
                connect_db=context.connect_db, platform_id=request_platform_id
            )
            try:
                fetched = client.get_bookings(
                    since_utc=since_utc,
                    from_date=from_date,
                    to_date=to_date,
                    statuses=statuses or None,
                    property_ids=property_ids or None,
                    limit=page_size,
                    offset=offset,
                    single_page=True,
                    log_event=_make_provider_http_log_event(
                        log=log,
                        task=task,
                        action_name="handle_get_provider_bookings",
                    ),
                )
            finally:
                _close_ownerrez_client(client)
            bookings_page = _build_ownerrez_bookings_page_result(
                fetched=fetched,
                offset=offset,
                page_size=page_size,
            )
        except OwnerRezRetryableError as exc:
            state.record_failure("bookings_fetched", str(exc))
            queue.fail_task(
                task,
                f"OWNERREZ_BOOKINGS_FETCH_RETRYABLE: {exc}",
                retry=True,
                retry_delay="2 minutes",
            )
            return
        except (OwnerRezConfigError, OwnerRezResponseShapeError) as exc:
            bookings_error = f"OWNERREZ_BOOKINGS_FETCH_PERMANENT: {exc}"
        except OwnerRezPermanentError as exc:
            bookings_error = f"OWNERREZ_BOOKINGS_FETCH_PERMANENT: {exc}"
        except Exception as exc:
            state.record_failure("bookings_fetched", str(exc))
            queue.fail_task(
                task,
                f"OWNERREZ_BOOKINGS_FETCH_RETRYABLE: {exc}",
                retry=True,
                retry_delay="2 minutes",
            )
            return

        state.checkpoint(
            "bookings_fetched",
            {
                "bookings_page": bookings_page,
                "bookings_error": bookings_error,
            },
        )

    fetched_data = state.get_step_data("bookings_fetched")
    bookings_page = (
        fetched_data.get("bookings_page")
        if isinstance(fetched_data.get("bookings_page"), dict)
        else None
    )
    bookings_error = as_optional_string(fetched_data.get("bookings_error"))

    if not state.is_step_done("page_written"):
        state.begin_step("page_written")
        response_key = generate_key("fetch_bookings_page")
        response_payload = dict(request_payload)
        response_payload["provider_key"] = provider_key
        response_payload["offset"] = offset
        response_payload["page_size"] = page_size
        response_payload["requested_page_size"] = requested_page_size
        if bookings_page is None:
            response_payload["items"] = []
            response_payload["next_page_url"] = None
            response_payload["provider_paging"] = {"offset": offset, "limit": page_size}
            response_payload["error"] = bookings_error
        else:
            response_payload["items"] = list(bookings_page.get("items") or [])
            response_payload["next_page_url"] = bookings_page.get("next_page_url")
            response_payload["provider_paging"] = bookings_page.get("provider_paging")
            response_payload["error"] = None
        response_payload["fetched_at_utc"] = (
            datetime.now(timezone.utc)
            .replace(microsecond=0)
            .isoformat()
            .replace("+00:00", "Z")
        )

        try:
            with context.connect_db() as conn:
                set_runtime_variable(
                    conn,
                    worker_id=context.scheduler.worker_id,
                    scope=FETCH_BOOKINGS_PAGE_SCOPE,
                    key=response_key,
                    value=response_payload,
                    ttl_minutes=_resolve_runtime_ttl(
                        action=action_name, scope=FETCH_BOOKINGS_PAGE_SCOPE
                    ),
                )
        except Exception as exc:
            state.record_failure("page_written", str(exc))
            queue.fail_task(task, f"BOOKINGS_PAGE_WRITE_FAILED: {exc}", retry=True)
            return
        state.checkpoint(
            "page_written",
            {
                "response_worker_id": context.scheduler.worker_id,
                "response_scope": FETCH_BOOKINGS_PAGE_SCOPE,
                "response_key": response_key,
                "item_count": (
                    len(response_payload["items"])
                    if isinstance(response_payload.get("items"), list)
                    else 0
                ),
            },
        )

    callback_task_uuid = None
    if not state.is_step_done("callback_enqueued"):
        state.begin_step("callback_enqueued")
        write_data = state.get_step_data("page_written")
        callback_payload = _fetch_callback_payload(
            response_worker_id=str(write_data["response_worker_id"]),
            response_scope=str(write_data["response_scope"]),
            response_key=str(write_data["response_key"]),
            source_action=action_name,
            action=str(return_ref["action"]),
        )
        try:
            callback_task_uuid = enqueue_with_meta(
                context.queue(str(return_ref["queue"] or PRIMARY_QUEUE)),
                str(return_ref["worker"]),
                callback_payload,
                current_task=task,
                current_worker=WORKER,
                current_action=action_name,
                next_worker=str(return_ref["worker"]),
                next_action=str(return_ref["action"]),
            )
        except Exception as exc:
            state.record_failure("callback_enqueued", str(exc))
            queue.fail_task(
                task, f"BOOKINGS_CALLBACK_ENQUEUE_FAILED: {exc}", retry=True
            )
            return
        state.checkpoint(
            "callback_enqueued", {"callback_task_uuid": callback_task_uuid}
        )

    callback_task_uuid = state.get_step_data("callback_enqueued").get(
        "callback_task_uuid"
    )
    cleanup_error = None
    try:
        with context.connect_db() as conn:
            delete_runtime_variable(
                conn,
                worker_id=source_worker_id,
                scope=source_scope,
                key=str(source_key),
            )
    except Exception as exc:
        cleanup_error = str(exc)

    page_data = state.get_step_data("page_written")
    result = {
        "status": "success",
        "source_action": action_name,
        "provider_key": provider_key,
        "platform_id": request_payload.get("platform_id"),
        "offset": offset,
        "page_size": page_size,
        "requested_page_size": requested_page_size,
        "item_count": int(page_data.get("item_count") or 0),
        "response_key": page_data.get("response_key"),
        "callback_task_uuid": callback_task_uuid,
        "error": bookings_error,
        "cleanup_error": cleanup_error,
    }
    step.log("external services bookings fetch completed", result)
    log.info(
        "task completed",
        metadata=result,
        **task_log_kwargs(task, "handle_get_provider_bookings"),
    )
    queue.complete_task(task, result)


def handle_classify_messages(
    context: ManagedWorkerContext,
    task: Task,
    *,
    source_action: Optional[str] = None,
) -> None:
    queue = context.main_queue
    step = default_step(context)
    log = default_app_logger(context)
    state = ActionStateManager.load(context, task)
    payload = task.payload
    classify_action = (
        source_action or as_optional_string(payload.get("action")) or CLASSIFY_ACTION
    )

    data_ref = _normalize_data_ref(payload, default_scope=CLASSIFY_SCOPE_IN)
    scope = str(data_ref["scope"])
    key = data_ref["key"]
    if not key:
        queue.fail_task(task, "missing data_ref.key", retry=False)
        return

    return_ref = normalize_return_ref(
        payload,
        default_queue=as_optional_string(getattr(task, "queue_name", None))
        or PRIMARY_QUEUE,
    )
    source_worker_id = data_ref["worker_id"] or context.scheduler.worker_id
    log.info(
        "task started",
        metadata={
            "scope": scope,
            "key": key,
            "has_return_ref": return_ref is not None,
            "source_action": classify_action,
        },
        **task_log_kwargs(task, "handle_classify_messages"),
    )

    if not state.is_step_done("data_read"):
        state.begin_step("data_read")
        try:
            with context.connect_db() as conn:
                log.db_before_read(
                    "read classify request runtime variable",
                    params={"scope": scope, "key": key},
                    **task_log_kwargs(task, "handle_classify_messages"),
                )
                request_payload = get_runtime_variable(
                    conn,
                    worker_id=source_worker_id,
                    scope=scope,
                    key=str(key),
                )
                log.db_after_read(
                    "read classify request runtime variable",
                    result={
                        "items_count": (
                            len(request_payload.get("items", []))
                            if isinstance(request_payload.get("items"), list)
                            else None
                        )
                    },
                    **task_log_kwargs(task, "handle_classify_messages"),
                )
        except Exception as exc:
            if isinstance(exc, LookupError):
                _warn_runtime_variable_unavailable(
                    log,
                    task,
                    action_name="handle_classify_messages",
                    worker_id=source_worker_id,
                    scope=scope,
                    key=str(key),
                    reason=exc,
                )
            log.error(
                "failed to read classify request",
                exc=exc,
                error_code="CLASSIFY_REQUEST_READ_FAILED",
                **task_log_kwargs(task, "handle_classify_messages"),
            )
            state.record_failure("data_read", str(exc))
            queue.fail_task(task, f"read classify request failed: {exc}", retry=True)
            return

        items = (
            request_payload.get("items") if isinstance(request_payload, dict) else None
        )
        if not isinstance(items, list) or not items:
            queue.fail_task(task, "classify request missing items", retry=False)
            return
        state.checkpoint(
            "data_read",
            {
                "source_worker_id": source_worker_id,
                "source_scope": scope,
                "source_key": key,
                "items_count": len(items),
            },
        )

    source_data = state.get_step_data("data_read")
    source_worker_id = str(source_data["source_worker_id"])
    scope = str(source_data["source_scope"])
    key = str(source_data["source_key"])

    classified_data = None
    if not state.is_step_done("classified"):
        state.begin_step("classified")
        try:
            with context.connect_db() as conn:
                request_payload = get_runtime_variable(
                    conn,
                    worker_id=source_worker_id,
                    scope=scope,
                    key=str(key),
                )
                items = (
                    request_payload.get("items")
                    if isinstance(request_payload, dict)
                    else None
                )
                if not isinstance(items, list) or not items:
                    raise ValueError("classify request missing items")

                if classify_action == CLASSIFY_DUMMY_ACTION:
                    results = _classify_items_dummy(items, dsn=context.dsn)
                else:
                    active_classes = _fetch_active_message_classes(conn)
                    active_categories = [
                        item["name"]
                        for item in active_classes
                        if as_optional_string(item.get("name"))
                    ]
                    if not active_categories:
                        log.error(
                            "message_classes table has no active categories",
                            error_code="CLASSIFY_MESSAGE_CLASSES_EMPTY",
                            **task_log_kwargs(task, "handle_classify_messages"),
                        )
                        state.record_failure(
                            "classified",
                            "message_classes table has no active categories",
                        )
                        queue.fail_task(
                            task,
                            "message_classes table has no active categories",
                            retry=False,
                        )
                        return

                    if not _has_required_fallback_class(active_categories):
                        message = "message_classes table is missing required 'unclassified' category"
                        log.error(
                            message,
                            error_code="CLASSIFY_REQUIRED_CATEGORY_MISSING",
                            **task_log_kwargs(task, "handle_classify_messages"),
                        )
                        state.record_failure("classified", message)
                        queue.fail_task(task, message, retry=False)
                        return

                    category_descriptions: Dict[str, str] = {
                        item["name"]: item["description"]
                        for item in active_classes
                        if item.get("name")
                    }
                    raw_results, usage = _classify_items_live(
                        items,
                        conn=conn,
                        allowed_categories=active_categories,
                        category_descriptions=category_descriptions,
                        app_logger=log,
                        app_log_kwargs=task_log_kwargs(
                            task, "handle_classify_messages"
                        ),
                    )
                    try:
                        results = _normalize_live_results(
                            raw_results,
                            allowed_categories=active_categories,
                            log=log,
                            task=task,
                        )
                    except ValueError as normalize_exc:
                        try:
                            _record_llm_usage(
                                conn,
                                action_name=classify_action,
                                task=task,
                                usage=usage,
                                success=False,
                                error_code="CLASSIFY_CATEGORY_VALIDATION_FAILED",
                                error_message=str(normalize_exc),
                            )
                        except Exception as usage_exc:
                            log.error(
                                "failed to persist llm usage",
                                exc=usage_exc,
                                error_code="CLASSIFY_LLM_USAGE_STORE_FAILED",
                                **task_log_kwargs(task, "handle_classify_messages"),
                            )
                            state.record_failure("classified", str(usage_exc))
                            queue.fail_task(
                                task, f"store llm usage failed: {usage_exc}", retry=True
                            )
                            return
                        raise

                    try:
                        _record_llm_usage(
                            conn,
                            action_name=classify_action,
                            task=task,
                            usage=usage,
                            success=True,
                        )
                    except Exception as usage_exc:
                        log.error(
                            "failed to persist llm usage",
                            exc=usage_exc,
                            error_code="CLASSIFY_LLM_USAGE_STORE_FAILED",
                            **task_log_kwargs(task, "handle_classify_messages"),
                        )
                        state.record_failure("classified", str(usage_exc))
                        queue.fail_task(
                            task, f"store llm usage failed: {usage_exc}", retry=True
                        )
                        return

            log.after_processing(
                "classification completed",
                summary={"items": len(items), "results": len(results)},
                **task_log_kwargs(task, "handle_classify_messages"),
            )
        except (OpenAIClassificationError, OllamaClassificationError) as exc:
            if exc.usage is not None:
                try:
                    with context.connect_db() as conn:
                        _record_llm_usage(
                            conn,
                            action_name=classify_action,
                            task=task,
                            usage=exc.usage,
                            success=False,
                            error_code=exc.error_code,
                            error_message=str(exc),
                        )
                except Exception as usage_exc:
                    log.error(
                        "failed to persist llm usage",
                        exc=usage_exc,
                        error_code="CLASSIFY_LLM_USAGE_STORE_FAILED",
                        **task_log_kwargs(task, "handle_classify_messages"),
                    )
                    state.record_failure("classified", str(usage_exc))
                    queue.fail_task(
                        task, f"store llm usage failed: {usage_exc}", retry=True
                    )
                    return
            log.error(
                "classification failed",
                exc=exc,
                error_code=exc.error_code,
                **task_log_kwargs(task, "handle_classify_messages"),
            )
            state.record_failure("classified", str(exc))
            queue.fail_task(task, str(exc), retry=exc.retryable)
            return
        except ValueError as exc:
            log.error(
                "invalid classify request",
                exc=exc,
                error_code="CLASSIFY_REQUEST_INVALID",
                **task_log_kwargs(task, "handle_classify_messages"),
            )
            state.record_failure("classified", str(exc))
            queue.fail_task(task, str(exc), retry=False)
            return
        except Exception as exc:
            log.error(
                "classification failed",
                exc=exc,
                error_code="CLASSIFY_FAILED",
                **task_log_kwargs(task, "handle_classify_messages"),
            )
            state.record_failure("classified", str(exc))
            queue.fail_task(task, str(exc), retry=True)
            return

        result_key = generate_key("classify_res")
        try:
            with context.connect_db() as conn:
                log.db_before_write(
                    "write classify result runtime variable",
                    data={
                        "scope": CLASSIFY_SCOPE_OUT,
                        "key": result_key,
                        "items": len(results),
                    },
                    **task_log_kwargs(task, "handle_classify_messages"),
                )
                set_runtime_variable(
                    conn,
                    worker_id=context.scheduler.worker_id,
                    scope=CLASSIFY_SCOPE_OUT,
                    key=result_key,
                    value={"results": results},
                    ttl_minutes=_resolve_runtime_ttl(
                        action=classify_action, scope=CLASSIFY_SCOPE_OUT
                    ),
                )
                log.db_after_write(
                    "write classify result runtime variable",
                    result={"scope": CLASSIFY_SCOPE_OUT, "key": result_key},
                    **task_log_kwargs(task, "handle_classify_messages"),
                )
        except Exception as exc:
            log.error(
                "failed to persist classify results",
                exc=exc,
                error_code="CLASSIFY_RESULT_STORE_FAILED",
                **task_log_kwargs(task, "handle_classify_messages"),
            )
            state.record_failure("classified", str(exc))
            queue.fail_task(task, f"store classify result failed: {exc}", retry=True)
            return

        classified_data = {
            "result_worker_id": context.scheduler.worker_id,
            "result_scope": CLASSIFY_SCOPE_OUT,
            "result_key": result_key,
            "items_classified": len(results),
        }
        state.checkpoint("classified", classified_data)
    else:
        classified_data = state.get_step_data("classified")

    callback_task_uuid = None
    if return_ref is not None:
        if not state.is_step_done("callback_enqueued"):
            state.begin_step("callback_enqueued")
            callback_payload = {
                "action": return_ref["action"],
                "source_action": classify_action,
                "data_ref": {
                    "worker_id": classified_data["result_worker_id"],
                    "scope": classified_data["result_scope"],
                    "key": classified_data["result_key"],
                },
                "original_ref": payload.get("original_ref"),
                "error": None,
            }
            try:
                log.db_before_write(
                    "enqueue classify callback",
                    data={
                        "worker": return_ref["worker"],
                        "queue": return_ref["queue"],
                        "action": return_ref["action"],
                    },
                    **task_log_kwargs(task, "handle_classify_messages"),
                )
                callback_task_uuid = enqueue_with_meta(
                    context.queue(str(return_ref["queue"] or PRIMARY_QUEUE)),
                    str(return_ref["worker"]),
                    callback_payload,
                    current_task=task,
                    current_worker=WORKER,
                    current_action=classify_action,
                    next_worker=str(return_ref["worker"]),
                    next_action=str(return_ref["action"]),
                )
                log.db_after_write(
                    "enqueue classify callback",
                    result={"callback_task_uuid": callback_task_uuid},
                    **task_log_kwargs(task, "handle_classify_messages"),
                )
            except Exception as exc:
                log.error(
                    "failed to enqueue classify callback",
                    exc=exc,
                    error_code="CLASSIFY_CALLBACK_ENQUEUE_FAILED",
                    **task_log_kwargs(task, "handle_classify_messages"),
                )
                state.record_failure("callback_enqueued", str(exc))
                queue.fail_task(
                    task, f"enqueue classify callback failed: {exc}", retry=True
                )
                return
            state.checkpoint(
                "callback_enqueued", {"callback_task_uuid": callback_task_uuid}
            )
        callback_task_uuid = state.get_step_data("callback_enqueued").get(
            "callback_task_uuid"
        )

    cleanup_error = None
    try:
        with context.connect_db() as conn:
            delete_runtime_variable(
                conn,
                worker_id=source_worker_id,
                scope=scope,
                key=str(key),
            )
    except Exception as exc:  # pragma: no cover - runtime path
        cleanup_error = str(exc)

    result = {
        "status": "classified",
        "request_key": key,
        "result_key": classified_data["result_key"],
        "items": classified_data["items_classified"],
        "source_action": classify_action,
        "callback_task_uuid": callback_task_uuid,
        "cleanup_error": cleanup_error,
    }
    step.log("external services classify completed", result)
    log.info(
        "task completed",
        metadata=result,
        **task_log_kwargs(task, "handle_classify_messages"),
    )
    queue.complete_task(task, result)


def handle_task(context: ManagedWorkerContext, task: Task) -> None:
    normalize_payload_meta(task.payload)
    action = task.payload.get("action")
    if action in (FETCH_ACTION, FETCH_DUMMY_ACTION):
        handle_fetch_messages(context, task, source_action=as_optional_string(action))
        return
    if action in (CLASSIFY_ACTION, CLASSIFY_DUMMY_ACTION):
        handle_classify_messages(
            context, task, source_action=as_optional_string(action)
        )
        return
    if action in (PROCESS_INSTRUCTION_ACTION, LEGACY_PROCESS_INSTRUCTION_ACTION):
        handle_process_instruction(
            context, task, source_action=PROCESS_INSTRUCTION_ACTION
        )
        return
    if (
        _extract_provider_key_from_bookings_action(as_optional_string(action) or "")
        is not None
    ):
        handle_get_provider_bookings(
            context, task, source_action=as_optional_string(action)
        )
        return
    context.main_queue.fail_task(task, f"Unexpected action {action}", retry=False)


def run_task(context: ManagedWorkerContext, task: Task) -> None:
    handle_task(context, task)


def main() -> None:
    global RUNTIME_VARIABLE_TTL_CONFIG
    args = parse_args()
    RUNTIME_VARIABLE_TTL_CONFIG = parse_runtime_variable_ttl_config(
        args.runtime_variable_ttl_config
    )
    logger, log_path = configure_worker_logger(WORKER, args.log_dir)
    step = NoOpStepLog()
    scheduler: Optional[ManagedSchedulerClient] = None
    app_logger: Any = NullAppLogger()

    try:
        dsn = build_dsn(args.dsn, args.auto_dsn, args.db_name)
        if not dsn:
            raise SystemExit(
                "DSN is required (use --dsn or --auto-dsn with POSTGRES_PASSWORD set)."
            )

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
            "external services worker started",
            metadata={
                "worker_id": scheduler.worker_id,
                "primary_queue": PRIMARY_QUEUE,
                "subscribed_queues": list(SUBSCRIBED_QUEUES),
                "dummy_messages_dir": str(LOCAL_DUMMY_MESSAGES_DIR),
                "classifier_csv": str(LOCAL_CLASSIFIER_CSV),
                "live_classifier_provider": _resolve_live_classifier_provider(),
                "live_classifier_model": _resolve_live_classifier_model(),
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
            logger.exception("external services worker failed")
        else:
            app_logger.error(
                "external services worker failed", exc=exc, action_name="worker_runtime"
            )
        raise SystemExit(1)
    finally:
        try:
            reset_default_ownerrez_client()
        except Exception as exc:
            if isinstance(app_logger, NullAppLogger):
                logger.exception(
                    "external services worker ownerrez client close failed"
                )
            else:
                app_logger.error(
                    "external services worker ownerrez client close failed",
                    exc=exc,
                    action_name="worker_shutdown",
                )
        if scheduler is not None:
            if not isinstance(app_logger, NullAppLogger):
                app_logger.info(
                    "external services worker shutting down",
                    action_name="worker_shutdown",
                )
            try:
                scheduler.state_manager.shutdown()
            except Exception as exc:
                if isinstance(app_logger, NullAppLogger):
                    logger.exception(
                        "external services worker clean shutdown checkpoint failed"
                    )
                else:
                    app_logger.error(
                        "external services worker clean shutdown checkpoint failed",
                        exc=exc,
                        action_name="worker_shutdown",
                    )
            try:
                app_logger.close()
            except Exception:
                logger.exception("external services worker app logger close failed")
            scheduler.close()


if __name__ == "__main__":
    main()
