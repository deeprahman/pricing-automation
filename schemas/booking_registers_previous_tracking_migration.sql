-- booking_registers previous-core-value tracking migration
-- Adds automatic JSONB history tracking for arrival, departure, and property_id.
--
-- Tracked path:
--   metadata.previous
--     - arrival: [<old_date>, ...]
--     - departure: [<old_date>, ...]
--     - property_id: [<old_property_id>, ...]
--     - last_changed_at: <timestamptz string>
--     - last_changed_by: <db user>
--     - changed_fields: [<field_name>, ...]
--
-- History retention:
--   Keep the most recent 5 items per tracked array.
--
-- Rollback:
--   DROP TRIGGER IF EXISTS trg_booking_registers_track_core_changes ON booking_registers;
--   DROP FUNCTION IF EXISTS track_booking_core_changes();

DO $$
BEGIN
    IF to_regclass('public.booking_registers') IS NULL THEN
        RAISE EXCEPTION 'Missing table booking_registers. Run booking_registers.sql first.';
    END IF;
END $$;

CREATE OR REPLACE FUNCTION track_booking_core_changes()
RETURNS TRIGGER AS $$
DECLARE
    v_metadata JSONB := COALESCE(NEW.metadata, '{}'::jsonb);
    v_previous JSONB;
    v_changed_fields TEXT[] := ARRAY[]::TEXT[];
BEGIN
    IF jsonb_typeof(v_metadata) <> 'object' THEN
        RAISE EXCEPTION 'booking_registers.metadata must be a JSON object'
            USING ERRCODE = '22023';
    END IF;

    v_previous := COALESCE(v_metadata->'previous', '{}'::jsonb);
    IF jsonb_typeof(v_previous) <> 'object' THEN
        v_previous := '{}'::jsonb;
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
                            COALESCE(v_previous->'arrival', '[]'::jsonb) || jsonb_build_array(to_jsonb(OLD.arrival))
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
                            COALESCE(v_previous->'departure', '[]'::jsonb) || jsonb_build_array(to_jsonb(OLD.departure))
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
                            COALESCE(v_previous->'property_id', '[]'::jsonb) || jsonb_build_array(to_jsonb(OLD.property_id))
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

DROP TRIGGER IF EXISTS trg_booking_registers_track_core_changes ON booking_registers;

CREATE TRIGGER trg_booking_registers_track_core_changes
    BEFORE UPDATE ON booking_registers
    FOR EACH ROW
    EXECUTE FUNCTION track_booking_core_changes();

UPDATE booking_registers
SET metadata = jsonb_set(
    COALESCE(metadata, '{}'::jsonb),
    '{previous}',
    '{}'::jsonb,
    true
)
WHERE metadata->'previous' IS NULL;
