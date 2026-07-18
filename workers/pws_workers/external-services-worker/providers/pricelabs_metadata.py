from __future__ import annotations

from typing import Any, Callable, Dict


def resolve_pricelabs_pms(
    listing_metadata: Dict[str, Any],
    as_optional_string: Callable[[Any], str | None],
) -> str | None:
    pms = as_optional_string(listing_metadata.get("pms"))
    if pms is not None:
        return pms

    raw_listing_metadata = listing_metadata.get("raw")
    if isinstance(raw_listing_metadata, dict):
        return as_optional_string(raw_listing_metadata.get("pms"))
    return None
