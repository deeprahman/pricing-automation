from __future__ import annotations

from typing import Any, Callable, Dict


def resolve_wheelhouse_channel(
    listing_metadata: Dict[str, Any],
    as_optional_string: Callable[[Any], str | None],
) -> str | None:
    channel = as_optional_string(listing_metadata.get("channel"))
    if channel is not None:
        return channel

    raw_listing_metadata = listing_metadata.get("raw")
    if isinstance(raw_listing_metadata, dict):
        return as_optional_string(raw_listing_metadata.get("channel"))
    return None

