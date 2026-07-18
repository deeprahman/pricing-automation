-- ============================================
-- SCANNERS FOR booking_registers
-- Version: 1.0
-- Run AFTER: booking_registers.sql
-- ============================================
--
-- PERFORMANCE ANALYSIS vs OLD SCANNERS
-- ─────────────────────────────────────────────────────────────────────────────
--
-- OLD ARCHITECTURE (bookings + bookings_metadata)
-- ───────────────────────────────────────────────
-- Both scanners did:
--
--   FROM bookings b
--   LEFT JOIN bookings_metadata bm ON bm.booking_entry_id = b.id
--   WHERE b.id > p_cursor_id
--     AND <date filter>
--     AND NOT (<metadata exclusion from bm.metadata>)
--
-- Cost drivers:
--   1. JOIN cost       — for every row in the date window, Postgres looks up
--                        bookings_metadata by booking_entry_id. Even with an
--                        index on booking_entry_id this is a separate random
--                        I/O per row, or a hash join that materialises the
--                        entire bookings_metadata table into memory.
--   2. LEFT JOIN risk  — if a booking has no metadata row, bm.metadata is NULL.
--                        The exclusion filter (`bm.metadata IS NOT NULL AND ...`)
--                        had to guard against that explicitly, adding a branch
--                        per row.
--   3. Two-table cache pressure — hot pages from both tables must fit in
--                        shared_buffers simultaneously. Large metadata tables
--                        evict booking pages and vice versa.
--
-- NEW ARCHITECTURE (booking_registers — single table, metadata inline)
-- ────────────────────────────────────────────────────────────────────
-- Both scanners now query ONE table. The metadata column lives in the same
-- heap page as the booking row, so:
--   • Zero JOIN — no extra lookup, no hash build, no merge
--   • One heap fetch per row satisfies all projected columns
--   • The exclusion filter reads metadata directly from the already-fetched
--     tuple; no second I/O
--
-- ─────────────────────────────────────────────────────────────────────────────
-- INDEX COVERAGE ANALYSIS
-- ─────────────────────────────────────────────────────────────────────────────
--
-- CHECKOUT SCANNER
-- ────────────────
-- Query shape:
--   WHERE id > :cursor AND departure = :target_date
--   ORDER BY id ASC LIMIT n
--
-- Existing index  idx_booking_registers_scanner  (arrival, departure, id)
--   PROBLEM: arrival is the leading column. For a departure-only equality
--   filter Postgres cannot use this index efficiently — it would need to
--   scan across all arrival values to find matching departure dates.
--   Result: likely full index scan or seq scan, negating pagination gains.
--
-- Fix (added below):
--   idx_booking_registers_checkout_scanner  (departure, id)
--   Postgres can seek directly to the departure page, then walk id forward
--   from the cursor. This gives an Index Scan (not just Index Only Scan
--   because heap is needed for projected columns) with near-zero startup cost.
--
-- EXTENSION SCANNER
-- ─────────────────
-- Query shape:
--   WHERE id > :cursor
--     AND (
--         arrival  BETWEEN :window_start AND :window_end
--      OR (departure - INTERVAL '1 day')::DATE BETWEEN :window_start AND :window_end
--     )
--     AND NOT (last_extended IS NOT NULL AND updated_at < last_extended)
--   ORDER BY id ASC LIMIT n
--
-- The OR across two different columns prevents a single B-tree index from
-- satisfying the date filter in one pass. Postgres handles this with a
-- BitmapOr plan:
--
--   BitmapOr
--     Bitmap Index Scan on idx_booking_registers_arrival   ← arrival range
--     Bitmap Index Scan on idx_booking_registers_scanner   ← arrival,departure,id
--                          (used for departure side via index condition recheck)
--
-- In practice Postgres will choose one of two approaches depending on
-- selectivity:
--   a) BitmapOr of two index scans — best when the window is narrow
--   b) Seq scan — if the window covers a large fraction of the table
--
-- The expression index  idx_booking_registers_meta_last_extended
--   ((metadata #>> '{bso,potential_extension,last_extended}'))
-- is NOT directly usable for the NOT (...updated_at < last_extended...) filter
-- because it involves a cross-column comparison (updated_at vs extracted text).
-- It remains useful for other queries but for the exclusion inside the scanner
-- Postgres evaluates it as a filter on heap tuples already fetched by the
-- date index. This is acceptable: the exclusion is cheap (one JSONB path
-- extraction + timestamp cast per row, already in memory).
--
-- ─────────────────────────────────────────────────────────────────────────────
-- SUMMARY TABLE
-- ─────────────────────────────────────────────────────────────────────────────
--
--  Dimension                  Old (two tables)          New (booking_registers)
--  ─────────────────────────  ────────────────────────  ───────────────────────
--  Heap reads per row         2 (bookings + metadata)   1
--  JOIN overhead              Hash or nested-loop join  None
--  NULL guard needed          Yes (LEFT JOIN)           No (DEFAULT '{}'::JSONB)
--  Checkout index quality     (departure, id) ✓         Needs new index (added)
--  Extension date index       (arrival,departure,id)    Same — BitmapOr plan
--  Metadata exclusion filter  Cross-table, guarded      Inline, no guard needed
--  Cache pressure             2 table heaps             1 table heap
--
-- ─────────────────────────────────────────────────────────────────────────────


-- ============================================
-- 1) Dependency validation
-- ============================================
DO $$
BEGIN
    IF to_regclass('public.booking_registers') IS NULL THEN
        RAISE EXCEPTION
            'Missing table: booking_registers. Run booking_registers.sql first.';
    END IF;
END $$;


-- ============================================
-- 2) Missing index for checkout scanner
--    (departure, id) — lets Postgres seek to an exact departure date and
--    then walk ids forward from the cursor without touching arrival at all.
-- ============================================
CREATE INDEX IF NOT EXISTS idx_booking_registers_checkout_scanner
    ON booking_registers (departure, id);


-- ============================================
-- 3) Checkout scanner
--    Returns bookings whose departure equals p_target_date.
--    Excludes rows already marked as cancelled in BSO metadata:
--      metadata.bso.cancellation.cancelled = true
--    Cursor-based pagination on id — call repeatedly until 0 rows returned.
--
--    Plan: Index Scan on idx_booking_registers_checkout_scanner
--          → seek to (departure = p_target_date, id > p_cursor_id)
--          → walk forward, LIMIT stops early
--          No JOIN, no subquery, no metadata guard needed.
-- ============================================
CREATE OR REPLACE FUNCTION scan_booking_registers_for_checkout(
    p_target_date   DATE,
    p_limit         INT,
    p_cursor_id     BIGINT
)
RETURNS TABLE (
    booking_id      BIGINT,
    arrival         DATE,
    departure       DATE,
    property_id     INT,
    platform_id     INT,
    guest_id        BIGINT,
    updated_at      TIMESTAMPTZ,
    metadata        JSONB
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        br.id           AS booking_id,
        br.arrival,
        br.departure,
        br.property_id,
        br.platform_id,
        br.guest_id,
        br.updated_at,
        br.metadata
    FROM booking_registers br
    WHERE
        br.id > p_cursor_id
        AND br.departure = p_target_date
        AND COALESCE((br.metadata #>> '{bso,cancellation,cancelled}')::boolean, false) = false
    ORDER BY br.id ASC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;


-- ============================================
-- 4) Extension scanner
--    Returns bookings whose stay dates overlap the scan window, excluding
--    bookings where updated_at predates last_extended (nothing to re-process).
--    Cursor-based pagination on id — call repeatedly until 0 rows returned.
--
--    Plan: BitmapOr of two index scans
--            Bitmap Index Scan on idx_booking_registers_arrival
--              (arrival BETWEEN window_start AND window_end)
--            Bitmap Index Scan on idx_booking_registers_departure
--              ((departure - 1) BETWEEN window_start AND window_end,
--               evaluated as departure BETWEEN window_start+1 AND window_end+1)
--          → Bitmap Heap Scan, recheck, then apply exclusion filter inline
--          No JOIN. metadata read from the same heap page already fetched.
--
--    NOTE on the exclusion filter:
--      Old code:  bm.metadata IS NOT NULL AND (bm.metadata #>> ...) IS NOT NULL AND ...
--      New code:  metadata DEFAULT '{}' so IS NOT NULL guard is gone.
--                 The path extraction is the only condition needed.
-- ============================================
CREATE OR REPLACE FUNCTION scan_booking_registers_for_extension(
    p_window_start  DATE,
    p_window_end    DATE,
    p_limit         INT,
    p_cursor_id     BIGINT
)
RETURNS TABLE (
    booking_id      BIGINT,
    arrival         DATE,
    departure       DATE,
    property_id     INT,
    platform_id     INT,
    guest_id        BIGINT,
    updated_at      TIMESTAMPTZ,
    metadata        JSONB
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        br.id           AS booking_id,
        br.arrival,
        br.departure,
        br.property_id,
        br.platform_id,
        br.guest_id,
        br.updated_at,
        br.metadata
    FROM booking_registers br
    WHERE
        -- Keyset pagination: continue from last processed id
        br.id > p_cursor_id

        -- Window filter: arrival in window OR last night of stay in window
        AND (
            br.arrival BETWEEN p_window_start AND p_window_end
            OR (br.departure - INTERVAL '1 day')::DATE
                   BETWEEN p_window_start AND p_window_end
        )

        -- Exclusion: skip if booking is unchanged since last extension op.
        -- metadata is always a non-null '{}' object — no IS NOT NULL guard needed.
        -- Reads from the heap page already fetched by the date index scan.
        AND NOT (
            (br.metadata #>> '{bso,potential_extension,last_extended}') IS NOT NULL
            -- Original condition kept for reference:
            -- AND br.updated_at < (
            --     br.metadata #>> '{bso,potential_extension,last_extended}'
            -- )::TIMESTAMPTZ
            AND br.updated_at <= (
                br.metadata #>> '{bso,potential_extension,last_extended}'
            )::TIMESTAMPTZ
        )

    ORDER BY br.id ASC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;
