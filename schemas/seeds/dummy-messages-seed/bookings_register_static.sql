-- ============================================================================
-- Dummy Fixture Seed (Static Add-on)
--
-- Adds static bookings used by fixture presets on top of the extension cohort.
-- Booking IDs: 55000001..55000030
-- Thread IDs : 95100001..95100030
-- ============================================================================

BEGIN;

DO $$
BEGIN
    IF to_regclass('public.booking_registers') IS NULL THEN
        RAISE EXCEPTION 'Missing table: booking_registers. Run booking_registers.sql first.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'upsert_booking_register'
          AND p.pronargs = 10
    ) THEN
        RAISE EXCEPTION 'Missing function: upsert_booking_register(...). Run booking_registers.sql first.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.platforms
        WHERE name = 'OwnerRez'
    ) THEN
        RAISE EXCEPTION 'OwnerRez platform missing. Run bookings_register_base.sql first.';
    END IF;

    IF (
        SELECT COUNT(*)
        FROM public.platform_property_lookup ppl
        JOIN public.platforms p ON p.id = ppl.platform_id
        WHERE p.name = 'OwnerRez'
          AND ppl.listing_id IN ('ownerrez_prop_1', 'ownerrez_prop_2', 'ownerrez_prop_3', 'ownerrez_prop_4', 'ownerrez_prop_5')
    ) < 5 THEN
        RAISE EXCEPTION 'OwnerRez lookup rows missing. Run bookings_register_base.sql first.';
    END IF;
END $$;

DELETE FROM public.booking_registers
WHERE id BETWEEN 55000001 AND 55000030
   OR metadata->>'seed' = 'dummy_static_booking_v1';

WITH
    pms AS (
        SELECT id AS platform_id FROM public.platforms WHERE name = 'OwnerRez'
    ),
    seed_rows AS (
        SELECT
            gs AS n,
            (55000000 + gs)::bigint AS booking_id,
            (95100000 + gs)::bigint AS thread_id,
            (850000000 + gs)::bigint AS guest_id,
            (((gs - 1) % 5) + 1)::int AS property_id,
            (CURRENT_DATE + 9 + gs)::date AS arrival,
            (CURRENT_DATE + 9 + gs + (3 + (gs % 3))::int)::date AS departure,
            CURRENT_TIMESTAMP - INTERVAL '30 days' + make_interval(hours => gs % 24) AS booked_at
        FROM generate_series(1, 30) AS gs
    ),
    resolved AS (
        SELECT
            sr.*,
            pms.platform_id,
            'ownerrez_prop_' || sr.property_id::text AS listing_id
        FROM seed_rows sr
        CROSS JOIN pms
    )
SELECT public.upsert_booking_register(
    p_id => r.booking_id,
    p_type => 'booking',
    p_arrival => r.arrival,
    p_departure => r.departure,
    p_booked_at => r.booked_at,
    p_guest_id => r.guest_id,
    p_platform_id => r.platform_id,
    p_listing_id => r.listing_id,
    p_thread_ids_json => jsonb_build_array(r.thread_id),
    p_metadata => jsonb_build_object(
        'seed', 'dummy_static_booking_v1',
        'fixture_pack', 'dummy_messages_seed_v2',
        'booking_id', r.booking_id::text,
        'listing_id', r.listing_id,
        'status', 'booked',
        'scenario', 'static_fixture_booking'
    )
)
FROM resolved r;

DO $$
DECLARE
    v_seq_name text;
    v_max_id bigint;
BEGIN
    SELECT pg_get_serial_sequence('public.booking_registers', 'id') INTO v_seq_name;
    IF v_seq_name IS NOT NULL THEN
        SELECT COALESCE(MAX(id), 0) INTO v_max_id FROM public.booking_registers;
        IF v_max_id > 0 THEN
            EXECUTE format('SELECT setval(%L, %s, true)', v_seq_name, v_max_id);
        END IF;
    END IF;
END $$;

COMMIT;
