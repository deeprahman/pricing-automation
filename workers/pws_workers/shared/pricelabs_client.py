from __future__ import annotations

from datetime import date
from typing import Any, Callable, Dict, Mapping, Optional, Sequence

import httpx

from pws_workers.shared.http_logging import (
    extract_http_response_preview,
    extract_provider_request_id,
    sanitize_http_metadata,
)


DEFAULT_PRICELABS_API_BASE_URL = "https://api.pricelabs.co"


class PriceLabsUnexpectedStatusError(RuntimeError):
    pass


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
        raise ValueError("PriceLabs base_url must not be empty")
    normalized = candidate.rstrip("/")
    parsed = httpx.URL(normalized)
    if not parsed.scheme or not parsed.host:
        raise ValueError("PriceLabs base_url must be a valid absolute URL")
    return normalized


def _require_string(value: Any, *, field_name: str) -> str:
    normalized = _as_optional_string(value)
    if normalized is None:
        raise ValueError(f"PriceLabs {field_name} is required")
    return normalized


def _require_iso_date(value: Any, *, field_name: str) -> str:
    normalized = _require_string(value, field_name=field_name)
    try:
        date.fromisoformat(normalized)
    except ValueError as exc:
        raise ValueError(f"PriceLabs {field_name} must be YYYY-MM-DD") from exc
    return normalized


def _assert_expected_status(
    response: httpx.Response,
    *,
    method: str,
    path: str,
    expected_statuses: Sequence[int],
) -> None:
    if int(response.status_code) in {int(value) for value in expected_statuses}:
        return
    expected = ", ".join(str(int(value)) for value in expected_statuses)
    raise PriceLabsUnexpectedStatusError(
        f"PriceLabs {method} {path} returned {response.status_code}, expected one of [{expected}]"
    )


class PriceLabsClient:
    def __init__(
        self,
        *,
        base_url: str = DEFAULT_PRICELABS_API_BASE_URL,
        headers: Optional[Mapping[str, str]] = None,
        timeout: Optional[httpx.Timeout | float] = None,
        verify: bool | str = True,
        transport: Optional[httpx.BaseTransport] = None,
    ) -> None:
        normalized_headers = {
            str(key): str(value)
            for key, value in (headers or {}).items()
            if _as_optional_string(key) is not None and _as_optional_string(value) is not None
        }
        self.base_url = _ensure_base_url(base_url)
        self._client = httpx.Client(
            base_url=self.base_url,
            headers=normalized_headers,
            timeout=timeout if timeout is not None else httpx.Timeout(connect=5.0, read=20.0, write=20.0, pool=5.0),
            verify=verify,
            transport=transport,
            follow_redirects=False,
        )

    def __enter__(self) -> "PriceLabsClient":
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
            raise ValueError("PriceLabs request method is required")
        if normalized_path is None:
            raise ValueError("PriceLabs request path is required")

        request = self._client.build_request(normalized_method, normalized_path, **kwargs)
        if log_event is not None:
            log_event(
                "info",
                "provider http request",
                sanitize_http_metadata(
                    {
                        "provider_key": "pricelabs",
                        "method": normalized_method,
                        "path": request.url.path,
                        "query_params": dict(request.url.params),
                        "request_headers": dict(request.headers),
                        "request_body": kwargs.get("json")
                        if "json" in kwargs
                        else kwargs.get("data")
                        if "data" in kwargs
                        else kwargs.get("content")
                        if "content" in kwargs
                        else None,
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
                            "provider_key": "pricelabs",
                            "method": normalized_method,
                            "path": normalized_path,
                            "query_params": dict(request.url.params),
                            "request_body": kwargs.get("json")
                            if "json" in kwargs
                            else kwargs.get("data")
                            if "data" in kwargs
                            else kwargs.get("content")
                            if "content" in kwargs
                            else None,
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
                            "provider_key": "pricelabs",
                            "method": normalized_method,
                            "path": normalized_path,
                            "query_params": dict(request.url.params),
                            "request_body": kwargs.get("json")
                            if "json" in kwargs
                            else kwargs.get("data")
                            if "data" in kwargs
                            else kwargs.get("content")
                            if "content" in kwargs
                            else None,
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
                        "provider_key": "pricelabs",
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

    def get_listing_prices(
        self,
        *,
        listing_id: str,
        pms: str,
        date_from: str,
        date_to: str,
        reason: Optional[bool] = None,
        log_event: Optional[Callable[[str, str, Dict[str, Any]], None]] = None,
    ) -> httpx.Response:
        listing_id_value = _require_string(listing_id, field_name="listing_id")
        pms_value = _require_string(pms, field_name="pms")
        date_from_value = _require_iso_date(date_from, field_name="date_from")
        date_to_value = _require_iso_date(date_to, field_name="date_to")
        if date.fromisoformat(date_from_value) > date.fromisoformat(date_to_value):
            raise ValueError("PriceLabs date_from must be <= date_to")

        listing_item: Dict[str, Any] = {
            "id": listing_id_value,
            "pms": pms_value,
            "dateFrom": date_from_value,
            "dateTo": date_to_value,
        }
        if reason is not None:
            listing_item["reason"] = bool(reason)

        response = self.request(
            "POST",
            "/v1/listing_prices",
            json={"listings": [listing_item]},
            log_event=log_event,
        )
        _assert_expected_status(
            response,
            method="POST",
            path="/v1/listing_prices",
            expected_statuses=(200,),
        )
        return response

    def get_listing_overrides(
        self,
        *,
        listing_id: str,
        pms: str,
        log_event: Optional[Callable[[str, str, Dict[str, Any]], None]] = None,
    ) -> httpx.Response:
        listing_id_value = _require_string(listing_id, field_name="listing_id")
        pms_value = _require_string(pms, field_name="pms")
        path = f"/v1/listings/{listing_id_value}/overrides"
        response = self.request(
            "GET",
            path,
            params={"pms": pms_value},
            log_event=log_event,
        )
        _assert_expected_status(
            response,
            method="GET",
            path=path,
            expected_statuses=(200,),
        )
        return response

    def set_listing_overrides(
        self,
        *,
        listing_id: str,
        pms: str,
        overrides: Sequence[Mapping[str, Any]],
        update_children: bool = False,
        log_event: Optional[Callable[[str, str, Dict[str, Any]], None]] = None,
    ) -> httpx.Response:
        listing_id_value = _require_string(listing_id, field_name="listing_id")
        pms_value = _require_string(pms, field_name="pms")
        path = f"/v1/listings/{listing_id_value}/overrides"
        response = self.request(
            "POST",
            path,
            json={
                "pms": pms_value,
                "update_children": bool(update_children),
                "overrides": [dict(item) for item in overrides],
            },
            log_event=log_event,
        )
        _assert_expected_status(
            response,
            method="POST",
            path=path,
            expected_statuses=(200,),
        )
        return response

    def delete_listing_overrides(
        self,
        *,
        listing_id: str,
        pms: str,
        dates: Sequence[str],
        update_children: bool = False,
        log_event: Optional[Callable[[str, str, Dict[str, Any]], None]] = None,
    ) -> httpx.Response:
        listing_id_value = _require_string(listing_id, field_name="listing_id")
        pms_value = _require_string(pms, field_name="pms")
        date_rows = [{"date": _require_iso_date(value, field_name="date")} for value in dates]
        if not date_rows:
            raise ValueError("PriceLabs dates is required")
        path = f"/v1/listings/{listing_id_value}/overrides"
        response = self.request(
            "DELETE",
            path,
            json={
                "pms": pms_value,
                "update_children": bool(update_children),
                "overrides": date_rows,
            },
            log_event=log_event,
        )
        _assert_expected_status(
            response,
            method="DELETE",
            path=path,
            expected_statuses=(204,),
        )
        return response


__all__ = [
    "DEFAULT_PRICELABS_API_BASE_URL",
    "PriceLabsUnexpectedStatusError",
    "PriceLabsClient",
]
