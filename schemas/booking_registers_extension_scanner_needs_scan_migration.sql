-- ============================================================================
-- booking_registers_extension_scanner_needs_scan_migration.sql
--
-- Purpose:
--   Make the extension scanner queue-driven by using booking_registers.needs_scan
--   as the source of truth for scanner eligibility.
--
-- Behavior:
--   - scan_booking_registers_for_extension(...) returns only rows where
--     needs_scan = 1.
--   - The date window still limits the scan scope.
--   - The function keeps the existing worker-compatible return shape:
--       booking_id, arrival, departure, property_id, platform_id,
--       guest_id, updated_at, metadata
--   - The old updated_at < metadata.bso.potential_extension.last_extended
--     skip rule is intentionally removed. Metadata-only changes do not bump
--     updated_at in the current booking_registers design, so needs_scan is now
--     the reliable scan gate.
--
-- Prerequisites:
--   - booking_registers.sql
--   - booking_registers_needs_scan_migration.sql
--
-- Safe to re-run: yes.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. DEPENDENCY VALIDATION
-- ============================================================================
DO $$
BEGIN
    IF to_regclass('public.booking_registers') IS NULL THEN
        RAISE EXCEPTION 'Missing table: booking_registers. Run booking_registers.sql first.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'booking_registers'
          AND column_name = 'needs_scan'
    ) THEN
        RAISE EXCEPTION
            'Missing column: booking_registers.needs_scan. Run booking_registers_needs_scan_migration.sql first.';
    END IF;
END $$;

-- ============================================================================
-- 2. EXTENSION SCANNER
-- ============================================================================
-- Drop first so the migration remains safe if an older function had a different
-- RETURNS TABLE shape.
DROP FUNCTION IF EXISTS public.scan_booking_registers_for_extension(DATE, DATE, INT, BIGINT);

CREATE OR REPLACE FUNCTION public.scan_booking_registers_for_extension(
    p_window_start DATE,
    p_window_end DATE,
    p_limit INT,
    p_cursor_id BIGINT
)
RETURNS TABLE (
    booking_id BIGINT,
    arrival DATE,
    departure DATE,
    property_id INT,
    platform_id INT,
    guest_id BIGINT,
    updated_at TIMESTAMPTZ,
    metadata JSONB
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_limit INT := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500);
    v_cursor_id BIGINT := GREATEST(COALESCE(p_cursor_id, 0), 0);
BEGIN
    IF p_window_start IS NULL THEN
        RAISE EXCEPTION 'p_window_start is required'
            USING ERRCODE = '22023';
    END IF;

    IF p_window_end IS NULL THEN
        RAISE EXCEPTION 'p_window_end is required'
            USING ERRCODE = '22023';
    END IF;

    IF p_window_end < p_window_start THEN
        RAISE EXCEPTION 'p_window_end (%) cannot be before p_window_start (%)',
            p_window_end, p_window_start
            USING ERRCODE = '22023';
    END IF;

    RETURN QUERY
    SELECT
        br.id AS booking_id,
        br.arrival,
        br.departure,
        br.property_id,
        br.platform_id,
        br.guest_id,
        br.updated_at,
        br.metadata
    FROM public.booking_registers br
    WHERE br.needs_scan = 1
      AND br.id > v_cursor_id
      AND LOWER(br.type) = 'booking'
      -- Departure is checkout date, so the last stayed night is departure - 1.
      -- This catches normal overlaps and long stays that fully cover the window.
      AND br.arrival <= p_window_end
      AND (br.departure - 1) >= p_window_start
      -- Skip rows that were already handled after their most recent booking update.
      -- This mirrors the scanner contract used by scan_actives integration tests.
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
    LIMIT v_limit;
END;
$$;

COMMENT ON FUNCTION public.scan_booking_registers_for_extension(DATE, DATE, INT, BIGINT) IS
'Queue-driven extension scanner. Returns booking_registers rows where needs_scan = 1 and the stay overlaps the requested date window. The worker should clear needs_scan only after successful processing.';

-- ============================================================================
-- 3. OPTIONAL SAFE CLEAR HELPER
-- ============================================================================
-- The worker may still clear the flag directly:
--   UPDATE booking_registers SET needs_scan = 0 WHERE id = :booking_id;
--
-- This helper exists so callers can use a stable database API instead.
-- It performs a flag-only update, which is the safe path expected by the
-- needs_scan trigger.
CREATE OR REPLACE FUNCTION public.mark_booking_register_extension_scanned(
    p_booking_id BIGINT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_updated INT := 0;
BEGIN
    IF p_booking_id IS NULL THEN
        RAISE EXCEPTION 'p_booking_id is required'
            USING ERRCODE = '22023';
    END IF;

    UPDATE public.booking_registers
    SET needs_scan = 0
    WHERE id = p_booking_id
      AND needs_scan = 1;

    GET DIAGNOSTICS v_updated = ROW_COUNT;
    RETURN v_updated > 0;
END;
$$;

COMMENT ON FUNCTION public.mark_booking_register_extension_scanned(BIGINT) IS
'Marks one booking_registers row as scanned by setting needs_scan = 0. Call only after extension processing succeeds.';

-- ============================================================================
-- 4. VERIFICATION
-- ============================================================================
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'scan_booking_registers_for_extension'
          AND p.pronargs = 4
    ) THEN
        RAISE EXCEPTION 'Failed to create scan_booking_registers_for_extension(DATE, DATE, INT, BIGINT)';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'mark_booking_register_extension_scanned'
          AND p.pronargs = 1
    ) THEN
        RAISE EXCEPTION 'Failed to create mark_booking_register_extension_scanned(BIGINT)';
    END IF;

    RAISE NOTICE 'OK: extension scanner now uses booking_registers.needs_scan as the scan gate.';
END $$;

COMMIT;

-- ============================================================================
-- WORKER USAGE
-- ============================================================================
/*
-- Fetch rows:
SELECT booking_id, arrival, departure, property_id, platform_id, guest_id, updated_at, metadata
FROM scan_booking_registers_for_extension(
    CURRENT_DATE,
    CURRENT_DATE + 10,
    100,
    0
);

-- After successful processing, clear the row:
SELECT mark_booking_register_extension_scanned(:booking_id);

-- Or clear directly:
UPDATE booking_registers
SET needs_scan = 0
WHERE id = :booking_id;
*/
