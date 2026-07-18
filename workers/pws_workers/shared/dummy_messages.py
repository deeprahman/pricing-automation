from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


class DummyMessages:
    """Lightweight accessor for paginated dummy message threads."""

    PAGE_SIZE = 6

    def __init__(self, base_dir: Path | str = "data/dummy_messages") -> None:
        self.base_dir = Path(base_dir)

    def _load_pages(self, thread_id: str) -> List[Tuple[int, int, Dict[str, Any]]]:
        pattern = f"**/thread-{thread_id}*.json"
        pages: List[Tuple[int, int, Dict[str, Any]]] = []
        for path in sorted(self.base_dir.glob(pattern)):
            with path.open("r", encoding="utf-8") as fh:
                data = json.load(fh)
            offset = int(data.get("offset", 0))
            limit = int(data.get("limit", len(data.get("items", []))))
            pages.append((offset, limit, data))
        return pages

    def get(
        self,
        thread_id: int | str,
        offset: Optional[int] = None,
        limit: Optional[int] = None,
    ) -> Dict[str, Any]:
        """
        Return a thread page exactly as stored on disk.

        Rules:
        - Default: ``thread-{thread_id}.json`` (offset 0).
        - Paged: ``thread-{thread_id}-{offset}-{limit}.json``.
        - For offset-only requests, any page whose offset matches is acceptable.
        - If the requested page is absent, raise ``FileNotFoundError``.
        """

        tid = str(thread_id)
        pages = self._load_pages(tid)
        if not pages:
            raise FileNotFoundError(f"No thread files found for thread_id {tid}")

        pages.sort(key=lambda page: page[0])

        desired_offset = 0 if offset is None else int(offset)
        desired_limit = None if limit is None else int(limit)

        for page_offset, page_limit, data in pages:
            if page_offset == desired_offset and desired_limit is not None and page_limit == desired_limit:
                return data

        if desired_limit is not None:
            for page_offset, page_limit, data in pages:
                if page_offset == desired_offset and page_limit < desired_limit and page_limit < self.PAGE_SIZE:
                    return data

        if desired_limit is None:
            for page_offset, _page_limit, data in pages:
                if page_offset == desired_offset:
                    return data

        raise FileNotFoundError(
            f"No page found for thread_id {tid} with offset={desired_offset} and limit={desired_limit}"
        )


Dummy_Messages = DummyMessages

__all__ = ["DummyMessages", "Dummy_Messages"]
