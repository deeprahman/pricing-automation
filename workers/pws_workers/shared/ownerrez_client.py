from __future__ import annotations

import os
import threading
import time
import warnings
from email.utils import parsedate_to_datetime
from pathlib import Path
from typing import Any, Callable, Dict, Mapping, Optional

import httpx

from pws_workers.shared.http_logging import (
    extract_http_response_preview,
    extract_provider_request_id,
    sanitize_http_metadata,
)


DEFAULT_OWNERREZ_API_BASE_URL = "https://api.ownerrez.com/v2"
OWNERREZ_MESSAGES_PATH = "messages"
OWNERREZ_BOOKINGS_PATH = "bookings"
DEFAULT_BACKOFF_SECONDS = (1.0, 2.0)
RETRYABLE_STATUS_CODES = {429, 500, 502, 503, 504}
PERMANENT_STATUS_CODES = {400, 401, 403, 404, 422}

LogEvent = Callable[[str, str, Dict[str, Any]], None]


class OwnerRezError(Exception):
    def __init__(
        self,
        message: str,
        *,
        failure_classification: str,
        status_code: Optional[int] = None,
        attempts: int = 1,
    ) -> None:
        super().__init__(message)
        self.failure_classification = failure_classification
        self.status_code = status_code
        self.attempts = attempts


class OwnerRezRetryableError(OwnerRezError):
    pass


class OwnerRezPermanentError(OwnerRezError):
    pass


class OwnerRezConfigError(OwnerRezError):
    pass


class OwnerRezResponseShapeError(OwnerRezError):
    pass


def _as_optional_string(value: Any) -> Optional[str]:
    if value is None:
        return None
    if isinstance(value, str):
        value = value.strip()
        return value or None
    return str(value)


def _coerce_optional_int(value: Any, *, field_name: str) -> Optional[int]:
    if value is None or value == "":
        return None
    try:
        return int(value)
    except (TypeError, ValueError) as exc:
        raise OwnerRezResponseShapeError(
            f"OwnerRez messages response has invalid {field_name}",
            failure_classification="invalid_response_shape",
        ) from exc


def _resolve_retry_after_seconds(value: Optional[str]) -> Optional[float]:
    retry_after = _as_optional_string(value)
    if retry_after is None:
        return None
    try:
        seconds = float(retry_after)
        return max(seconds, 0.0)
    except ValueError:
        pass

    try:
        retry_at = parsedate_to_datetime(retry_after)
    except (TypeError, ValueError, IndexError, OverflowError):
        return None
    if retry_at.tzinfo is None:
        return None
    return max(retry_at.timestamp() - time.time(), 0.0)


def _ensure_base_url(base_url: str) -> str:
    candidate = _as_optional_string(base_url)
    if candidate is None:
        raise OwnerRezConfigError(
            "OWNERREZ_API_BASE_URL must not be empty",
            failure_classification="invalid_base_url",
        )
    normalized = candidate.rstrip("/")
    try:
        parsed = httpx.URL(normalized)
    except Exception as exc:
        raise OwnerRezConfigError(
            "OWNERREZ_API_BASE_URL must be a valid absolute URL",
            failure_classification="invalid_base_url",
        ) from exc
    if not parsed.scheme or not parsed.host:
        raise OwnerRezConfigError(
            "OWNERREZ_API_BASE_URL must be a valid absolute URL",
            failure_classification="invalid_base_url",
        )
    return normalized


def _resolve_verify(ca_bundle: Optional[str]) -> bool | str:
    path_value = _as_optional_string(ca_bundle)
    if path_value is None:
        return True
    path = Path(path_value).expanduser()
    if not path.exists():
        raise OwnerRezConfigError(
            f"OWNERREZ_CA_BUNDLE path does not exist: {path}",
            failure_classification="missing_ca_bundle",
        )
    return str(path)


class OwnerRezClient:
    def __init__(
        self,
        *,
        token: str,
        base_url: str = DEFAULT_OWNERREZ_API_BASE_URL,
        ca_bundle: Optional[str] = None,
        transport: Optional[httpx.BaseTransport] = None,
    ) -> None:
        bearer_token = _as_optional_string(token)
        if bearer_token is None:
            raise OwnerRezConfigError(
                "OWNERREZ_BEARER_TOKEN is required",
                failure_classification="missing_bearer_token",
            )

        self.base_url = _ensure_base_url(base_url)
        self._client = httpx.Client(
            base_url=self.base_url,
            headers={
                "Accept": "application/json",
                "Authorization": f"Bearer {bearer_token}",
            },
            timeout=httpx.Timeout(connect=5.0, read=20.0, write=20.0, pool=5.0),
            verify=_resolve_verify(ca_bundle),
            transport=transport,
            follow_redirects=False,
        )

    def close(self) -> None:
        self._client.close()

    def _request_json(
        self,
        *,
        path: str,
        params: Mapping[str, Any],
        request_metadata: Dict[str, Any],
        log_event: Optional[LogEvent] = None,
    ) -> tuple[Dict[str, Any], int]:
        query_params = dict(params)
        for attempt in range(1, 4):
            try:
                request = self._client.build_request("GET", path, params=query_params)
                if log_event is not None:
                    request_event = sanitize_http_metadata(
                        {
                            **request_metadata,
                            "provider_key": "ownerrez",
                            "retry_attempt": attempt,
                            "url": str(request.url),
                            "path": request.url.path,
                            "query_params": dict(request.url.params),
                            "request_headers": dict(request.headers),
                            "request_body": None,
                        }
                    )
                    log_event("info", "provider http request", request_event)
                response = self._client.send(request)
            except httpx.TimeoutException as exc:
                if log_event is not None:
                    log_event(
                        "warn",
                        "provider http request failed",
                        sanitize_http_metadata(
                            {
                                **request_metadata,
                                "provider_key": "ownerrez",
                                "retry_attempt": attempt,
                                "path": path,
                                "query_params": query_params,
                                "request_body": None,
                                "error_class": exc.__class__.__name__,
                                "error": str(exc),
                            }
                        ),
                    )
                if attempt >= 3:
                    raise OwnerRezRetryableError(
                        f"OwnerRez GET {path} timed out after {attempt} attempts",
                        failure_classification="timeout",
                        attempts=attempt,
                    ) from exc
                delay_seconds = DEFAULT_BACKOFF_SECONDS[attempt - 1]
                if log_event is not None:
                    log_event(
                        "warn",
                        "provider http retry scheduled",
                        sanitize_http_metadata(
                            {
                                **request_metadata,
                                "provider_key": "ownerrez",
                                "retry_attempt": attempt,
                                "status_code": None,
                                "retry_delay_seconds": delay_seconds,
                                "failure_classification": "timeout",
                            }
                        ),
                    )
                time.sleep(delay_seconds)
                continue
            except httpx.TransportError as exc:
                if log_event is not None:
                    log_event(
                        "warn",
                        "provider http request failed",
                        sanitize_http_metadata(
                            {
                                **request_metadata,
                                "provider_key": "ownerrez",
                                "retry_attempt": attempt,
                                "path": path,
                                "query_params": query_params,
                                "request_body": None,
                                "error_class": exc.__class__.__name__,
                                "error": str(exc),
                            }
                        ),
                    )
                if attempt >= 3:
                    raise OwnerRezRetryableError(
                        f"OwnerRez GET {path} failed after {attempt} attempts: {exc}",
                        failure_classification="transport_error",
                        attempts=attempt,
                    ) from exc
                delay_seconds = DEFAULT_BACKOFF_SECONDS[attempt - 1]
                if log_event is not None:
                    log_event(
                        "warn",
                        "provider http retry scheduled",
                        sanitize_http_metadata(
                            {
                                **request_metadata,
                                "provider_key": "ownerrez",
                                "retry_attempt": attempt,
                                "status_code": None,
                                "retry_delay_seconds": delay_seconds,
                                "failure_classification": "transport_error",
                            }
                        ),
                    )
                time.sleep(delay_seconds)
                continue

            status_code = response.status_code
            if log_event is not None:
                response_event = sanitize_http_metadata(
                    {
                        **request_metadata,
                        "provider_key": "ownerrez",
                        "retry_attempt": attempt,
                        "path": request.url.path,
                        "query_params": dict(request.url.params),
                        "request_headers": dict(request.headers),
                        "status_code": status_code,
                        "response_headers": dict(response.headers),
                        "response_body_preview": extract_http_response_preview(response),
                        "provider_request_id": extract_provider_request_id(response),
                    }
                )
                log_event("info", "provider http response", response_event)

            if status_code in RETRYABLE_STATUS_CODES:
                message = self._build_http_error_message(response, path=path)
                if attempt >= 3:
                    raise OwnerRezRetryableError(
                        message,
                        failure_classification=f"http_{status_code}",
                        status_code=status_code,
                        attempts=attempt,
                    )
                delay_seconds = _resolve_retry_after_seconds(response.headers.get("Retry-After"))
                if delay_seconds is None:
                    delay_seconds = DEFAULT_BACKOFF_SECONDS[attempt - 1]
                if log_event is not None:
                    log_event(
                        "warn",
                        "provider http retry scheduled",
                        sanitize_http_metadata(
                            {
                                **request_metadata,
                                "provider_key": "ownerrez",
                                "retry_attempt": attempt,
                                "status_code": status_code,
                                "retry_delay_seconds": delay_seconds,
                                "failure_classification": f"http_{status_code}",
                            }
                        ),
                    )
                time.sleep(delay_seconds)
                continue

            if response.is_error:
                raise OwnerRezPermanentError(
                    self._build_http_error_message(response, path=path),
                    failure_classification=f"http_{status_code}",
                    status_code=status_code,
                    attempts=attempt,
                )

            try:
                payload = response.json()
            except ValueError as exc:
                raise OwnerRezResponseShapeError(
                    f"OwnerRez response for {path} was not valid JSON",
                    failure_classification="invalid_json",
                    status_code=status_code,
                    attempts=attempt,
                ) from exc
            if log_event is not None:
                log_event(
                    "debug",
                    "provider http response normalized",
                    sanitize_http_metadata(
                        {
                            **request_metadata,
                            "provider_key": "ownerrez",
                            "retry_attempt": attempt,
                            "path": path,
                            "offset": payload.get("offset") if isinstance(payload, dict) else None,
                            "limit": payload.get("limit") if isinstance(payload, dict) else None,
                            "items_count": len(payload.get("items", [])) if isinstance(payload, dict) and isinstance(payload.get("items"), list) else None,
                        }
                    ),
                )
            return payload, attempt

        raise OwnerRezRetryableError(
            f"OwnerRez GET {path} exhausted retries",
            failure_classification="exhausted_retries",
            attempts=3,
        )

    def get_messages(
        self,
        *,
        thread_id: int,
        offset: Optional[int] = None,
        limit: Optional[int] = None,
        since_utc: Optional[str] = None,
        log_event: Optional[LogEvent] = None,
    ) -> Dict[str, Any]:
        normalized_since = _as_optional_string(since_utc)
        params: Dict[str, Any] = {
            "threadId": int(thread_id),
            "include_drafts": "false",
            "include_attachments": "false",
        }
        if normalized_since is not None:
            params["since_utc"] = normalized_since
        if offset is not None:
            params["offset"] = int(offset)
        if limit is not None:
            params["limit"] = int(limit)

        payload, attempt = self._request_json(
            path=OWNERREZ_MESSAGES_PATH,
            params=params,
            request_metadata={
                "method": "GET",
                "path": OWNERREZ_MESSAGES_PATH,
                "thread_id": int(thread_id),
                "offset": offset,
                "limit": limit,
                "since_utc": normalized_since,
            },
            log_event=log_event,
        )
        normalized = self._normalize_messages_response(
            payload,
            thread_id=int(thread_id),
            offset=offset,
            limit=limit,
            since_utc=normalized_since,
        )
        if log_event is not None:
            log_event(
                "debug",
                "provider http response normalized",
                sanitize_http_metadata(
                    {
                        "provider_key": "ownerrez",
                        "method": "GET",
                        "path": OWNERREZ_MESSAGES_PATH,
                        "thread_id": int(thread_id),
                        "offset": normalized.get("offset"),
                        "limit": normalized.get("limit"),
                        "since_utc": normalized.get("since_utc"),
                        "retry_attempt": attempt,
                        "items_count": len(normalized.get("items", [])),
                    }
                ),
            )
        return normalized

    def get_messages_page_url(
        self,
        *,
        page_url: str,
        thread_id: int,
        log_event: Optional[LogEvent] = None,
    ) -> Dict[str, Any]:
        request_target = self._normalize_page_request_target(page_url)
        
        # ✅ FIX: Parse URL to extract path and query parameters separately
        # The request_target looks like: "messages?threadId=10626854&include_drafts=false&..."
        # We need to separate the path from the query params before passing to _request_json
        try:
            url = httpx.URL(request_target)
            path = url.path
            params = dict(url.params)
        except Exception:
            # Fallback for any parsing issues
            if '?' in request_target:
                path, query_string = request_target.split('?', 1)
                # Parse query string manually if needed
                params = {}
                for param in query_string.split('&'):
                    if '=' in param:
                        key, value = param.split('=', 1)
                        params[key] = value
            else:
                path = request_target
                params = {}
        
        payload, attempt = self._request_json(
            path=path,  # ✅ FIXED: Just the path, no query string
            params=params,  # ✅ FIXED: Query parameters as dictionary
            request_metadata={
                "method": "GET",
                "path": path,
                "thread_id": int(thread_id),
                "page_url": page_url,
            },
            log_event=log_event,
        )
        normalized = self._normalize_messages_response(
            payload,
            thread_id=int(thread_id),
            offset=None,
            limit=None,
            since_utc=None,
        )
        if log_event is not None:
            log_event(
                "debug",
                "provider http response normalized",
                sanitize_http_metadata(
                    {
                        "provider_key": "ownerrez",
                        "method": "GET",
                        "path": path,
                        "thread_id": int(thread_id),
                        "page_url": page_url,
                        "offset": normalized.get("offset"),
                        "limit": normalized.get("limit"),
                        "retry_attempt": attempt,
                        "items_count": len(normalized.get("items", [])),
                    }
                ),
            )
        return normalized

    def get_bookings(
        self,
        *,
        since_utc: Optional[str] = None,
        from_date: Optional[str] = None,
        to_date: Optional[str] = None,
        statuses: Optional[tuple[str, ...]] = ("active", "pending", "canceled"),
        property_ids: Optional[tuple[int, ...]] = None,
        limit: int = 100,
        offset: int = 0,
        single_page: bool = False,
        log_event: Optional[LogEvent] = None,
    ) -> Dict[str, Any]:
        normalized_since = _as_optional_string(since_utc)
        requested_property_ids = tuple(int(item) for item in (property_ids or ()))
        if normalized_since is None and not requested_property_ids:
            raise OwnerRezResponseShapeError(
                "OwnerRez bookings request requires since_utc or property_ids",
                failure_classification="invalid_request",
            )

        if limit < 1:
            raise OwnerRezResponseShapeError(
                "OwnerRez bookings request limit must be positive",
                failure_classification="invalid_request",
            )

        requested_statuses = tuple(
            str(item).strip().lower()
            for item in (statuses or ())
            if _as_optional_string(item) is not None
        )
        if not requested_statuses:
            requested_statuses = ("active", "pending", "canceled")
        # OwnerRez appears to honor a single status value; omit the filter when we want all statuses.
        status_param = requested_statuses[0] if len(requested_statuses) == 1 else None

        normalized_from = _as_optional_string(from_date)
        normalized_to = _as_optional_string(to_date)
        all_items: list[Dict[str, Any]] = []
        current_offset = int(offset)
        page_count = 0
        last_next_page_url: Optional[str] = None

        while True:
            params: Dict[str, Any] = {
                "limit": int(limit),
                "offset": current_offset,
            }
            if normalized_since is not None:
                params["since_utc"] = normalized_since
            if normalized_from is not None:
                params["from"] = normalized_from
            if normalized_to is not None:
                params["to"] = normalized_to
            if status_param is not None:
                params["status"] = status_param
            if requested_property_ids:
                params["property_ids"] = ",".join(str(item) for item in requested_property_ids)

            payload, attempt = self._request_json(
                path=OWNERREZ_BOOKINGS_PATH,
                params=params,
                request_metadata={
                    "method": "GET",
                    "path": OWNERREZ_BOOKINGS_PATH,
                    "since_utc": normalized_since,
                    "from": normalized_from,
                    "to": normalized_to,
                    "offset": current_offset,
                    "limit": int(limit),
                    "status": status_param,
                    "property_ids": params.get("property_ids"),
                },
                log_event=log_event,
            )
            normalized_page = self._normalize_bookings_response(
                payload,
                since_utc=normalized_since,
                offset=current_offset,
                limit=int(limit),
                property_ids=requested_property_ids,
            )
            page_count += 1
            all_items.extend(normalized_page["items"])
            last_next_page_url = _as_optional_string(normalized_page.get("next_page_url"))

            if log_event is not None:
                log_event(
                    "debug",
                    "provider http response normalized",
                    sanitize_http_metadata(
                        {
                            "provider_key": "ownerrez",
                            "method": "GET",
                            "path": OWNERREZ_BOOKINGS_PATH,
                            "since_utc": normalized_since,
                            "offset": normalized_page.get("offset"),
                            "limit": normalized_page.get("limit"),
                            "retry_attempt": attempt,
                            "items_count": len(normalized_page.get("items", [])),
                            "page_count": page_count,
                        }
                    ),
                )

            if single_page:
                break

            next_page_url = last_next_page_url
            if not normalized_page["items"]:
                break
            if next_page_url is None:
                break

            next_offset = self._parse_next_offset(next_page_url, fallback=current_offset + normalized_page["limit"])
            if next_offset is None or next_offset <= current_offset:
                break
            current_offset = next_offset

        return {
            "items": all_items,
            "since_utc": normalized_since,
            "from": normalized_from,
            "to": normalized_to,
            "offset": int(offset),
            "limit": int(limit),
            "page_count": page_count,
            "next_page_url": last_next_page_url,
            "status": list(requested_statuses),
            "property_ids": list(requested_property_ids),
        }

    def _build_http_error_message(self, response: httpx.Response, *, path: str) -> str:
        detail: Optional[str] = None
        try:
            payload = response.json()
        except ValueError:
            payload = None
        if isinstance(payload, dict):
            for field_name in ("message", "detail", "error"):
                detail = _as_optional_string(payload.get(field_name))
                if detail:
                    break
        if detail is None:
            detail = _as_optional_string(response.text)
        if detail is not None and len(detail) > 240:
            detail = f"{detail[:237]}..."
        status_text = f"{response.status_code} {response.reason_phrase}".strip()
        if detail:
            return f"OwnerRez GET {path} returned {status_text}: {detail}"
        return f"OwnerRez GET {path} returned {status_text}"

    def _normalize_messages_response(
        self,
        payload: Any,
        *,
        thread_id: int,
        offset: Optional[int],
        limit: Optional[int],
        since_utc: Optional[str],
    ) -> Dict[str, Any]:
        if not isinstance(payload, dict):
            raise OwnerRezResponseShapeError(
                "OwnerRez messages response must be a JSON object",
                failure_classification="invalid_response_shape",
            )

        items_missing = "items" not in payload
        # Treat omitted items as an empty no-message response, while keeping strict
        # validation for explicitly malformed items values.
        if items_missing:
            items = []
        else:
            items = payload.get("items")
        if not isinstance(items, list):
            raise OwnerRezResponseShapeError(
                "OwnerRez messages response missing items list",
                failure_classification="invalid_response_shape",
            )
        if any(not isinstance(item, dict) for item in items):
            raise OwnerRezResponseShapeError(
                "OwnerRez messages response items must be objects",
                failure_classification="invalid_response_shape",
            )

        thread = payload.get("thread")
        if not isinstance(thread, dict):
            raise OwnerRezResponseShapeError(
                "OwnerRez messages response missing thread object",
                failure_classification="invalid_response_shape",
            )

        normalized = dict(payload)
        normalized_thread = dict(thread)
        normalized_thread_id = _coerce_optional_int(normalized_thread.get("id"), field_name="thread.id")
        normalized_thread["id"] = normalized_thread_id if normalized_thread_id is not None else int(thread_id)
        normalized["thread"] = normalized_thread
        normalized["items"] = items
        normalized["since_utc"] = since_utc
        normalized["next_page_url"] = _as_optional_string(normalized.get("next_page_url"))
        if items_missing:
            normalized["_items_missing_treated_as_empty"] = True

        resolved_offset = _coerce_optional_int(normalized.get("offset"), field_name="offset")
        if resolved_offset is None:
            resolved_offset = 0 if offset is None else int(offset)
        normalized["offset"] = resolved_offset

        resolved_limit = _coerce_optional_int(normalized.get("limit"), field_name="limit")
        if resolved_limit is None:
            if limit is not None:
                resolved_limit = int(limit)
            else:
                resolved_limit = len(items)
        normalized["limit"] = resolved_limit
        return normalized

    def _normalize_page_request_target(self, page_url: str) -> str:
        """
        Normalize pagination URLs from OwnerRez API to relative paths.
        
        The API returns absolute paths like "/v2/messages?threadId=123&offset=20"
        but our client uses relative paths like "messages?threadId=123&offset=20"
        This method converts API's absolute paths to our relative path format.
        """
        target = _as_optional_string(page_url)
        if target is None:
            raise OwnerRezResponseShapeError(
                "OwnerRez messages next_page_url must not be empty",
                failure_classification="invalid_response_shape",
            )
        try:
            httpx.URL(target)  # validate structure only
        except Exception as exc:
            raise OwnerRezResponseShapeError(
                "OwnerRez messages next_page_url must be a valid URL",
                failure_classification="invalid_response_shape",
            ) from exc
        
        # Convert API's absolute paths to our relative path format
        # API returns: "/v2/messages?threadId=123&offset=20"
        # We need: "messages?threadId=123&offset=20"
        if target.startswith("/v2/"):
            return target[4:]  # Strip "/v2/" prefix
        
        # If path doesn't start with /v2/, return as-is (full URL or unexpected format)
        # Log warning in case API changed its format
        if target.startswith("/") and not target.startswith("/v2/"):
            warnings.warn(
                f"OwnerRez next_page_url '{target}' uses unexpected path format. "
                f"Expected '/v2/...' but got '{target}'. "
                f"This may indicate an API change.",
                category=RuntimeWarning,
                stacklevel=2,
            )
        
        return target

    def _normalize_bookings_response(
        self,
        payload: Any,
        *,
        since_utc: Optional[str],
        offset: int,
        limit: int,
        property_ids: tuple[int, ...],
    ) -> Dict[str, Any]:
        if not isinstance(payload, dict):
            raise OwnerRezResponseShapeError(
                "OwnerRez bookings response must be a JSON object",
                failure_classification="invalid_response_shape",
            )

        # OwnerRez omits "items" on empty bookings pages when property_ids are used.
        items = payload.get("items")
        if items is None:
            if property_ids:
                items = []
            else:
                raise OwnerRezResponseShapeError(
                    "OwnerRez bookings response missing items list",
                    failure_classification="invalid_response_shape",
                )
        elif not isinstance(items, list):
            raise OwnerRezResponseShapeError(
                "OwnerRez bookings response missing items list",
                failure_classification="invalid_response_shape",
            )
        if any(not isinstance(item, dict) for item in items):
            raise OwnerRezResponseShapeError(
                "OwnerRez bookings response items must be objects",
                failure_classification="invalid_response_shape",
            )

        normalized = dict(payload)
        normalized["items"] = items
        normalized["since_utc"] = since_utc

        resolved_offset = _coerce_optional_int(normalized.get("offset"), field_name="offset")
        if resolved_offset is None:
            resolved_offset = int(offset)
        normalized["offset"] = resolved_offset

        resolved_limit = _coerce_optional_int(normalized.get("limit"), field_name="limit")
        if resolved_limit is None:
            resolved_limit = int(limit)
        normalized["limit"] = resolved_limit
        normalized["next_page_url"] = _as_optional_string(normalized.get("next_page_url"))
        return normalized

    def _parse_next_offset(self, next_page_url: str, *, fallback: int) -> Optional[int]:
        try:
            params = httpx.URL(next_page_url).params
        except Exception:
            return fallback
        raw_offset = params.get("offset")
        parsed_offset = _coerce_optional_int(raw_offset, field_name="offset")
        if parsed_offset is None:
            return fallback
        return parsed_offset


def build_ownerrez_client_from_env(
    env: Optional[Mapping[str, str]] = None,
    *,
    transport: Optional[httpx.BaseTransport] = None,
) -> OwnerRezClient:
    source = os.environ if env is None else env
    return OwnerRezClient(
        token=source.get("OWNERREZ_BEARER_TOKEN", ""),
        base_url=source.get("OWNERREZ_API_BASE_URL", DEFAULT_OWNERREZ_API_BASE_URL),
        ca_bundle=source.get("OWNERREZ_CA_BUNDLE"),
        transport=transport,
    )


_DEFAULT_CLIENT_LOCK = threading.Lock()
_DEFAULT_CLIENT: Optional[OwnerRezClient] = None


def get_default_ownerrez_client() -> OwnerRezClient:
    global _DEFAULT_CLIENT
    with _DEFAULT_CLIENT_LOCK:
        if _DEFAULT_CLIENT is None:
            _DEFAULT_CLIENT = build_ownerrez_client_from_env()
        return _DEFAULT_CLIENT


def reset_default_ownerrez_client() -> None:
    global _DEFAULT_CLIENT
    with _DEFAULT_CLIENT_LOCK:
        if _DEFAULT_CLIENT is not None:
            _DEFAULT_CLIENT.close()
            _DEFAULT_CLIENT = None


__all__ = [
    "DEFAULT_OWNERREZ_API_BASE_URL",
    "OWNERREZ_BOOKINGS_PATH",
    "OWNERREZ_MESSAGES_PATH",
    "OwnerRezClient",
    "OwnerRezConfigError",
    "OwnerRezError",
    "OwnerRezPermanentError",
    "OwnerRezResponseShapeError",
    "OwnerRezRetryableError",
    "build_ownerrez_client_from_env",
    "get_default_ownerrez_client",
    "reset_default_ownerrez_client",
]
