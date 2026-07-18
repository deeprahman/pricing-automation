from __future__ import annotations

from typing import Any


def _string_or_none(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text if text else None


def _extract_path_value(payload: Any, path: str) -> Any:
    current = payload
    for segment in path.split("."):
        if isinstance(current, dict):
            if segment not in current:
                return None
            current = current[segment]
            continue
        if isinstance(current, list) and segment.isdigit():
            index = int(segment)
            if index < 0 or index >= len(current):
                return None
            current = current[index]
            continue
        return None
    return current


def _normalize_string_list(values: Any) -> list[str] | None:
    if not isinstance(values, list):
        return None
    normalized: list[str] = []
    seen: set[str] = set()
    for item in values:
        value: Any = item
        if isinstance(item, dict):
            value = (
                item.get("name")
                or item.get("label")
                or item.get("title")
                or item.get("value")
            )
        text = _string_or_none(value)
        if not text or text in seen:
            continue
        seen.add(text)
        normalized.append(text)
    return normalized or None


def extract_listing_amenities(raw: Any) -> list[str] | None:
    if not isinstance(raw, dict):
        return None

    direct_amenities = _normalize_string_list(raw.get("amenities"))
    if direct_amenities:
        return direct_amenities

    amenity_call_outs = _normalize_string_list(raw.get("amenity_call_outs"))
    if amenity_call_outs:
        return amenity_call_outs

    amenity_categories = raw.get("amenity_categories")
    if isinstance(amenity_categories, list):
        flattened: list[str] = []
        seen: set[str] = set()
        for category in amenity_categories:
            if not isinstance(category, dict):
                continue
            names = _normalize_string_list(category.get("amenities")) or []
            for name in names:
                if name in seen:
                    continue
                seen.add(name)
                flattened.append(name)
        if flattened:
            return flattened

    return None


def build_property_details(item: dict[str, Any]) -> dict[str, Any]:
    details: dict[str, Any] = {}
    for key in ("city", "state", "country"):
        value = _string_or_none(item.get(key))
        if value:
            details[key] = value

    raw = item.get("raw")
    if isinstance(raw, dict):
        address_fields = {
            "street": ("address.street1", "address.line1", "location.street1"),
            "street2": ("address.street2", "address.line2", "location.street2"),
            "postal_code": ("address.postal_code", "address.zip", "location.postal_code"),
        }
        for field_name, candidate_paths in address_fields.items():
            if field_name in details:
                continue
            for path in candidate_paths:
                value = _string_or_none(_extract_path_value(raw, path))
                if value:
                    details[field_name] = value
                    break

    return details


def build_listing_metadata(item: dict[str, Any]) -> dict[str, Any]:
    metadata: dict[str, Any] = {}
    raw = item.get("raw")

    name = _string_or_none(item.get("name"))
    if not name and isinstance(raw, dict):
        for path in ("name", "title", "external_name"):
            value = _string_or_none(_extract_path_value(raw, path))
            if value:
                name = value
                break
    if name:
        metadata["name"] = name

    pms = _string_or_none(item.get("pms"))
    if not pms and isinstance(raw, dict):
        pms = _string_or_none(_extract_path_value(raw, "pms"))
    if pms:
        metadata["pms"] = pms

    channel = _string_or_none(item.get("channel"))
    if not channel and isinstance(raw, dict):
        channel = _string_or_none(_extract_path_value(raw, "channel"))
    if channel:
        metadata["channel"] = channel

    for key in ("city", "state", "country", "timezone", "currency_code", "public_url"):
        value = _string_or_none(item.get(key))
        if value:
            metadata[key] = value

    amenities = extract_listing_amenities(raw)
    if amenities:
        metadata["amenities"] = amenities

    if isinstance(raw, dict):
        metadata["raw"] = raw

    return metadata
