-- ============================================
-- STAY EXTENSION & CONTRACTION TRACKING MIGRATION
-- ============================================
-- Purpose: add automatic stay delta tracking under metadata.stay_extended
--          and metadata.stay_contracted while preserving metadata.previous
--          core-change history.

DO $$
BEGIN
    IF to_regclass('public.booking_registers') IS NULL THEN
        RAISE EXCEPTION 'Missing table booking_registers. Run booking_registers.sql first.';
    END IF;
END $$;

DROP TRIGGER IF EXISTS trg_booking_registers_track_core_changes ON booking_registers;

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

    IF cardinality(v_changed_fields) > 0 THEN
        v_previous := jsonb_set(v_previous, '{last_changed_at}', to_jsonb(NOW()), true);
        v_previous := jsonb_set(v_previous, '{last_changed_by}', to_jsonb(current_user), true);
        v_previous := jsonb_set(v_previous, '{changed_fields}', to_jsonb(v_changed_fields), true);
    END IF;

    v_metadata := jsonb_set(v_metadata, '{previous}', v_previous, true);
    NEW.metadata := v_metadata;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_booking_registers_track_core_changes
    BEFORE UPDATE ON booking_registers
    FOR EACH ROW
    EXECUTE FUNCTION track_booking_core_changes();

CREATE OR REPLACE FUNCTION get_booking_net_stay_change(p_id BIGINT)
RETURNS TABLE (
    booking_id BIGINT,
    current_stay INT,
    net_change INT,
    total_extended INT,
    total_contracted INT,
    extension_count INT,
    contraction_count INT,
    net_direction TEXT
) AS $$
DECLARE
    v_metadata JSONB;
    v_arrival DATE;
    v_departure DATE;
    v_extended_total INT := 0;
    v_contracted_total INT := 0;
    v_extended_count INT := 0;
    v_contracted_count INT := 0;
    v_extended_elem JSONB;
    v_contracted_elem JSONB;
BEGIN
    SELECT arrival, departure, metadata
    INTO v_arrival, v_departure, v_metadata
    FROM booking_registers
    WHERE id = p_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Booking with id % not found', p_id;
    END IF;

    FOR v_extended_elem IN SELECT * FROM jsonb_array_elements(COALESCE(v_metadata->'stay_extended', '[]'::jsonb))
    LOOP
        v_extended_total := v_extended_total + (v_extended_elem::text::INT);
        v_extended_count := v_extended_count + 1;
    END LOOP;

    FOR v_contracted_elem IN SELECT * FROM jsonb_array_elements(COALESCE(v_metadata->'stay_contracted', '[]'::jsonb))
    LOOP
        v_contracted_total := v_contracted_total + (v_contracted_elem::text::INT);
        v_contracted_count := v_contracted_count + 1;
    END LOOP;

    RETURN QUERY
    SELECT
        p_id AS booking_id,
        (v_departure - v_arrival) AS current_stay,
        (v_extended_total - v_contracted_total) AS net_change,
        v_extended_total AS total_extended,
        v_contracted_total AS total_contracted,
        v_extended_count AS extension_count,
        v_contracted_count AS contraction_count,
        CASE
            WHEN v_extended_total > v_contracted_total THEN 'NET_EXTENSION'
            WHEN v_extended_total < v_contracted_total THEN 'NET_CONTRACTION'
            ELSE 'NO_NET_CHANGE'
        END AS net_direction;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE INDEX IF NOT EXISTS idx_booking_registers_stay_extended_gin
    ON booking_registers USING GIN ((metadata->'stay_extended'));

CREATE INDEX IF NOT EXISTS idx_booking_registers_stay_contracted_gin
    ON booking_registers USING GIN ((metadata->'stay_contracted'));
