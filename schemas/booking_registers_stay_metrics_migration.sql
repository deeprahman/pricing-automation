-- booking_registers stay metrics migration
-- Purpose:
--   1) Backfill metadata.stay_length and metadata.booking_window for existing rows.
--   2) Ensure create/update/upsert paths keep those metrics current.
--
-- stay_length = departure - arrival in nights.
-- booking_window = max(arrival - booked_at::date, 0) in days.

DO $$
BEGIN
    IF to_regclass('public.booking_registers') IS NULL THEN
        RAISE EXCEPTION 'Missing table booking_registers. Run booking_registers.sql first.';
    END IF;
END $$;

CREATE OR REPLACE FUNCTION enrich_booking_register_stay_metrics(
    p_metadata JSONB,
    p_arrival DATE,
    p_departure DATE,
    p_booked_at TIMESTAMPTZ
) RETURNS JSONB AS $$
DECLARE
    v_metadata JSONB := COALESCE(p_metadata, '{}'::JSONB);
BEGIN
    IF jsonb_typeof(v_metadata) <> 'object' THEN
        RAISE EXCEPTION 'metadata must be a JSON object'
            USING ERRCODE = '22023';
    END IF;

    IF p_arrival IS NOT NULL AND p_departure IS NOT NULL THEN
        v_metadata := jsonb_set(
            v_metadata,
            '{stay_length}',
            to_jsonb((p_departure - p_arrival)::INT),
            true
        );
    END IF;

    IF p_arrival IS NOT NULL AND p_booked_at IS NOT NULL THEN
        v_metadata := jsonb_set(
            v_metadata,
            '{booking_window}',
            to_jsonb(GREATEST((p_arrival - p_booked_at::DATE)::INT, 0)),
            true
        );
    END IF;

    RETURN v_metadata;
END;
$$ LANGUAGE plpgsql STABLE;

UPDATE booking_registers
SET metadata = enrich_booking_register_stay_metrics(metadata, arrival, departure, booked_at)
WHERE arrival IS NOT NULL
  AND departure IS NOT NULL
  AND booked_at IS NOT NULL;

CREATE OR REPLACE FUNCTION create_booking_register(
    p_id BIGINT DEFAULT NULL,
    p_type TEXT DEFAULT 'booking',
    p_arrival DATE DEFAULT NULL,
    p_departure DATE DEFAULT NULL,
    p_booked_at TIMESTAMPTZ DEFAULT NULL,
    p_guest_id BIGINT DEFAULT NULL,
    p_platform_id INT DEFAULT NULL,
    p_listing_id TEXT DEFAULT NULL,
    p_thread_ids_json JSONB DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::JSONB
) RETURNS booking_registers AS $$
DECLARE
    v_lookup RECORD;
    v_metadata JSONB;
    v_row booking_registers%ROWTYPE;
BEGIN
    SELECT *
    INTO v_lookup
    FROM resolve_booking_register_lookup(p_platform_id, p_listing_id);

    v_metadata := enrich_booking_register_stay_metrics(
        normalize_booking_register_metadata(p_metadata, p_listing_id),
        p_arrival,
        p_departure,
        p_booked_at
    );

    IF p_id IS NULL THEN
        INSERT INTO booking_registers (
            type,
            arrival,
            departure,
            booked_at,
            guest_id,
            property_id,
            platform_id,
            ppl_id,
            thread_ids_json,
            metadata
        )
        VALUES (
            COALESCE(NULLIF(BTRIM(p_type), ''), 'booking'),
            p_arrival,
            p_departure,
            p_booked_at,
            p_guest_id,
            v_lookup.property_id,
            p_platform_id,
            v_lookup.ppl_id,
            p_thread_ids_json,
            v_metadata
        )
        RETURNING *
        INTO v_row;
    ELSE
        INSERT INTO booking_registers (
            id,
            type,
            arrival,
            departure,
            booked_at,
            guest_id,
            property_id,
            platform_id,
            ppl_id,
            thread_ids_json,
            metadata
        )
        VALUES (
            p_id,
            COALESCE(NULLIF(BTRIM(p_type), ''), 'booking'),
            p_arrival,
            p_departure,
            p_booked_at,
            p_guest_id,
            v_lookup.property_id,
            p_platform_id,
            v_lookup.ppl_id,
            p_thread_ids_json,
            v_metadata
        )
        RETURNING *
        INTO v_row;
    END IF;

    RETURN v_row;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION update_booking_register(
    p_id BIGINT,
    p_type TEXT DEFAULT NULL,
    p_arrival DATE DEFAULT NULL,
    p_departure DATE DEFAULT NULL,
    p_booked_at TIMESTAMPTZ DEFAULT NULL,
    p_guest_id BIGINT DEFAULT NULL,
    p_platform_id INT DEFAULT NULL,
    p_listing_id TEXT DEFAULT NULL,
    p_thread_ids_json JSONB DEFAULT NULL,
    p_metadata JSONB DEFAULT NULL
) RETURNS booking_registers AS $$
DECLARE
    v_current booking_registers%ROWTYPE;
    v_current_listing_id TEXT;
    v_lookup RECORD;
    v_type TEXT;
    v_arrival DATE;
    v_departure DATE;
    v_booked_at TIMESTAMPTZ;
    v_metadata JSONB;
    v_row booking_registers%ROWTYPE;
BEGIN
    SELECT *
    INTO v_current
    FROM booking_registers
    WHERE id = p_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'booking_registers id % was not found', p_id
            USING ERRCODE = 'P0002';
    END IF;

    SELECT ppl.listing_id
    INTO v_current_listing_id
    FROM platform_property_lookup ppl
    WHERE ppl.id = v_current.ppl_id;

    IF v_current_listing_id IS NULL THEN
        RAISE EXCEPTION
            'platform_property_lookup id % was not found for booking_registers id %',
            v_current.ppl_id, p_id
            USING ERRCODE = '23503';
    END IF;

    SELECT *
    INTO v_lookup
    FROM resolve_booking_register_lookup(
        COALESCE(p_platform_id, v_current.platform_id),
        COALESCE(NULLIF(BTRIM(p_listing_id), ''), v_current_listing_id)
    );

    v_type := COALESCE(NULLIF(BTRIM(p_type), ''), v_current.type);
    v_arrival := COALESCE(p_arrival, v_current.arrival);
    v_departure := COALESCE(p_departure, v_current.departure);
    v_booked_at := COALESCE(p_booked_at, v_current.booked_at);

    IF p_metadata IS NULL THEN
        v_metadata := COALESCE(v_current.metadata, '{}'::JSONB);
    ELSE
        v_metadata := COALESCE(v_current.metadata, '{}'::JSONB)
            || normalize_booking_register_metadata(p_metadata, NULL);
    END IF;

    v_metadata := normalize_booking_register_metadata(
        v_metadata,
        COALESCE(NULLIF(BTRIM(p_listing_id), ''), v_current_listing_id)
    );
    v_metadata := enrich_booking_register_stay_metrics(
        v_metadata,
        v_arrival,
        v_departure,
        v_booked_at
    );

    UPDATE booking_registers
    SET
        type = v_type,
        arrival = v_arrival,
        departure = v_departure,
        booked_at = v_booked_at,
        guest_id = COALESCE(p_guest_id, v_current.guest_id),
        property_id = v_lookup.property_id,
        platform_id = COALESCE(p_platform_id, v_current.platform_id),
        ppl_id = v_lookup.ppl_id,
        thread_ids_json = COALESCE(p_thread_ids_json, v_current.thread_ids_json),
        metadata = v_metadata
    WHERE id = p_id
    RETURNING *
    INTO v_row;

    RETURN v_row;
END;
$$ LANGUAGE plpgsql;
