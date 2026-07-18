# Bookings Worker How-To

Location: `workers/pws_workers/bookings-worker/bookings_worker.py`

Primary queue: `bookings`

This worker owns booking ingestion into `booking_registers` and booking-driven BSO scan orchestration.

## Supported Actions

- `get_bookings`
- `get_bookings_ret`
- `register_bookings`
- `scan_actives`
- `update_message_threads`
- `bso_start_chain`
- `process_checkout`

Compatibility aliases accepted by the worker:

- `ret_get_bookings` -> `get_bookings_ret`
- `get_boogings_ret` -> `get_bookings_ret`
- `start_bso_chain` -> `bso_start_chain`
- `scan_checkedout` is removed.
- `process_checkout` is canonical; `scan_checked_out` remains a legacy compatibility alias.

## Core Pipelines

Provider fetch pipeline:

```text
bookings-worker:get_bookings
  -> external-services-worker:get_{provider_key}_bookings
  -> bookings-worker:get_bookings_ret
  -> bookings-worker:register_bookings
  -> bookings-worker:get_bookings (next page when needed)
```

Active BSO scan pipeline:

```text
bookings-worker:scan_actives
  -> messages-worker:check_classification
  -> bookings-worker:bso_start_chain
  -> property-platform-worker:get_linked_listings
  -> pricing-engine-worker:get_cat_rule
  -> booking-special-operation-worker:generate_class_rule_insturction
```

Checked-out cleanup pipeline:

```text
bookings-worker:process_checkout
  -> booking-special-operation-worker:remove-bso
```

Message refresh pipeline:

```text
bookings-worker:update_message_threads
  -> messages-worker:fetch
```

## Runtime Variable Scopes Used

- `fetch-bookings-request`
- `fetch-bookings-page`
- `fetch-bookings-rescan`
- `register-bookings-request`
- `check-classification-result`
- Legacy compatibility read: `check-clasification-result`

## Action Notes

### `get_bookings`

Purpose: validate and normalize a provider bookings request, persist request context, and delegate external fetching to `external-services-worker`.

Required fields:

- `provider_key`
- `platform_id` (or configured default `BOOKINGS_OWNERREZ_PLATFORM_ID` for `ownerrez`)

Optional fields:

- `listing_ids` (if omitted/empty, resolved from DB by `platform_id`)
- `from_date` (`YYYY-MM-DD`; defaults to today in `America/New_York`)
- `to_date` (`YYYY-MM-DD`; defaults to `from_date + n_days`)
- `n_days` (defaults to `30`, must be positive)
- `timezone` (defaults to `America/New_York`)
- `offset` (defaults to `0`)
- `limit` (defaults to `30`)
- `provider_query`
- `request_kind`

Example payload:

```json
{
  "action": "get_bookings",
  "provider_key": "ownerrez",
  "listing_ids": ["389550", "389551"],
  "from_date": "2026-04-12",
  "to_date": "2026-05-12",
  "timezone": "America/New_York",
  "offset": 0,
  "limit": 30
}
```

### `get_bookings_ret`

Purpose: read one fetched page from runtime storage, enqueue registration if items exist, and enqueue continuation `get_bookings` when paging indicates more data.

Expected callback shape:

```json
{
  "action": "get_bookings_ret",
  "data_ref": {
    "worker_id": "external-services-worker@...",
    "scope": "fetch-bookings-page",
    "key": "fetch_bookings_page_..."
  }
}
```

Behavior highlights:

- If page has no items: completes with `status = "no_work"`.
- If items exist: enqueues `register_bookings`.
- If provider paging indicates continuation: enqueues next `get_bookings` page.

### `register_bookings`

Purpose: consume provider page items and persist valid bookings into `booking_registers`.

Behavior highlights:

- Excludes non-booking blocks.
- Excludes out-of-focus rows when focus bounds are present.
- Upserts booking rows.
- Detects cancelled bookings and enqueues `booking-special-operation-worker:remove-bso`.

It can read from `data_ref` or from inline `items` payload.

### `scan_actives`

Purpose: scan active booking registers and start the BSO chain for matched rows.

Inputs:

- Optional `platform_id`
- `window_start` and `window_end`, or `window_start` + `n_days`
- Optional `limit` and `cursor_id`

Behavior highlights:

- Filters cancelled rows.
- Requires booking context with thread IDs.
- Enqueues `messages-worker:check_classification` with `return_ref` back to `bso_start_chain`.
- Self-enqueues continuation when scanner page is full.

### `update_message_threads`

Purpose: scan active booking registers and enqueue `messages-worker:fetch` for each associated thread.

Inputs:

- Optional `platform_id`
- `window_start` and `window_end`, or `window_start` + `n_days`
- Optional `limit` and `cursor_id`

Behavior highlights:

- Uses the same active-window scanner and cancellation filtering as `scan_actives`.
- Resolves booking context and thread IDs from `booking_registers`.
- Enqueues one `messages-worker:fetch` task per matched thread.
- Self-enqueues continuation when scanner page is full.

### `bso_start_chain`

Purpose: consume classification callback result and forward categories + canonical pair to property-platform worker.

Expected callback source scope:

- `check-classification-result` (legacy `check-clasification-result` accepted)

Behavior highlights:

- If classes are empty: completes `no_work`.
- If classes exist: enqueues `property-platform-worker:get_linked_listings`.

### `process_checkout`

Purpose: scan checked-out booking registers and enqueue BSO removals.

Inputs:

- Optional `target_date` (defaults to local today)
- Optional `platform_id`
- Optional `limit` and `cursor_id`

Behavior highlights:

- Filters cancelled rows as needed by metadata rules.
- Enqueues `booking-special-operation-worker:remove-bso`.
- Self-enqueues continuation when scanner page is full.

## Local Run

From repo root:

```bash
python workers/pws_workers/bookings-worker/bookings_worker.py --auto-dsn
```

Common options:

- `--dsn <postgres_dsn>`
- `--auto-dsn`
- `--db-name <name>`
- `--log-dir <dir>`
- `--poll-interval <seconds>`

## Enqueue Examples (Task Scheduler Helper Shape)

### Start provider fetch

```json
{
  "worker": "bookings-worker",
  "queue": "bookings",
  "action": "get_bookings",
  "payload": {
    "provider_key": "ownerrez",
    "listing_ids": ["389550"],
    "from_date": "2026-04-12",
    "to_date": "2026-05-12",
    "offset": 0,
    "limit": 30
  }
}
```

### Scan actives

```json
{
  "worker": "bookings-worker",
  "queue": "bookings",
  "action": "scan_actives",
  "payload": {
    "window_start": "2026-04-13",
    "n_days": 30,
    "limit": 100,
    "cursor_id": 0
  }
}
```

### Scan checked-out

```json
{
  "worker": "bookings-worker",
  "queue": "bookings",
  "action": "process_checkout",
  "payload": {
    "target_date": "2026-04-13",
    "limit": 100,
    "cursor_id": 0
  }
}
```

### Update message threads

```json
{
  "worker": "bookings-worker",
  "queue": "bookings",
  "action": "update_message_threads",
  "payload": {
    "window_start": "2026-04-13",
    "n_days": 30,
    "limit": 100,
    "cursor_id": 0
  }
}
```

## Step-by-Step Example (OwnerRez, 7 Bookings, `limit = 2`)

Assume:

- Provider: `ownerrez`
- The date window/listings return exactly 7 booking items total.
- Each fetch page asks for `limit = 2`.
- Provider pages come back as: `2 + 2 + 2 + 1`.

### Step 1. Seed `get_bookings` (page 1 request)

Task payload:

```json
{
  "action": "get_bookings",
  "provider_key": "ownerrez",
  "platform_id": 1,
  "listing_ids": ["389550", "389551"],
  "from_date": "2026-04-12",
  "to_date": "2026-07-11",
  "timezone": "UTC",
  "offset": 0,
  "limit": 2
}
```

What `get_bookings` does:

1. Validates payload (`listing_ids` non-empty, dates valid, `to_date > from_date`, `offset >= 0`, `limit > 0`).
2. Writes normalized request runtime data under `fetch-bookings-request`.
3. Enqueues `external-services-worker:get_ownerrez_bookings` with:
   - `data_ref` to the request runtime key.
   - `return_ref` back to `bookings-worker:get_bookings_ret`.

### Step 2. Provider callback to `get_bookings_ret` (page 1 response: 2 items)

Callback task payload:

```json
{
  "action": "get_bookings_ret",
  "data_ref": {
    "worker_id": "external-services-worker@abc123-1",
    "scope": "fetch-bookings-page",
    "key": "fetch_bookings_page_p1"
  }
}
```

Assumed runtime page payload referenced by that `data_ref` (example):

```json
{
  "provider_key": "ownerrez",
  "platform_id": 1,
  "listing_ids": ["389550", "389551"],
  "timezone": "UTC",
  "provider_query": {
    "from": "2026-04-12",
    "to": "2026-07-11"
  },
  "offset": 0,
  "page_size": 2,
  "items": [{ "booking_id": 1001 }, { "booking_id": 1002 }]
}
```

What `get_bookings_ret` does:

1. Loads page runtime payload via `data_ref`.
2. Sees `item_count = 2` (non-zero), so enqueues `register_bookings` using the same page `data_ref`.
3. Checks continuation: because page is full (`item_count == limit`), it enqueues next `get_bookings` with `offset = 2`, `limit = 2`.

Next-page task payload it enqueues:

```json
{
  "action": "get_bookings",
  "provider_key": "ownerrez",
  "platform_id": 1,
  "listing_ids": ["389550", "389551"],
  "from_date": "2026-04-12",
  "to_date": "2026-07-11",
  "timezone": "UTC",
  "offset": 2,
  "limit": 2
}
```

### Step 3. `register_bookings` for page 1

Task payload:

```json
{
  "action": "register_bookings",
  "data_ref": {
    "worker_id": "external-services-worker@abc123-1",
    "scope": "fetch-bookings-page",
    "key": "fetch_bookings_page_p1"
  }
}
```

What `register_bookings` does:

1. Reads the page data from runtime using `data_ref`.
2. Filters rows:
   - excludes non-booking blocks,
   - excludes out-of-focus rows (if focus dates apply),
   - marks cancelled bookings.
3. Upserts remaining bookings into `booking_registers`.
4. If any are cancelled, enqueues `booking-special-operation-worker:remove-bso` per cancelled booking.
5. Deletes source runtime variable key when done (best effort cleanup).

### Step 4. Page 2 loop (`offset = 2`)

`get_bookings` runs again (same payload shape, now `offset = 2`), then provider returns 2 items.

`get_bookings_ret` repeats:

1. Enqueue `register_bookings` for page 2.
2. Enqueue next `get_bookings` with `offset = 4`.

### Step 5. Page 3 loop (`offset = 4`)

Provider returns 2 more items.

`get_bookings_ret` repeats:

1. Enqueue `register_bookings` for page 3.
2. Enqueue next `get_bookings` with `offset = 6`.

### Step 6. Page 4 loop (`offset = 6`, last page has 1 item)

Provider returns only 1 item.

Example callback page payload shape (simplified):

```json
{
  "provider_key": "ownerrez",
  "platform_id": 1,
  "listing_ids": ["389550", "389551"],
  "provider_query": {
    "from": "2026-04-12",
    "to": "2026-07-11"
  },
  "offset": 6,
  "page_size": 2,
  "items": [{ "booking_id": 1007 }]
}
```

`get_bookings_ret` behavior on final page:

1. Enqueues `register_bookings` (because items exist).
2. Does not enqueue another `get_bookings` (page is not full and no explicit provider continuation signal).

### Final outcome for this 7-booking example

Expected action counts:

- `get_bookings`: 4 tasks (`offset` 0, 2, 4, 6)
- `get_bookings_ret`: 4 callbacks
- `register_bookings`: 4 tasks (one per non-empty page)

Effective booking persistence:

- Up to 7 rows attempted for upsert across the 4 registration tasks.
- Final stored count may be lower if any items are blocks/out-of-focus.
- Cancelled bookings are still upserted with cancellation state and also trigger `remove-bso` enqueue(s).

## Easy Walkthrough: `scan_actives` (7 bookings, `limit = 2`)

### What this action does

`scan_actives` scans active booking rows, filters out rows that should not continue, then enqueues `messages-worker:check_classification` for the remaining rows.

### Input task

```json
{
  "action": "scan_actives",
  "window_start": "2026-04-13",
  "window_end": "2026-05-13",
  "limit": 2,
  "cursor_id": 0
}
```

### Example data (7 rows total, split by pagination)

With `limit = 2`, the worker runs 4 scans: `2 + 2 + 2 + 1`.

```json
{
  "scan_1_cursor_0": [
    { "booking_id": 2001, "platform_id": 1, "metadata": { "status": "confirmed" } },
    { "booking_id": 2002, "platform_id": 1, "metadata": { "status": "cancelled" } }
  ],
  "scan_2_cursor_2002": [
    { "booking_id": 2003, "platform_id": 1, "metadata": { "status": "confirmed" } },
    { "booking_id": 2004, "platform_id": 2, "metadata": { "status": "confirmed" } }
  ],
  "scan_3_cursor_2004": [
    { "booking_id": 2005, "platform_id": 1, "metadata": { "status": "confirmed" } },
    { "booking_id": 2006, "platform_id": 1, "metadata": { "status": "confirmed" } }
  ],
  "scan_4_cursor_2006": [
    { "booking_id": 2007, "platform_id": 1, "metadata": { "status": "confirmed" } }
  ]
}
```

Assumptions for this example:

- `2002` is cancelled, so it is filtered out.
- `2006` has no thread IDs in booking context, so it is filtered out.

### Per-page behavior

Scan 1 (`cursor_id = 0`):

1. Raw rows: `2001`, `2002` (`raw_count = 2`).
2. After filtering: keep `2001` only (`matched_count = 1`).
3. Enqueue one `check_classification` task for `2001`.
4. Full page (`2 == limit`), so enqueue continuation with `cursor_id = 2002`.

Scan 2 (`cursor_id = 2002`):

1. Raw rows: `2003`, `2004`.
2. After filtering: keep both.
3. Enqueue two `check_classification` tasks.
4. Enqueue continuation with `cursor_id = 2004`.

Scan 3 (`cursor_id = 2004`):

1. Raw rows: `2005`, `2006`.
2. After filtering: keep `2005` only (`2006` has no threads).
3. Enqueue one `check_classification` task.
4. Enqueue continuation with `cursor_id = 2006`.

Scan 4 (`cursor_id = 2006`):

1. Raw rows: `2007` (`raw_count = 1`).
2. After filtering: keep `2007`.
3. Enqueue one `check_classification` task.
4. Not a full page, so stop (no continuation).

### Example `check_classification` payload (one row)

```json
{
  "action": "check_classification",
  "platform_id": 1,
  "thread_ids": [9102001, 9102002],
  "return_ref": {
    "worker": "bookings-worker",
    "queue": "bookings",
    "action": "bso_start_chain"
  },
  "booking_context": {
    "booking_id": 2001,
    "booking_entry_id": 2001,
    "external_booking_id": "OR-2001",
    "property_id": 9001,
    "platform_id": 1,
    "ppl_id": 81001,
    "listing_id": "LST-81001",
    "arrival": "2026-04-16",
    "departure": "2026-04-22",
    "booked_at": "2026-03-20T10:30:00+00:00",
    "stay_length": 6,
    "booking_window": 27,
    "classes": ["booking_confirmation"],
    "metadata": {
      "booking_id": "OR-2001",
      "listing_id": "LST-81001",
      "classes": ["booking_confirmation"],
      "stay_extended": true,
      "stay_contracted": false,
      "bso": {
        "potential_extension": {
          "last_extended": "2026-04-10T00:00:00+00:00"
        }
      }
    },
    "canonical_pair": {
      "platform_property_lookup_id": 81001
    }
  }
}
```

### Totals for this 7-row example

- Total scanned rows: `7`
- Filtered out as cancelled: `1` (`2002`)
- Filtered out for missing thread IDs: `1` (`2006`)
- Classification tasks enqueued: `5`

### What happens after `scan_actives`

1. `messages-worker:check_classification` writes classes to runtime (`check-classification-result`).
2. It enqueues `bookings-worker:bso_start_chain` with `data_ref`.
3. `bso_start_chain` forwards non-empty classes to `property-platform-worker:get_linked_listings`.
4. Then pricing and BSO instruction flow continues.

## Easy Walkthrough: `scan_cancelled` (actual action: `process_checkout`, `limit = 2`)

### Important naming note

There is no action named `scan_cancelled` in this worker. The real action is `process_checkout`.

### What this action does

`process_checkout` scans checkout rows and enqueues `booking-special-operation-worker:remove-bso` for each matched row.

Important behavior from current code:

- It applies optional `platform_id` filtering.
- It does not apply cancellation-status filtering here.

### Input task

```json
{
  "action": "process_checkout",
  "target_date": "2026-04-13",
  "limit": 2,
  "cursor_id": 0
}
```

### Example data (7 rows total, split by pagination)

```json
{
  "scan_1_cursor_0": [
    { "booking_id": 3001, "platform_id": 1, "metadata": { "status": "checked_out" } },
    { "booking_id": 3002, "platform_id": 1, "metadata": { "status": "cancelled" } }
  ],
  "scan_2_cursor_3002": [
    { "booking_id": 3003, "platform_id": 1, "metadata": { "status": "checked_out" } },
    { "booking_id": 3004, "platform_id": 2, "metadata": { "status": "checked_out" } }
  ],
  "scan_3_cursor_3004": [
    { "booking_id": 3005, "platform_id": 1, "metadata": { "status": "checked_out" } },
    { "booking_id": 3006, "platform_id": 1, "metadata": { "status": "canceled_by_guest" } }
  ],
  "scan_4_cursor_3006": [
    { "booking_id": 3007, "platform_id": 1, "metadata": { "status": "checked_out" } }
  ]
}
```

No `platform_id` filter is provided in this example, so all 7 rows are matched.

### Per-page behavior

Scan 1 (`cursor_id = 0`):

1. Raw rows: `3001`, `3002`.
2. Matched rows: `3001`, `3002`.
3. Enqueue two `remove-bso` tasks.
4. Full page, enqueue continuation with `cursor_id = 3002`.

Scan 2 (`cursor_id = 3002`):

1. Raw rows: `3003`, `3004`.
2. Matched rows: both.
3. Enqueue two `remove-bso` tasks.
4. Enqueue continuation with `cursor_id = 3004`.

Scan 3 (`cursor_id = 3004`):

1. Raw rows: `3005`, `3006`.
2. Matched rows: both.
3. Enqueue two `remove-bso` tasks.
4. Enqueue continuation with `cursor_id = 3006`.

Scan 4 (`cursor_id = 3006`):

1. Raw rows: `3007`.
2. Matched rows: `3007`.
3. Enqueue one `remove-bso` task.
4. Not a full page, so stop (no continuation).

### Example `remove-bso` payload (from current code)

```json
{
  "action": "remove-bso",
  "booking_id": 3001,
  "reason_code": "checkout",
  "reason_note": "booking checked out on 2026-04-13"
}
```

### Totals for this 7-row example

- Total scanned rows: `7`
- Total matched rows: `7`
- Total `remove-bso` tasks enqueued: `7`

If you pass `platform_id`, matched rows and removal task count are reduced to that platform only.

## Operational Notes

- This worker is action-state/checkpoint based; retries resume safely from checkpoints.
- Pagination is task-driven, not a single long-running loop.
- Provider HTTP calls are delegated to `external-services-worker`.
- Runtime-variable TTL resolution follows manifest + runtime config precedence.
