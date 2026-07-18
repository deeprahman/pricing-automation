-- ============================================================================
-- booking_registers needs-scan migration
-- ============================================================================
-- Purpose:
--   Add a first-class scanner flag to booking_registers.
--
-- Behavior:
--   - New rows are always queued for scan: needs_scan = 1.
--   - Any UPDATE queues the row for scan: needs_scan = 1.
--   - Metadata JSONB changes also queue the row for scan.
--   - The scanner is allowed to clear the flag with a flag-only update:
--       UPDATE booking_registers SET needs_scan = 0 WHERE id = ...;
--
-- Notes:
--   - The flag uses SMALLINT because the desired external representation is 0/1.
--   - This migration also patches track_booking_core_changes() so it does not
--     rewrite metadata during a flag-only update. Without that guard, clearing
--     needs_scan could be turned back into a metadata update and re-queued.
--
-- Prerequisites:
--   - booking_registers.sql
--
-- Safe to re-run: yes.
-- ============================================================================

-- ============================================================================
-- 1. DEPENDENCY VALIDATION
-- ============================================================================

DO $$
BEGIN
    IF to_regclass('public.booking_registers') IS NULL THEN
        RAISE EXCEPTION 'Missing table booking_registers. Run booking_registers.sql first.';
    END IF;
END $$;

-- ============================================================================
-- 2. ADD COLUMN
-- ============================================================================

ALTER TABLE booking_registers
    ADD COLUMN IF NOT EXISTS needs_scan SMALLINT NOT NULL DEFAULT 1;

ALTER TABLE booking_registers
    DROP CONSTRAINT IF EXISTS chk_booking_registers_needs_scan;

ALTER TABLE booking_registers
    ADD CONSTRAINT chk_booking_registers_needs_scan
    CHECK (needs_scan IN (0, 1));

-- Keep existing rows queued after migration. This is intentionally conservative.
UPDATE booking_registers
SET needs_scan = 1
WHERE needs_scan IS DISTINCT FROM 1;

COMMENT ON COLUMN booking_registers.needs_scan IS
'0/1 scanner queue flag. 1 means the booking should be picked up by the scanner. Any insert or real update sets it to 1. Scanner may clear it to 0 after successful processing.';

-- ============================================================================
-- 3. PATCH CORE-CHANGE TRACKING FUNCTION
--    Prevent metadata rewrites during scanner flag-only updates.
-- ============================================================================

CREATE OR REPLACE FUNCTION track_booking_core_changes()
RETURNS TRIGGER AS $$
DECLARE
    v_metadata JSONB := COALESCE(NEW.metadata, '{}'::jsonb);
    v_previous JSONB;
    v_changed_fields TEXT[] := ARRAY[]::TEXT[];
    v_old_stay_length INT;
    v_new_stay_length INT;
    v_stay_delta INT;
BEGIN
    IF jsonb_typeof(v_metadata) <> 'object' THEN
        RAISE EXCEPTION 'booking_registers.metadata must be a JSON object'
            USING ERRCODE = '22023';
    END IF;

    v_previous := COALESCE(v_metadata->'previous', '{}'::jsonb);
    IF jsonb_typeof(v_previous) <> 'object' THEN
        v_previous := '{}'::jsonb;
    END IF;

    IF OLD.arrival IS NOT NULL
       AND OLD.departure IS NOT NULL
       AND NEW.arrival IS NOT NULL
       AND NEW.departure IS NOT NULL
    THEN
        v_old_stay_length := (OLD.departure - OLD.arrival);
        v_new_stay_length := (NEW.departure - NEW.arrival);

        IF v_new_stay_length > v_old_stay_length THEN
            v_stay_delta := v_new_stay_length - v_old_stay_length;

            v_metadata := jsonb_set(
                v_metadata,
                '{stay_extended}',
                (
                    SELECT COALESCE(jsonb_agg(e), '[]'::jsonb)
                    FROM (
                        SELECT e
                        FROM (
                            SELECT e, ord
                            FROM jsonb_array_elements(
                                COALESCE(v_metadata->'stay_extended', '[]'::jsonb)
                                || jsonb_build_array(to_jsonb(v_stay_delta))
                            ) WITH ORDINALITY AS t(e, ord)
                            ORDER BY ord DESC
                            LIMIT 5
                        ) keep_last
                        ORDER BY ord ASC
                    ) ordered
                ),
                true
            );

            v_changed_fields := array_append(v_changed_fields, 'stay_extended');
        ELSIF v_new_stay_length < v_old_stay_length THEN
            v_stay_delta := v_old_stay_length - v_new_stay_length;

            v_metadata := jsonb_set(
                v_metadata,
                '{stay_contracted}',
                (
                    SELECT COALESCE(jsonb_agg(e), '[]'::jsonb)
                    FROM (
                        SELECT e
                        FROM (
                            SELECT e, ord
                            FROM jsonb_array_elements(
                                COALESCE(v_metadata->'stay_contracted', '[]'::jsonb)
                                || jsonb_build_array(to_jsonb(v_stay_delta))
                            ) WITH ORDINALITY AS t(e, ord)
                            ORDER BY ord DESC
                            LIMIT 5
                        ) keep_last
                        ORDER BY ord ASC
                    ) ordered
                ),
                true
            );

            v_changed_fields := array_append(v_changed_fields, 'stay_contracted');
        END IF;
    END IF;

    IF NEW.arrival IS DISTINCT FROM OLD.arrival THEN
        v_previous := jsonb_set(
            v_previous,
            '{arrival}',
            (
                SELECT COALESCE(jsonb_agg(e), '[]'::jsonb)
                FROM (
                    SELECT e
                    FROM (
                        SELECT e, ord
                        FROM jsonb_array_elements(
                            COALESCE(v_previous->'arrival', '[]'::jsonb)
                            || jsonb_build_array(to_jsonb(OLD.arrival))
                        ) WITH ORDINALITY AS t(e, ord)
                        ORDER BY ord DESC
                        LIMIT 5
                    ) keep_last
                    ORDER BY ord ASC
                ) ordered
            ),
            true
        );

        v_changed_fields := array_append(v_changed_fields, 'arrival');
    END IF;

    IF NEW.departure IS DISTINCT FROM OLD.departure THEN
        v_previous := jsonb_set(
            v_previous,
            '{departure}',
            (
                SELECT COALESCE(jsonb_agg(e), '[]'::jsonb)
                FROM (
                    SELECT e
                    FROM (
                        SELECT e, ord
                        FROM jsonb_array_elements(
                            COALESCE(v_previous->'departure', '[]'::jsonb)
                            || jsonb_build_array(to_jsonb(OLD.departure))
                        ) WITH ORDINALITY AS t(e, ord)
                        ORDER BY ord DESC
                        LIMIT 5
                    ) keep_last
                    ORDER BY ord ASC
                ) ordered
            ),
            true
        );

        v_changed_fields := array_append(v_changed_fields, 'departure');
    END IF;

    IF NEW.property_id IS DISTINCT FROM OLD.property_id THEN
        v_previous := jsonb_set(
            v_previous,
            '{property_id}',
            (
                SELECT COALESCE(jsonb_agg(e), '[]'::jsonb)
                FROM (
                    SELECT e
                    FROM (
                        SELECT e, ord
                        FROM jsonb_array_elements(
                            COALESCE(v_previous->'property_id', '[]'::jsonb)
                            || jsonb_build_array(to_jsonb(OLD.property_id))
                        ) WITH ORDINALITY AS t(e, ord)
                        ORDER BY ord DESC
                        LIMIT 5
                    ) keep_last
                    ORDER BY ord ASC
                ) ordered
            ),
            true
        );

        v_changed_fields := array_append(v_changed_fields, 'property_id');
    END IF;

    -- Only rewrite metadata when this trigger actually tracked a core/stay change.
    -- This keeps scanner flag-only updates from mutating metadata and being
    -- re-queued by the needs_scan trigger.
    IF cardinality(v_changed_fields) > 0 THEN
        v_previous := jsonb_set(v_previous, '{last_changed_at}', to_jsonb(NOW()), true);
        v_previous := jsonb_set(v_previous, '{last_changed_by}', to_jsonb(current_user), true);
        v_previous := jsonb_set(v_previous, '{changed_fields}', to_jsonb(v_changed_fields), true);

        v_metadata := jsonb_set(v_metadata, '{previous}', v_previous, true);
        NEW.metadata := v_metadata;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 4. NEEDS-SCAN TRIGGER
--    Name ends with zz so it runs after existing BEFORE UPDATE triggers such as:
--      - trg_booking_registers_track_core_changes
--      - trg_booking_registers_updated_at
-- ============================================================================

CREATE OR REPLACE FUNCTION set_booking_registers_needs_scan()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.needs_scan := 1;
        RETURN NEW;
    END IF;

    -- Preserve invalid explicit updates so the CHECK constraint can reject them.
    -- Without this guard, trigger-requeue logic could silently coerce invalid
    -- values (for example 2) back to 1.
    IF TG_OP = 'UPDATE'
       AND OLD.needs_scan IS DISTINCT FROM NEW.needs_scan
       AND NEW.needs_scan IS DISTINCT FROM 0
       AND NEW.needs_scan IS DISTINCT FROM 1
    THEN
        RETURN NEW;
    END IF;

    -- Allow the scanner to clear the flag after successful processing.
    -- This must be a true flag-only update. Any data change, including metadata,
    -- will fall through and set needs_scan back to 1.
    IF TG_OP = 'UPDATE'
       AND OLD.needs_scan IS DISTINCT FROM NEW.needs_scan
       AND NEW.needs_scan = 0
       AND NEW.id              IS NOT DISTINCT FROM OLD.id
       AND NEW.type            IS NOT DISTINCT FROM OLD.type
       AND NEW.arrival         IS NOT DISTINCT FROM OLD.arrival
       AND NEW.departure       IS NOT DISTINCT FROM OLD.departure
       AND NEW.booked_at       IS NOT DISTINCT FROM OLD.booked_at
       AND NEW.guest_id        IS NOT DISTINCT FROM OLD.guest_id
       AND NEW.property_id     IS NOT DISTINCT FROM OLD.property_id
       AND NEW.platform_id     IS NOT DISTINCT FROM OLD.platform_id
       AND NEW.ppl_id          IS NOT DISTINCT FROM OLD.ppl_id
       AND NEW.thread_ids_json IS NOT DISTINCT FROM OLD.thread_ids_json
       AND NEW.metadata        IS NOT DISTINCT FROM OLD.metadata
       AND NEW.created_at      IS NOT DISTINCT FROM OLD.created_at
       AND NEW.updated_at      IS NOT DISTINCT FROM OLD.updated_at
    THEN
        RETURN NEW;
    END IF;

    -- Any insert/update other than the scanner's flag-only clear requires scan.
    -- This intentionally covers JSONB metadata updates.
    NEW.needs_scan := 1;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_booking_registers_zz_needs_scan ON booking_registers;

CREATE TRIGGER trg_booking_registers_zz_needs_scan
    BEFORE INSERT OR UPDATE ON booking_registers
    FOR EACH ROW
    EXECUTE FUNCTION set_booking_registers_needs_scan();

-- ============================================================================
-- 5. SCANNER INDEX
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_booking_registers_needs_scan_id
    ON booking_registers (id)
    WHERE needs_scan = 1;

-- Optional date-window indexes for larger tables. Add after EXPLAIN ANALYZE if
-- the scanner remains date-window bound even after filtering by needs_scan.
--
-- CREATE INDEX IF NOT EXISTS idx_booking_registers_needs_scan_arrival_id
--     ON booking_registers (arrival, id)
--     WHERE needs_scan = 1;
--
-- CREATE INDEX IF NOT EXISTS idx_booking_registers_needs_scan_departure_id
--     ON booking_registers (departure, id)
--     WHERE needs_scan = 1;

-- ============================================================================
-- 6. VERIFICATION
-- ============================================================================

DO $$
DECLARE
    v_column_exists BOOLEAN;
    v_constraint_exists BOOLEAN;
    v_trigger_exists BOOLEAN;
    v_index_exists BOOLEAN;
BEGIN
    SELECT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'booking_registers'
          AND column_name = 'needs_scan'
    ) INTO v_column_exists;

    SELECT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.booking_registers'::regclass
          AND conname = 'chk_booking_registers_needs_scan'
    ) INTO v_constraint_exists;

    SELECT EXISTS (
        SELECT 1
        FROM pg_trigger
        WHERE tgrelid = 'public.booking_registers'::regclass
          AND tgname = 'trg_booking_registers_zz_needs_scan'
          AND NOT tgisinternal
    ) INTO v_trigger_exists;

    SELECT EXISTS (
        SELECT 1
        FROM pg_indexes
        WHERE schemaname = 'public'
          AND tablename = 'booking_registers'
          AND indexname = 'idx_booking_registers_needs_scan_id'
    ) INTO v_index_exists;

    IF NOT v_column_exists THEN
        RAISE EXCEPTION 'FAIL: needs_scan column missing';
    END IF;
    IF NOT v_constraint_exists THEN
        RAISE EXCEPTION 'FAIL: chk_booking_registers_needs_scan constraint missing';
    END IF;
    IF NOT v_trigger_exists THEN
        RAISE EXCEPTION 'FAIL: trg_booking_registers_zz_needs_scan trigger missing';
    END IF;
    IF NOT v_index_exists THEN
        RAISE EXCEPTION 'FAIL: idx_booking_registers_needs_scan_id index missing';
    END IF;

    RAISE NOTICE 'OK: booking_registers needs_scan migration verified successfully.';
END $$;

-- ============================================================================
-- USAGE
-- ============================================================================

-- Scanner fetch pattern:
-- SELECT *
-- FROM booking_registers
-- WHERE needs_scan = 1
--   AND id > :cursor_id
-- ORDER BY id ASC
-- LIMIT :limit;
--
-- Scanner success path:
-- UPDATE booking_registers
-- SET needs_scan = 0
-- WHERE id = :booking_register_id;
