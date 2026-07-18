#!/usr/bin/env python3
"""
Generate seed SQL for message processing tables from data/dummy_messages.

Outputs: schemas/seeds/message_processing.seed_data.sql
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import List, Tuple


ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = ROOT / "data" / "dummy_messages"
OUT_FILE = ROOT / "schemas" / "seeds" / "message_processing.seed_data.sql"


def dollar_quote(body: str, tag: str = "MSG") -> str:
    """Return a dollar-quoted literal that does not collide with the body."""
    while f"${tag}$" in body:
        tag += "X"
    return f"${tag}$" + body + f"${tag}$"


def load_threads() -> Tuple[List[tuple], List[tuple]]:
    records = []
    progress_by_thread = {}
    for path in sorted(DATA_DIR.glob("messages-for-booking-*/thread-*.json")):
        data = json.loads(path.read_text())
        thread = int(data["thread"]["id"])
        booking = int(data["thread"]["booking_id"])
        offset = int(data.get("offset") or 0)
        limit = int(data.get("limit") or 20)
        items = sorted(data.get("items", []), key=lambda i: i["date_utc"])

        for item in items:
            records.append(
                (
                    thread,
                    booking,
                    int(item["id"]),
                    item["date_utc"],
                    item["body"],
                )
            )

        if items:
            last = items[-1]
            progress_row = (
                (
                    thread,
                    booking,
                    int(last["id"]),
                    last["date_utc"],
                    offset,
                    limit,
                    offset + len(items),
                )
            )
            existing = progress_by_thread.get(thread)
            if existing is None or progress_row[4] > existing[4]:
                progress_by_thread[thread] = progress_row

    # stable order: thread then mid
    records.sort(key=lambda r: (r[0], r[2]))
    progress = [progress_by_thread[thread] for thread in sorted(progress_by_thread)]
    return records, progress


def main() -> None:
    records, progress = load_threads()
    lines: List[str] = []
    lines.append("-- Seed data for message processing (generated from data/dummy_messages)")
    lines.append("BEGIN;")
    lines.append(
        "TRUNCATE TABLE "
        "message_class_lookup, "
        "message_processing_status, "
        "messages, "
        "message_thread_progress "
        "RESTART IDENTITY CASCADE;"
    )

    for thread, booking, mid, ts, body in records:
        dq = dollar_quote(body)
        lines.append(
            "INSERT INTO messages (platform_id, thread_id, mid, content, message_timestamp, metadata)"
            f" VALUES (1, {thread}, {mid}, {dq}, TIMESTAMPTZ '{ts}', '{{}}'::jsonb)"
            " ON CONFLICT (platform_id, thread_id, mid) DO NOTHING;"
        )

    lines.append("")
    for thread, booking, last_mid, last_ts, offset, limit, total in progress:
        lines.append(
            'INSERT INTO message_thread_progress (platform_id, thread_id, booking_id, last_seen_mid, last_seen_date_utc, "offset", "limit", total)'
            f" VALUES (1, {thread}, {booking}, {last_mid}, TIMESTAMPTZ '{last_ts}', {offset}, {limit}, {total})"
            " ON CONFLICT DO NOTHING;"
        )

    lines.append("COMMIT;")
    OUT_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Wrote {OUT_FILE} with {len(records)} messages and {len(progress)} threads.")


if __name__ == "__main__":
    main()
