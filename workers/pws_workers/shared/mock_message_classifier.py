"""Local mock of the OpenAI-backed MessageClassifier."""

from __future__ import annotations

import csv
import json
import os
from pathlib import Path
from typing import Dict, Tuple

try:
    import psycopg  # type: ignore
except Exception as exc:  # pragma: no cover - handled at runtime
    psycopg = None
    _psycopg_import_error = exc
else:
    _psycopg_import_error = None


ROOT = Path(__file__).resolve().parents[3]
DEFAULT_CSV_PATH = ROOT / "data" / "dummy_messages" / "thread-category-summary.csv"
CATEGORY_PRIORITY = ["Check-out", "Medical", "Job", "Insurance"]


def _build_dsn_from_env() -> str:
    host = os.getenv("POSTGRES_HOST", "localhost")
    port = os.getenv("POSTGRES_PORT", os.getenv("POSTGRES_HOST_PORT", "5432"))
    dbname = os.getenv("POSTGRES_DB") or os.getenv("POSTGRES_DATABASE") or os.getenv("SCHEMA_DB") or "auto_pws"
    user = os.getenv("POSTGRES_USER", "postgres")
    password = os.getenv("POSTGRES_PASSWORD", "")

    parts = [f"host={host}", f"port={port}", f"dbname={dbname}", f"user={user}"]
    if password:
        parts.append(f"password={password}")
    return " ".join(parts)


def _load_category_map(csv_path: Path) -> Dict[Tuple[int, int], str]:
    if not csv_path.exists():
        raise RuntimeError(f"Category CSV not found at {csv_path}")

    mapping: Dict[Tuple[int, int], str] = {}
    with csv_path.open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            thread_str = (row.get("Thread ID") or "").strip()
            mid_str = (row.get("Message ID") or "").strip()
            if not thread_str or not mid_str or mid_str == "-":
                continue
            try:
                thread_id = int(thread_str)
                mid = int(mid_str)
            except ValueError:
                continue

            category = "uncategorized"
            for column in CATEGORY_PRIORITY:
                value = (row.get(column) or "").strip().lower()
                if value == "yes":
                    category = column.lower()
                    break
            mapping[(thread_id, mid)] = category
    return mapping


class MockMessageClassifier:
    """Drop-in replacement for MessageClassifier that reads from DB + CSV."""

    def __init__(self, dsn: str | None = None, csv_path: Path | None = None) -> None:
        if psycopg is None:
            raise RuntimeError(
                "psycopg is required for MockMessageClassifier; install psycopg[binary] or psycopg2."
            ) from _psycopg_import_error

        self.dsn = dsn or _build_dsn_from_env()
        self.csv_path = Path(csv_path) if csv_path else DEFAULT_CSV_PATH
        self._category_map = _load_category_map(self.csv_path)

    def _connect(self):
        return psycopg.connect(self.dsn)

    def _fetch_thread_mid(self, pk: int) -> Tuple[int, int]:
        query = "SELECT thread_id, mid FROM messages WHERE id = %s AND deleted_at IS NULL"
        with self._connect() as conn:
            with conn.cursor() as cur:
                cur.execute(query, (pk,))
                row = cur.fetchone()
        if not row:
            raise LookupError(f"Message pk {pk} not found")
        thread_id, mid = row
        return int(thread_id), int(mid)

    def _resolve_category(self, thread_id: int, mid: int) -> str:
        return self._category_map.get((thread_id, mid), "uncategorized")

    def classify(self, pk: int, message_body: str) -> str:
        thread_id, mid = self._fetch_thread_mid(int(pk))
        category = self._resolve_category(thread_id, mid)
        return json.dumps({"pk": int(pk), "category": category})

    def classify_messages(self, messages: list[dict]) -> list[str]:
        results: list[str] = []
        for msg in messages:
            pk = int(msg["pk"])
            body = str(msg.get("body", ""))
            _ = body
            results.append(self.classify(pk, body))
        return results


__all__ = ["MockMessageClassifier"]
