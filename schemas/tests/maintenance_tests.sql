-- ============================================================
--  maintenance_tests.sql
--  Test suite for maintenance.sql functions and objects
--
--  Strategy:
--    • All test data is inserted inside a single outer transaction
--      that ROLLBACK at the end — zero permanent side-effects.
--    • Guard-clause (exception) tests use nested DO blocks with
--      EXCEPTION handlers so a caught error never aborts the outer
--      transaction.
--    • Each test records PASS / FAIL into the temp table
--      maint_test_results and prints a live NOTICE.
--    • A final summary block raises an ERROR if any test failed,
--      making CI pipelines fail cleanly.
--
--  Run: psql -v ON_ERROR_STOP=1 -f maintenance_tests.sql
--  Expected output: all PASS, final summary NOTICE with 0 failures.
-- ============================================================

BEGIN;

-- ============================================================
-- T-0  INFRASTRUCTURE
-- ============================================================

CREATE TEMP TABLE maint_test_results (
    id          SERIAL PRIMARY KEY,
    section     TEXT NOT NULL,
    test_name   TEXT NOT NULL,
    passed      BOOLEAN NOT NULL,
    detail      TEXT,
    ran_at      TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

-- Helper: assert an expression is TRUE
CREATE OR REPLACE FUNCTION maint_assert(
    p_section   TEXT,
    p_test_name TEXT,
    p_passed    BOOLEAN,
    p_detail    TEXT DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
    v_status TEXT := CASE WHEN p_passed THEN '✓ PASS' ELSE '✗ FAIL' END;
BEGIN
    INSERT INTO maint_test_results (section, test_name, passed, detail)
    VALUES (p_section, p_test_name, p_passed, p_detail);
    RAISE NOTICE '[%] % — %  %', v_status, p_section, p_test_name, COALESCE(p_detail, '');
END;
$$ LANGUAGE plpgsql;

-- Helper: assert a call raises an exception matching a pattern
CREATE OR REPLACE FUNCTION maint_assert_raises(
    p_section   TEXT,
    p_test_name TEXT,
    p_sql       TEXT,
    p_pattern   TEXT DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
    v_raised BOOLEAN := FALSE;
    v_msg    TEXT;
BEGIN
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN OTHERS THEN
        v_raised := TRUE;
        v_msg    := SQLERRM;
    END;

    IF v_raised AND (p_pattern IS NULL OR v_msg ILIKE '%' || p_pattern || '%') THEN
        PERFORM maint_assert(p_section, p_test_name, TRUE,
            'raised: ' || LEFT(COALESCE(v_msg,''), 80));
    ELSIF v_raised THEN
        PERFORM maint_assert(p_section, p_test_name, FALSE,
            'exception raised but message mismatch. got: ' || LEFT(v_msg, 80));
    ELSE
        PERFORM maint_assert(p_section, p_test_name, FALSE, 'no exception raised');
    END IF;
END;
$$ LANGUAGE plpgsql;


-- ============================================================
-- T-1  SCHEMA / OBJECT EXISTENCE
-- ============================================================

DO $$
DECLARE v_sec TEXT := 'T-1 Schema';
BEGIN
    -- Functions
    PERFORM maint_assert(v_sec, 'cleanup_app_logs exists',
        EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'cleanup_app_logs'));

    PERFORM maint_assert(v_sec, 'cleanup_old_messages exists',
        EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'cleanup_old_messages'));

    PERFORM maint_assert(v_sec, 'archive_old_bookings exists',
        EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'archive_old_bookings'));

    PERFORM maint_assert(v_sec, 'cleanup_removed_applied_rules exists',
        EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'cleanup_removed_applied_rules'));

    PERFORM maint_assert(v_sec, 'cleanup_failed_applied_rules exists',
        EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'cleanup_failed_applied_rules'));

    PERFORM maint_assert(v_sec, 'cleanup_audit_log exists',
        EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'cleanup_audit_log'));

    PERFORM maint_assert(v_sec, 'cleanup_rate_limits exists',
        EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'cleanup_rate_limits'));

    PERFORM maint_assert(v_sec, 'cleanup_inactive_workers exists',
        EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'cleanup_inactive_workers'));

    PERFORM maint_assert(v_sec, 'cleanup_llm_model_usage exists',
        EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'cleanup_llm_model_usage'));

    PERFORM maint_assert(v_sec, 'small_server_disk_maintenance_run exists',
        EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'small_server_disk_maintenance_run'));

    PERFORM maint_assert(v_sec, 'daily_maintenance_run exists',
        EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'daily_maintenance_run'));

    PERFORM maint_assert(v_sec, 'monthly_maintenance_run exists',
        EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'monthly_maintenance_run'));

    PERFORM maint_assert(v_sec, 'ensure_daily_maintenance_schedule exists',
        EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'ensure_daily_maintenance_schedule'));

    PERFORM maint_assert(v_sec, 'ensure_monthly_maintenance_schedule exists',
        EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'ensure_monthly_maintenance_schedule'));

    -- Objects
    PERFORM maint_assert(v_sec, 'booking_registers_archive table exists',
        to_regclass('public.booking_registers_archive') IS NOT NULL);

    PERFORM maint_assert(v_sec, 'table_growth_monitor view exists',
        to_regclass('public.table_growth_monitor') IS NOT NULL);

    -- Archive table has archived_at column
    PERFORM maint_assert(v_sec, 'booking_registers_archive has archived_at column',
        EXISTS(
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = 'public'
              AND table_name   = 'booking_registers_archive'
              AND column_name  = 'archived_at'
        ));

    -- Archive indexes
    PERFORM maint_assert(v_sec, 'idx_booking_registers_archive_departure exists',
        EXISTS(SELECT 1 FROM pg_indexes
               WHERE tablename = 'booking_registers_archive'
                 AND indexname = 'idx_booking_registers_archive_departure'));

    PERFORM maint_assert(v_sec, 'idx_booking_registers_archive_platform exists',
        EXISTS(SELECT 1 FROM pg_indexes
               WHERE tablename = 'booking_registers_archive'
                 AND indexname = 'idx_booking_registers_archive_platform'));
END $$;


-- ============================================================
-- T-2  FIXTURE DATA
--      Insert the minimal FK chain needed by downstream tests:
--        platform → property → platform_property_lookup
--        → pricing_operation_types → pricing_rule → booking_register
--      All IDs use very high values (starting at 99900) so they
--      never collide with existing production rows.
-- ============================================================

-- Platform
INSERT INTO platforms (id, name, type, metadata)
VALUES (99901, '__test_maint_platform__', 'airbnb', '{}')
ON CONFLICT (id) DO NOTHING;

-- Property (descrp must satisfy the not-null check)
INSERT INTO properties (id, descrp)
VALUES (99901, '{"name":"Test Property","latitude":"1.0","longitude":"1.0"}'::jsonb)
ON CONFLICT (id) DO NOTHING;

-- Platform Property Lookup
INSERT INTO platform_property_lookup (id, properties_ptr, platform_id, listing_id, metadata)
VALUES (99901, 99901, 99901, '__test_listing_99901__', '{}')
ON CONFLICT (id) DO NOTHING;

-- Pricing operation type (needed for pricing_rules FK)
INSERT INTO pricing_operation_types (id, operation_code, operation_name, category, is_active)
VALUES (99901, '__test_op_99901__', 'Test Operation', 'pricing', TRUE)
ON CONFLICT (id) DO NOTHING;

-- Pricing rule (global scope, applicable_dates satisfies valid_date_scope)
INSERT INTO pricing_rules (
    id, rule_uuid, operation_id, rule_config, applicable_dates,
    status, priority, requires_approval
)
VALUES (
    99901,
    '00000000-0000-0000-0000-000000009901'::UUID,
    99901,
    '{"operation":{"do":"set","type":"fixed"}}'::jsonb,
    '["2020-01-01"]'::jsonb,
    'active',
    50,
    FALSE
)
ON CONFLICT (id) DO NOTHING;


-- ============================================================
-- T-3  cleanup_app_logs
-- ============================================================

DO $$
DECLARE
    v_sec      TEXT := 'T-3 cleanup_app_logs';
    v_old_id   BIGINT;
    v_new_id   BIGINT;
    v_deleted  BIGINT;
BEGIN
    -- Insert two rows: one old (120 days), one recent (1 day)
    INSERT INTO app_logs (level, message, source, created_at)
    VALUES ('INFO', '__maint_test_old__', '__maint_test__', NOW() - INTERVAL '120 days')
    RETURNING id INTO v_old_id;

    INSERT INTO app_logs (level, message, source, created_at)
    VALUES ('INFO', '__maint_test_recent__', '__maint_test__', NOW() - INTERVAL '1 day')
    RETURNING id INTO v_new_id;

    -- Happy path: only the old row should be deleted
    SELECT cleanup_app_logs('90 days') INTO v_deleted;

    PERFORM maint_assert(v_sec, 'returns count >= 1 for old rows',
        v_deleted >= 1,
        'deleted=' || v_deleted);

    PERFORM maint_assert(v_sec, 'old row is gone',
        NOT EXISTS(SELECT 1 FROM app_logs WHERE id = v_old_id));

    PERFORM maint_assert(v_sec, 'recent row still exists',
        EXISTS(SELECT 1 FROM app_logs WHERE id = v_new_id));

    -- Idempotency: calling again with no more old rows returns 0
    SELECT cleanup_app_logs('90 days') INTO v_deleted;
    PERFORM maint_assert(v_sec, 'idempotent: second call returns 0 old deletions',
        v_deleted = 0,
        'second_deleted=' || v_deleted);

    -- Default parameters work without explicit args
    SELECT cleanup_app_logs() INTO v_deleted;
    PERFORM maint_assert(v_sec, 'default params call does not error',
        TRUE);

    -- Cleanup: remove the recent row we inserted
    DELETE FROM app_logs WHERE id = v_new_id;
END $$;

-- Guard: interval below minimum
PERFORM maint_assert_raises(
    'T-3 cleanup_app_logs',
    'guard: retention < 1 day raises',
    $$SELECT cleanup_app_logs('12 hours')$$,
    'at least 1 day'
);

-- Guard: batch_size out of range
PERFORM maint_assert_raises(
    'T-3 cleanup_app_logs',
    'guard: batch_size 0 raises',
    $$SELECT cleanup_app_logs('90 days', 0)$$,
    'between 1 and 50000'
);

PERFORM maint_assert_raises(
    'T-3 cleanup_app_logs',
    'guard: batch_size 99999 raises',
    $$SELECT cleanup_app_logs('90 days', 99999)$$,
    'between 1 and 50000'
);


-- ============================================================
-- T-4  cleanup_old_messages
-- ============================================================

DO $$
DECLARE
    v_sec              TEXT := 'T-4 cleanup_old_messages';
    v_old_soft_id      BIGINT;
    v_old_active_id    BIGINT;
    v_recent_id        BIGINT;
    v_orphan_platform  INT  := 99801;
    v_orphan_thread    BIGINT := 99801;
    r                  RECORD;
BEGIN
    -- Phase-1 target: soft-deleted message older than grace (40 days)
    INSERT INTO messages (platform_id, thread_id, mid, content, message_timestamp,
                          created_at, deleted_at)
    VALUES (99801, 99801, 99801, '__maint_soft_del__',
            NOW() - INTERVAL '45 days',
            NOW() - INTERVAL '45 days',
            NOW() - INTERVAL '40 days')
    RETURNING id INTO v_old_soft_id;

    -- Phase-2 target: active message older than active_retention (800 days)
    INSERT INTO messages (platform_id, thread_id, mid, content, message_timestamp, created_at)
    VALUES (99801, 99802, 99802, '__maint_active_old__',
            NOW() - INTERVAL '800 days',
            NOW() - INTERVAL '800 days')
    RETURNING id INTO v_old_active_id;

    -- Recent active message — must survive
    INSERT INTO messages (platform_id, thread_id, mid, content, message_timestamp, created_at)
    VALUES (99801, 99803, 99803, '__maint_recent__',
            NOW() - INTERVAL '1 day',
            NOW() - INTERVAL '1 day')
    RETURNING id INTO v_recent_id;

    -- Orphaned thread progress (platform/thread has no messages)
    INSERT INTO message_thread_progress (platform_id, thread_id, booking_id)
    VALUES (v_orphan_platform, v_orphan_thread, 0)
    ON CONFLICT (platform_id, thread_id) DO NOTHING;

    -- Run cleanup: grace=30d, retention=730d
    SELECT * INTO r FROM cleanup_old_messages('30 days', '730 days');

    PERFORM maint_assert(v_sec, 'phase-1: soft-deleted_count >= 1',
        r.deleted_soft_messages >= 1,
        'got ' || r.deleted_soft_messages);

    PERFORM maint_assert(v_sec, 'phase-2: old active_count >= 1',
        r.deleted_active_messages >= 1,
        'got ' || r.deleted_active_messages);

    PERFORM maint_assert(v_sec, 'phase-3: orphaned thread_progress count >= 1',
        r.deleted_thread_progress >= 1,
        'got ' || r.deleted_thread_progress);

    PERFORM maint_assert(v_sec, 'old soft-deleted message is gone',
        NOT EXISTS(SELECT 1 FROM messages WHERE id = v_old_soft_id));

    PERFORM maint_assert(v_sec, 'old active message is gone',
        NOT EXISTS(SELECT 1 FROM messages WHERE id = v_old_active_id));

    PERFORM maint_assert(v_sec, 'recent message still exists',
        EXISTS(SELECT 1 FROM messages WHERE id = v_recent_id));

    PERFORM maint_assert(v_sec, 'orphaned thread_progress row is gone',
        NOT EXISTS(SELECT 1 FROM message_thread_progress
                   WHERE platform_id = v_orphan_platform
                     AND thread_id   = v_orphan_thread));

    -- Idempotency
    SELECT * INTO r FROM cleanup_old_messages('30 days', '730 days');
    PERFORM maint_assert(v_sec, 'idempotent: second call returns all zeros',
        r.deleted_soft_messages = 0
        AND r.deleted_active_messages = 0,
        format('soft=%s active=%s', r.deleted_soft_messages, r.deleted_active_messages));

    -- Default params call
    SELECT * INTO r FROM cleanup_old_messages();
    PERFORM maint_assert(v_sec, 'default params call does not error', TRUE);

    -- Cleanup surviving recent message
    DELETE FROM messages WHERE id = v_recent_id;
END $$;

-- Guards
PERFORM maint_assert_raises(
    'T-4 cleanup_old_messages',
    'guard: soft_deleted_grace < 1 day raises',
    $$SELECT * FROM cleanup_old_messages('12 hours', '730 days')$$,
    'at least 1 day'
);

PERFORM maint_assert_raises(
    'T-4 cleanup_old_messages',
    'guard: active_retention < 90 days raises',
    $$SELECT * FROM cleanup_old_messages('30 days', '30 days')$$,
    'at least 90 days'
);


-- ============================================================
-- T-5  archive_old_bookings
-- ============================================================

DO $$
DECLARE
    v_sec         TEXT := 'T-5 archive_old_bookings';
    v_old_id      BIGINT;
    v_recent_id   BIGINT;
    v_archived    BIGINT;
    v_count_arc   BIGINT;
BEGIN
    -- Insert a booking with departure 10 years ago (should be archived)
    INSERT INTO booking_registers (
        type, arrival, departure, booked_at,
        guest_id, property_id, platform_id, ppl_id,
        thread_ids_json, metadata, created_at, updated_at
    )
    VALUES (
        'booking',
        CURRENT_DATE - INTERVAL '10 years' - INTERVAL '30 days',
        CURRENT_DATE - INTERVAL '10 years',
        NOW() - INTERVAL '10 years',
        99901, 99901, 99901, 99901,
        '[]'::jsonb,
        '{"test":"archive_old_booking"}'::jsonb,
        NOW() - INTERVAL '10 years',
        NOW() - INTERVAL '10 years'
    )
    RETURNING id INTO v_old_id;

    -- Insert a booking with departure yesterday (must NOT be archived)
    INSERT INTO booking_registers (
        type, arrival, departure, booked_at,
        guest_id, property_id, platform_id, ppl_id,
        thread_ids_json, metadata
    )
    VALUES (
        'booking',
        CURRENT_DATE - INTERVAL '4 days',
        CURRENT_DATE - INTERVAL '1 day',
        NOW() - INTERVAL '5 days',
        99901, 99901, 99901, 99901,
        '[]'::jsonb,
        '{"test":"archive_recent_booking"}'::jsonb
    )
    RETURNING id INTO v_recent_id;

    -- Archive with 7-year cutoff
    SELECT archive_old_bookings('7 years') INTO v_archived;

    PERFORM maint_assert(v_sec, 'returns count >= 1',
        v_archived >= 1,
        'archived=' || v_archived);

    PERFORM maint_assert(v_sec, 'old booking removed from booking_registers',
        NOT EXISTS(SELECT 1 FROM booking_registers WHERE id = v_old_id));

    PERFORM maint_assert(v_sec, 'old booking present in booking_registers_archive',
        EXISTS(SELECT 1 FROM booking_registers_archive WHERE id = v_old_id));

    PERFORM maint_assert(v_sec, 'recent booking still in booking_registers',
        EXISTS(SELECT 1 FROM booking_registers WHERE id = v_recent_id));

    PERFORM maint_assert(v_sec, 'recent booking NOT in archive',
        NOT EXISTS(SELECT 1 FROM booking_registers_archive WHERE id = v_recent_id));

    -- Verify archived_at column was populated
    PERFORM maint_assert(v_sec, 'archived_at is set in archive row',
        EXISTS(
            SELECT 1 FROM booking_registers_archive
            WHERE id = v_old_id AND archived_at IS NOT NULL
        ));

    -- Idempotency: running again should not duplicate archive rows
    SELECT archive_old_bookings('7 years') INTO v_archived;
    PERFORM maint_assert(v_sec, 'idempotent: second archive call returns 0',
        v_archived = 0,
        'second_archived=' || v_archived);

    SELECT COUNT(*) INTO v_count_arc
    FROM booking_registers_archive WHERE id = v_old_id;
    PERFORM maint_assert(v_sec, 'no duplicate rows in archive',
        v_count_arc = 1,
        'count_in_archive=' || v_count_arc);

    -- Cleanup: delete the archive row and the recent booking
    DELETE FROM booking_registers_archive WHERE id = v_old_id;
    DELETE FROM booking_registers WHERE id = v_recent_id;
END $$;

-- Guards
PERFORM maint_assert_raises(
    'T-5 archive_old_bookings',
    'guard: older_than < 1 year raises',
    $$SELECT archive_old_bookings('6 months')$$,
    'at least 1 year'
);


-- ============================================================
-- T-6  cleanup_removed_applied_rules
-- ============================================================

DO $$
DECLARE
    v_sec          TEXT := 'T-6 cleanup_removed_applied_rules';
    v_br_id        BIGINT;
    v_old_rule_id  BIGINT;
    v_new_rule_id  BIGINT;
    v_live_rule_id BIGINT;
    v_deleted      BIGINT;
BEGIN
    -- Insert a booking_register to satisfy FK
    INSERT INTO booking_registers (
        type, arrival, departure, booked_at,
        guest_id, property_id, platform_id, ppl_id,
        thread_ids_json, metadata
    )
    VALUES (
        'booking',
        CURRENT_DATE + 10, CURRENT_DATE + 15,
        NOW(), 99901, 99901, 99901, 99901,
        '[]'::jsonb, '{}'::jsonb
    )
    RETURNING id INTO v_br_id;

    -- Old 'removed' rule — should be deleted (removed 400 days ago)
    INSERT INTO booking_applied_rules (
        booking_entry_id, property_id, platform_id, listing_id,
        rule_uuid, trigger_category, instruction,
        status, applied_at, removed_at, updated_at
    )
    VALUES (
        v_br_id, 99901, 99901, '__test_listing_99901__',
        '00000000-0000-0000-0000-000000009901'::UUID,
        'checkout', '{"action":"test"}'::jsonb,
        'removed',
        NOW() - INTERVAL '400 days',
        NOW() - INTERVAL '400 days',
        NOW() - INTERVAL '400 days'
    )
    RETURNING id INTO v_old_rule_id;

    -- Recent 'removed' rule — must survive (removed 5 days ago)
    INSERT INTO booking_applied_rules (
        booking_entry_id, property_id, platform_id, listing_id,
        rule_uuid, trigger_category, instruction,
        status, applied_at, removed_at, updated_at
    )
    VALUES (
        v_br_id, 99901, 99901, '__test_listing_99901__',
        '00000000-0000-0000-0000-000000009901'::UUID,
        'checkout', '{"action":"test"}'::jsonb,
        'removed',
        NOW() - INTERVAL '5 days',
        NOW() - INTERVAL '5 days',
        NOW() - INTERVAL '5 days'
    )
    RETURNING id INTO v_new_rule_id;

    -- 'applied' rule — must NEVER be touched regardless of age
    INSERT INTO booking_applied_rules (
        booking_entry_id, property_id, platform_id, listing_id,
        rule_uuid, trigger_category, instruction,
        status, applied_at, updated_at
    )
    VALUES (
        v_br_id, 99901, 99901, '__test_listing_99901__',
        '00000000-0000-0000-0000-000000009901'::UUID,
        'checkout', '{"action":"test"}'::jsonb,
        'applied',
        NOW() - INTERVAL '500 days',
        NOW() - INTERVAL '500 days'
    )
    RETURNING id INTO v_live_rule_id;

    SELECT cleanup_removed_applied_rules('1 year') INTO v_deleted;

    PERFORM maint_assert(v_sec, 'returns count >= 1',
        v_deleted >= 1,
        'deleted=' || v_deleted);

    PERFORM maint_assert(v_sec, 'old removed rule is gone',
        NOT EXISTS(SELECT 1 FROM booking_applied_rules WHERE id = v_old_rule_id));

    PERFORM maint_assert(v_sec, 'recent removed rule still exists',
        EXISTS(SELECT 1 FROM booking_applied_rules WHERE id = v_new_rule_id));

    PERFORM maint_assert(v_sec, 'applied rule untouched even though old',
        EXISTS(SELECT 1 FROM booking_applied_rules WHERE id = v_live_rule_id));

    -- Idempotency
    SELECT cleanup_removed_applied_rules('1 year') INTO v_deleted;
    PERFORM maint_assert(v_sec, 'idempotent: second call returns 0 for same cutoff',
        v_deleted = 0);

    -- Cleanup
    DELETE FROM booking_applied_rules WHERE booking_entry_id = v_br_id;
    DELETE FROM booking_registers WHERE id = v_br_id;
END $$;

-- Guards
PERFORM maint_assert_raises(
    'T-6 cleanup_removed_applied_rules',
    'guard: older_than < 30 days raises',
    $$SELECT cleanup_removed_applied_rules('10 days')$$,
    'at least 30 days'
);


-- ============================================================
-- T-7  cleanup_failed_applied_rules
-- ============================================================

DO $$
DECLARE
    v_sec           TEXT := 'T-7 cleanup_failed_applied_rules';
    v_br_id         BIGINT;
    v_old_fail_id   BIGINT;
    v_recent_fail_id BIGINT;
    v_applied_id    BIGINT;
    v_deleted       BIGINT;
BEGIN
    INSERT INTO booking_registers (
        type, arrival, departure, booked_at,
        guest_id, property_id, platform_id, ppl_id,
        thread_ids_json, metadata
    )
    VALUES (
        'booking',
        CURRENT_DATE + 20, CURRENT_DATE + 25,
        NOW(), 99901, 99901, 99901, 99901,
        '[]'::jsonb, '{}'::jsonb
    )
    RETURNING id INTO v_br_id;

    -- Old 'failed' rule — should be deleted (updated 120 days ago)
    INSERT INTO booking_applied_rules (
        booking_entry_id, property_id, platform_id, listing_id,
        rule_uuid, trigger_category, instruction,
        status, applied_at, updated_at
    )
    VALUES (
        v_br_id, 99901, 99901, '__test_listing_99901__',
        '00000000-0000-0000-0000-000000009901'::UUID,
        'checkout', '{"action":"test_fail"}'::jsonb,
        'failed',
        NOW() - INTERVAL '120 days',
        NOW() - INTERVAL '120 days'
    )
    RETURNING id INTO v_old_fail_id;

    -- Recent 'failed' rule — must survive
    INSERT INTO booking_applied_rules (
        booking_entry_id, property_id, platform_id, listing_id,
        rule_uuid, trigger_category, instruction,
        status, applied_at, updated_at
    )
    VALUES (
        v_br_id, 99901, 99901, '__test_listing_99901__',
        '00000000-0000-0000-0000-000000009901'::UUID,
        'checkout', '{"action":"test_fail"}'::jsonb,
        'failed',
        NOW() - INTERVAL '2 days',
        NOW() - INTERVAL '2 days'
    )
    RETURNING id INTO v_recent_fail_id;

    -- 'applied' rule that is old — must NOT be touched
    INSERT INTO booking_applied_rules (
        booking_entry_id, property_id, platform_id, listing_id,
        rule_uuid, trigger_category, instruction,
        status, applied_at, updated_at
    )
    VALUES (
        v_br_id, 99901, 99901, '__test_listing_99901__',
        '00000000-0000-0000-0000-000000009901'::UUID,
        'checkout', '{"action":"test_fail"}'::jsonb,
        'applied',
        NOW() - INTERVAL '200 days',
        NOW() - INTERVAL '200 days'
    )
    RETURNING id INTO v_applied_id;

    SELECT cleanup_failed_applied_rules('90 days') INTO v_deleted;

    PERFORM maint_assert(v_sec, 'returns count >= 1',
        v_deleted >= 1, 'deleted=' || v_deleted);

    PERFORM maint_assert(v_sec, 'old failed rule is gone',
        NOT EXISTS(SELECT 1 FROM booking_applied_rules WHERE id = v_old_fail_id));

    PERFORM maint_assert(v_sec, 'recent failed rule still exists',
        EXISTS(SELECT 1 FROM booking_applied_rules WHERE id = v_recent_fail_id));

    PERFORM maint_assert(v_sec, 'applied rule untouched',
        EXISTS(SELECT 1 FROM booking_applied_rules WHERE id = v_applied_id));

    -- Status orthogonality: removed rules are NOT affected by this function
    -- (they have status='applied' here so this just confirms function is scoped)
    PERFORM maint_assert(v_sec, 'function only deletes status=failed rows',
        NOT EXISTS(
            SELECT 1 FROM booking_applied_rules
            WHERE status != 'failed'
              AND id NOT IN (v_recent_fail_id, v_applied_id)
              AND booking_entry_id = v_br_id
        ));

    -- Cleanup
    DELETE FROM booking_applied_rules WHERE booking_entry_id = v_br_id;
    DELETE FROM booking_registers WHERE id = v_br_id;
END $$;

-- Guards
PERFORM maint_assert_raises(
    'T-7 cleanup_failed_applied_rules',
    'guard: older_than < 7 days raises',
    $$SELECT cleanup_failed_applied_rules('3 days')$$,
    'at least 7 days'
);


-- ============================================================
-- T-8  cleanup_audit_log
-- ============================================================

DO $$
DECLARE
    v_sec      TEXT := 'T-8 cleanup_audit_log';
    v_old_id   BIGINT;
    v_new_id   BIGINT;
    v_deleted  BIGINT;
BEGIN
    INSERT INTO audit_log (operation, entity_type, actor_id, created_at)
    VALUES ('cleanup', 'task', '__maint_test__', NOW() - INTERVAL '200 days')
    RETURNING id INTO v_old_id;

    INSERT INTO audit_log (operation, entity_type, actor_id, created_at)
    VALUES ('cleanup', 'task', '__maint_test__', NOW() - INTERVAL '1 day')
    RETURNING id INTO v_new_id;

    SELECT cleanup_audit_log('180 days') INTO v_deleted;

    PERFORM maint_assert(v_sec, 'returns count >= 1',
        v_deleted >= 1, 'deleted=' || v_deleted);

    PERFORM maint_assert(v_sec, 'old row is gone',
        NOT EXISTS(SELECT 1 FROM audit_log WHERE id = v_old_id));

    PERFORM maint_assert(v_sec, 'recent row still exists',
        EXISTS(SELECT 1 FROM audit_log WHERE id = v_new_id));

    -- Idempotency
    SELECT cleanup_audit_log('180 days') INTO v_deleted;
    PERFORM maint_assert(v_sec, 'idempotent: second call returns 0',
        v_deleted = 0);

    DELETE FROM audit_log WHERE id = v_new_id;
END $$;

-- Guards
PERFORM maint_assert_raises(
    'T-8 cleanup_audit_log',
    'guard: older_than < 7 days raises',
    $$SELECT cleanup_audit_log('3 days')$$,
    'at least 7 days'
);


-- ============================================================
-- T-9  cleanup_rate_limits
-- ============================================================

DO $$
DECLARE
    v_sec      TEXT := 'T-9 cleanup_rate_limits';
    v_old_id   BIGINT;
    v_new_id   BIGINT;
    v_deleted  BIGINT;
BEGIN
    -- Unique window_start per test to avoid UNIQUE constraint conflicts
    INSERT INTO rate_limits (identifier, operation, window_start, request_count)
    VALUES ('__maint_test__', 'test_op', NOW() - INTERVAL '5 hours', 1)
    RETURNING id INTO v_old_id;

    INSERT INTO rate_limits (identifier, operation, window_start, request_count)
    VALUES ('__maint_test__', 'test_op', NOW() - INTERVAL '30 minutes', 1)
    RETURNING id INTO v_new_id;

    SELECT cleanup_rate_limits('2 hours') INTO v_deleted;

    PERFORM maint_assert(v_sec, 'returns count >= 1',
        v_deleted >= 1, 'deleted=' || v_deleted);

    PERFORM maint_assert(v_sec, 'old window row is gone',
        NOT EXISTS(SELECT 1 FROM rate_limits WHERE id = v_old_id));

    PERFORM maint_assert(v_sec, 'recent window row still exists',
        EXISTS(SELECT 1 FROM rate_limits WHERE id = v_new_id));

    -- Idempotency
    SELECT cleanup_rate_limits('2 hours') INTO v_deleted;
    PERFORM maint_assert(v_sec, 'idempotent: no rows deleted second time',
        v_deleted = 0);

    DELETE FROM rate_limits WHERE id = v_new_id;
END $$;

-- Guards
PERFORM maint_assert_raises(
    'T-9 cleanup_rate_limits',
    'guard: older_than < 30 minutes raises',
    $$SELECT cleanup_rate_limits('10 minutes')$$,
    'at least 30 minutes'
);


-- ============================================================
-- T-10  cleanup_inactive_workers
-- ============================================================

DO $$
DECLARE
    v_sec             TEXT := 'T-10 cleanup_inactive_workers';
    v_stale_wid       TEXT := '__maint_stale_worker_99901__';
    v_recent_wid      TEXT := '__maint_recent_worker_99901__';
    v_active_wid      TEXT := '__maint_active_worker_99901__';
    r                 RECORD;
BEGIN
    -- Stale inactive worker (last seen 200 days ago) — should be deleted
    INSERT INTO worker_registry (worker_id, worker_name, is_active, last_seen_at)
    VALUES (v_stale_wid, 'Stale Test Worker', FALSE, NOW() - INTERVAL '200 days')
    ON CONFLICT (worker_id) DO UPDATE
        SET is_active = FALSE, last_seen_at = NOW() - INTERVAL '200 days';

    INSERT INTO worker_api_keys (worker_id, api_key_hash, api_key_prefix, is_active)
    VALUES (v_stale_wid,
            encode(digest('__stale_test_key_99901__', 'sha256'), 'hex'),
            'sk_stale99',
            FALSE)
    ON CONFLICT (worker_id) DO NOTHING;

    -- Recent inactive worker (last seen 5 days ago) — must survive
    INSERT INTO worker_registry (worker_id, worker_name, is_active, last_seen_at)
    VALUES (v_recent_wid, 'Recent Inactive Worker', FALSE, NOW() - INTERVAL '5 days')
    ON CONFLICT (worker_id) DO UPDATE
        SET is_active = FALSE, last_seen_at = NOW() - INTERVAL '5 days';

    -- Active worker (old last_seen) — must NEVER be deleted
    INSERT INTO worker_registry (worker_id, worker_name, is_active, last_seen_at)
    VALUES (v_active_wid, 'Active Old Worker', TRUE, NOW() - INTERVAL '300 days')
    ON CONFLICT (worker_id) DO UPDATE
        SET is_active = TRUE, last_seen_at = NOW() - INTERVAL '300 days';

    SELECT * INTO r FROM cleanup_inactive_workers('180 days');

    PERFORM maint_assert(v_sec, 'deleted_workers >= 1',
        r.deleted_workers >= 1,
        'deleted_workers=' || r.deleted_workers);

    PERFORM maint_assert(v_sec, 'deleted_api_keys >= 1',
        r.deleted_api_keys >= 1,
        'deleted_api_keys=' || r.deleted_api_keys);

    PERFORM maint_assert(v_sec, 'stale worker removed from worker_registry',
        NOT EXISTS(SELECT 1 FROM worker_registry WHERE worker_id = v_stale_wid));

    PERFORM maint_assert(v_sec, 'stale worker API key removed',
        NOT EXISTS(SELECT 1 FROM worker_api_keys WHERE worker_id = v_stale_wid));

    PERFORM maint_assert(v_sec, 'recent inactive worker still in registry',
        EXISTS(SELECT 1 FROM worker_registry WHERE worker_id = v_recent_wid));

    PERFORM maint_assert(v_sec, 'active worker untouched despite old last_seen',
        EXISTS(SELECT 1 FROM worker_registry WHERE worker_id = v_active_wid));

    -- Empty-set case (no more stale workers)
    SELECT * INTO r FROM cleanup_inactive_workers('180 days');
    PERFORM maint_assert(v_sec, 'idempotent: second call returns 0 deleted_workers for stale set',
        r.deleted_workers = 0);

    -- Cleanup remaining test workers
    DELETE FROM worker_api_keys WHERE worker_id IN (v_recent_wid, v_active_wid);
    DELETE FROM worker_registry  WHERE worker_id IN (v_recent_wid, v_active_wid);
END $$;

-- Guards
PERFORM maint_assert_raises(
    'T-10 cleanup_inactive_workers',
    'guard: inactive_since < 7 days raises',
    $$SELECT * FROM cleanup_inactive_workers('3 days')$$,
    'at least 7 days'
);


-- ============================================================
-- T-11  cleanup_llm_model_usage
-- ============================================================

DO $$
DECLARE
    v_sec      TEXT := 'T-11 cleanup_llm_model_usage';
    v_old_id   BIGINT;
    v_new_id   BIGINT;
    v_deleted  BIGINT;
BEGIN
    -- Only run if the table exists (function is designed to skip gracefully)
    IF to_regclass('public.llm_model_usage') IS NOT NULL THEN

        INSERT INTO llm_model_usage (
            worker_name, action_name, provider, model, success, created_at
        )
        VALUES ('__maint_test__', 'test_action', 'openai', 'gpt-test',
                TRUE, NOW() - INTERVAL '120 days')
        RETURNING id INTO v_old_id;

        INSERT INTO llm_model_usage (
            worker_name, action_name, provider, model, success, created_at
        )
        VALUES ('__maint_test__', 'test_action', 'openai', 'gpt-test',
                TRUE, NOW() - INTERVAL '1 day')
        RETURNING id INTO v_new_id;

        SELECT cleanup_llm_model_usage('90 days') INTO v_deleted;

        PERFORM maint_assert(v_sec, 'returns count >= 1',
            v_deleted >= 1, 'deleted=' || v_deleted);

        PERFORM maint_assert(v_sec, 'old usage row is gone',
            NOT EXISTS(SELECT 1 FROM llm_model_usage WHERE id = v_old_id));

        PERFORM maint_assert(v_sec, 'recent usage row still exists',
            EXISTS(SELECT 1 FROM llm_model_usage WHERE id = v_new_id));

        DELETE FROM llm_model_usage WHERE id = v_new_id;

    ELSE
        -- Table absent: function should return 0 silently
        SELECT cleanup_llm_model_usage('90 days') INTO v_deleted;
        PERFORM maint_assert(v_sec, 'returns 0 when table absent',
            v_deleted = 0, 'deleted=' || v_deleted);
    END IF;

    -- Idempotency when table exists
    SELECT cleanup_llm_model_usage('90 days') INTO v_deleted;
    PERFORM maint_assert(v_sec, 'idempotent: second call returns 0',
        v_deleted = 0);
END $$;

-- Guard: retention too small
PERFORM maint_assert_raises(
    'T-11 cleanup_llm_model_usage',
    'guard: older_than < 7 days raises',
    $$SELECT cleanup_llm_model_usage('3 days')$$,
    'at least 7 days'
);


-- ============================================================
-- T-12  table_growth_monitor view
-- ============================================================

DO $$
DECLARE
    v_sec       TEXT := 'T-12 table_growth_monitor';
    v_row_count INT;
    v_bad_pct   INT;
BEGIN
    SELECT COUNT(*) INTO v_row_count FROM table_growth_monitor;

    -- Should return at least 1 row (the app_logs table is always present)
    PERFORM maint_assert(v_sec, 'view returns at least 1 row',
        v_row_count >= 1,
        'row_count=' || v_row_count);

    -- All dead_row_pct values must be between 0 and 100
    SELECT COUNT(*) INTO v_bad_pct
    FROM table_growth_monitor
    WHERE dead_row_pct < 0 OR dead_row_pct > 100;

    PERFORM maint_assert(v_sec, 'dead_row_pct is always 0–100',
        v_bad_pct = 0,
        'invalid_pct_rows=' || v_bad_pct);

    -- total_size_bytes must be >= 0
    PERFORM maint_assert(v_sec, 'total_size_bytes >= 0 for all rows',
        NOT EXISTS(
            SELECT 1 FROM table_growth_monitor WHERE total_size_bytes < 0
        ));

    -- booking_registers appears in the view
    PERFORM maint_assert(v_sec, 'booking_registers appears in view',
        EXISTS(
            SELECT 1 FROM table_growth_monitor WHERE tablename = 'booking_registers'
        ));

    -- app_logs appears in the view
    PERFORM maint_assert(v_sec, 'app_logs appears in view',
        EXISTS(
            SELECT 1 FROM table_growth_monitor WHERE tablename = 'app_logs'
        ));

    -- All required columns are accessible (no column errors)
    PERFORM maint_assert(v_sec, 'all required columns accessible',
        EXISTS(
            SELECT
                schemaname, tablename, total_size, total_size_bytes,
                live_rows, dead_rows, dead_row_pct,
                last_autovacuum, last_autoanalyze
            FROM table_growth_monitor
            LIMIT 1
        ));
END $$;


-- ============================================================
-- T-13  daily_maintenance_run  (structural + no-error check)
-- ============================================================

DO $$
DECLARE
    v_sec          TEXT := 'T-13 daily_maintenance_run';
    v_row_count    INT;
    v_error_count  INT;
    v_job_names    TEXT[];
    v_expected_jobs TEXT[] := ARRAY[
        'app_logs', 'task_queue', 'task_metadata_history',
        'audit_log', 'rate_limits', 'messages',
        'applied_rules_removed', 'applied_rules_failed',
        'llm_model_usage', 'inactive_workers',
        'nightlyrates_listing', 'calculated_prices_partitions',
        'expired_pricing_data'
    ];
    v_missing_job TEXT;
BEGIN
    -- Run the orchestrator
    CREATE TEMP TABLE _dmr_results AS
    SELECT * FROM daily_maintenance_run();

    SELECT COUNT(*) INTO v_row_count FROM _dmr_results;

    PERFORM maint_assert(v_sec, 'returns exactly 13 job rows',
        v_row_count = 13,
        'got=' || v_row_count);

    -- No job should have a non-NULL error_message
    SELECT COUNT(*) INTO v_error_count
    FROM _dmr_results
    WHERE error_message IS NOT NULL;

    PERFORM maint_assert(v_sec, 'all 13 jobs completed without errors',
        v_error_count = 0,
        'jobs_with_errors=' || v_error_count || COALESCE(
            ' | ' || (
                SELECT STRING_AGG(job_name || ': ' || error_message, '; ')
                FROM _dmr_results WHERE error_message IS NOT NULL
            ), ''
        ));

    -- All expected job_names are present
    FOREACH v_missing_job IN ARRAY v_expected_jobs LOOP
        PERFORM maint_assert(v_sec,
            'job "' || v_missing_job || '" present in results',
            EXISTS(SELECT 1 FROM _dmr_results WHERE job_name = v_missing_job));
    END LOOP;

    -- duration_ms should be numeric and >= 0 for all rows
    PERFORM maint_assert(v_sec, 'all duration_ms values >= 0',
        NOT EXISTS(SELECT 1 FROM _dmr_results WHERE duration_ms < 0));

    -- rows_affected is not NULL for any row
    PERFORM maint_assert(v_sec, 'rows_affected is not NULL for any job',
        NOT EXISTS(SELECT 1 FROM _dmr_results WHERE rows_affected IS NULL));

    DROP TABLE _dmr_results;
END $$;


-- ============================================================
-- T-14  monthly_maintenance_run  (structural + no-error check)
-- ============================================================

DO $$
DECLARE
    v_sec         TEXT := 'T-14 monthly_maintenance_run';
    v_row_count   INT;
    v_error_count INT;
BEGIN
    CREATE TEMP TABLE _mmr_results AS
    SELECT * FROM monthly_maintenance_run();

    SELECT COUNT(*) INTO v_row_count FROM _mmr_results;

    PERFORM maint_assert(v_sec, 'returns exactly 1 job row',
        v_row_count = 1,
        'got=' || v_row_count);

    SELECT COUNT(*) INTO v_error_count
    FROM _mmr_results
    WHERE error_message IS NOT NULL;

    PERFORM maint_assert(v_sec, 'booking_registers_archive job has no error',
        v_error_count = 0,
        'errors=' || v_error_count || COALESCE(
            ' | ' || (SELECT error_message FROM _mmr_results LIMIT 1), ''
        ));

    PERFORM maint_assert(v_sec, 'job_name is booking_registers_archive',
        EXISTS(SELECT 1 FROM _mmr_results WHERE job_name = 'booking_registers_archive'));

    PERFORM maint_assert(v_sec, 'duration_ms >= 0',
        NOT EXISTS(SELECT 1 FROM _mmr_results WHERE duration_ms < 0));

    DROP TABLE _mmr_results;
END $$;


-- ============================================================
-- T-15  ensure_daily_maintenance_schedule
--       and ensure_monthly_maintenance_schedule
-- ============================================================

DO $$
DECLARE
    v_sec    TEXT := 'T-15 schedule_helpers';
    v_result TEXT;
BEGIN
    -- Both functions must return a non-empty string regardless of
    -- whether pg_cron is installed or not.
    SELECT ensure_daily_maintenance_schedule() INTO v_result;
    PERFORM maint_assert(v_sec, 'ensure_daily_maintenance_schedule returns a string',
        v_result IS NOT NULL AND length(v_result) > 0,
        LEFT(COALESCE(v_result, 'NULL'), 80));

    SELECT ensure_monthly_maintenance_schedule() INTO v_result;
    PERFORM maint_assert(v_sec, 'ensure_monthly_maintenance_schedule returns a string',
        v_result IS NOT NULL AND length(v_result) > 0,
        LEFT(COALESCE(v_result, 'NULL'), 80));

    -- Custom job name parameter
    SELECT ensure_daily_maintenance_schedule('test-daily-maint-custom', '30 4 * * *')
    INTO v_result;
    PERFORM maint_assert(v_sec, 'custom job_name param accepted',
        v_result IS NOT NULL AND length(v_result) > 0);

    SELECT ensure_monthly_maintenance_schedule('test-monthly-maint-custom', '0 5 15 * *')
    INTO v_result;
    PERFORM maint_assert(v_sec, 'custom monthly job_name param accepted',
        v_result IS NOT NULL AND length(v_result) > 0);
END $$;


-- ============================================================
-- T-16  CROSS-FUNCTION / INTEGRATION CHECKS
-- ============================================================

DO $$
DECLARE
    v_sec     TEXT := 'T-16 Integration';
    v_br_id   BIGINT;
    v_msg_id  BIGINT;
    v_bar_id  BIGINT;
    v_del     BIGINT;
    r         RECORD;
BEGIN
    -- Insert a booking that is WITHIN retention (should not be archived
    -- by any cleanup function — confirms functions respect boundaries)
    INSERT INTO booking_registers (
        type, arrival, departure, booked_at,
        guest_id, property_id, platform_id, ppl_id,
        thread_ids_json, metadata
    )
    VALUES (
        'booking',
        CURRENT_DATE + 5, CURRENT_DATE + 10,
        NOW(), 99901, 99901, 99901, 99901,
        '[]'::jsonb, '{"test":"integration"}'::jsonb
    )
    RETURNING id INTO v_br_id;

    -- Insert a recent message (should survive cleanup)
    INSERT INTO messages (platform_id, thread_id, mid, content, message_timestamp)
    VALUES (99701, 99701, 99701, '__maint_integration_msg__', NOW())
    RETURNING id INTO v_msg_id;

    -- Insert a 'processing' (non-terminal) applied rule
    INSERT INTO booking_applied_rules (
        booking_entry_id, property_id, platform_id, listing_id,
        rule_uuid, trigger_category, instruction,
        status, applied_at, updated_at
    )
    VALUES (
        v_br_id, 99901, 99901, '__test_listing_99901__',
        '00000000-0000-0000-0000-000000009901'::UUID,
        'checkout', '{"action":"integration"}'::jsonb,
        'processing',
        NOW() - INTERVAL '200 days',
        NOW() - INTERVAL '200 days'
    )
    RETURNING id INTO v_bar_id;

    -- Run all cleanup functions: none should touch within-retention or
    -- non-terminal status rows
    SELECT cleanup_app_logs('90 days')         INTO v_del;
    SELECT cleanup_removed_applied_rules('1 year') INTO v_del;
    SELECT cleanup_failed_applied_rules('90 days') INTO v_del;
    SELECT cleanup_audit_log('180 days')       INTO v_del;
    SELECT cleanup_rate_limits('2 hours')      INTO v_del;
    SELECT * INTO r FROM cleanup_old_messages('30 days','2 years');
    PERFORM cleanup_inactive_workers('180 days');
    SELECT archive_old_bookings('7 years')     INTO v_del;

    PERFORM maint_assert(v_sec,
        'recent booking NOT archived after running archive_old_bookings',
        EXISTS(SELECT 1 FROM booking_registers WHERE id = v_br_id));

    PERFORM maint_assert(v_sec,
        'recent message survives all cleanup functions',
        EXISTS(SELECT 1 FROM messages WHERE id = v_msg_id));

    PERFORM maint_assert(v_sec,
        'processing (non-terminal) applied rule untouched by cleanup_removed/failed',
        EXISTS(SELECT 1 FROM booking_applied_rules WHERE id = v_bar_id));

    -- Cleanup
    DELETE FROM booking_applied_rules WHERE id = v_bar_id;
    DELETE FROM messages WHERE id = v_msg_id;
    DELETE FROM booking_registers WHERE id = v_br_id;
END $$;


-- ============================================================
-- T-17  FIXTURE TEARDOWN
-- ============================================================

DO $$
BEGIN
    -- Remove test FK-chain fixture data in dependency order
    DELETE FROM pricing_rules             WHERE id = 99901;
    DELETE FROM pricing_operation_types   WHERE id = 99901;
    DELETE FROM platform_property_lookup  WHERE id = 99901;
    DELETE FROM properties                WHERE id = 99901;
    DELETE FROM platforms                 WHERE id = 99901;

    RAISE NOTICE 'T-17 Teardown: fixture data removed.';
END $$;


-- ============================================================
-- FINAL SUMMARY
-- ============================================================

DO $$
DECLARE
    v_total   INT;
    v_passed  INT;
    v_failed  INT;
    v_rec     RECORD;
BEGIN
    SELECT COUNT(*),
           COUNT(*) FILTER (WHERE passed),
           COUNT(*) FILTER (WHERE NOT passed)
    INTO v_total, v_passed, v_failed
    FROM maint_test_results;

    RAISE NOTICE '═══════════════════════════════════════════════════';
    RAISE NOTICE 'MAINTENANCE TEST SUITE SUMMARY';
    RAISE NOTICE '───────────────────────────────────────────────────';
    RAISE NOTICE 'Total:  %', v_total;
    RAISE NOTICE 'Passed: %', v_passed;
    RAISE NOTICE 'Failed: %', v_failed;
    RAISE NOTICE '───────────────────────────────────────────────────';

    IF v_failed > 0 THEN
        RAISE NOTICE 'FAILED TESTS:';
        FOR v_rec IN
            SELECT section, test_name, detail
            FROM maint_test_results
            WHERE NOT passed
            ORDER BY id
        LOOP
            RAISE NOTICE '  ✗ [%] % — %',
                v_rec.section, v_rec.test_name, COALESCE(v_rec.detail, '');
        END LOOP;
        RAISE NOTICE '═══════════════════════════════════════════════════';
        -- Raise EXCEPTION so psql -v ON_ERROR_STOP=1 exits non-zero
        RAISE EXCEPTION 'TEST SUITE FAILED: % of % tests failed.', v_failed, v_total;
    ELSE
        RAISE NOTICE 'ALL % TESTS PASSED ✓', v_total;
        RAISE NOTICE '═══════════════════════════════════════════════════';
    END IF;
END $$;


-- Roll back every single INSERT / DELETE made during this run.
-- The database is returned to exactly the state it was in before.
ROLLBACK;
