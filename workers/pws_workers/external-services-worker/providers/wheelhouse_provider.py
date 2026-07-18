from __future__ import annotations

from datetime import date
from decimal import Decimal
from typing import Any, Dict

from .base import ProviderHelpers, execute_provider_plan
from .wheelhouse_metadata import resolve_wheelhouse_channel


class WheelhouseProviderAdapter:
    provider_key = "wheelhouse"

    def build_execution_plan(
        self,
        target: Dict[str, Any],
        instruction: Dict[str, Any],
        helpers: ProviderHelpers,
    ) -> Dict[str, Any]:
        provider_key = self.provider_key
        listing_metadata = target.get("listing_metadata") if isinstance(target.get("listing_metadata"), dict) else {}

        remove = bool(instruction.get("remove"))
        dates = [str(value) for value in (instruction.get("dates") or [])]
        amount = instruction.get("amount")
        if not isinstance(amount, Decimal):
            amount = Decimal(str(amount))
        operation = helpers.as_optional_string(instruction.get("operation")) or ""
        instruction_type = helpers.as_optional_string(instruction.get("type")) or ""
        target_rate_type = (
            helpers.as_optional_string(instruction.get("target_rate_type")) or "base"
        ).lower()
        listing_id = helpers.as_optional_string(target.get("listing_id"))
        if listing_id is None:
            raise helpers.permanent_error_cls(
                "instruction target listing_id is missing",
                error_code="LISTING_BINDING_NOT_FOUND",
            )
        channel = resolve_wheelhouse_channel(
            listing_metadata, helpers.as_optional_string
        )
        if channel is None:
            raise helpers.permanent_error_cls(
                "Wheelhouse custom-rate writes require listing_metadata.channel",
                error_code="PROVIDER_CONFIG_MISSING",
            )
        query_params = {"channel": channel}

        plan: Dict[str, Any] = {
            "provider_key": provider_key,
            "operation_kind": "remove" if remove else "apply",
            "base_url": target.get("base_url"),
            "headers": target.get("headers"),
            "affected_dates": list(dates),
            "http_calls": [],
            "baseline_required": False,
            "baseline_source": None,
        }
        endpoint = helpers.provider_endpoint_spec(provider_key, remove=remove)

        if remove:
            delete_ranges = [
                {
                    "start_date": start_date,
                    "end_date": end_date,
                }
                for start_date, end_date in helpers.compress_iso_dates(dates)
            ]
            plan["http_calls"] = [
                {
                    "method": "DELETE",
                    "path": endpoint["path"].format(listing_id=listing_id),
                    "transport_path": endpoint["transport_path"].format(listing_id=listing_id),
                    "query_params": query_params,
                    "body": {"delete_ranges": delete_ranges},
                }
            ]
            return plan

        if instruction_type == "percentage":
            if target_rate_type in {"minimum", "maximum"}:
                resolved_prices = helpers.resolve_execution_prices(
                    instruction, dates=dates
                )
                currency = helpers.resolve_instruction_currency(
                    instruction, listing_metadata
                )
                if currency is None:
                    raise helpers.permanent_error_cls(
                        "Wheelhouse fixed-price writes require currency",
                        error_code="PROVIDER_CONFIG_MISSING",
                    )
                plan["baseline_required"] = True
                execution_context = instruction.get("execution_context")
                if isinstance(execution_context, dict):
                    plan["baseline_source"] = helpers.as_optional_string(
                        execution_context.get("baseline_source")
                    )
                custom_rates = []
                for date_value in dates:
                    current_date = date.fromisoformat(date_value)
                    weekday_key = current_date.strftime("%A").lower()
                    base_amount = resolved_prices[date_value]
                    delta = (base_amount * amount) / Decimal("100")
                    new_amount = (
                        base_amount + delta
                        if operation == "increase"
                        else base_amount - delta
                    )
                    custom_rates.append(
                        {
                            "start_date": date_value,
                            "end_date": date_value,
                            "rate_type": "fixed",
                            "currency": currency,
                            weekday_key: helpers.round_currency(new_amount),
                        }
                    )
                plan["http_calls"] = [
                    {
                        "method": "PUT",
                        "path": endpoint["path"].format(listing_id=listing_id),
                        "transport_path": endpoint["transport_path"].format(
                            listing_id=listing_id
                        ),
                        "query_params": query_params,
                        "body": {"custom_rates": custom_rates},
                    }
                ]
                return plan

            adjustment = Decimal("100") + amount if operation == "increase" else Decimal("100") - amount
            body = {
                "custom_rates": [
                    {
                        "start_date": start_date,
                        "end_date": end_date,
                        "rate_type": "adjustment",
                        "adjustment": helpers.decimal_to_json_number(adjustment),
                    }
                    for start_date, end_date in helpers.compress_iso_dates(dates)
                ]
            }
            plan["http_calls"] = [
                {
                    "method": "PUT",
                    "path": endpoint["path"].format(listing_id=listing_id),
                    "transport_path": endpoint["transport_path"].format(listing_id=listing_id),
                    "query_params": query_params,
                    "body": body,
                }
            ]
            return plan

        if instruction_type == "fixed":
            currency = helpers.resolve_instruction_currency(instruction, listing_metadata)
            if currency is None:
                raise helpers.permanent_error_cls(
                    "Wheelhouse fixed-price writes require currency",
                    error_code="PROVIDER_CONFIG_MISSING",
                )
            custom_rates = []
            for date_value in dates:
                current_date = date.fromisoformat(date_value)
                weekday_key = current_date.strftime("%A").lower()
                custom_rates.append(
                    {
                        "start_date": date_value,
                        "end_date": date_value,
                        "rate_type": "fixed",
                        "currency": currency,
                        weekday_key: helpers.round_currency(amount),
                    }
                )
            plan["http_calls"] = [
                {
                    "method": "PUT",
                    "path": endpoint["path"].format(listing_id=listing_id),
                    "transport_path": endpoint["transport_path"].format(listing_id=listing_id),
                    "query_params": query_params,
                    "body": {"custom_rates": custom_rates},
                }
            ]
            return plan

        # Compatibility-only path for legacy flat instructions.
        resolved_prices = helpers.resolve_execution_prices(instruction, dates=dates)
        currency = helpers.resolve_instruction_currency(instruction, listing_metadata)
        if currency is None:
            raise helpers.permanent_error_cls(
                "Wheelhouse fixed-price writes require currency",
                error_code="PROVIDER_CONFIG_MISSING",
            )
        plan["baseline_required"] = True
        execution_context = instruction.get("execution_context")
        if isinstance(execution_context, dict):
            plan["baseline_source"] = helpers.as_optional_string(execution_context.get("baseline_source"))
        custom_rates = []
        for date_value in dates:
            current_date = date.fromisoformat(date_value)
            weekday_key = current_date.strftime("%A").lower()
            custom_rates.append(
                {
                    "start_date": date_value,
                    "end_date": date_value,
                    "rate_type": "fixed",
                    "currency": currency,
                    weekday_key: helpers.round_currency(
                        resolved_prices[date_value] + amount
                        if operation == "increase"
                        else resolved_prices[date_value] - amount
                    ),
                }
            )
        plan["http_calls"] = [
            {
                "method": "PUT",
                "path": endpoint["path"].format(listing_id=listing_id),
                "transport_path": endpoint["transport_path"].format(listing_id=listing_id),
                "query_params": query_params,
                "body": {"custom_rates": custom_rates},
            }
        ]
        return plan

    def execute_plan(
        self,
        plan: Dict[str, Any],
        helpers: ProviderHelpers,
        log_event=None,
    ) -> Dict[str, Any]:
        def _client_factory(base_url, headers, timeout, verify, transport, shared_helpers):
            return shared_helpers.wheelhouse_client_cls(
                base_url=base_url,
                headers=headers,
                timeout=timeout,
                verify=verify,
                transport=transport,
            )

        return execute_provider_plan(
            expected_provider_key=self.provider_key,
            plan=plan,
            helpers=helpers,
            client_factory=_client_factory,
            log_event=log_event,
        )


__all__ = ["WheelhouseProviderAdapter"]
