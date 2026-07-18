\set ON_ERROR_STOP on
\pset pager off

-- ============================================================================
-- booking_registers regression test suite
-- ============================================================================
-- Purpose:
--   Runs a broad SQL-only regression suite for booking_registers and related
--   scanner/metadata behavior.
--
-- How to run:
--   psql "$DATABASE_URL" -f test_booking_registers.sql
--
-- Expected prerequisites:
--   - property/platform tables have at least one valid platform_property_lookup
--     row with platform_id, properties_ptr, and listing_id.
--   - Run the booking_registers base DDL and related migrations first.
--
-- Safety:
--   - Test rows are tagged in metadata.test_suite and cleaned up at start/end.
--   - Existing non-test rows are not modified.
--   - No external extensions are required.
-- ============================================================================

SET search_path = pg_temp, public;
SET client_min_messages = NOTICE;

DROP TABLE IF EXISTS pg_temp.br_test_results;
CREATE TEMP TABLE br_test_results (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    test_name   TEXT NOT NULL,
    passed      BOOLEAN NOT NULL,
    detail      TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
) ON COMMIT PRESERVE ROWS;

CREATE OR REPLACE FUNCTION pg_temp.br_assert(
    p_test_name TEXT,
    p_condition BOOLEAN,
    p_detail TEXT DEFAULT NULL
) RETURNS VOID AS $$
BEGIN
    INSERT INTO br_test_results (test_name, passed, detail)
    VALUES (p_test_name, COALESCE(p_condition, FALSE), p_detail);

    IF COALESCE(p_condition, FALSE) THEN
        RAISE NOTICE 'PASS: %', p_test_name;
    ELSE
        RAISE WARNING 'FAIL: % - %', p_test_name, COALESCE(p_detail, 'no detail');
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.br_assert_raises(
    p_test_name TEXT,
    p_sql TEXT,
    p_expected_sqlstates TEXT[] DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
    v_state TEXT;
    v_message TEXT;
    v_expected TEXT := COALESCE(array_to_string(p_expected_sqlstates, ','), 'any error');
BEGIN
    BEGIN
        EXECUTE p_sql;
        INSERT INTO br_test_results (test_name, passed, detail)
        VALUES (p_test_name, FALSE, 'expected SQLSTATE ' || v_expected || ', but statement succeeded');
        RAISE WARNING 'FAIL: % - expected SQLSTATE %, but statement succeeded', p_test_name, v_expected;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS
            v_state = RETURNED_SQLSTATE,
            v_message = MESSAGE_TEXT;

        IF p_expected_sqlstates IS NULL
           OR cardinality(p_expected_sqlstates) = 0
           OR v_state = ANY (p_expected_sqlstates)
        THEN
            INSERT INTO br_test_results (test_name, passed, detail)
            VALUES (p_test_name, TRUE, 'caught SQLSTATE ' || v_state || ': ' || v_message);
            RAISE NOTICE 'PASS: % - caught SQLSTATE %', p_test_name, v_state;
        ELSE
            INSERT INTO br_test_results (test_name, passed, detail)
            VALUES (p_test_name, FALSE, 'expected SQLSTATE ' || v_expected || ', got ' || v_state || ': ' || v_message);
            RAISE WARNING 'FAIL: % - expected SQLSTATE %, got %: %', p_test_name, v_expected, v_state, v_message;
        END IF;
    END;
END;
$$ LANGUAGE plpgsql;

-- --------------------------------------------------------------------------
-- 1. Static prerequisites
-- --------------------------------------------------------------------------
SELECT pg_temp.br_assert('prereq: booking_registers table exists', to_regclass('public.booking_registers') IS NOT NULL, NULL);
SELECT pg_temp.br_assert('prereq: platforms table exists', to_regclass('public.platforms') IS NOT NULL, NULL);
SELECT pg_temp.br_assert('prereq: properties table exists', to_regclass('public.properties') IS NOT NULL, NULL);
SELECT pg_temp.br_assert('prereq: platform_property_lookup table exists', to_regclass('public.platform_property_lookup') IS NOT NULL, NULL);

DO $$
DECLARE
    v_failed INT;
BEGIN
    SELECT COUNT(*) INTO v_failed
    FROM br_test_results
    WHERE NOT passed;

    IF v_failed > 0 THEN
        RAISE EXCEPTION 'Stopping early: % prerequisite object test(s) failed.', v_failed;
    END IF;
END $$;

SELECT pg_temp.br_assert(
    'prereq: needs_scan column exists',
    EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'booking_registers'
          AND column_name = 'needs_scan'
    ),
    'Run booking_registers_needs_scan_migration.sql.'
);

SELECT pg_temp.br_assert(
    'prereq: create_booking_register exists',
    EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'create_booking_register'
          AND p.pronargs = 10
    ),
    NULL
);

SELECT pg_temp.br_assert(
    'prereq: update_booking_register exists',
    EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'update_booking_register'
          AND p.pronargs = 10
    ),
    NULL
);

SELECT pg_temp.br_assert(
    'prereq: upsert_booking_register exists',
    EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'upsert_booking_register'
          AND p.pronargs = 10
    ),
    NULL
);

SELECT pg_temp.br_assert(
    'prereq: get_booking_net_stay_change exists',
    EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'get_booking_net_stay_change'
          AND p.pronargs = 1
    ),
    'Run booking_registers_stay_tracking_migration.sql.'
);

SELECT pg_temp.br_assert(
    'prereq: checkout scanner exists',
    EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'scan_booking_registers_for_checkout'
          AND p.pronargs = 3
    ),
    'Run scanners_for_booking_registers.sql.'
);

SELECT pg_temp.br_assert(
    'prereq: queue-driven extension scanner exists',
    EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'scan_booking_registers_for_extension'
          AND p.pronargs = 4
    ),
    'Run booking_registers_extension_scanner_needs_scan_migration.sql and booking_registers_needs_scan_manual_override_migration.sql.'
);

SELECT pg_temp.br_assert(
    'prereq: mark_booking_register_extension_scanned exists',
    EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'mark_booking_register_extension_scanned'
          AND p.pronargs = 1
    ),
    'Run booking_registers_needs_scan_manual_override_migration.sql.'
);

SELECT pg_temp.br_assert(
    'prereq: mark_booking_register_extension_needs_scan exists',
    EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'mark_booking_register_extension_needs_scan'
          AND p.pronargs = 1
    ),
    'Run booking_registers_needs_scan_manual_override_migration.sql.'
);

SELECT pg_temp.br_assert(
    'prereq: set_booking_register_needs_scan exists',
    EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'set_booking_register_needs_scan'
          AND p.pronargs = 2
    ),
    'Run booking_registers_needs_scan_manual_override_migration.sql.'
);

SELECT pg_temp.br_assert(
    'prereq: updated_at trigger exists',
    EXISTS (
        SELECT 1
        FROM pg_trigger
        WHERE tgrelid = 'public.booking_registers'::regclass
          AND tgname = 'trg_booking_registers_updated_at'
          AND NOT tgisinternal
    ),
    NULL
);

SELECT pg_temp.br_assert(
    'prereq: previous/stay tracking trigger exists',
    EXISTS (
        SELECT 1
        FROM pg_trigger
        WHERE tgrelid = 'public.booking_registers'::regclass
          AND tgname = 'trg_booking_registers_track_core_changes'
          AND NOT tgisinternal
    ),
    'Run previous/stay tracking migration.'
);

SELECT pg_temp.br_assert(
    'prereq: legacy needs_scan trigger is absent',
    NOT EXISTS (
        SELECT 1
        FROM pg_trigger
        WHERE tgrelid = 'public.booking_registers'::regclass
          AND tgname = 'trg_booking_registers_zz_needs_scan'
          AND NOT tgisinternal
    ),
    'Run booking_registers_needs_scan_manual_override_migration.sql.'
);

SELECT pg_temp.br_assert(
    'prereq: needs_scan guard trigger exists',
    EXISTS (
        SELECT 1
        FROM pg_trigger
        WHERE tgrelid = 'public.booking_registers'::regclass
          AND tgname = 'trg_booking_registers_needs_scan_guard'
          AND NOT tgisinternal
    ),
    'Run booking_registers_needs_scan_manual_override_migration.sql.'
);

SELECT pg_temp.br_assert(
    'prereq: exact ppl validator trigger exists',
    EXISTS (
        SELECT 1
        FROM pg_trigger
        WHERE tgrelid = 'public.booking_registers'::regclass
          AND tgname = 'trg_booking_registers_validate_ppl'
          AND NOT tgisinternal
    ),
    NULL
);

-- Index coverage checks. These fail fast on missing performance-critical paths.
SELECT pg_temp.br_assert('index: arrival index exists', to_regclass('public.idx_booking_registers_arrival') IS NOT NULL, NULL);
SELECT pg_temp.br_assert('index: departure index exists', to_regclass('public.idx_booking_registers_departure') IS NOT NULL, NULL);
SELECT pg_temp.br_assert('index: checkout scanner index exists', to_regclass('public.idx_booking_registers_checkout_scanner') IS NOT NULL, 'Run scanners_for_booking_registers.sql.');
SELECT pg_temp.br_assert('index: needs_scan partial index exists', to_regclass('public.idx_booking_registers_needs_scan_id') IS NOT NULL, 'Run booking_registers_needs_scan_migration.sql.');
SELECT pg_temp.br_assert('index: platform/external booking unique index exists', to_regclass('public.uq_booking_registers_platform_external_booking_id') IS NOT NULL, NULL);
SELECT pg_temp.br_assert('index: metadata GIN index exists', to_regclass('public.idx_booking_registers_metadata_gin') IS NOT NULL, NULL);
SELECT pg_temp.br_assert('index: thread_ids_json GIN index exists', to_regclass('public.idx_booking_registers_thread_ids_gin') IS NOT NULL, NULL);

DO $$
DECLARE
    v_failed INT;
BEGIN
    SELECT COUNT(*) INTO v_failed
    FROM br_test_results
    WHERE NOT passed;

    IF v_failed > 0 THEN
        RAISE EXCEPTION 'Stopping early: % prerequisite test(s) failed.', v_failed;
    END IF;
END $$;

-- --------------------------------------------------------------------------
-- 2. Test context and cleanup
-- --------------------------------------------------------------------------
DELETE FROM public.booking_registers
WHERE metadata->>'test_suite' LIKE '__booking_registers_regression__%';

DROP TABLE IF EXISTS pg_temp.br_test_ctx;
CREATE TEMP TABLE br_test_ctx AS
SELECT
    ('__booking_registers_regression__' || txid_current()::TEXT) AS run_id,
    ppl.id::BIGINT AS ppl_id,
    ppl.platform_id::INT AS platform_id,
    ppl.properties_ptr::INT AS property_id,
    BTRIM(ppl.listing_id::TEXT) AS listing_id
FROM public.platform_property_lookup ppl
JOIN public.platforms pf ON pf.id = ppl.platform_id
JOIN public.properties pr ON pr.id = ppl.properties_ptr
WHERE ppl.platform_id IS NOT NULL
  AND ppl.properties_ptr IS NOT NULL
  AND NULLIF(BTRIM(ppl.listing_id::TEXT), '') IS NOT NULL
ORDER BY ppl.id
LIMIT 1;

SELECT pg_temp.br_assert(
    'fixture: usable platform_property_lookup row exists',
    EXISTS (SELECT 1 FROM br_test_ctx),
    'Seed platform_property_lookup with a valid platform_id, properties_ptr, and listing_id before running this suite.'
);

DO $$
DECLARE
    v_failed INT;
BEGIN
    SELECT COUNT(*) INTO v_failed
    FROM br_test_results
    WHERE NOT passed;

    IF v_failed > 0 THEN
        RAISE EXCEPTION 'Stopping early: fixture setup failed.';
    END IF;
END $$;

DROP TABLE IF EXISTS pg_temp.br_test_ids;
CREATE TEMP TABLE br_test_ids (
    name TEXT PRIMARY KEY,
    id BIGINT NOT NULL
) ON COMMIT PRESERVE ROWS;

-- --------------------------------------------------------------------------
-- 3. Unit-level helper function checks
-- --------------------------------------------------------------------------
SELECT pg_temp.br_assert(
    'helper: resolve_booking_register_lookup returns exact mapping',
    EXISTS (
        SELECT 1
        FROM br_test_ctx ctx
        CROSS JOIN LATERAL public.resolve_booking_register_lookup(ctx.platform_id, ctx.listing_id) r
        WHERE r.ppl_id = ctx.ppl_id
          AND r.property_id = ctx.property_id
    ),
    NULL
);

SELECT pg_temp.br_assert(
    'helper: normalize_booking_register_metadata adds listing_id',
    EXISTS (
        SELECT 1
        FROM br_test_ctx ctx
        WHERE public.normalize_booking_register_metadata('{"a": 1}'::jsonb, ctx.listing_id)->>'listing_id' = ctx.listing_id
    ),
    NULL
);

SELECT pg_temp.br_assert(
    'helper: enrich_booking_register_stay_metrics calculates stay_length and booking_window',
    (
        public.enrich_booking_register_stay_metrics(
            '{}'::jsonb,
            DATE '2026-06-10',
            DATE '2026-06-14',
            TIMESTAMPTZ '2026-05-27T00:00:00Z'
        )->>'stay_length' = '4'
        AND public.enrich_booking_register_stay_metrics(
            '{}'::jsonb,
            DATE '2026-06-10',
            DATE '2026-06-14',
            TIMESTAMPTZ '2026-05-27T00:00:00Z'
        )->>'booking_window' = '14'
    ),
    NULL
);

SELECT pg_temp.br_assert_raises(
    'helper error: resolve requires platform_id',
    format('SELECT * FROM public.resolve_booking_register_lookup(NULL, %L)', (SELECT listing_id FROM br_test_ctx)),
    ARRAY['22023']
);

SELECT pg_temp.br_assert_raises(
    'helper error: resolve requires listing_id',
    format('SELECT * FROM public.resolve_booking_register_lookup(%s, NULL)', (SELECT platform_id FROM br_test_ctx)),
    ARRAY['22023']
);

SELECT pg_temp.br_assert_raises(
    'helper error: normalize metadata rejects scalar JSON',
    'SELECT public.normalize_booking_register_metadata(''[]''::jsonb, ''x'')',
    ARRAY['22023']
);

-- --------------------------------------------------------------------------
-- 4. Create/read/update behavior
-- --------------------------------------------------------------------------
INSERT INTO br_test_ids (name, id)
SELECT
    'base',
    (
        public.create_booking_register(
            p_type => 'booking',
            p_arrival => DATE '2026-06-10',
            p_departure => DATE '2026-06-14',
            p_booked_at => TIMESTAMPTZ '2026-05-27T00:00:00Z',
            p_guest_id => 900000001,
            p_platform_id => ctx.platform_id,
            p_listing_id => ctx.listing_id,
            p_thread_ids_json => jsonb_build_array('thread-base', ctx.run_id),
            p_metadata => jsonb_build_object(
                'booking_id', 'BRTEST_BASE_' || ctx.run_id,
                'test_suite', ctx.run_id,
                'case', 'base'
            )
        )
    ).id
FROM br_test_ctx ctx;

SELECT pg_temp.br_assert(
    'create: row inserted',
    EXISTS (
        SELECT 1
        FROM public.booking_registers br
        JOIN br_test_ids ids ON ids.id = br.id AND ids.name = 'base'
    ),
    NULL
);

SELECT pg_temp.br_assert(
    'create: lookup fields match exact mapping',
    EXISTS (
        SELECT 1
        FROM public.booking_registers br
        JOIN br_test_ids ids ON ids.id = br.id AND ids.name = 'base'
        JOIN br_test_ctx ctx ON TRUE
        WHERE br.ppl_id = ctx.ppl_id
          AND br.platform_id = ctx.platform_id
          AND br.property_id = ctx.property_id
          AND br.metadata->>'listing_id' = ctx.listing_id
    ),
    NULL
);

SELECT pg_temp.br_assert(
    'create: metadata stay metrics are enriched',
    EXISTS (
        SELECT 1
        FROM public.booking_registers br
        JOIN br_test_ids ids ON ids.id = br.id AND ids.name = 'base'
        WHERE br.metadata->>'stay_length' = '4'
          AND br.metadata->>'booking_window' = '14'
    ),
    'If this fails, the final installed create_booking_register is not enriching stay metrics.'
);

SELECT pg_temp.br_assert(
    'create: new row is queued for scan',
    EXISTS (
        SELECT 1
        FROM public.booking_registers br
        JOIN br_test_ids ids ON ids.id = br.id AND ids.name = 'base'
        WHERE br.needs_scan = 1
    ),
    NULL
);

SELECT pg_temp.br_assert(
    'read: get_booking_register_by_id returns created row',
    EXISTS (
        SELECT 1
        FROM br_test_ids ids
        CROSS JOIN LATERAL public.get_booking_register_by_id(ids.id) br
        WHERE ids.name = 'base'
          AND br.id = ids.id
          AND br.metadata->>'case' = 'base'
    ),
    NULL
);

SELECT pg_sleep(0.03);

DO $$
DECLARE
    v_base_id BIGINT;
BEGIN
    SELECT id INTO v_base_id FROM br_test_ids WHERE name = 'base';

    PERFORM public.update_booking_register(
        p_id => v_base_id,
        p_departure => DATE '2026-06-16',
        p_metadata => '{"source":"update_departure"}'::jsonb
    );
END $$;

SELECT pg_temp.br_assert(
    'update: departure changed and metrics refreshed',
    EXISTS (
        SELECT 1
        FROM public.booking_registers br
        JOIN br_test_ids ids ON ids.id = br.id AND ids.name = 'base'
        WHERE br.departure = DATE '2026-06-16'
          AND br.metadata->>'stay_length' = '6'
          AND br.metadata->>'source' = 'update_departure'
    ),
    NULL
);

SELECT pg_temp.br_assert(
    'tracking: previous departure captured',
    EXISTS (
        SELECT 1
        FROM public.booking_registers br
        JOIN br_test_ids ids ON ids.id = br.id AND ids.name = 'base'
        WHERE br.metadata #> '{previous,departure}' ? '2026-06-14'
          AND br.metadata #> '{previous,changed_fields}' ? 'departure'
    ),
    NULL
);

SELECT pg_temp.br_assert(
    'tracking: stay extension delta captured',
    EXISTS (
        SELECT 1
        FROM public.booking_registers br
        JOIN br_test_ids ids ON ids.id = br.id AND ids.name = 'base'
        WHERE br.metadata->'stay_extended' @> '[2]'::jsonb
          AND br.metadata #> '{previous,changed_fields}' ? 'stay_extended'
    ),
    NULL
);

SELECT pg_sleep(0.03);

DO $$
DECLARE
    v_base_id BIGINT;
BEGIN
    SELECT id INTO v_base_id FROM br_test_ids WHERE name = 'base';

    PERFORM public.update_booking_register(
        p_id => v_base_id,
        p_arrival => DATE '2026-06-09'
    );
END $$;

SELECT pg_temp.br_assert(
    'tracking: previous arrival captured',
    EXISTS (
        SELECT 1
        FROM public.booking_registers br
        JOIN br_test_ids ids ON ids.id = br.id AND ids.name = 'base'
        WHERE br.arrival = DATE '2026-06-09'
          AND br.metadata #> '{previous,arrival}' ? '2026-06-10'
    ),
    NULL
);

SELECT pg_sleep(0.03);

DO $$
DECLARE
    v_base_id BIGINT;
BEGIN
    SELECT id INTO v_base_id FROM br_test_ids WHERE name = 'base';

    PERFORM public.update_booking_register(
        p_id => v_base_id,
        p_departure => DATE '2026-06-13'
    );
END $$;

SELECT pg_temp.br_assert(
    'tracking: stay contraction delta captured',
    EXISTS (
        SELECT 1
        FROM public.booking_registers br
        JOIN br_test_ids ids ON ids.id = br.id AND ids.name = 'base'
        WHERE br.departure = DATE '2026-06-13'
          AND br.metadata->'stay_contracted' @> '[3]'::jsonb
          AND br.metadata #> '{previous,changed_fields}' ? 'stay_contracted'
    ),
    NULL
);

-- Retention: previous.* arrays keep the most recent 5 values.
DO $$
DECLARE
    v_base_id BIGINT;
    v_arrivals DATE[] := ARRAY[
        DATE '2026-06-08',
        DATE '2026-06-07',
        DATE '2026-06-06',
        DATE '2026-06-05',
        DATE '2026-06-04',
        DATE '2026-06-03'
    ];
    v_i INT;
BEGIN
    SELECT id INTO v_base_id FROM br_test_ids WHERE name = 'base';

    FOR v_i IN 1..array_length(v_arrivals, 1) LOOP
        PERFORM public.update_booking_register(
            p_id => v_base_id,
            p_arrival => v_arrivals[v_i]
        );
    END LOOP;
END $$;

SELECT pg_temp.br_assert(
    'tracking: previous arrival retention is capped at 5',
    EXISTS (
        SELECT 1
        FROM public.booking_registers br
        JOIN br_test_ids ids ON ids.id = br.id AND ids.name = 'base'
        WHERE jsonb_array_length(br.metadata #> '{previous,arrival}') = 5
          AND br.metadata #> '{previous,arrival}' ? '2026-06-04'
          AND NOT (br.metadata #> '{previous,arrival}' ? '2026-06-10')
    ),
    NULL
);

-- --------------------------------------------------------------------------
-- 5. updated_at and needs_scan manual-override behavior
-- --------------------------------------------------------------------------
DROP TABLE IF EXISTS pg_temp.br_before;
CREATE TEMP TABLE br_before AS
SELECT br.id, br.updated_at, br.metadata
FROM public.booking_registers br
JOIN br_test_ids ids ON ids.id = br.id AND ids.name = 'base';

UPDATE public.booking_registers br
SET metadata = br.metadata || '{"metadata_only": true}'::jsonb
FROM br_test_ids ids
WHERE ids.name = 'base'
  AND ids.id = br.id;

SELECT pg_temp.br_assert(
    'updated_at: metadata-only update does not bump updated_at',
    EXISTS (
        SELECT 1
        FROM public.booking_registers br
        JOIN br_before b ON b.id = br.id
        WHERE br.updated_at = b.updated_at
          AND br.metadata->>'metadata_only' = 'true'
          AND br.needs_scan = 1
    ),
    'Metadata-only changes should preserve updated_at and not implicitly change needs_scan.'
);

SELECT pg_sleep(0.03);
TRUNCATE TABLE br_before;
INSERT INTO br_before (id, updated_at, metadata)
SELECT br.id, br.updated_at, br.metadata
FROM public.booking_registers br
JOIN br_test_ids ids ON ids.id = br.id AND ids.name = 'base';

UPDATE public.booking_registers br
SET guest_id = br.guest_id + 1
FROM br_test_ids ids
WHERE ids.name = 'base'
  AND ids.id = br.id;

SELECT pg_temp.br_assert(
    'updated_at: core update bumps updated_at',
    EXISTS (
        SELECT 1
        FROM public.booking_registers br
        JOIN br_before b ON b.id = br.id
        WHERE br.updated_at > b.updated_at
    ),
    NULL
);

-- Clear via approved helper and verify no metadata side effects.
DROP TABLE IF EXISTS pg_temp.br_metadata_before_clear;
CREATE TEMP TABLE br_metadata_before_clear AS
SELECT br.id, br.metadata
FROM public.booking_registers br
JOIN br_test_ids ids ON ids.id = br.id AND ids.name = 'base';

SELECT pg_temp.br_assert(
    'needs_scan: mark scanned helper returns true for queued row',
    EXISTS (
        SELECT 1
        FROM br_test_ids ids
        WHERE ids.name = 'base'
          AND public.mark_booking_register_extension_scanned(ids.id) = TRUE
    ),
    NULL
);

SELECT pg_temp.br_assert(
    'needs_scan: mark scanned helper sets needs_scan to 0 and leaves metadata unchanged',
    EXISTS (
        SELECT 1
        FROM public.booking_registers br
        JOIN br_metadata_before_clear b ON b.id = br.id
        JOIN br_test_ids ids ON ids.id = br.id AND ids.name = 'base'
        WHERE br.needs_scan = 0
          AND br.metadata = b.metadata
    ),
    NULL
);

SELECT pg_temp.br_assert(
    'needs_scan: mark scanned helper returns false when already clear',
    EXISTS (
        SELECT 1
        FROM br_test_ids ids
        WHERE ids.name = 'base'
          AND public.mark_booking_register_extension_scanned(ids.id) = FALSE
    ),
    NULL
);

SELECT pg_sleep(0.03);
TRUNCATE TABLE br_before;
INSERT INTO br_before (id, updated_at, metadata)
SELECT br.id, br.updated_at, br.metadata
FROM public.booking_registers br
JOIN br_test_ids ids ON ids.id = br.id AND ids.name = 'base';

UPDATE public.booking_registers br
SET metadata = br.metadata || '{"requeue_after_clear": true}'::jsonb
FROM br_test_ids ids
WHERE ids.name = 'base'
  AND ids.id = br.id;

SELECT pg_temp.br_assert(
    'needs_scan: metadata update after clear does not requeue row',
    EXISTS (
        SELECT 1
        FROM public.booking_registers br
        JOIN br_before b ON b.id = br.id
        JOIN br_test_ids ids ON ids.id = br.id AND ids.name = 'base'
        WHERE br.needs_scan = 0
          AND br.updated_at = b.updated_at
          AND br.metadata->>'requeue_after_clear' = 'true'
    ),
    NULL
);

SELECT pg_temp.br_assert_raises(
    'needs_scan guard: direct UPDATE is blocked',
    format('UPDATE public.booking_registers SET needs_scan = 1 WHERE id = %s', (SELECT id FROM br_test_ids WHERE name = 'base')),
    ARRAY['42501']
);

SELECT pg_temp.br_assert(
    'needs_scan: mark needs-scan helper returns true when setting from 0 to 1',
    EXISTS (
        SELECT 1
        FROM br_test_ids ids
        WHERE ids.name = 'base'
          AND public.mark_booking_register_extension_needs_scan(ids.id) = TRUE
    ),
    NULL
);

SELECT pg_temp.br_assert(
    'needs_scan: mark needs-scan helper returns false when already set',
    EXISTS (
        SELECT 1
        FROM br_test_ids ids
        WHERE ids.name = 'base'
          AND public.mark_booking_register_extension_needs_scan(ids.id) = FALSE
    ),
    NULL
);

SELECT pg_temp.br_assert_raises(
    'needs_scan setter: rejects non 0/1 values',
    format('SELECT public.set_booking_register_needs_scan(%s, 2)', (SELECT id FROM br_test_ids WHERE name = 'base')),
    ARRAY['22023']
);

-- --------------------------------------------------------------------------
-- 6. Controlled net stay change summary
-- --------------------------------------------------------------------------
INSERT INTO br_test_ids (name, id)
SELECT
    'net_change',
    (
        public.create_booking_register(
            p_type => 'booking',
            p_arrival => DATE '2026-07-01',
            p_departure => DATE '2026-07-03',
            p_booked_at => TIMESTAMPTZ '2026-06-01T00:00:00Z',
            p_guest_id => 900000002,
            p_platform_id => ctx.platform_id,
            p_listing_id => ctx.listing_id,
            p_thread_ids_json => jsonb_build_array('thread-net', ctx.run_id),
            p_metadata => jsonb_build_object(
                'booking_id', 'BRTEST_NET_' || ctx.run_id,
                'test_suite', ctx.run_id,
                'case', 'net_change'
            )
        )
    ).id
FROM br_test_ctx ctx;

DO $$
DECLARE
    v_id BIGINT;
BEGIN
    SELECT id INTO v_id FROM br_test_ids WHERE name = 'net_change';

    PERFORM public.update_booking_register(p_id => v_id, p_departure => DATE '2026-07-06'); -- +3
    PERFORM public.update_booking_register(p_id => v_id, p_departure => DATE '2026-07-05'); -- -1
END $$;

SELECT pg_temp.br_assert(
    'stay summary: get_booking_net_stay_change returns correct totals',
    EXISTS (
        SELECT 1
        FROM br_test_ids ids
        CROSS JOIN LATERAL public.get_booking_net_stay_change(ids.id) s
        WHERE ids.name = 'net_change'
          AND s.current_stay = 4
          AND s.net_change = 2
          AND s.total_extended = 3
          AND s.total_contracted = 1
          AND s.extension_count = 1
          AND s.contraction_count = 1
          AND s.net_direction = 'NET_EXTENSION'
    ),
    NULL
);

-- --------------------------------------------------------------------------
-- 7. Upsert behavior and uniqueness
-- --------------------------------------------------------------------------
INSERT INTO br_test_ids (name, id)
SELECT
    'upsert_first',
    (
        public.upsert_booking_register(
            p_id => NULL,
            p_type => 'booking',
            p_arrival => DATE '2026-08-01',
            p_departure => DATE '2026-08-05',
            p_booked_at => TIMESTAMPTZ '2026-07-01T00:00:00Z',
            p_guest_id => 900000003,
            p_platform_id => ctx.platform_id,
            p_listing_id => ctx.listing_id,
            p_thread_ids_json => jsonb_build_array('thread-upsert', ctx.run_id),
            p_metadata => jsonb_build_object(
                'booking_id', 'BRTEST_UPSERT_' || ctx.run_id,
                'test_suite', ctx.run_id,
                'case', 'upsert',
                'upsert_marker', 'first'
            )
        )
    ).id
FROM br_test_ctx ctx;

INSERT INTO br_test_ids (name, id)
SELECT
    'upsert_second',
    (
        public.upsert_booking_register(
            p_id => NULL,
            p_type => 'booking',
            p_arrival => DATE '2026-08-01',
            p_departure => DATE '2026-08-06',
            p_booked_at => TIMESTAMPTZ '2026-07-01T00:00:00Z',
            p_guest_id => 900000004,
            p_platform_id => ctx.platform_id,
            p_listing_id => ctx.listing_id,
            p_thread_ids_json => jsonb_build_array('thread-upsert-2', ctx.run_id),
            p_metadata => jsonb_build_object(
                'booking_id', 'BRTEST_UPSERT_' || ctx.run_id,
                'upsert_marker', 'second'
            )
        )
    ).id
FROM br_test_ctx ctx;

SELECT pg_temp.br_assert(
    'upsert: external booking id updates existing row when p_id is NULL',
    EXISTS (
        SELECT 1
        FROM br_test_ids a
        JOIN br_test_ids b ON b.name = 'upsert_second'
        JOIN public.booking_registers br ON br.id = a.id
        WHERE a.name = 'upsert_first'
          AND a.id = b.id
          AND br.departure = DATE '2026-08-06'
          AND br.guest_id = 900000004
          AND br.metadata->>'upsert_marker' = 'second'
          AND br.metadata->>'test_suite' LIKE '__booking_registers_regression__%'
    ),
    NULL
);

SELECT pg_temp.br_assert(
    'upsert: unique platform/external booking id has only one row',
    EXISTS (
        SELECT 1
        FROM br_test_ctx ctx
        WHERE (
            SELECT COUNT(*)
            FROM public.booking_registers br
            WHERE br.platform_id = ctx.platform_id
              AND br.metadata->>'booking_id' = 'BRTEST_UPSERT_' || ctx.run_id
        ) = 1
    ),
    NULL
);

SELECT pg_temp.br_assert_raises(
    'unique constraint: direct duplicate create fails',
    format(
        $fmt$
        SELECT public.create_booking_register(
            p_type => 'booking',
            p_arrival => DATE '2026-08-10',
            p_departure => DATE '2026-08-12',
            p_booked_at => TIMESTAMPTZ '2026-07-01T00:00:00Z',
            p_guest_id => 900000005,
            p_platform_id => %s,
            p_listing_id => %L,
            p_thread_ids_json => %L::jsonb,
            p_metadata => %L::jsonb
        )
        $fmt$,
        (SELECT platform_id FROM br_test_ctx),
        (SELECT listing_id FROM br_test_ctx),
        '["thread-duplicate"]',
        jsonb_build_object(
            'booking_id', 'BRTEST_UPSERT_' || (SELECT run_id FROM br_test_ctx),
            'test_suite', (SELECT run_id FROM br_test_ctx),
            'case', 'duplicate'
        )::TEXT
    ),
    ARRAY['23505']
);

-- --------------------------------------------------------------------------
-- 8. Lookup/list functions
-- --------------------------------------------------------------------------
SELECT pg_temp.br_assert(
    'lookup: get by metadata booking_id finds upserted row',
    EXISTS (
        SELECT 1
        FROM br_test_ctx ctx
        CROSS JOIN LATERAL public.get_booking_registers_by_metadata_booking_id(
            'BRTEST_UPSERT_' || ctx.run_id,
            ctx.platform_id,
            10,
            NULL
        ) br
        JOIN br_test_ids ids ON ids.name = 'upsert_first' AND ids.id = br.id
    ),
    NULL
);

SELECT pg_temp.br_assert(
    'lookup: get by metadata listing_id finds test rows',
    EXISTS (
        SELECT 1
        FROM br_test_ctx ctx
        CROSS JOIN LATERAL public.get_booking_registers_by_metadata_listing_id(
            ctx.listing_id,
            ctx.platform_id,
            50,
            NULL
        ) br
        WHERE br.metadata->>'test_suite' = ctx.run_id
    ),
    NULL
);

SELECT pg_temp.br_assert(
    'lookup: get by platform_id finds test rows',
    EXISTS (
        SELECT 1
        FROM br_test_ctx ctx
        CROSS JOIN LATERAL public.get_booking_registers_by_platform_id(
            ctx.platform_id,
            500,
            (SELECT COALESCE(MAX(ids.id), 0) + 1 FROM br_test_ids ids)
        ) br
        WHERE br.metadata->>'test_suite' = ctx.run_id
    ),
    NULL
);

SELECT pg_temp.br_assert(
    'lookup: find_booking_registers respects limit clamp',
    (
        SELECT COUNT(*) <= 1
        FROM br_test_ctx ctx
        CROSS JOIN LATERAL public.find_booking_registers(
            p_platform_id => ctx.platform_id,
            p_metadata_listing_id => ctx.listing_id,
            p_limit => 1,
            p_cursor => NULL
        ) br
    ),
    NULL
);

-- --------------------------------------------------------------------------
-- 9. Scanner behavior
-- --------------------------------------------------------------------------
INSERT INTO br_test_ids (name, id)
SELECT
    'checkout_ok',
    (
        public.create_booking_register(
            p_type => 'booking',
            p_arrival => DATE '2026-10-05',
            p_departure => DATE '2026-10-10',
            p_booked_at => TIMESTAMPTZ '2026-09-01T00:00:00Z',
            p_guest_id => 900000006,
            p_platform_id => ctx.platform_id,
            p_listing_id => ctx.listing_id,
            p_thread_ids_json => jsonb_build_array('thread-checkout-ok', ctx.run_id),
            p_metadata => jsonb_build_object(
                'booking_id', 'BRTEST_CHECKOUT_OK_' || ctx.run_id,
                'test_suite', ctx.run_id,
                'case', 'checkout_ok'
            )
        )
    ).id
FROM br_test_ctx ctx;

INSERT INTO br_test_ids (name, id)
SELECT
    'checkout_cancelled',
    (
        public.create_booking_register(
            p_type => 'booking',
            p_arrival => DATE '2026-10-05',
            p_departure => DATE '2026-10-10',
            p_booked_at => TIMESTAMPTZ '2026-09-01T00:00:00Z',
            p_guest_id => 900000007,
            p_platform_id => ctx.platform_id,
            p_listing_id => ctx.listing_id,
            p_thread_ids_json => jsonb_build_array('thread-checkout-cancelled', ctx.run_id),
            p_metadata => jsonb_build_object(
                'booking_id', 'BRTEST_CHECKOUT_CANCELLED_' || ctx.run_id,
                'test_suite', ctx.run_id,
                'case', 'checkout_cancelled',
                'bso', jsonb_build_object('cancellation', jsonb_build_object('cancelled', TRUE))
            )
        )
    ).id
FROM br_test_ctx ctx;

SELECT pg_temp.br_assert(
    'checkout scanner: returns matching non-cancelled departure',
    EXISTS (
        SELECT 1
        FROM br_test_ids ids
        JOIN LATERAL public.scan_booking_registers_for_checkout(DATE '2026-10-10', 100, 0) s ON s.booking_id = ids.id
        WHERE ids.name = 'checkout_ok'
    ),
    NULL
);

SELECT pg_temp.br_assert(
    'checkout scanner: excludes BSO cancelled rows',
    NOT EXISTS (
        SELECT 1
        FROM br_test_ids ids
        JOIN LATERAL public.scan_booking_registers_for_checkout(DATE '2026-10-10', 100, 0) s ON s.booking_id = ids.id
        WHERE ids.name = 'checkout_cancelled'
    ),
    NULL
);

SELECT pg_temp.br_assert(
    'checkout scanner: cursor excludes processed ids',
    NOT EXISTS (
        SELECT 1
        FROM br_test_ids ids
        JOIN LATERAL public.scan_booking_registers_for_checkout(DATE '2026-10-10', 100, ids.id) s ON s.booking_id = ids.id
        WHERE ids.name = 'checkout_ok'
    ),
    NULL
);

INSERT INTO br_test_ids (name, id)
SELECT
    'extension_overlap',
    (
        public.create_booking_register(
            p_type => 'booking',
            p_arrival => DATE '2026-11-01',
            p_departure => DATE '2026-11-10',
            p_booked_at => TIMESTAMPTZ '2026-10-01T00:00:00Z',
            p_guest_id => 900000008,
            p_platform_id => ctx.platform_id,
            p_listing_id => ctx.listing_id,
            p_thread_ids_json => jsonb_build_array('thread-extension-overlap', ctx.run_id),
            p_metadata => jsonb_build_object(
                'booking_id', 'BRTEST_EXTENSION_OVERLAP_' || ctx.run_id,
                'test_suite', ctx.run_id,
                'case', 'extension_overlap'
            )
        )
    ).id
FROM br_test_ctx ctx;

INSERT INTO br_test_ids (name, id)
SELECT
    'extension_cleared',
    (
        public.create_booking_register(
            p_type => 'booking',
            p_arrival => DATE '2026-11-01',
            p_departure => DATE '2026-11-10',
            p_booked_at => TIMESTAMPTZ '2026-10-01T00:00:00Z',
            p_guest_id => 900000009,
            p_platform_id => ctx.platform_id,
            p_listing_id => ctx.listing_id,
            p_thread_ids_json => jsonb_build_array('thread-extension-cleared', ctx.run_id),
            p_metadata => jsonb_build_object(
                'booking_id', 'BRTEST_EXTENSION_CLEARED_' || ctx.run_id,
                'test_suite', ctx.run_id,
                'case', 'extension_cleared'
            )
        )
    ).id
FROM br_test_ctx ctx;

INSERT INTO br_test_ids (name, id)
SELECT
    'extension_block',
    (
        public.create_booking_register(
            p_type => 'block',
            p_arrival => DATE '2026-11-01',
            p_departure => DATE '2026-11-10',
            p_booked_at => TIMESTAMPTZ '2026-10-01T00:00:00Z',
            p_guest_id => 900000010,
            p_platform_id => ctx.platform_id,
            p_listing_id => ctx.listing_id,
            p_thread_ids_json => jsonb_build_array('thread-extension-block', ctx.run_id),
            p_metadata => jsonb_build_object(
                'booking_id', 'BRTEST_EXTENSION_BLOCK_' || ctx.run_id,
                'test_suite', ctx.run_id,
                'case', 'extension_block'
            )
        )
    ).id
FROM br_test_ctx ctx;

SELECT public.mark_booking_register_extension_scanned(id)
FROM br_test_ids
WHERE name = 'extension_cleared';

UPDATE public.booking_registers br
SET metadata = jsonb_set(
        jsonb_set(
            COALESCE(br.metadata, '{}'::jsonb),
            '{bso}',
            COALESCE(br.metadata->'bso', '{}'::jsonb),
            true
        ),
        '{bso,potential_extension}',
        COALESCE(br.metadata->'bso'->'potential_extension', '{}'::jsonb)
            || jsonb_build_object(
                'last_extended',
                to_jsonb(br.updated_at + INTERVAL '1 hour')
            ),
        true
    )
FROM br_test_ids ids
WHERE ids.name = 'extension_cleared'
  AND ids.id = br.id;

SELECT pg_temp.br_assert(
    'extension scanner: returns queued booking that overlaps the window',
    EXISTS (
        SELECT 1
        FROM br_test_ids ids
        JOIN LATERAL public.scan_booking_registers_for_extension(DATE '2026-11-05', DATE '2026-11-06', 100, 0) s ON s.booking_id = ids.id
        WHERE ids.name = 'extension_overlap'
    ),
    NULL
);

SELECT pg_temp.br_assert(
    'extension scanner: excludes rows when needs_scan = 0 and updated_at < last_extended',
    NOT EXISTS (
        SELECT 1
        FROM br_test_ids ids
        JOIN LATERAL public.scan_booking_registers_for_extension(DATE '2026-11-05', DATE '2026-11-06', 100, 0) s ON s.booking_id = ids.id
        WHERE ids.name = 'extension_cleared'
    ),
    NULL
);

SELECT pg_temp.br_assert(
    'extension scanner: manual override includes row even when updated_at < last_extended',
    EXISTS (
        SELECT 1
        FROM br_test_ids ids
        WHERE ids.name = 'extension_cleared'
          AND public.mark_booking_register_extension_needs_scan(ids.id) = TRUE
    ),
    NULL
);

SELECT pg_temp.br_assert(
    'extension scanner: override-forced row is returned',
    EXISTS (
        SELECT 1
        FROM br_test_ids ids
        JOIN LATERAL public.scan_booking_registers_for_extension(DATE '2026-11-05', DATE '2026-11-06', 100, 0) s ON s.booking_id = ids.id
        WHERE ids.name = 'extension_cleared'
    ),
    NULL
);

SELECT public.mark_booking_register_extension_scanned(id)
FROM br_test_ids
WHERE name = 'extension_cleared';

UPDATE public.booking_registers br
SET metadata = jsonb_set(
        jsonb_set(
            COALESCE(br.metadata, '{}'::jsonb),
            '{bso}',
            COALESCE(br.metadata->'bso', '{}'::jsonb),
            true
        ),
        '{bso,potential_extension}',
        COALESCE(br.metadata->'bso'->'potential_extension', '{}'::jsonb)
            || jsonb_build_object(
                'last_extended',
                to_jsonb(br.updated_at - INTERVAL '1 hour')
            ),
        true
    )
FROM br_test_ids ids
WHERE ids.name = 'extension_cleared'
  AND ids.id = br.id;

SELECT pg_temp.br_assert(
    'extension scanner: includes rows with needs_scan = 0 when updated_at >= last_extended',
    EXISTS (
        SELECT 1
        FROM br_test_ids ids
        JOIN LATERAL public.scan_booking_registers_for_extension(DATE '2026-11-05', DATE '2026-11-06', 100, 0) s ON s.booking_id = ids.id
        WHERE ids.name = 'extension_cleared'
    ),
    NULL
);

SELECT public.mark_booking_register_extension_scanned(id)
FROM br_test_ids
WHERE name = 'extension_overlap';

SELECT pg_temp.br_assert(
    'extension scanner: includes rows with needs_scan = 0 when last_extended is absent',
    EXISTS (
        SELECT 1
        FROM br_test_ids ids
        JOIN LATERAL public.scan_booking_registers_for_extension(DATE '2026-11-05', DATE '2026-11-06', 100, 0) s ON s.booking_id = ids.id
        WHERE ids.name = 'extension_overlap'
    ),
    NULL
);

SELECT pg_temp.br_assert(
    'extension scanner: excludes non-booking types',
    NOT EXISTS (
        SELECT 1
        FROM br_test_ids ids
        JOIN LATERAL public.scan_booking_registers_for_extension(DATE '2026-11-05', DATE '2026-11-06', 100, 0) s ON s.booking_id = ids.id
        WHERE ids.name = 'extension_block'
    ),
    NULL
);

SELECT pg_temp.br_assert(
    'extension scanner: cursor excludes processed ids',
    NOT EXISTS (
        SELECT 1
        FROM br_test_ids ids
        JOIN LATERAL public.scan_booking_registers_for_extension(DATE '2026-11-05', DATE '2026-11-06', 100, ids.id) s ON s.booking_id = ids.id
        WHERE ids.name = 'extension_overlap'
    ),
    NULL
);

SELECT pg_temp.br_assert_raises(
    'extension scanner error: rejects reversed date window',
    'SELECT * FROM public.scan_booking_registers_for_extension(DATE ''2026-11-06'', DATE ''2026-11-05'', 100, 0)',
    ARRAY['22023']
);

-- --------------------------------------------------------------------------
-- 10. Constraint and validation error paths
-- --------------------------------------------------------------------------
SELECT pg_temp.br_assert_raises(
    'constraint: arrival must be before departure',
    format(
        $fmt$
        SELECT public.create_booking_register(
            p_type => 'booking',
            p_arrival => DATE '2026-12-10',
            p_departure => DATE '2026-12-10',
            p_booked_at => TIMESTAMPTZ '2026-11-01T00:00:00Z',
            p_guest_id => 900000011,
            p_platform_id => %s,
            p_listing_id => %L,
            p_thread_ids_json => %L::jsonb,
            p_metadata => %L::jsonb
        )
        $fmt$,
        (SELECT platform_id FROM br_test_ctx),
        (SELECT listing_id FROM br_test_ctx),
        '["thread-invalid-date"]',
        jsonb_build_object('booking_id', 'BRTEST_INVALID_DATE_' || (SELECT run_id FROM br_test_ctx), 'test_suite', (SELECT run_id FROM br_test_ctx))::TEXT
    ),
    ARRAY['23514']
);

SELECT pg_temp.br_assert_raises(
    'constraint: thread_ids_json must be non-empty array',
    format(
        $fmt$
        SELECT public.create_booking_register(
            p_type => 'booking',
            p_arrival => DATE '2026-12-01',
            p_departure => DATE '2026-12-05',
            p_booked_at => TIMESTAMPTZ '2026-11-01T00:00:00Z',
            p_guest_id => 900000012,
            p_platform_id => %s,
            p_listing_id => %L,
            p_thread_ids_json => '[]'::jsonb,
            p_metadata => %L::jsonb
        )
        $fmt$,
        (SELECT platform_id FROM br_test_ctx),
        (SELECT listing_id FROM br_test_ctx),
        jsonb_build_object('booking_id', 'BRTEST_EMPTY_THREAD_' || (SELECT run_id FROM br_test_ctx), 'test_suite', (SELECT run_id FROM br_test_ctx))::TEXT
    ),
    ARRAY['23514']
);

SELECT pg_temp.br_assert_raises(
    'constraint: metadata must be JSON object',
    format(
        $fmt$
        SELECT public.create_booking_register(
            p_type => 'booking',
            p_arrival => DATE '2026-12-01',
            p_departure => DATE '2026-12-05',
            p_booked_at => TIMESTAMPTZ '2026-11-01T00:00:00Z',
            p_guest_id => 900000013,
            p_platform_id => %s,
            p_listing_id => %L,
            p_thread_ids_json => %L::jsonb,
            p_metadata => '[]'::jsonb
        )
        $fmt$,
        (SELECT platform_id FROM br_test_ctx),
        (SELECT listing_id FROM br_test_ctx),
        '["thread-invalid-metadata"]'
    ),
    ARRAY['22023']
);

SELECT pg_temp.br_assert_raises(
    'validation: unknown listing_id fails lookup',
    format(
        $fmt$
        SELECT public.create_booking_register(
            p_type => 'booking',
            p_arrival => DATE '2026-12-01',
            p_departure => DATE '2026-12-05',
            p_booked_at => TIMESTAMPTZ '2026-11-01T00:00:00Z',
            p_guest_id => 900000014,
            p_platform_id => %s,
            p_listing_id => %L,
            p_thread_ids_json => %L::jsonb,
            p_metadata => %L::jsonb
        )
        $fmt$,
        (SELECT platform_id FROM br_test_ctx),
        'missing_listing_' || (SELECT run_id FROM br_test_ctx),
        '["thread-missing-listing"]',
        jsonb_build_object('booking_id', 'BRTEST_MISSING_LISTING_' || (SELECT run_id FROM br_test_ctx), 'test_suite', (SELECT run_id FROM br_test_ctx))::TEXT
    ),
    ARRAY['23503']
);

-- --------------------------------------------------------------------------
-- 11. Delete behavior
-- --------------------------------------------------------------------------
INSERT INTO br_test_ids (name, id)
SELECT
    'delete_me',
    (
        public.create_booking_register(
            p_type => 'booking',
            p_arrival => DATE '2026-12-20',
            p_departure => DATE '2026-12-22',
            p_booked_at => TIMESTAMPTZ '2026-11-01T00:00:00Z',
            p_guest_id => 900000015,
            p_platform_id => ctx.platform_id,
            p_listing_id => ctx.listing_id,
            p_thread_ids_json => jsonb_build_array('thread-delete', ctx.run_id),
            p_metadata => jsonb_build_object(
                'booking_id', 'BRTEST_DELETE_' || ctx.run_id,
                'test_suite', ctx.run_id,
                'case', 'delete_me'
            )
        )
    ).id
FROM br_test_ctx ctx;

SELECT public.delete_booking_register(id)
FROM br_test_ids
WHERE name = 'delete_me';

SELECT pg_temp.br_assert(
    'delete: row is removed',
    NOT EXISTS (
        SELECT 1
        FROM public.booking_registers br
        JOIN br_test_ids ids ON ids.id = br.id AND ids.name = 'delete_me'
    ),
    NULL
);

SELECT pg_temp.br_assert_raises(
    'delete: get deleted row raises not found',
    format('SELECT public.get_booking_register_by_id(%s)', (SELECT id FROM br_test_ids WHERE name = 'delete_me')),
    ARRAY['P0002']
);

-- --------------------------------------------------------------------------
-- 12. Cleanup, result table, and final status
-- --------------------------------------------------------------------------
DELETE FROM public.booking_registers
WHERE metadata->>'test_suite' IN (SELECT run_id FROM br_test_ctx)
   OR metadata->>'test_suite' LIKE '__booking_registers_regression__%';

\echo ''
\echo 'booking_registers test results'
TABLE br_test_results ORDER BY id;

DO $$
DECLARE
    v_total INT;
    v_failed INT;
    v_passed INT;
BEGIN
    SELECT COUNT(*), COUNT(*) FILTER (WHERE NOT passed), COUNT(*) FILTER (WHERE passed)
    INTO v_total, v_failed, v_passed
    FROM br_test_results;

    RAISE NOTICE 'booking_registers test summary: % passed, % failed, % total', v_passed, v_failed, v_total;

    IF v_failed > 0 THEN
        RAISE EXCEPTION 'booking_registers regression suite failed: % of % tests failed', v_failed, v_total;
    END IF;
END $$;
