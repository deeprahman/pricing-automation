-- ============================================================================
-- booking_registers needs-scan manual override migration
-- ============================================================================
-- Purpose:
--   Convert needs_scan from trigger-managed queueing to a manual override flag.
--
-- Behavior after migration:
--   - needs_scan default remains 1 for new rows.
--   - Existing rows are normalized to needs_scan = 0 once.
--   - Direct UPDATE of booking_registers.needs_scan is blocked.
--   - needs_scan can only be changed via approved SQL functions:
--       set_booking_register_needs_scan(...)
--       mark_booking_register_extension_needs_scan(...)
--       mark_booking_register_extension_scanned(...)
--   - Extension scanner eligibility is hybrid:
--       include if needs_scan = 1
--       otherwise include unless (updated_at < metadata.bso.potential_extension.last_extended)
--
-- Prerequisites:
--   - booking_registers.sql
--   - booking_registers_needs_scan_migration.sql
--   - booking_registers_extension_scanner_needs_scan_migration.sql
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

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'scan_booking_registers_for_extension'
          AND p.pronargs = 4
    ) THEN
        RAISE EXCEPTION
            'Missing function: scan_booking_registers_for_extension(DATE, DATE, INT, BIGINT). Run booking_registers_extension_scanner_needs_scan_migration.sql first.';
    END IF;
END $$;

-- ============================================================================
-- 2. REMOVE AUTO-QUEUEING NEEDS_SCAN TRIGGER/FUNCTION
-- ============================================================================
DROP TRIGGER IF EXISTS trg_booking_registers_zz_needs_scan ON public.booking_registers;
DROP TRIGGER IF EXISTS trg_booking_registers_needs_scan_guard ON public.booking_registers;
DROP FUNCTION IF EXISTS public.set_booking_registers_needs_scan();

-- ============================================================================
-- 3. NORMALIZE EXISTING ROWS + KEEP NEW-ROW DEFAULT
-- ============================================================================
UPDATE public.booking_registers
SET needs_scan = 0
WHERE needs_scan IS DISTINCT FROM 0;

ALTER TABLE public.booking_registers
    ALTER COLUMN needs_scan SET DEFAULT 1;

COMMENT ON COLUMN public.booking_registers.needs_scan IS
'Manual scanner override flag (0/1). 1 force-includes row in extension scanner. 0 uses updated_at/last_extended fallback logic.';

-- ============================================================================
-- 4. HARD ENFORCEMENT GUARD (FUNCTION-ONLY WRITES)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.guard_booking_registers_needs_scan_update()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.needs_scan IS DISTINCT FROM OLD.needs_scan THEN
        IF current_setting('pws.booking_registers_needs_scan_guard', true) IS DISTINCT FROM 'allow' THEN
            RAISE EXCEPTION
                'Direct updates to booking_registers.needs_scan are not allowed. Use set_booking_register_needs_scan(...) or mark_booking_register_extension_* helpers.'
                USING ERRCODE = '42501';
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_booking_registers_needs_scan_guard ON public.booking_registers;

CREATE TRIGGER trg_booking_registers_needs_scan_guard
    BEFORE UPDATE ON public.booking_registers
    FOR EACH ROW
    EXECUTE FUNCTION public.guard_booking_registers_needs_scan_update();

-- ============================================================================
-- 5. AUTHORIZED WRITE API
-- ============================================================================
CREATE OR REPLACE FUNCTION public.set_booking_register_needs_scan(
    p_booking_id BIGINT,
    p_needs_scan SMALLINT
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

    IF p_needs_scan IS NULL OR p_needs_scan NOT IN (0, 1) THEN
        RAISE EXCEPTION 'p_needs_scan must be 0 or 1'
            USING ERRCODE = '22023';
    END IF;

    PERFORM set_config('pws.booking_registers_needs_scan_guard', 'allow', true);

    UPDATE public.booking_registers
    SET needs_scan = p_needs_scan
    WHERE id = p_booking_id
      AND needs_scan IS DISTINCT FROM p_needs_scan;

    GET DIAGNOSTICS v_updated = ROW_COUNT;

    -- Narrow the allow window to this update only.
    PERFORM set_config('pws.booking_registers_needs_scan_guard', '', true);

    RETURN v_updated > 0;
END;
$$;

COMMENT ON FUNCTION public.set_booking_register_needs_scan(BIGINT, SMALLINT) IS
'Authorized needs_scan setter. Enforces 0/1 and bypasses the needs_scan guard trigger via an internal transaction-local token.';

CREATE OR REPLACE FUNCTION public.set_booking_register_needs_scan(
    p_booking_id BIGINT,
    p_needs_scan INT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
AS $$
BEGIN
    IF p_needs_scan IS NULL OR p_needs_scan NOT IN (0, 1) THEN
        RAISE EXCEPTION 'p_needs_scan must be 0 or 1'
            USING ERRCODE = '22023';
    END IF;

    RETURN public.set_booking_register_needs_scan(p_booking_id, p_needs_scan::SMALLINT);
END;
$$;

COMMENT ON FUNCTION public.set_booking_register_needs_scan(BIGINT, INT) IS
'Compatibility overload for integer callers. Validates 0/1 and delegates to set_booking_register_needs_scan(BIGINT, SMALLINT).';

CREATE OR REPLACE FUNCTION public.mark_booking_register_extension_needs_scan(
    p_booking_id BIGINT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
AS $$
BEGIN
    RETURN public.set_booking_register_needs_scan(p_booking_id, 1::SMALLINT);
END;
$$;

COMMENT ON FUNCTION public.mark_booking_register_extension_needs_scan(BIGINT) IS
'Marks one booking_registers row for extension scanning by setting needs_scan = 1 through the authorized setter.';

CREATE OR REPLACE FUNCTION public.mark_booking_register_extension_scanned(
    p_booking_id BIGINT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
AS $$
BEGIN
    RETURN public.set_booking_register_needs_scan(p_booking_id, 0::SMALLINT);
END;
$$;

COMMENT ON FUNCTION public.mark_booking_register_extension_scanned(BIGINT) IS
'Marks one booking_registers row as scanned by setting needs_scan = 0 through the authorized setter.';

-- ============================================================================
-- 6. HYBRID EXTENSION SCANNER LOGIC
-- ============================================================================
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
    WHERE br.id > v_cursor_id
      AND LOWER(br.type) = 'booking'
      -- Departure is checkout date, so the last stayed night is departure - 1.
      -- This catches normal overlaps and long stays that fully cover the window.
      AND br.arrival <= p_window_end
      AND (br.departure - 1) >= p_window_start
      -- Manual override:
      --   needs_scan = 1 -> include always.
      -- Fallback when needs_scan = 0:
      --   skip if updated_at <= last_extended.
      AND CASE
          WHEN br.needs_scan = 1 THEN TRUE
          -- Original condition kept for reference:
          -- AND br.updated_at < (
          --     br.metadata #>> '{bso,potential_extension,last_extended}'
          -- )::TIMESTAMPTZ
          WHEN (br.metadata #>> '{bso,potential_extension,last_extended}') IS NOT NULL
               AND br.updated_at <= (
                   br.metadata #>> '{bso,potential_extension,last_extended}'
               )::TIMESTAMPTZ
          THEN FALSE
          ELSE TRUE
      END
    ORDER BY br.id ASC
    LIMIT v_limit;
END;
$$;

COMMENT ON FUNCTION public.scan_booking_registers_for_extension(DATE, DATE, INT, BIGINT) IS
'Hybrid extension scanner: include if needs_scan=1; otherwise skip when updated_at is older than or equal to metadata.bso.potential_extension.last_extended.';

-- ============================================================================
-- 7. VERIFICATION
-- ============================================================================
DO $$
DECLARE
    v_guard_trigger_exists BOOLEAN;
    v_legacy_trigger_exists BOOLEAN;
    v_setter_exists BOOLEAN;
    v_mark_set_exists BOOLEAN;
    v_mark_clear_exists BOOLEAN;
BEGIN
    SELECT EXISTS (
        SELECT 1
        FROM pg_trigger
        WHERE tgrelid = 'public.booking_registers'::regclass
          AND tgname = 'trg_booking_registers_needs_scan_guard'
          AND NOT tgisinternal
    ) INTO v_guard_trigger_exists;

    SELECT EXISTS (
        SELECT 1
        FROM pg_trigger
        WHERE tgrelid = 'public.booking_registers'::regclass
          AND tgname = 'trg_booking_registers_zz_needs_scan'
          AND NOT tgisinternal
    ) INTO v_legacy_trigger_exists;

    SELECT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'set_booking_register_needs_scan'
          AND p.pronargs = 2
    ) INTO v_setter_exists;

    SELECT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'mark_booking_register_extension_needs_scan'
          AND p.pronargs = 1
    ) INTO v_mark_set_exists;

    SELECT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'mark_booking_register_extension_scanned'
          AND p.pronargs = 1
    ) INTO v_mark_clear_exists;

    IF NOT v_guard_trigger_exists THEN
        RAISE EXCEPTION 'FAIL: trg_booking_registers_needs_scan_guard trigger missing';
    END IF;
    IF v_legacy_trigger_exists THEN
        RAISE EXCEPTION 'FAIL: legacy trigger trg_booking_registers_zz_needs_scan should be removed';
    END IF;
    IF NOT v_setter_exists THEN
        RAISE EXCEPTION 'FAIL: set_booking_register_needs_scan(BIGINT, SMALLINT) missing';
    END IF;
    IF NOT v_mark_set_exists THEN
        RAISE EXCEPTION 'FAIL: mark_booking_register_extension_needs_scan(BIGINT) missing';
    END IF;
    IF NOT v_mark_clear_exists THEN
        RAISE EXCEPTION 'FAIL: mark_booking_register_extension_scanned(BIGINT) missing';
    END IF;

    RAISE NOTICE 'OK: booking_registers needs_scan manual override migration verified successfully.';
END $$;

COMMIT;
