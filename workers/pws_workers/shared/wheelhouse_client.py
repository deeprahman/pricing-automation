from __future__ import annotations

from typing import Any, Callable, Dict, Mapping, Optional

import httpx

from pws_workers.shared.http_logging import (
    extract_http_response_preview,
    extract_provider_request_id,
    sanitize_http_metadata,
)


DEFAULT_WHEELHOUSE_API_BASE_URL = "https://api.usewheelhouse.com"
WHEELHOUSE_RM_HEADER_NAME = "X-Integration-Api-Key"


def _as_optional_string(value: Any) -> Optional[str]:
    if value is None:
        return None
    if isinstance(value, str):
        value = value.strip()
        return value or None
    return str(value)


def _ensure_base_url(base_url: str) -> str:
    candidate = _as_optional_string(base_url)
    if candidate is None:
        raise ValueError("Wheelhouse base_url must not be empty")
    normalized = candidate.rstrip("/")
    parsed = httpx.URL(normalized)
    if not parsed.scheme or not parsed.host:
        raise ValueError("Wheelhouse base_url must be a valid absolute URL")
    return normalized


def _resolve_wheelhouse_integration_key(headers: Mapping[str, str]) -> Optional[str]:
    lowered = {str(key).strip().lower(): _as_optional_string(value) for key, value in headers.items()}
    for header_name in (
        "x-integration-api-key",
        "x-integration-apikey",
        "x-user-access-key",
        "x-user-accesskey",
        "x-user-api-key",
        "x-user-apikey",
    ):
        value = lowered.get(header_name)
        if value is not None:
            return value
    return None


def _normalize_headers(headers: Mapping[str, str] | None) -> Dict[str, str]:
    normalized_headers = {
        str(key): str(value)
        for key, value in (headers or {}).items()
        if _as_optional_string(key) is not None and _as_optional_string(value) is not None
    }
    integration_key = _resolve_wheelhouse_integration_key(normalized_headers)
    if integration_key is None:
        return normalized_headers

    auth_aliases = {
        "x-integration-api-key",
        "x-integration-apikey",
        "x-user-access-key",
        "x-user-accesskey",
        "x-user-api-key",
        "x-user-apikey",
    }
    filtered_headers = {
        key: value
        for key, value in normalized_headers.items()
        if str(key).strip().lower() not in auth_aliases
    }
    filtered_headers[WHEELHOUSE_RM_HEADER_NAME] = integration_key
    return filtered_headers


class WheelhouseClient:
    def __init__(
        self,
        *,
        base_url: str = DEFAULT_WHEELHOUSE_API_BASE_URL,
        headers: Optional[Mapping[str, str]] = None,
        timeout: Optional[httpx.Timeout | float] = None,
        verify: bool | str = True,
        transport: Optional[httpx.BaseTransport] = None,
    ) -> None:
        normalized_headers = _normalize_headers(headers)
        self.base_url = _ensure_base_url(base_url)
        self._client = httpx.Client(
            base_url=self.base_url,
            headers=normalized_headers,
            timeout=timeout if timeout is not None else httpx.Timeout(connect=5.0, read=20.0, write=20.0, pool=5.0),
            verify=verify,
            transport=transport,
            follow_redirects=False,
        )

    def __enter__(self) -> "WheelhouseClient":
        return self

    def __exit__(self, exc_type, exc, tb) -> bool:
        self.close()
        return False

    def close(self) -> None:
        self._client.close()

    def request(
        self,
        method: str,
        path: str,
        *,
        log_event: Optional[Callable[[str, str, Dict[str, Any]], None]] = None,
        **kwargs: Any,
    ) -> httpx.Response:
        normalized_method = (_as_optional_string(method) or "").upper()
        normalized_path = _as_optional_string(path)
        if not normalized_method:
            raise ValueError("Wheelhouse request method is required")
        if normalized_path is None:
            raise ValueError("Wheelhouse request path is required")

        request = self._client.build_request(normalized_method, normalized_path, **kwargs)
        request_body = kwargs.get("json") if "json" in kwargs else kwargs.get("data") if "data" in kwargs else kwargs.get("content") if "content" in kwargs else None
        if log_event is not None:
            log_event(
                "info",
                "provider http request",
                sanitize_http_metadata(
                    {
                        "provider_key": "wheelhouse",
                        "method": normalized_method,
                        "path": request.url.path,
                        "query_params": dict(request.url.params),
                        "request_headers": dict(request.headers),
                        "request_body": request_body,
                        "retry_attempt": 1,
                    }
                ),
            )

        try:
            response = self._client.send(request)
        except httpx.TimeoutException as exc:
            if log_event is not None:
                log_event(
                    "warn",
                    "provider http request failed",
                    sanitize_http_metadata(
                        {
                            "provider_key": "wheelhouse",
                            "method": normalized_method,
                            "path": normalized_path,
                            "query_params": dict(request.url.params),
                            "request_body": request_body,
                            "retry_attempt": 1,
                            "error_class": exc.__class__.__name__,
                            "error": str(exc),
                        }
                    ),
                )
            raise
        except httpx.TransportError as exc:
            if log_event is not None:
                log_event(
                    "warn",
                    "provider http request failed",
                    sanitize_http_metadata(
                        {
                            "provider_key": "wheelhouse",
                            "method": normalized_method,
                            "path": normalized_path,
                            "query_params": dict(request.url.params),
                            "request_body": request_body,
                            "retry_attempt": 1,
                            "error_class": exc.__class__.__name__,
                            "error": str(exc),
                        }
                    ),
                )
            raise

        if log_event is not None:
            log_event(
                "info",
                "provider http response",
                sanitize_http_metadata(
                    {
                        "provider_key": "wheelhouse",
                        "method": normalized_method,
                        "path": request.url.path,
                        "query_params": dict(request.url.params),
                        "status_code": response.status_code,
                        "response_headers": dict(response.headers),
                        "response_body_preview": extract_http_response_preview(response),
                        "provider_request_id": extract_provider_request_id(response),
                        "retry_attempt": 1,
                    }
                ),
            )

        return response


__all__ = [
    "DEFAULT_WHEELHOUSE_API_BASE_URL",
    "WheelhouseClient",
]
