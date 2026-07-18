#!/usr/bin/env python3
"""
Fetch dummy message threads by ID, paginate, and optionally record progress.

Usage:
  python scripts/fetch_dummy_thread.py --thread-id 91000002 --page 0 --page-size 20 --auto-dsn
  python scripts/fetch_dummy_thread.py --thread-id 91000001 --page 0 --no-db          # dry run only

- When --auto-dsn is used, values are pulled from environment or .env in the repo root.
- Maps thread_id -> booking_id from data/dummy_messages/thread-category-summary.md
- Locates the corresponding JSON file under data/dummy_messages/messages-for-booking-*/thread-*.json
- Paginates items (zero-based page) and prints the slice plus a JSON payload
- Upserts offset/limit/total progress into message_thread_progress after each fetch (unless --no-db)
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Dict, List, Optional, Any

import psycopg  # type: ignore


ROOT = Path(__file__).resolve().parents[1]
SUMMARY_PATH = ROOT / "data" / "dummy_messages" / "thread-category-summary.md"
DATA_DIR = ROOT / "data" / "dummy_messages"


def build_dsn(cli_dsn: Optional[str], auto: bool, db_name: Optional[str]) -> str:
    """Build a Postgres DSN from CLI or environment variables."""
    if cli_dsn:
        return cli_dsn
    if not auto:
        raise SystemExit("DSN is required (use --dsn or --auto-dsn).")

    password = os.getenv("POSTGRES_PASSWORD")
    if not password:
        raise SystemExit("POSTGRES_PASSWORD is required for --auto-dsn.")

    host = os.getenv("POSTGRES_HOST", "127.0.0.1")
    port = os.getenv("POSTGRES_HOST_PORT") or os.getenv("POSTGRES_PORT") or "5432"
    user = os.getenv("POSTGRES_USER", "n8n")
    dbname = db_name or os.getenv("SCHEMA_DB") or os.getenv("POSTGRES_DB") or "auto_pws"

    return f"host={host} port={port} dbname={dbname} user={user} password={password}"


def load_env_file(path: Path) -> None:
    """
    Best-effort load of KEY=VALUE pairs from a .env file into os.environ
    without overriding variables already set in the process.
    """
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, val = line.split("=", 1)
        key = key.strip()
        val = val.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = val


def load_thread_map(summary_path: Path) -> Dict[int, int]:
    """Parse the Markdown table mapping booking_id -> thread_id."""
    mapping: Dict[int, int] = {}
    if not summary_path.exists():
        raise SystemExit(f"Summary file not found: {summary_path}")

    with summary_path.open("r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or line.startswith("---"):
                continue
            if line.lower().startswith("booking id"):
                continue
            if "|" not in line:
                continue
            parts = [p.strip() for p in line.split("|")]
            if len(parts) < 3:
                continue
            try:
                booking_id = int(parts[0])
                thread_id = int(parts[1])
            except ValueError:
                continue
            mapping[thread_id] = booking_id
    if not mapping:
        raise SystemExit("No thread mappings found in summary file.")
    return mapping


def thread_json_path(booking_id: int, thread_id: int) -> Path:
    return DATA_DIR / f"messages-for-booking-{booking_id}" / f"thread-{thread_id}.json"


def load_thread_data(path: Path) -> Dict[str, Any]:
    if not path.exists():
        raise SystemExit(f"Thread file not found: {path}")
    with path.open("r", encoding="utf-8") as fh:
        data = json.load(fh)
    if "items" not in data:
        raise SystemExit(f"Thread file missing 'items': {path}")
    return data


def effective_page_size(requested: int, json_limit: Optional[Any]) -> int:
    try:
        limit_int = int(json_limit) if json_limit is not None else None
    except (TypeError, ValueError):
        limit_int = None
    return min(requested, limit_int) if limit_int else requested


def paginate(items: List[Dict[str, Any]], page: int, page_size: int) -> List[Dict[str, Any]]:
    start = page * page_size
    end = start + page_size
    return items[start:end]


def upsert_progress(
    conn,
    *,
    platform_id: int,
    thread_id: int,
    booking_id: int,
    page: int,
    page_size: int,
    total: int,
    last_seen_mid: Optional[int],
    last_seen_date_utc: Optional[str],
) -> None:
    sql = """
    INSERT INTO message_thread_progress (
        platform_id, thread_id, booking_id, last_seen_mid, last_seen_date_utc, "offset", "limit", total
    )
    VALUES (%(platform_id)s, %(thread_id)s, %(booking_id)s, %(last_seen_mid)s, %(last_seen_date_utc)s, %(offset)s, %(limit)s, %(total)s)
    ON CONFLICT (platform_id, thread_id) DO UPDATE
    SET booking_id = EXCLUDED.booking_id,
        last_seen_mid = EXCLUDED.last_seen_mid,
        last_seen_date_utc = EXCLUDED.last_seen_date_utc,
        "offset" = EXCLUDED."offset",
        "limit" = EXCLUDED."limit",
        total = EXCLUDED.total;
    """
    offset = page * page_size
    with conn.cursor() as cur:
        cur.execute(
            sql,
            {
                "platform_id": platform_id,
                "thread_id": thread_id,
                "booking_id": booking_id,
                "last_seen_mid": last_seen_mid,
                "last_seen_date_utc": last_seen_date_utc,
                "offset": offset,
                "limit": page_size,
                "total": total,
            },
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Fetch dummy message thread by ID and track pagination progress.")
    parser.add_argument("--thread-id", type=int, required=True, help="Thread ID to fetch (e.g., 91000002)")
    parser.add_argument("--platform-id", type=int, default=1, help="Platform ID (default: 1)")
    parser.add_argument("--page", type=int, default=0, help="Zero-based page number to fetch (default: 0)")
    parser.add_argument("--page-size", type=int, default=20, help="Page size (default: 20)")
    parser.add_argument("--dsn", default=None, help="Postgres DSN")
    parser.add_argument("--auto-dsn", action="store_true", help="Build DSN from environment variables")
    parser.add_argument("--db-name", default=None, help="Override database name when using --auto-dsn")
    parser.add_argument("--update-empty", action="store_true", help="Update DB even when the page is empty")
    parser.add_argument("--update-db", dest="update_db", action="store_true", help="Write pagination progress to DB (default)")
    parser.add_argument("--no-db", dest="update_db", action="store_false", help="Skip DB writes")
    parser.set_defaults(update_db=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    # If auto-dsn is requested, preload .env to hydrate POSTGRES_* values when missing.
    if args.auto_dsn:
        load_env_file(ROOT / ".env")

    thread_map = load_thread_map(SUMMARY_PATH)
    booking_id = thread_map.get(args.thread_id)
    if booking_id is None:
        raise SystemExit(f"Thread ID {args.thread_id} not found in summary.")

    json_path = thread_json_path(booking_id, args.thread_id)
    data = load_thread_data(json_path)

    page_size = effective_page_size(args.page_size, data.get("limit"))
    items: List[Dict[str, Any]] = data.get("items", [])
    page_items = paginate(items, args.page, page_size)
    source_total = len(items)
    offset = args.page * page_size
    fetched_total = offset + len(page_items)

    last_seen_mid = page_items[-1]["id"] if page_items else None
    last_seen_date_utc = page_items[-1]["date_utc"] if page_items else None

    print(f"Thread file: {json_path}")
    print(f"Booking ID: {booking_id} | Thread ID: {args.thread_id} | Platform ID: {args.platform_id}")
    print(
        f"Total items: {source_total} | Page: {args.page} | Offset: {offset} | "
        f"Limit: {page_size} | Returned: {len(page_items)} | Fetched total: {fetched_total}"
    )
    if page_items:
        print(f"Last seen mid: {last_seen_mid} @ {last_seen_date_utc}")
    else:
        print("Page is empty.")

    payload = {
        "thread": data.get("thread", {}),
        "booking_id": booking_id,
        "thread_id": args.thread_id,
        "platform_id": args.platform_id,
        "page": args.page,
        "offset": offset,
        "limit": page_size,
        "items": page_items,
        "returned": len(page_items),
        "total": fetched_total,
        "source_total": source_total,
    }
    print(json.dumps(payload, indent=2, default=str))

    if args.update_db:
        if not page_items and not args.update_empty:
            print("DB update skipped (empty page and --update-empty not set).")
        else:
            dsn = build_dsn(args.dsn, args.auto_dsn, args.db_name)
            conn = psycopg.connect(dsn, autocommit=True)
            upsert_progress(
                conn,
                platform_id=args.platform_id,
                thread_id=args.thread_id,
                booking_id=booking_id,
                page=args.page,
                page_size=page_size,
                total=fetched_total,
                last_seen_mid=last_seen_mid,
                last_seen_date_utc=last_seen_date_utc,
            )
            conn.close()
            print("DB progress upserted.")


if __name__ == "__main__":
    main()
