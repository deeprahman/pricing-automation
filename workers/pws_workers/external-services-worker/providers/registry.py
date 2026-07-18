from __future__ import annotations

from typing import Dict, Optional

from .base import ProviderAdapter
from .ownerrez_provider import OwnerRezProviderAdapter
from .pricelabs_provider import PriceLabsProviderAdapter
from .wheelhouse_provider import WheelhouseProviderAdapter


_ADAPTERS: Dict[str, ProviderAdapter] = {
    "ownerrez": OwnerRezProviderAdapter(),
    "pricelabs": PriceLabsProviderAdapter(),
    "wheelhouse": WheelhouseProviderAdapter(),
}


def get_provider_adapter(provider_key: str) -> Optional[ProviderAdapter]:
    return _ADAPTERS.get(provider_key)


def supported_provider_keys() -> tuple[str, ...]:
    return tuple(sorted(_ADAPTERS.keys()))


__all__ = ["get_provider_adapter", "supported_provider_keys"]
