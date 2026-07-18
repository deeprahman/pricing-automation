-- ============================================================================
-- Dummy Fixture Seed (Base)
--
-- Seeds extension-scanner-oriented bookings for fixture presets.
-- Booking IDs: 54000001..54000120
-- Thread IDs : 94000001..94000120
--
-- Uses public.upsert_booking_register so stay metrics are computed through the
-- same logic path as production.
-- ============================================================================

BEGIN;

DO $$
BEGIN
    IF to_regclass('public.platforms') IS NULL THEN
        RAISE EXCEPTION 'Missing table: platforms. Run property_platform_sql.sql first.';
    END IF;

    IF to_regclass('public.properties') IS NULL THEN
        RAISE EXCEPTION 'Missing table: properties. Run property_platform_sql.sql first.';
    END IF;

    IF to_regclass('public.platform_property_lookup') IS NULL THEN
        RAISE EXCEPTION 'Missing table: platform_property_lookup. Run property_platform_sql.sql first.';
    END IF;

    IF to_regclass('public.booking_registers') IS NULL THEN
        RAISE EXCEPTION 'Missing table: booking_registers. Run booking_registers.sql first.';
    END IF;

    IF to_regclass('public.messages') IS NULL THEN
        RAISE EXCEPTION 'Missing table: messages. Run message_processing.sql first.';
    END IF;

    IF to_regclass('public.message_class_lookup') IS NULL THEN
        RAISE EXCEPTION 'Missing table: message_class_lookup. Run message_processing.sql first.';
    END IF;

    IF to_regclass('public.message_processing_status') IS NULL THEN
        RAISE EXCEPTION 'Missing table: message_processing_status. Run message_processing.sql first.';
    END IF;

    IF to_regclass('public.message_thread_progress') IS NULL THEN
        RAISE EXCEPTION 'Missing table: message_thread_progress. Run message_processing.sql first.';
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
END $$;

INSERT INTO public.platforms (name, type, is_active, metadata)
VALUES
    ('OwnerRez', 'pms', TRUE, '{"seed":"extension_scanner_behavior_v1"}'::jsonb),
    ('PriceLabs', 'dpt', TRUE, '{"seed":"extension_scanner_behavior_v1"}'::jsonb),
    ('Wheelhouse', 'dpt', TRUE, '{"seed":"extension_scanner_behavior_v1"}'::jsonb)
ON CONFLICT (name) DO UPDATE
SET type = EXCLUDED.type,
    is_active = TRUE,
    metadata = COALESCE(platforms.metadata, '{}'::jsonb) || EXCLUDED.metadata;

INSERT INTO public.properties (id, descrp)
VALUES
    (1, '{"latitude":"26.66551","longitude":"-80.06345","name":"Parker Ave House","street":"5406 Parker Ave","city":"West Palm Beach","state":"FL","zip":"33405","country":"US"}'::jsonb),
    (2, '{"latitude":"26.61512","longitude":"-80.05781","name":"Olive Ave Retreat","street":"812 Olive Ave","city":"Lake Worth","state":"FL","zip":"33460","country":"US"}'::jsonb),
    (3, '{"latitude":"26.71394","longitude":"-80.05099","name":"Banyan Blvd Bungalow","street":"229 Banyan Blvd","city":"West Palm Beach","state":"FL","zip":"33401","country":"US"}'::jsonb),
    (4, '{"latitude":"26.72010","longitude":"-80.03819","name":"Sunset Ave Villa","street":"150 Sunset Ave","city":"Palm Beach","state":"FL","zip":"33480","country":"US"}'::jsonb),
    (5, '{"latitude":"26.65103","longitude":"-80.05702","name":"Summa St Cottage","street":"419 Summa St","city":"West Palm Beach","state":"FL","zip":"33405","country":"US"}'::jsonb)
ON CONFLICT (id) DO UPDATE
SET descrp = EXCLUDED.descrp;

WITH
    ownerrez AS (SELECT id FROM public.platforms WHERE name = 'OwnerRez'),
    pricelabs AS (SELECT id FROM public.platforms WHERE name = 'PriceLabs'),
    wheelhouse AS (SELECT id FROM public.platforms WHERE name = 'Wheelhouse')
INSERT INTO public.platform_property_lookup (platform_id, properties_ptr, listing_id, metadata)
VALUES
    ((SELECT id FROM ownerrez), 1, 'ownerrez_prop_1', '{"currency_code":"USD","seed":"extension_scanner_behavior_v1"}'::jsonb),
    ((SELECT id FROM ownerrez), 2, 'ownerrez_prop_2', '{"currency_code":"USD","seed":"extension_scanner_behavior_v1"}'::jsonb),
    ((SELECT id FROM ownerrez), 3, 'ownerrez_prop_3', '{"currency_code":"USD","seed":"extension_scanner_behavior_v1"}'::jsonb),
    ((SELECT id FROM ownerrez), 4, 'ownerrez_prop_4', '{"currency_code":"USD","seed":"extension_scanner_behavior_v1"}'::jsonb),
    ((SELECT id FROM ownerrez), 5, 'ownerrez_prop_5', '{"currency_code":"USD","seed":"extension_scanner_behavior_v1"}'::jsonb),
    ((SELECT id FROM pricelabs), 1, 'pricelabs_prop_1', '{"currency_code":"USD","seed":"extension_scanner_behavior_v1"}'::jsonb),
    ((SELECT id FROM pricelabs), 2, 'pricelabs_prop_2', '{"currency_code":"USD","seed":"extension_scanner_behavior_v1"}'::jsonb),
    ((SELECT id FROM pricelabs), 3, 'pricelabs_prop_3', '{"currency_code":"USD","seed":"extension_scanner_behavior_v1"}'::jsonb),
    ((SELECT id FROM wheelhouse), 4, 'wheelhouse_prop_4', '{"currency_code":"USD","seed":"extension_scanner_behavior_v1"}'::jsonb),
    ((SELECT id FROM wheelhouse), 5, 'wheelhouse_prop_5', '{"currency_code":"USD","seed":"extension_scanner_behavior_v1"}'::jsonb)
ON CONFLICT (platform_id, listing_id) DO UPDATE
SET properties_ptr = EXCLUDED.properties_ptr,
    metadata = COALESCE(platform_property_lookup.metadata, '{}'::jsonb) || EXCLUDED.metadata;

WITH pms AS (
    SELECT id AS platform_id FROM public.platforms WHERE name = 'OwnerRez'
), target_messages AS (
    SELECT m.id
    FROM public.messages m
    JOIN pms ON pms.platform_id = m.platform_id
    WHERE m.thread_id BETWEEN 94000001 AND 94000120
       OR m.thread_id BETWEEN 95100001 AND 95100030
)
DELETE FROM public.message_class_lookup mcl
USING target_messages tm
WHERE mcl.message_id = tm.id;

WITH pms AS (
    SELECT id AS platform_id FROM public.platforms WHERE name = 'OwnerRez'
), target_messages AS (
    SELECT m.id
    FROM public.messages m
    JOIN pms ON pms.platform_id = m.platform_id
    WHERE m.thread_id BETWEEN 94000001 AND 94000120
       OR m.thread_id BETWEEN 95100001 AND 95100030
)
DELETE FROM public.message_processing_status mps
USING target_messages tm
WHERE mps.message_id = tm.id;

WITH pms AS (
    SELECT id AS platform_id FROM public.platforms WHERE name = 'OwnerRez'
)
DELETE FROM public.message_thread_progress mtp
USING pms
WHERE mtp.platform_id = pms.platform_id
  AND (
      mtp.thread_id BETWEEN 94000001 AND 94000120
      OR mtp.thread_id BETWEEN 95100001 AND 95100030
  );

WITH pms AS (
    SELECT id AS platform_id FROM public.platforms WHERE name = 'OwnerRez'
)
DELETE FROM public.messages m
USING pms
WHERE m.platform_id = pms.platform_id
  AND (
      m.thread_id BETWEEN 94000001 AND 94000120
      OR m.thread_id BETWEEN 95100001 AND 95100030
  );

DELETE FROM public.booking_registers
WHERE id BETWEEN 54000001 AND 54000120
   OR id BETWEEN 55000001 AND 55000030
   OR metadata->>'seed' IN ('extension_scanner_behavior_v1', 'dummy_static_booking_v1');

WITH
    pms AS (
        SELECT id AS platform_id FROM public.platforms WHERE name = 'OwnerRez'
    ),
    seed_rows AS (
        SELECT
            gs AS n,
            (54000000 + gs)::bigint AS booking_id,
            (94000000 + gs)::bigint AS thread_id,
            (840000000 + gs)::bigint AS guest_id,
            (((gs - 1) % 5) + 1)::int AS property_id,
            CASE
                WHEN gs BETWEEN 1 AND 90 THEN 'inside_window'
                WHEN gs BETWEEN 91 AND 105 THEN 'outside_before_window'
                ELSE 'outside_after_window'
            END AS window_group,
            CASE
                WHEN gs BETWEEN 1 AND 30 THEN 'last_extended_lt_updated_at'
                WHEN gs BETWEEN 31 AND 40 THEN 'last_extended_eq_updated_at'
                WHEN gs BETWEEN 41 AND 60 THEN 'last_extended_gt_updated_at'
                WHEN gs BETWEEN 61 AND 90 THEN 'last_extended_missing'
                WHEN gs BETWEEN 91 AND 105 THEN 'outside_before_window'
                ELSE 'outside_after_window'
            END AS scenario_name,
            CASE
                WHEN gs BETWEEN 1 AND 90 THEN CURRENT_DATE - 25 + (((gs - 1) % 60)::int)
                WHEN gs BETWEEN 91 AND 105 THEN CURRENT_DATE - 75 + (((gs - 91) % 10)::int)
                ELSE CURRENT_DATE + 70 + (((gs - 106) % 10)::int)
            END AS arrival,
            CASE
                WHEN gs BETWEEN 1 AND 90 THEN CURRENT_DATE - 25 + (((gs - 1) % 60)::int) + (3 + (gs % 4))::int
                WHEN gs BETWEEN 91 AND 105 THEN CURRENT_DATE - 75 + (((gs - 91) % 10)::int) + 5
                ELSE CURRENT_DATE + 70 + (((gs - 106) % 10)::int) + 5
            END AS departure,
            CURRENT_TIMESTAMP - INTERVAL '14 days' + make_interval(hours => gs % 24) AS booked_at,
            CASE
                WHEN gs BETWEEN 1 AND 15 THEN 0
                WHEN gs BETWEEN 16 AND 30 THEN 1
                WHEN gs BETWEEN 31 AND 35 THEN 0
                WHEN gs BETWEEN 36 AND 40 THEN 1
                WHEN gs BETWEEN 41 AND 50 THEN 0
                WHEN gs BETWEEN 51 AND 60 THEN 1
                WHEN gs BETWEEN 61 AND 75 THEN 0
                WHEN gs BETWEEN 76 AND 90 THEN 1
                WHEN gs BETWEEN 91 AND 105 THEN (gs % 2)::smallint
                ELSE ((gs + 1) % 2)::smallint
            END AS target_needs_scan
        FROM generate_series(1, 120) AS gs
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
        'seed', 'extension_scanner_behavior_v1',
        'fixture_pack', 'dummy_messages_seed_v2',
        'booking_id', r.booking_id::text,
        'listing_id', r.listing_id,
        'status', 'booked',
        'scenario', r.scenario_name,
        'window_group', r.window_group,
        'target_needs_scan', r.target_needs_scan
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
