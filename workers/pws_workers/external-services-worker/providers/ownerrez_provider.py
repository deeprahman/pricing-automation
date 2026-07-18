from __future__ import annotations

import re
from decimal import Decimal
from typing import Any, Dict

from .base import ProviderHelpers, execute_provider_plan


class OwnerRezProviderAdapter:
    provider_key = "ownerrez"

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
        # OwnerRez `property_id` maps to the platform listing identifier in this system
        # (listing_id / platform_property_id), not the internal physical property id.
        property_id_source = (
            instruction.get("platform_property_id")
            or target.get("platform_property_id")
            or instruction.get("listing_id")
            or target.get("listing_id")
        )
        property_id = None
        if property_id_source is not None:
            match = re.search(r"(\d+)$", str(property_id_source))
            if match is not None:
                property_id = match.group(1)
        if property_id is None:
            raise helpers.permanent_error_cls(
                "OwnerRez property_id must come from listing_id/platform_property_id (not internal property_id)",
                error_code="LISTING_BINDING_NOT_FOUND",
            )
        try:
            property_id = int(property_id)
        except (TypeError, ValueError):
            pass

        currency = helpers.resolve_instruction_currency(instruction, listing_metadata)
        if currency is None:
            raise helpers.permanent_error_cls(
                "OwnerRez writes require currency",
                error_code="PROVIDER_CONFIG_MISSING",
            )

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
            resolved_prices = helpers.resolve_execution_prices(instruction, dates=dates)
            plan["baseline_required"] = True
            execution_context = instruction.get("execution_context")
            if isinstance(execution_context, dict):
                plan["baseline_source"] = helpers.as_optional_string(execution_context.get("baseline_source"))
            body = []
            for date_value in dates:
                body.append(
                    {
                        "property_id": property_id,
                        "date": date_value,
                        "currency": currency,
                        "amount": helpers.round_currency(resolved_prices[date_value]),
                    }
                )
            plan["http_calls"] = [
                {
                    "method": "PATCH",
                    "path": endpoint["path"],
                    "transport_path": endpoint["transport_path"],
                    "body": body,
                }
            ]
            return plan

        if instruction_type in {"percentage", "flat"}:
            resolved_prices = helpers.resolve_execution_prices(instruction, dates=dates)
            plan["baseline_required"] = True
            execution_context = instruction.get("execution_context")
            if isinstance(execution_context, dict):
                plan["baseline_source"] = helpers.as_optional_string(execution_context.get("baseline_source"))
        else:
            resolved_prices = {}

        body = []
        for date_value in dates:
            if instruction_type == "fixed":
                new_amount = amount
            else:
                base_amount = resolved_prices[date_value]
                if instruction_type == "percentage":
                    delta = (base_amount * amount) / Decimal("100")
                else:
                    # Compatibility-only path for legacy flat instructions.
                    delta = amount
                new_amount = base_amount + delta if operation == "increase" else base_amount - delta
            body.append(
                {
                    "property_id": property_id,
                    "date": date_value,
                    "currency": currency,
                    "amount": helpers.round_currency(new_amount),
                }
            )
        plan["http_calls"] = [
            {
                "method": "PATCH",
                "path": endpoint["path"],
                "transport_path": endpoint["transport_path"],
                "body": body,
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
            client_kwargs: Dict[str, Any] = {
                "base_url": base_url,
                "headers": headers,
                "timeout": timeout,
                "verify": verify,
                "follow_redirects": False,
            }
            if transport is not None:
                client_kwargs["transport"] = transport
            return shared_helpers.httpx.Client(**client_kwargs)

        return execute_provider_plan(
            expected_provider_key=self.provider_key,
            plan=plan,
            helpers=helpers,
            client_factory=_client_factory,
            log_event=log_event,
        )


__all__ = ["OwnerRezProviderAdapter"]
