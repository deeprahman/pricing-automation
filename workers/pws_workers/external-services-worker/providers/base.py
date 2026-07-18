from __future__ import annotations

from dataclasses import dataclass
import inspect
from typing import Any, Callable, Dict, Optional, Protocol


class ProviderAdapter(Protocol):
    provider_key: str

    def build_execution_plan(
        self,
        target: Dict[str, Any],
        instruction: Dict[str, Any],
        helpers: "ProviderHelpers",
    ) -> Dict[str, Any]:
        ...

    def execute_plan(
        self,
        plan: Dict[str, Any],
        helpers: "ProviderHelpers",
        log_event: Optional[Callable[[str, str, Dict[str, Any]], None]] = None,
    ) -> Dict[str, Any]:
        ...


@dataclass(frozen=True)
class ProviderHelpers:
    canonical_provider_key: Callable[[Any], str | None]
    as_optional_string: Callable[[Any], str | None]
    coerce_required_int: Callable[[Dict[str, Any], str], int]
    provider_endpoint_spec: Callable[[str, bool], Dict[str, str]]
    resolve_instruction_currency: Callable[[Dict[str, Any], Dict[str, Any]], str | None]
    resolve_execution_prices: Callable[..., Dict[str, Any]]
    compress_iso_dates: Callable[[list[str]], list[tuple[str, str]]]
    decimal_to_json_number: Callable[[Any], int | float]
    round_currency: Callable[[Any], float]
    normalize_domain: Callable[[Any, str], str]
    process_instruction_error_result: Callable[..., Dict[str, Any]]
    extract_provider_request_id: Callable[[Any], str | None]
    response_error_message: Callable[..., str]
    process_instruction_mock_mode_enabled: Callable[[str], bool]
    execute_plan_mock: Callable[..., Dict[str, Any]]
    retryable_status_codes: set[int]
    permanent_status_codes: set[int]
    permanent_error_cls: type[Exception]
    retryable_error_cls: type[Exception]
    httpx: Any
    pricelabs_client_cls: Any
    wheelhouse_client_cls: Any


def execute_provider_plan(
    *,
    expected_provider_key: str,
    plan: Dict[str, Any],
    helpers: ProviderHelpers,
    client_factory: Callable[[str, Dict[str, str], Any, Any, Any, ProviderHelpers], Any],
    log_event: Optional[Callable[[str, str, Dict[str, Any]], None]] = None,
) -> Dict[str, Any]:
    provider_key = helpers.canonical_provider_key(plan.get("provider_key"))
    if provider_key is None:
        raise helpers.permanent_error_cls(
            "provider execution plan is missing provider_key",
            error_code="PROVIDER_CONFIG_MISSING",
        )
    if provider_key != expected_provider_key:
        raise helpers.permanent_error_cls(
            f"provider execution plan provider_key '{provider_key}' does not match '{expected_provider_key}'",
            error_code="PROVIDER_CONFIG_MISSING",
        )

    http_calls = plan.get("http_calls")
    if not isinstance(http_calls, list) or not http_calls:
        raise helpers.permanent_error_cls(
            "provider execution plan has no http_calls",
            error_code="PROVIDER_CONFIG_MISSING",
        )

    affected_dates = [str(value) for value in (plan.get("affected_dates") or [])]
    if helpers.process_instruction_mock_mode_enabled(provider_key):
        return helpers.execute_plan_mock(
            provider_key=provider_key,
            http_calls=http_calls,
            affected_dates=affected_dates,
        )

    base_url = helpers.normalize_domain(plan.get("base_url"), provider_key)
    headers = plan.get("headers") if isinstance(plan.get("headers"), dict) else {}
    timeout = plan.get("timeout")
    transport = plan.get("transport")
    verify = plan.get("verify", True)
    timeout_value = timeout if timeout is not None else helpers.httpx.Timeout(
        connect=5.0, read=20.0, write=20.0, pool=5.0
    )

    http_statuses: list[int] = []
    provider_request_ids: list[str] = []
    successful_call_count = 0

    with client_factory(base_url, headers, timeout_value, verify, transport, helpers) as client:
        for raw_call in http_calls:
            if not isinstance(raw_call, dict):
                raise helpers.permanent_error_cls(
                    "provider execution plan contains an invalid http_call entry",
                    error_code="PROVIDER_CONFIG_MISSING",
                )
            method = (helpers.as_optional_string(raw_call.get("method")) or "").upper()
            path = helpers.as_optional_string(raw_call.get("path"))
            transport_path = helpers.as_optional_string(raw_call.get("transport_path")) or path
            if not method or path is None or transport_path is None:
                raise helpers.permanent_error_cls(
                    "provider execution plan contains an incomplete http_call entry",
                    error_code="PROVIDER_CONFIG_MISSING",
                )

            body_provided = "body" in raw_call
            body = raw_call.get("body") if body_provided else None
            query_params = raw_call.get("query_params")
            if query_params is not None and not isinstance(query_params, dict):
                raise helpers.permanent_error_cls(
                    "provider execution plan contains invalid query_params",
                    error_code="PROVIDER_CONFIG_MISSING",
                )
            try:
                response = _request_with_optional_log_event(
                    client=client,
                    method=method,
                    transport_path=transport_path,
                    provider_key=provider_key,
                    body=body,
                    body_provided=body_provided,
                    query_params=query_params if isinstance(query_params, dict) else None,
                    helpers=helpers,
                    log_event=log_event,
                )
            except helpers.httpx.TimeoutException as exc:
                raise helpers.retryable_error_cls(f"{provider_key} {method} {path} timed out") from exc
            except helpers.httpx.TransportError as exc:
                raise helpers.retryable_error_cls(f"{provider_key} {method} {path} failed: {exc}") from exc

            http_statuses.append(int(response.status_code))
            request_id = helpers.extract_provider_request_id(response)
            if request_id is not None:
                provider_request_ids.append(request_id)

            if response.status_code == 207:
                return helpers.process_instruction_error_result(
                    provider_key=provider_key,
                    affected_dates=affected_dates,
                    error=f"{provider_key} {method} {path} returned 207 Multi-Status",
                    partial_success=True,
                    http_statuses=http_statuses,
                    provider_request_ids=provider_request_ids,
                )

            if response.status_code in helpers.retryable_status_codes:
                raise helpers.retryable_error_cls(
                    helpers.response_error_message(response, provider_key=provider_key, method=method, path=path)
                )

            if response.status_code in helpers.permanent_status_codes or response.is_error:
                return helpers.process_instruction_error_result(
                    provider_key=provider_key,
                    affected_dates=affected_dates,
                    error=helpers.response_error_message(
                        response, provider_key=provider_key, method=method, path=path
                    ),
                    partial_success=successful_call_count > 0,
                    http_statuses=http_statuses,
                    provider_request_ids=provider_request_ids,
                )

            successful_call_count += 1

    return {
        "provider_key": provider_key,
        "success": True,
        "partial_success": False,
        "http_statuses": http_statuses,
        "provider_request_ids": provider_request_ids,
        "affected_dates": affected_dates,
        "error": None,
    }


def _request_supports_log_event(client_request: Any) -> bool:
    try:
        signature = inspect.signature(client_request)
    except (TypeError, ValueError):
        return False
    for parameter in signature.parameters.values():
        if parameter.kind == inspect.Parameter.VAR_KEYWORD or parameter.name == "log_event":
            return True
    return False


def _request_with_optional_log_event(
    *,
    client: Any,
    method: str,
    transport_path: str,
    provider_key: str,
    body: Any,
    body_provided: bool,
    query_params: Dict[str, Any] | None,
    helpers: ProviderHelpers,
    log_event: Optional[Callable[[str, str, Dict[str, Any]], None]] = None,
):
    request_kwargs: Dict[str, Any] = {"json": body if body_provided else None}
    if query_params:
        request_kwargs["params"] = query_params
    client_request = client.request
    if log_event is not None and _request_supports_log_event(client_request):
        return client_request(method, transport_path, log_event=log_event, **request_kwargs)

    if log_event is not None:
        log_event(
            "info",
            "provider http request",
            {
                "provider_key": provider_key,
                "method": method,
                "path": transport_path,
                "query_params": query_params or {},
                "request_headers": dict(getattr(client, "headers", {}) or {}),
                "request_body": body if body_provided else None,
                "retry_attempt": 1,
            },
        )

    try:
        response = client_request(method, transport_path, **request_kwargs)
    except helpers.httpx.TimeoutException as exc:
        if log_event is not None:
            log_event(
                "warn",
                "provider http request failed",
                {
                    "provider_key": provider_key,
                    "method": method,
                    "path": transport_path,
                    "query_params": query_params or {},
                    "request_body": body if body_provided else None,
                    "retry_attempt": 1,
                    "error_class": exc.__class__.__name__,
                    "error": str(exc),
                },
            )
        raise
    except helpers.httpx.TransportError as exc:
        if log_event is not None:
            log_event(
                "warn",
                "provider http request failed",
                {
                    "provider_key": provider_key,
                    "method": method,
                    "path": transport_path,
                    "query_params": query_params or {},
                    "request_body": body if body_provided else None,
                    "retry_attempt": 1,
                    "error_class": exc.__class__.__name__,
                    "error": str(exc),
                },
            )
        raise

    if log_event is not None:
        response_preview: Any = None
        try:
            response_preview = response.json()
        except Exception:
            response_preview = getattr(response, "text", None)
        log_event(
            "info",
            "provider http response",
            {
                "provider_key": provider_key,
                "method": method,
                "path": transport_path,
                "query_params": query_params or {},
                "status_code": int(response.status_code),
                "response_headers": dict(getattr(response, "headers", {}) or {}),
                "response_body_preview": response_preview,
                "provider_request_id": helpers.extract_provider_request_id(response),
                "retry_attempt": 1,
            },
        )
    return response


__all__ = [
    "ProviderAdapter",
    "ProviderHelpers",
    "execute_provider_plan",
]
