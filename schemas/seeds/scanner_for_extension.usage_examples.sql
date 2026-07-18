-- ============================================================================
-- BOOKING SCANNER 1 — USAGE EXAMPLES
-- ============================================================================
-- Run AFTER:
--   1) schemas/scanner_for_extension.sql
--   2) schemas/seeds/scanner_for_extension.seed_data.sql
-- Purpose:
--   - Example scanner calls and QA/debugging queries
-- ============================================================================

-- ============================================
-- 3. USAGE EXAMPLES
-- ============================================

-- --------------------------------------------
-- EXAMPLE A: Single call — first page
-- Fetch up to 500 bookings in the window, starting from the beginning
-- Expected results: B1, B2, B3, B7, B8 (5 bookings)
-- Expected excluded: B4 (outside window), B5 (unchanged since BSO), B6 (outside window)
-- --------------------------------------------

SELECT *
FROM scan_bookings_for_extension(
    '2026-02-23',   -- p_window_start
    '2026-02-25',   -- p_window_end
    500,            -- p_limit
    0               -- p_cursor_id: 0 = start from beginning
);


-- --------------------------------------------
-- EXAMPLE B: Keyset pagination — page 2
-- Simulate: page 1 returned bookings up to id = 1003
-- Page 2 continues from id > 1003
-- Expected: B7 (1007), B8 (1008)
-- --------------------------------------------

SELECT *
FROM scan_bookings_for_extension(
    '2026-02-23',
    '2026-02-25',
    500,
    1003            -- p_cursor_id: last id from page 1
);


-- --------------------------------------------
-- EXAMPLE C: Small batch size (simulate n8n loop with limit=2)
-- Mimics how n8n iterates: fetch 2, advance cursor, repeat
-- --------------------------------------------

-- Iteration 1: cursor=0 → returns B1(1001), B2(1002)
SELECT * FROM scan_bookings_for_extension('2026-02-23', '2026-02-25', 2, 0);

-- Iteration 2: cursor=1002 → returns B3(1003), B7(1007)
SELECT * FROM scan_bookings_for_extension('2026-02-23', '2026-02-25', 2, 1002);

-- Iteration 3: cursor=1007 → returns B8(1008)
SELECT * FROM scan_bookings_for_extension('2026-02-23', '2026-02-25', 2, 1007);

-- Iteration 4: cursor=1008 → returns 0 rows → n8n loop stops
SELECT * FROM scan_bookings_for_extension('2026-02-23', '2026-02-25', 2, 1008);


-- --------------------------------------------
-- EXAMPLE D: Verify exclusion — inspect B5 directly
-- Confirm B5 is excluded because updated_at < last_extended
-- --------------------------------------------

SELECT
    b.id,
    b.arrival,
    b.departure,
    b.updated_at,
    bm.metadata #>> '{bso,potential_extension,last_extended}' AS last_extended,
    CASE
        WHEN b.updated_at < (bm.metadata #>> '{bso,potential_extension,last_extended}')::TIMESTAMPTZ
        THEN 'EXCLUDED — no change since last BSO'
        ELSE 'INCLUDED'
    END AS scanner_decision
FROM bookings b
LEFT JOIN bookings_metadata bm ON bm.booking_entry_id = b.id
WHERE b.id = 1005;


-- --------------------------------------------
-- EXAMPLE E: Simulate a departure date change on B5
-- After update, updated_at bumps via trigger → B5 becomes eligible again
-- --------------------------------------------

UPDATE bookings
SET departure = '2026-03-05'   -- departure changed
WHERE id = 1005;

-- Now re-run scanner — B5 should appear (updated_at is now > last_extended)
SELECT *
FROM scan_bookings_for_extension('2026-02-23', '2026-02-25', 500, 0)
WHERE booking_id = 1005;


-- --------------------------------------------
-- EXAMPLE F: Full result summary with decision column (debugging / QA)
-- Shows all bookings in window with include/exclude reason
-- --------------------------------------------

SELECT
    b.id                                                                AS booking_id,
    b.arrival,
    b.departure,
    b.updated_at,
    bm.metadata #>> '{bso,potential_extension,last_extended}'          AS last_extended,
    CASE
        -- Outside window
        WHEN NOT (
            b.arrival BETWEEN '2026-02-23' AND '2026-02-25'
            OR (b.departure - INTERVAL '1 day')::DATE BETWEEN '2026-02-23' AND '2026-02-25'
        ) THEN 'EXCLUDED — outside window'
        -- Unchanged since last BSO
        WHEN bm.metadata IS NOT NULL
         AND (bm.metadata #>> '{bso,potential_extension,last_extended}') IS NOT NULL
         AND b.updated_at < (bm.metadata #>> '{bso,potential_extension,last_extended}')::TIMESTAMPTZ
        THEN 'EXCLUDED — unchanged since last BSO'
        ELSE 'INCLUDED'
    END                                                                 AS scanner_decision
FROM bookings b
LEFT JOIN bookings_metadata bm ON bm.booking_entry_id = b.id
WHERE b.id BETWEEN 1001 AND 1008
ORDER BY b.id;
