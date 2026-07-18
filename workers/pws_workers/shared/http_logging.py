from __future__ import annotations

from collections.abc import Mapping, Sequence
from decimal import Decimal
import re
from typing import Any, Dict, Optional

import httpx


MAX_STRING_LENGTH = 1200
MAX_COLLECTION_ITEMS = 25
MAX_DEPTH = 6

_SECRET_KEY_RE = re.compile(
    r"(authorization|api[_-]?key|access[_-]?key|password|secret|cookie|session|token|bearer|csrf)",
    re.IGNORECASE,
)
_SECRET_HEADER_NAMES = {
    "authorization",
    "proxy-authorization",
    "x-api-key",
    "x-integration-api-key",
    "x-user-api-key",
    "x-user-access-key",
    "cookie",
    "set-cookie",
    "x-csrf-token",
    "x-xsrf-token",
}


def _as_optional_string(value: Any) -> Optional[str]:
    if value is None:
        return None
    if isinstance(value, str):
        text = value.strip()
        return text or None
    text = str(value).strip()
    return text or None


def _is_secret_key(key: Any) -> bool:
    normalized = str(key).strip().lower().replace("-", "_").replace(" ", "_")
    if normalized in _SECRET_HEADER_NAMES:
        return True
    return bool(_SECRET_KEY_RE.search(normalized))


def _truncate_string(value: str) -> str:
    if len(value) <= MAX_STRING_LENGTH:
        return value
    return f"{value[: MAX_STRING_LENGTH - 3]}..."


def sanitize_http_value(value: Any, *, _depth: int = 0) -> Any:
    if value is None or isinstance(value, (bool, int, float)):
        return value
    if isinstance(value, Decimal):
        return str(value)
    if isinstance(value, str):
        return _truncate_string(value)
    if isinstance(value, (bytes, bytearray, memoryview)):
        return f"<{type(value).__name__} len={len(value)}>"
    if _depth >= MAX_DEPTH:
        return "<depth-limit>"

    if isinstance(value, httpx.Headers):
        value = dict(value.items())
    elif isinstance(value, httpx.QueryParams):
        value = dict(value.multi_items())
    elif isinstance(value, httpx.URL):
        return str(value)

    if isinstance(value, Mapping):
        sanitized: Dict[str, Any] = {}
        for raw_key, raw_value in value.items():
            key = str(raw_key)
            sanitized[key] = "<redacted>" if _is_secret_key(key) else sanitize_http_value(
                raw_value,
                _depth=_depth + 1,
            )
        return sanitized

    if isinstance(value, Sequence) and not isinstance(value, (str, bytes, bytearray, memoryview)):
        items = [sanitize_http_value(item, _depth=_depth + 1) for item in list(value)[:MAX_COLLECTION_ITEMS]]
        if len(value) > MAX_COLLECTION_ITEMS:
            items.append(f"<truncated {len(value) - MAX_COLLECTION_ITEMS} items>")
        return items

    if isinstance(value, set):
        ordered = sorted(value, key=str)
        return sanitize_http_value(ordered, _depth=_depth)

    return _truncate_string(str(value))


def sanitize_http_metadata(metadata: Mapping[str, Any]) -> Dict[str, Any]:
    return {str(key): sanitize_http_value(value) for key, value in metadata.items()}


def extract_http_response_preview(response: httpx.Response) -> Any:
    try:
        payload = response.json()
    except ValueError:
        payload = _as_optional_string(response.text)
    if payload is None:
        return None
    return sanitize_http_value(payload)


def extract_provider_request_id(response: httpx.Response) -> Optional[str]:
    for header_name in ("x-request-id", "request-id", "x-amzn-requestid", "x-correlation-id"):
        value = _as_optional_string(response.headers.get(header_name))
        if value is not None:
            return value

    try:
        payload = response.json()
    except ValueError:
        payload = None
    if isinstance(payload, Mapping):
        for field_name in ("request_id", "requestId", "correlation_id", "correlationId"):
            value = _as_optional_string(payload.get(field_name))
            if value is not None:
                return value
    return None


__all__ = [
    "extract_http_response_preview",
    "extract_provider_request_id",
    "sanitize_http_metadata",
    "sanitize_http_value",
]
