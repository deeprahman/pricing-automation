# Dummy Fixture Seed Pack HOWTO

This directory contains the fixture seed pack used by:

- `tests/worker-fixture.sh`
- `tests/worker-fixture.ps1` (wrapper over Bash)

The pack is Linux-first and is designed to mirror production-style booking
metadata enrichment and internal message processing without calling external
providers.

## Seed Files and Purpose

1. `bookings_register_base.sql`
   - Seeds the extension-oriented booking cohort.
   - Booking IDs: `54000001..54000120`
   - Thread IDs: `94000001..94000120`
   - Inserts via `upsert_booking_register(...)` so `stay_length` and
     `booking_window` are computed by production logic.

2. `bookings_register_scanner.sql`
   - Applies extension scanner state matrix (`last_extended`, `needs_scan`).
   - Uses `mark_booking_register_extension_scanned(...)` and
     `mark_booking_register_extension_needs_scan(...)`.

3. `bookings_register_static.sql`
   - Adds static booking cohort for additive scenarios.
   - Booking IDs: `55000001..55000030`
   - Thread IDs: `95100001..95100030`
   - Also inserts via `upsert_booking_register(...)`.

4. `message_processing.seed_data.sql`
   - Simulates ingestion stage only.
   - Inserts messages via `store_message_items(...)`.
   - Upserts thread progress via `set_thread_progress_row(...)`.
   - Does **not** finalize classification.

5. `message_processing_classified.seed_data.sql`
   - Applies deterministic message classes and marks processing as completed.
   - Keeps class distribution aligned with extension-scanner behavior.

## Preset Composition

`tests/worker-fixture.sh` composes the files as:

- `seedScanner`: `base + scanner`
- `seedBookings`: `base + static + scanner`
- `seedMessages`: `base + static + scanner + message_processing`
- `postClassification`: `seedMessages + message_processing_classified + pricing_data_only`

`postClassificationLive` is separate and uses `schemas/seeds/db-live`.

## Manual Usage

From repo root:

```bash
# Base extension cohort + scanner states
bash tests/worker-fixture.sh seed --path schemas/seeds/dummy-messages-seed/bookings_register_base.sql,schemas/seeds/dummy-messages-seed/bookings_register_scanner.sql

# Full post-classification fixture preset
bash tests/worker-fixture.sh postClassification
```

## Quick Verification Queries

```sql
-- Extension cohort count: expect 120
SELECT COUNT(*) FROM booking_registers WHERE id BETWEEN 54000001 AND 54000120;

-- Static cohort count (post seedBookings/seedMessages/postClassification): expect 30
SELECT COUNT(*) FROM booking_registers WHERE id BETWEEN 55000001 AND 55000030;

-- Classified rows present (post postClassification): should be > 0
SELECT COUNT(*) FROM message_class_lookup;

-- Processing completed rows present (post postClassification): should be > 0
SELECT COUNT(*) FROM message_processing_status WHERE status = 'completed';
```
