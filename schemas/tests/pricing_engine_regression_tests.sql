-- ============================================================================
-- Pricing Engine regression test suite
--
-- Purpose:
--   Validate core Pricing Engine mechanics after SQL or function changes.
--
-- Usage:
--   psql -v ON_ERROR_STOP=1 -d <database> -f pricing_engine_regression_tests.sql
--
-- Optional API-level tests:
--   To also test create_pricing_rule(...) and calculate_daily_price(...), set a
--   valid worker API key before running this file in the same session:
--
--   SET pricing_regression.api_key = '<valid_worker_api_key>';
--   \i pricing_engine_regression_tests.sql
--
-- Notes:
--   - The suite runs inside one transaction and ends with ROLLBACK.
--   - Existing active pricing rules are temporarily set inactive inside the
--     transaction so test rules are isolated from production/business rules.
--   - The database must already contain at least one valid
--     platform_property_lookup row joined to properties and platforms.
--   - API-level tests are skipped unless pricing_regression.api_key is set.
-- ============================================================================

BEGIN;

SET LOCAL search_path = public, pg_temp;
SET LOCAL client_min_messages = NOTICE;

CREATE TEMP TABLE pricing_regression_results (
    id BIGSERIAL PRIMARY KEY,
    test_name TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('PASS', 'SKIP')),
    details TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.pricing_regression_pass(
    p_test_name TEXT,
    p_details TEXT DEFAULT NULL
) RETURNS VOID AS $$
BEGIN
    INSERT INTO pricing_regression_results(test_name, status, details)
    VALUES (p_test_name, 'PASS', p_details);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.pricing_regression_skip(
    p_test_name TEXT,
    p_details TEXT DEFAULT NULL
) RETURNS VOID AS $$
BEGIN
    INSERT INTO pricing_regression_results(test_name, status, details)
    VALUES (p_test_name, 'SKIP', p_details);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.pricing_regression_assert_true(
    p_condition BOOLEAN,
    p_test_name TEXT,
    p_details TEXT DEFAULT NULL
) RETURNS VOID AS $$
BEGIN
    IF NOT COALESCE(p_condition, FALSE) THEN
        RAISE EXCEPTION 'Pricing Engine regression failed: % | %',
            p_test_name,
            COALESCE(p_details, 'no details')
            USING ERRCODE = 'P0001';
    END IF;

    PERFORM pg_temp.pricing_regression_pass(p_test_name, p_details);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.pricing_regression_assert_eq_text(
    p_actual TEXT,
    p_expected TEXT,
    p_test_name TEXT
) RETURNS VOID AS $$
BEGIN
    IF p_actual IS DISTINCT FROM p_expected THEN
        RAISE EXCEPTION 'Pricing Engine regression failed: % | expected=%, actual=%',
            p_test_name, p_expected, p_actual
            USING ERRCODE = 'P0001';
    END IF;

    PERFORM pg_temp.pricing_regression_pass(
        p_test_name,
        format('expected=%s, actual=%s', p_expected, p_actual)
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.pricing_regression_assert_eq_int(
    p_actual INT,
    p_expected INT,
    p_test_name TEXT
) RETURNS VOID AS $$
BEGIN
    IF p_actual IS DISTINCT FROM p_expected THEN
        RAISE EXCEPTION 'Pricing Engine regression failed: % | expected=%, actual=%',
            p_test_name, p_expected, p_actual
            USING ERRCODE = 'P0001';
    END IF;

    PERFORM pg_temp.pricing_regression_pass(
        p_test_name,
        format('expected=%s, actual=%s', p_expected, p_actual)
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.pricing_regression_assert_eq_numeric(
    p_actual NUMERIC,
    p_expected NUMERIC,
    p_test_name TEXT
) RETURNS VOID AS $$
BEGIN
    IF p_actual IS DISTINCT FROM p_expected THEN
        RAISE EXCEPTION 'Pricing Engine regression failed: % | expected=%, actual=%',
            p_test_name, p_expected, p_actual
            USING ERRCODE = 'P0001';
    END IF;

    PERFORM pg_temp.pricing_regression_pass(
        p_test_name,
        format('expected=%s, actual=%s', p_expected, p_actual)
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_temp.pricing_regression_insert_rule(
    p_rule_name TEXT,
    p_scope TEXT,
    p_fixture_property_id BIGINT,
    p_fixture_platform_id BIGINT,
    p_fixture_ppl_id BIGINT,
    p_operation_code TEXT,
    p_rule_config JSONB,
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL,
    p_priority INT DEFAULT 50,
    p_allow_override BOOLEAN DEFAULT TRUE,
    p_applicable_dates JSONB DEFAULT NULL,
    p_day_of_week_pattern INT DEFAULT NULL
) RETURNS BIGINT AS $$
DECLARE
    v_operation_id BIGINT;
    v_rule_id BIGINT;
    v_config JSONB;
BEGIN
    SELECT id
    INTO v_operation_id
    FROM pricing_operation_types
    WHERE operation_code = p_operation_code
      AND is_active = TRUE
    ORDER BY id
    LIMIT 1;

    IF v_operation_id IS NULL THEN
        RAISE EXCEPTION 'Missing active pricing_operation_types row for operation_code=%', p_operation_code;
    END IF;

    v_config := COALESCE(p_rule_config, '{}'::JSONB);

    IF jsonb_typeof(v_config) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'Test rule_config must be a JSON object';
    END IF;

    v_config := v_config || jsonb_build_object(
        'metadata',
        COALESCE(v_config->'metadata', '{}'::JSONB)
        || jsonb_build_object('test_suite', 'pricing_engine_regression')
    );

    INSERT INTO pricing_rules (
        property_id,
        platform_id,
        platform_property_lookup_id,
        operation_id,
        rule_config,
        applicable_dates,
        start_date,
        end_date,
        day_of_week_pattern,
        rule_name,
        priority,
        status,
        allow_override,
        created_by,
        created_via,
        activated_at
    ) VALUES (
        CASE WHEN p_scope = 'property' THEN p_fixture_property_id ELSE NULL END,
        CASE WHEN p_scope = 'platform' THEN p_fixture_platform_id ELSE NULL END,
        CASE WHEN p_scope = 'listing' THEN p_fixture_ppl_id ELSE NULL END,
        v_operation_id,
        v_config,
        p_applicable_dates,
        p_start_date,
        p_end_date,
        p_day_of_week_pattern,
        p_rule_name,
        p_priority,
        'active',
        p_allow_override,
        'pricing_regression',
        'sql_regression_test',
        NOW()
    )
    RETURNING id INTO v_rule_id;

    RETURN v_rule_id;
END;
$$ LANGUAGE plpgsql;

DO $$
DECLARE
    v_property_id BIGINT;
    v_platform_id BIGINT;
    v_ppl_id BIGINT;
    v_listing_id TEXT;
    v_api_key TEXT;

    v_base_date DATE := CURRENT_DATE + 30;
    v_d_set DATE;
    v_d_scope DATE;
    v_d_applicable DATE;
    v_d_applicable_miss DATE;
    v_d_stay DATE;
    v_d_tree DATE;
    v_d_window_start DATE;
    v_d_position DATE;
    v_d_cap DATE;
    v_d_conflict DATE;
    v_d_hard_conflict DATE;
    v_d_invalid DATE;
    v_d_calc DATE;
    v_d_override DATE;
    v_d_blocked DATE;
    v_d_api DATE;

    v_id BIGINT;
    v_id_a BIGINT;
    v_id_b BIGINT;
    v_id_c BIGINT;
    v_id_d BIGINT;
    v_low_rule_id BIGINT;
    v_high_rule_id BIGINT;
    v_exists BOOLEAN;
    v_count INT;
    v_text TEXT;
    v_reason JSONB;
    v_expected_error BOOLEAN;
    v_calc JSONB;
    v_uuid UUID;
    v_dow_bit INT;
BEGIN
    -- ---------------------------------------------------------------------
    -- Preflight: required tables and functions
    -- ---------------------------------------------------------------------
    PERFORM pg_temp.pricing_regression_assert_true(to_regclass('public.pricing_config') IS NOT NULL, 'preflight table pricing_config exists');
    PERFORM pg_temp.pricing_regression_assert_true(to_regclass('public.pricing_operation_types') IS NOT NULL, 'preflight table pricing_operation_types exists');
    PERFORM pg_temp.pricing_regression_assert_true(to_regclass('public.pricing_rules') IS NOT NULL, 'preflight table pricing_rules exists');
    PERFORM pg_temp.pricing_regression_assert_true(to_regclass('public.pricing_rule_audit') IS NOT NULL, 'preflight table pricing_rule_audit exists');
    PERFORM pg_temp.pricing_regression_assert_true(to_regclass('public.price_overrides') IS NOT NULL, 'preflight table price_overrides exists');
    PERFORM pg_temp.pricing_regression_assert_true(to_regclass('public.calculated_prices') IS NOT NULL, 'preflight table calculated_prices exists');
    PERFORM pg_temp.pricing_regression_assert_true(to_regclass('public.ical_events') IS NOT NULL, 'preflight table ical_events exists');
    PERFORM pg_temp.pricing_regression_assert_true(to_regclass('public.gap_days') IS NOT NULL, 'preflight table gap_days exists');
    PERFORM pg_temp.pricing_regression_assert_true(to_regclass('public.platform_property_lookup') IS NOT NULL, 'preflight table platform_property_lookup exists');
    PERFORM pg_temp.pricing_regression_assert_true(to_regclass('public.properties') IS NOT NULL, 'preflight table properties exists');
    PERFORM pg_temp.pricing_regression_assert_true(to_regclass('public.platforms') IS NOT NULL, 'preflight table platforms exists');

    PERFORM pg_temp.pricing_regression_assert_true(
        EXISTS (
            SELECT 1
            FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public'
              AND p.proname = 'get_applicable_pricing_rules'
              AND p.pronargs = 13
        ),
        'preflight get_applicable_pricing_rules has latest 13-parameter signature'
    );

    PERFORM pg_temp.pricing_regression_assert_true(
        EXISTS (
            SELECT 1
            FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public'
              AND p.proname = 'calculate_daily_price'
              AND p.pronargs = 10
        ),
        'preflight calculate_daily_price has 10-parameter signature'
    );

    PERFORM pg_temp.pricing_regression_assert_true(
        EXISTS (
            SELECT 1 FROM pricing_operation_types
            WHERE operation_code = 'set'
              AND is_active = TRUE
        ),
        'preflight canonical set operation exists and is active'
    );

    -- ---------------------------------------------------------------------
    -- Find one real fixture mapping. This avoids guessing unknown NOT NULL
    -- columns in property/platform tables owned by another schema file.
    -- ---------------------------------------------------------------------
    SELECT
        ppl.id::BIGINT,
        ppl.platform_id::BIGINT,
        ppl.properties_ptr::BIGINT,
        ppl.listing_id::TEXT
    INTO
        v_ppl_id,
        v_platform_id,
        v_property_id,
        v_listing_id
    FROM platform_property_lookup ppl
    JOIN properties pr ON pr.id = ppl.properties_ptr
    JOIN platforms pf ON pf.id = ppl.platform_id
    WHERE ppl.id IS NOT NULL
      AND ppl.platform_id IS NOT NULL
      AND ppl.properties_ptr IS NOT NULL
    ORDER BY ppl.id
    LIMIT 1;

    PERFORM pg_temp.pricing_regression_assert_true(
        v_ppl_id IS NOT NULL,
        'fixture platform_property_lookup row is available',
        'The test suite needs at least one valid platform/listing/property mapping.'
    );

    RAISE NOTICE 'Pricing regression fixture: property_id=%, platform_id=%, ppl_id=%, listing_id=%',
        v_property_id, v_platform_id, v_ppl_id, v_listing_id;

    -- ---------------------------------------------------------------------
    -- Isolate tests from existing active pricing rules. Rollback restores them.
    -- ---------------------------------------------------------------------
    UPDATE pricing_rules
    SET status = 'inactive'
    WHERE status = 'active';

    v_d_set := v_base_date;
    v_d_scope := v_base_date + 1;
    v_d_applicable := v_base_date + 2;
    v_d_applicable_miss := v_base_date + 3;
    v_d_stay := v_base_date + 4;
    v_d_tree := v_base_date + 5;
    v_d_window_start := v_base_date + 6;
    v_d_position := v_base_date + 10;
    v_d_cap := v_base_date + 11;
    v_d_conflict := v_base_date + 12;
    v_d_hard_conflict := v_base_date + 13;
    v_d_invalid := v_base_date + 14;
    v_d_calc := v_base_date + 15;
    v_d_override := v_base_date + 16;
    v_d_blocked := v_base_date + 17;
    v_d_api := v_base_date + 18;

    DELETE FROM calculated_prices
    WHERE property_id = v_property_id
      AND platform_id = v_platform_id
      AND date BETWEEN v_base_date AND v_base_date + 60;

    DELETE FROM price_overrides
    WHERE property_id = v_property_id
      AND platform_id = v_platform_id
      AND date BETWEEN v_base_date AND v_base_date + 60;

    DELETE FROM gap_days
    WHERE property_id = v_property_id
      AND platform_id = v_platform_id
      AND gap_date BETWEEN v_base_date AND v_base_date + 60;

    DELETE FROM ical_events
    WHERE property_id = v_property_id
      AND platform_id = v_platform_id
      AND start_date < v_base_date + 61
      AND end_date > v_base_date - 1;

    INSERT INTO pricing_config(key, value, value_type, description, category)
    VALUES (
        'max_stay_adjustment_rules',
        '1',
        'integer',
        'Regression test default for stay-adjustment rule cap.',
        'pricing'
    )
    ON CONFLICT (key) DO UPDATE
    SET value = EXCLUDED.value,
        value_type = EXCLUDED.value_type,
        category = EXCLUDED.category,
        updated_at = NOW();

    -- ---------------------------------------------------------------------
    -- Pure helper mechanics
    -- ---------------------------------------------------------------------
    PERFORM pg_temp.pricing_regression_assert_true(
        matches_dow_pattern(DATE '2026-05-11', 1),
        'matches_dow_pattern matches Monday bit'
    );

    PERFORM pg_temp.pricing_regression_assert_true(
        NOT matches_dow_pattern(DATE '2026-05-11', 2),
        'matches_dow_pattern rejects wrong bit'
    );

    PERFORM pg_temp.pricing_regression_assert_true(
        evaluate_rule_apply_window(
            '{"applies_from":"arrival","duration_days":3}'::JSONB,
            v_d_window_start + 2,
            v_d_window_start,
            v_d_window_start + 5
        ),
        'evaluate_rule_apply_window allows target inside arrival window'
    );

    PERFORM pg_temp.pricing_regression_assert_true(
        NOT evaluate_rule_apply_window(
            '{"applies_from":"arrival","duration_days":3}'::JSONB,
            v_d_window_start + 3,
            v_d_window_start,
            v_d_window_start + 5
        ),
        'evaluate_rule_apply_window rejects first target outside arrival window'
    );

    v_reason := pricing_rule_configs_overlap_reason(
        '{"stay_length":1}'::JSONB,
        '{"stay_length":2}'::JSONB
    );

    PERFORM pg_temp.pricing_regression_assert_true(
        COALESCE((v_reason->>'overlap')::BOOLEAN, TRUE) = FALSE,
        'pricing_rule_configs_overlap_reason detects disjoint numeric domains',
        v_reason::TEXT
    );

    v_expected_error := FALSE;
    BEGIN
        PERFORM validate_pricing_rule_condition_tree(
            '{"type":"group","evaluation_operator":"xor","members":[]}'::JSONB,
            5,
            20,
            50
        );
    EXCEPTION WHEN OTHERS THEN
        v_expected_error := TRUE;
    END;

    PERFORM pg_temp.pricing_regression_assert_true(
        v_expected_error,
        'validate_pricing_rule_condition_tree rejects invalid group operator'
    );

    -- ---------------------------------------------------------------------
    -- set/override normalization
    -- ---------------------------------------------------------------------
    v_id := pg_temp.pricing_regression_insert_rule(
        'REG_SET_NORMALIZATION',
        'property',
        v_property_id,
        v_platform_id,
        v_ppl_id,
        'set',
        jsonb_build_object(
            'subject', 'price',
            'operation', jsonb_build_object('do', 'set', 'type', 'fixed', 'amount', 250)
        ),
        v_d_set,
        v_d_set,
        45
    );

    SELECT EXISTS (
        SELECT 1
        FROM get_applicable_pricing_rules(
            v_property_id,
            v_platform_id,
            v_d_set,
            'override',
            FALSE,
            v_ppl_id,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL
        ) r
        WHERE r.rule_id = v_id
          AND r.operation_code = 'set'
    ) INTO v_exists;

    PERFORM pg_temp.pricing_regression_assert_true(
        v_exists,
        'legacy override operation filter resolves to canonical set rule'
    );

    -- ---------------------------------------------------------------------
    -- Scope precedence: listing > property > platform > global
    -- ---------------------------------------------------------------------
    v_id_a := pg_temp.pricing_regression_insert_rule(
        'REG_SCOPE_GLOBAL',
        'global',
        v_property_id,
        v_platform_id,
        v_ppl_id,
        'increase',
        jsonb_build_object('subject', 'price', 'operation', jsonb_build_object('do', '+ increase', 'type', 'flat', 'amount', 1)),
        v_d_scope,
        v_d_scope,
        10
    );

    v_id_b := pg_temp.pricing_regression_insert_rule(
        'REG_SCOPE_PLATFORM',
        'platform',
        v_property_id,
        v_platform_id,
        v_ppl_id,
        'increase',
        jsonb_build_object('subject', 'price', 'operation', jsonb_build_object('do', '+ increase', 'type', 'flat', 'amount', 2)),
        v_d_scope,
        v_d_scope,
        20
    );

    v_id_c := pg_temp.pricing_regression_insert_rule(
        'REG_SCOPE_PROPERTY',
        'property',
        v_property_id,
        v_platform_id,
        v_ppl_id,
        'increase',
        jsonb_build_object('subject', 'price', 'operation', jsonb_build_object('do', '+ increase', 'type', 'flat', 'amount', 3)),
        v_d_scope,
        v_d_scope,
        30
    );

    v_id_d := pg_temp.pricing_regression_insert_rule(
        'REG_SCOPE_LISTING',
        'listing',
        v_property_id,
        v_platform_id,
        v_ppl_id,
        'increase',
        jsonb_build_object('subject', 'price', 'operation', jsonb_build_object('do', '+ increase', 'type', 'flat', 'amount', 4)),
        v_d_scope,
        v_d_scope,
        40
    );

    SELECT COUNT(*)::INT
    INTO v_count
    FROM get_applicable_pricing_rules(
        v_property_id, v_platform_id, v_d_scope, 'increase', FALSE,
        v_ppl_id, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    ) r
    WHERE r.rule_id IN (v_id_a, v_id_b, v_id_c, v_id_d);

    PERFORM pg_temp.pricing_regression_assert_eq_int(v_count, 4, 'scope precedence returns all four matching scope levels');

    SELECT r.scope
    INTO v_text
    FROM get_applicable_pricing_rules(
        v_property_id, v_platform_id, v_d_scope, 'increase', FALSE,
        v_ppl_id, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    ) r
    WHERE r.rule_id IN (v_id_a, v_id_b, v_id_c, v_id_d)
    LIMIT 1;

    PERFORM pg_temp.pricing_regression_assert_eq_text(v_text, 'listing', 'listing scope sorts before property/platform/global');

    -- ---------------------------------------------------------------------
    -- Date matching and applicable_dates JSONB matching
    -- ---------------------------------------------------------------------
    v_id := pg_temp.pricing_regression_insert_rule(
        'REG_APPLICABLE_DATES',
        'property',
        v_property_id,
        v_platform_id,
        v_ppl_id,
        'increase',
        jsonb_build_object('subject', 'price', 'operation', jsonb_build_object('do', '+ increase', 'type', 'flat', 'amount', 5)),
        NULL,
        NULL,
        61,
        TRUE,
        jsonb_build_object(v_d_applicable::TEXT, TRUE),
        NULL
    );

    SELECT EXISTS (
        SELECT 1 FROM get_applicable_pricing_rules(
            v_property_id, v_platform_id, v_d_applicable, 'increase', FALSE,
            v_ppl_id, NULL, NULL, NULL, NULL, NULL, NULL, NULL
        ) r WHERE r.rule_id = v_id
    ) INTO v_exists;

    PERFORM pg_temp.pricing_regression_assert_true(v_exists, 'applicable_dates JSONB includes configured target date');

    SELECT EXISTS (
        SELECT 1 FROM get_applicable_pricing_rules(
            v_property_id, v_platform_id, v_d_applicable_miss, 'increase', FALSE,
            v_ppl_id, NULL, NULL, NULL, NULL, NULL, NULL, NULL
        ) r WHERE r.rule_id = v_id
    ) INTO v_exists;

    PERFORM pg_temp.pricing_regression_assert_true(NOT v_exists, 'applicable_dates JSONB excludes unconfigured target date');

    v_dow_bit := CASE EXTRACT(DOW FROM v_d_applicable)::INT
        WHEN 0 THEN 64
        WHEN 1 THEN 1
        WHEN 2 THEN 2
        WHEN 3 THEN 4
        WHEN 4 THEN 8
        WHEN 5 THEN 16
        WHEN 6 THEN 32
    END;

    v_id := pg_temp.pricing_regression_insert_rule(
        'REG_DOW_PATTERN',
        'property',
        v_property_id,
        v_platform_id,
        v_ppl_id,
        'decrease',
        jsonb_build_object('subject', 'price', 'operation', jsonb_build_object('do', '- decrease', 'type', 'flat', 'amount', 1)),
        NULL,
        NULL,
        62,
        TRUE,
        NULL,
        v_dow_bit
    );

    SELECT EXISTS (
        SELECT 1 FROM get_applicable_pricing_rules(
            v_property_id, v_platform_id, v_d_applicable, 'decrease', FALSE,
            v_ppl_id, NULL, NULL, NULL, NULL, NULL, NULL, NULL
        ) r WHERE r.rule_id = v_id
    ) INTO v_exists;

    PERFORM pg_temp.pricing_regression_assert_true(v_exists, 'day_of_week_pattern matches computed target date bit');

    -- ---------------------------------------------------------------------
    -- Stay adjustment matching and negative input guard
    -- ---------------------------------------------------------------------
    v_id := pg_temp.pricing_regression_insert_rule(
        'REG_STAY_ADJUSTMENT',
        'property',
        v_property_id,
        v_platform_id,
        v_ppl_id,
        'increase',
        jsonb_build_object(
            'subject', 'price',
            'operation', jsonb_build_object('do', '+ increase', 'type', 'percentage', 'amount', 10),
            'stay_length', jsonb_build_object('gte', 5),
            'stay_extended', 2,
            'stay_contracted', 1,
            'net_stay', jsonb_build_object('gte', 6)
        ),
        v_d_stay,
        v_d_stay,
        63
    );

    SELECT EXISTS (
        SELECT 1 FROM get_applicable_pricing_rules(
            v_property_id, v_platform_id, v_d_stay, 'increase', FALSE,
            v_ppl_id, 5, NULL, 2, 1, NULL, NULL, NULL
        ) r WHERE r.rule_id = v_id
    ) INTO v_exists;

    PERFORM pg_temp.pricing_regression_assert_true(v_exists, 'stay adjustment rule matches stay_length, extension, contraction, and net_stay');

    SELECT EXISTS (
        SELECT 1 FROM get_applicable_pricing_rules(
            v_property_id, v_platform_id, v_d_stay, 'increase', FALSE,
            v_ppl_id, 5, NULL, 1, 1, NULL, NULL, NULL
        ) r WHERE r.rule_id = v_id
    ) INTO v_exists;

    PERFORM pg_temp.pricing_regression_assert_true(NOT v_exists, 'stay adjustment rule rejects wrong stay_extended value');

    v_expected_error := FALSE;
    BEGIN
        PERFORM 1 FROM get_applicable_pricing_rules(
            v_property_id, v_platform_id, v_d_stay, 'increase', FALSE,
            v_ppl_id, 5, NULL, -1, 0, NULL, NULL, NULL
        );
    EXCEPTION WHEN SQLSTATE '22023' THEN
        v_expected_error := TRUE;
    END;

    PERFORM pg_temp.pricing_regression_assert_true(v_expected_error, 'negative stay_extended input is rejected');

    -- ---------------------------------------------------------------------
    -- Condition tree matching
    -- ---------------------------------------------------------------------
    v_id := pg_temp.pricing_regression_insert_rule(
        'REG_CONDITION_TREE_AND',
        'property',
        v_property_id,
        v_platform_id,
        v_ppl_id,
        'increase',
        jsonb_build_object(
            'subject', 'price',
            'operation', jsonb_build_object('do', '+ increase', 'type', 'flat', 'amount', 7),
            'conditions_version', 2,
            'condition_tree', jsonb_build_object(
                'type', 'group',
                'evaluation_operator', 'and',
                'members', jsonb_build_array(
                    jsonb_build_object('type', 'condition', 'condition_name', 'stay_length', 'comparison_operator', 'gte', 'value', 3),
                    jsonb_build_object('type', 'condition', 'condition_name', 'booking_category', 'comparison_operator', 'any_of', 'value', jsonb_build_array('job_related'))
                )
            )
        ),
        v_d_tree,
        v_d_tree,
        64
    );

    SELECT EXISTS (
        SELECT 1 FROM get_applicable_pricing_rules(
            v_property_id, v_platform_id, v_d_tree, 'increase', FALSE,
            v_ppl_id, 4, ARRAY['job_related']::TEXT[], NULL, NULL, NULL, NULL, NULL
        ) r WHERE r.rule_id = v_id
    ) INTO v_exists;

    PERFORM pg_temp.pricing_regression_assert_true(v_exists, 'condition_tree AND matches numeric and booking category inputs');

    SELECT EXISTS (
        SELECT 1 FROM get_applicable_pricing_rules(
            v_property_id, v_platform_id, v_d_tree, 'increase', FALSE,
            v_ppl_id, 4, ARRAY['medical_related']::TEXT[], NULL, NULL, NULL, NULL, NULL
        ) r WHERE r.rule_id = v_id
    ) INTO v_exists;

    PERFORM pg_temp.pricing_regression_assert_true(NOT v_exists, 'condition_tree AND rejects wrong booking category');

    -- ---------------------------------------------------------------------
    -- apply_window through get_applicable_pricing_rules
    -- ---------------------------------------------------------------------
    v_id := pg_temp.pricing_regression_insert_rule(
        'REG_APPLY_WINDOW',
        'property',
        v_property_id,
        v_platform_id,
        v_ppl_id,
        'increase',
        jsonb_build_object(
            'subject', 'price',
            'operation', jsonb_build_object('do', '+ increase', 'type', 'flat', 'amount', 8),
            'apply_window', jsonb_build_object('applies_from', 'arrival', 'duration_days', 3)
        ),
        v_d_window_start,
        v_d_window_start + 10,
        65
    );

    SELECT EXISTS (
        SELECT 1 FROM get_applicable_pricing_rules(
            v_property_id, v_platform_id, v_d_window_start + 2, 'increase', FALSE,
            v_ppl_id, NULL, NULL, NULL, NULL, v_d_window_start, v_d_window_start + 5, NULL
        ) r WHERE r.rule_id = v_id
    ) INTO v_exists;

    PERFORM pg_temp.pricing_regression_assert_true(v_exists, 'apply_window allows target date inside arrival-relative window');

    SELECT EXISTS (
        SELECT 1 FROM get_applicable_pricing_rules(
            v_property_id, v_platform_id, v_d_window_start + 3, 'increase', FALSE,
            v_ppl_id, NULL, NULL, NULL, NULL, v_d_window_start, v_d_window_start + 5, NULL
        ) r WHERE r.rule_id = v_id
    ) INTO v_exists;

    PERFORM pg_temp.pricing_regression_assert_true(NOT v_exists, 'apply_window rejects target date outside arrival-relative window');

    -- ---------------------------------------------------------------------
    -- Booking class position matching
    -- ---------------------------------------------------------------------
    v_id := pg_temp.pricing_regression_insert_rule(
        'REG_BOOKING_CLASS_POSITION',
        'property',
        v_property_id,
        v_platform_id,
        v_ppl_id,
        'increase',
        jsonb_build_object(
            'subject', 'price',
            'operation', jsonb_build_object('do', '+ increase', 'type', 'flat', 'amount', 9),
            'conditions_version', 2,
            'condition_tree', jsonb_build_object(
                'type', 'condition',
                'condition_name', 'booking_category',
                'comparison_operator', 'any_of',
                'value', jsonb_build_array('job_related'),
                'pos', jsonb_build_array(0)
            )
        ),
        v_d_position,
        v_d_position,
        66
    );

    SELECT EXISTS (
        SELECT 1 FROM get_applicable_pricing_rules(
            v_property_id, v_platform_id, v_d_position, 'increase', FALSE,
            v_ppl_id, NULL, ARRAY['job_related']::TEXT[], NULL, NULL, NULL, NULL,
            '{"job_related":[0]}'::JSONB
        ) r WHERE r.rule_id = v_id
    ) INTO v_exists;

    PERFORM pg_temp.pricing_regression_assert_true(v_exists, 'booking class position rule matches correct class position');

    SELECT EXISTS (
        SELECT 1 FROM get_applicable_pricing_rules(
            v_property_id, v_platform_id, v_d_position, 'increase', FALSE,
            v_ppl_id, NULL, ARRAY['job_related']::TEXT[], NULL, NULL, NULL, NULL,
            '{"job_related":[1]}'::JSONB
        ) r WHERE r.rule_id = v_id
    ) INTO v_exists;

    PERFORM pg_temp.pricing_regression_assert_true(NOT v_exists, 'booking class position rule rejects wrong class position');

    -- ---------------------------------------------------------------------
    -- Stay-adjustment cap
    -- ---------------------------------------------------------------------
    v_low_rule_id := pg_temp.pricing_regression_insert_rule(
        'REG_STAY_CAP_LOW',
        'property',
        v_property_id,
        v_platform_id,
        v_ppl_id,
        'increase',
        jsonb_build_object(
            'subject', 'price',
            'operation', jsonb_build_object('do', '+ increase', 'type', 'flat', 'amount', 11),
            'stay_extended', 1
        ),
        v_d_cap,
        v_d_cap,
        50
    );

    v_high_rule_id := pg_temp.pricing_regression_insert_rule(
        'REG_STAY_CAP_HIGH',
        'property',
        v_property_id,
        v_platform_id,
        v_ppl_id,
        'increase',
        jsonb_build_object(
            'subject', 'price',
            'operation', jsonb_build_object('do', '+ increase', 'type', 'flat', 'amount', 12),
            'stay_extended', 1
        ),
        v_d_cap,
        v_d_cap,
        60
    );

    SELECT COUNT(*)::INT
    INTO v_count
    FROM get_applicable_pricing_rules(
        v_property_id, v_platform_id, v_d_cap, 'increase', FALSE,
        v_ppl_id, NULL, NULL, 1, 0, NULL, NULL, NULL
    ) r
    WHERE r.rule_id IN (v_low_rule_id, v_high_rule_id);

    PERFORM pg_temp.pricing_regression_assert_eq_int(v_count, 1, 'max_stay_adjustment_rules caps matching stay-adjustment rules to one');

    SELECT r.rule_id
    INTO v_id
    FROM get_applicable_pricing_rules(
        v_property_id, v_platform_id, v_d_cap, 'increase', FALSE,
        v_ppl_id, NULL, NULL, 1, 0, NULL, NULL, NULL
    ) r
    WHERE r.rule_id IN (v_low_rule_id, v_high_rule_id);

    PERFORM pg_temp.pricing_regression_assert_true(v_id = v_high_rule_id, 'stay-adjustment cap keeps highest-scoring stay rule');

    -- ---------------------------------------------------------------------
    -- Conflict guards
    -- ---------------------------------------------------------------------
    v_id_a := pg_temp.pricing_regression_insert_rule(
        'REG_CONFLICT_BASE',
        'property',
        v_property_id,
        v_platform_id,
        v_ppl_id,
        'increase',
        jsonb_build_object('subject', 'price', 'operation', jsonb_build_object('do', '+ increase', 'type', 'flat', 'amount', 13)),
        v_d_conflict,
        v_d_conflict,
        77,
        TRUE
    );

    v_expected_error := FALSE;
    BEGIN
        PERFORM pg_temp.pricing_regression_insert_rule(
            'REG_CONFLICT_BLOCKED_SAME_PRIORITY',
            'property',
            v_property_id,
            v_platform_id,
            v_ppl_id,
            'increase',
            jsonb_build_object('subject', 'price', 'operation', jsonb_build_object('do', '+ increase', 'type', 'flat', 'amount', 14)),
            v_d_conflict,
            v_d_conflict,
            77,
            TRUE
        );
    EXCEPTION WHEN OTHERS THEN
        v_expected_error := TRUE;
    END;

    PERFORM pg_temp.pricing_regression_assert_true(v_expected_error, 'semantic guard blocks same-scope same-priority overlapping rule');

    v_id_b := pg_temp.pricing_regression_insert_rule(
        'REG_CONFLICT_ALLOWED_BY_METADATA',
        'property',
        v_property_id,
        v_platform_id,
        v_ppl_id,
        'increase',
        jsonb_build_object(
            'subject', 'price',
            'operation', jsonb_build_object('do', '+ increase', 'type', 'flat', 'amount', 15),
            'metadata', jsonb_build_object('allow_same_priority_overlap', TRUE)
        ),
        v_d_conflict,
        v_d_conflict,
        77,
        TRUE
    );

    PERFORM pg_temp.pricing_regression_assert_true(v_id_b IS NOT NULL, 'metadata allow_same_priority_overlap permits explicit same-priority overlap');

    v_id_c := pg_temp.pricing_regression_insert_rule(
        'REG_HARD_CONFLICT_BASE',
        'property',
        v_property_id,
        v_platform_id,
        v_ppl_id,
        'decrease',
        jsonb_build_object('subject', 'price', 'operation', jsonb_build_object('do', '- decrease', 'type', 'flat', 'amount', 16)),
        v_d_hard_conflict,
        v_d_hard_conflict,
        70,
        FALSE
    );

    v_expected_error := FALSE;
    BEGIN
        PERFORM pg_temp.pricing_regression_insert_rule(
            'REG_HARD_CONFLICT_BLOCKED',
            'property',
            v_property_id,
            v_platform_id,
            v_ppl_id,
            'decrease',
            jsonb_build_object('subject', 'price', 'operation', jsonb_build_object('do', '- decrease', 'type', 'flat', 'amount', 17)),
            v_d_hard_conflict,
            v_d_hard_conflict,
            71,
            TRUE
        );
    EXCEPTION WHEN OTHERS THEN
        v_expected_error := TRUE;
    END;

    PERFORM pg_temp.pricing_regression_assert_true(v_expected_error, 'allow_override=false hard conflict blocks overlapping incoming rule');

    -- ---------------------------------------------------------------------
    -- Rule-config trigger edge cases
    -- ---------------------------------------------------------------------
    v_expected_error := FALSE;
    BEGIN
        PERFORM pg_temp.pricing_regression_insert_rule(
            'REG_INVALID_CONDITION_TREE_VERSION',
            'listing',
            v_property_id,
            v_platform_id,
            v_ppl_id,
            'increase',
            jsonb_build_object(
                'subject', 'price',
                'operation', jsonb_build_object('do', '+ increase', 'type', 'flat', 'amount', 1),
                'conditions_version', 1,
                'condition_tree', jsonb_build_object('type', 'condition', 'condition_name', 'stay_length', 'comparison_operator', 'gte', 'value', 1)
            ),
            v_d_invalid,
            v_d_invalid,
            10
        );
    EXCEPTION WHEN OTHERS THEN
        v_expected_error := TRUE;
    END;

    PERFORM pg_temp.pricing_regression_assert_true(v_expected_error, 'rule_config trigger rejects condition_tree without conditions_version 2');

    v_expected_error := FALSE;
    BEGIN
        PERFORM pg_temp.pricing_regression_insert_rule(
            'REG_INVALID_POSITION_METADATA',
            'listing',
            v_property_id,
            v_platform_id,
            v_ppl_id,
            'increase',
            jsonb_build_object(
                'subject', 'price',
                'operation', jsonb_build_object('do', '+ increase', 'type', 'flat', 'amount', 1),
                'conditions_version', 2,
                'condition_tree', jsonb_build_object(
                    'type', 'condition',
                    'condition_name', 'booking_category',
                    'comparison_operator', 'any_of',
                    'value', jsonb_build_array('job_related', 'medical_related'),
                    'pos', jsonb_build_array(0)
                )
            ),
            v_d_invalid + 1,
            v_d_invalid + 1,
            11
        );
    EXCEPTION WHEN OTHERS THEN
        v_expected_error := TRUE;
    END;

    PERFORM pg_temp.pricing_regression_assert_true(v_expected_error, 'rule_config trigger rejects booking class pos/value length mismatch');

    -- ---------------------------------------------------------------------
    -- Gap day lookup in rule matching
    -- ---------------------------------------------------------------------
    INSERT INTO gap_days(
        property_id,
        platform_id,
        gap_date,
        preceding_booking_end,
        following_booking_start,
        gap_length,
        gap_position,
        days_until_gap,
        is_last_minute,
        is_long_gap,
        is_weekend_gap
    ) VALUES (
        v_property_id,
        v_platform_id,
        v_base_date + 20,
        v_base_date + 19,
        v_base_date + 23,
        3,
        1,
        20,
        FALSE,
        TRUE,
        FALSE
    ) ON CONFLICT (property_id, platform_id, gap_date) DO UPDATE
    SET is_long_gap = TRUE,
        is_last_minute = FALSE,
        gap_length = 3;

    v_id := pg_temp.pricing_regression_insert_rule(
        'REG_GAP_DAY_CONDITION',
        'property',
        v_property_id,
        v_platform_id,
        v_ppl_id,
        'increase',
        jsonb_build_object(
            'subject', 'price',
            'operation', jsonb_build_object('do', '+ increase', 'type', 'flat', 'amount', 18),
            'conditions', jsonb_build_object(
                'gap_day', jsonb_build_object('is_long_gap', TRUE)
            )
        ),
        v_base_date + 20,
        v_base_date + 20,
        67
    );

    SELECT EXISTS (
        SELECT 1 FROM get_applicable_pricing_rules(
            v_property_id, v_platform_id, v_base_date + 20, 'increase', TRUE,
            v_ppl_id, NULL, NULL, NULL, NULL, NULL, NULL, NULL
        ) r WHERE r.rule_id = v_id
    ) INTO v_exists;

    PERFORM pg_temp.pricing_regression_assert_true(v_exists, 'gap_day condition matches long gap metadata when p_check_gaps is true');

    -- ---------------------------------------------------------------------
    -- API-level rule creation and full price calculation tests.
    -- These run only when a valid worker API key is supplied through the custom
    -- setting pricing_regression.api_key.
    -- ---------------------------------------------------------------------
    v_api_key := NULLIF(current_setting('pricing_regression.api_key', TRUE), '');

    IF v_api_key IS NULL THEN
        PERFORM pg_temp.pricing_regression_skip(
            'API-level create_pricing_rule and calculate_daily_price tests',
            'Set pricing_regression.api_key to run worker-authenticated tests.'
        );
    ELSE
        v_uuid := create_pricing_rule(
            v_api_key,
            v_property_id,
            NULL,
            'increase',
            jsonb_build_object(
                'subject', 'price',
                'operation', jsonb_build_object('do', '+ increase', 'type', 'flat', 'amount', 6),
                'metadata', jsonb_build_object('test_suite', 'pricing_engine_regression')
            ),
            NULL,
            v_d_api,
            v_d_api,
            NULL,
            55,
            'REG_API_CREATE_RULE',
            NULL
        );

        PERFORM pg_temp.pricing_regression_assert_true(
            EXISTS (SELECT 1 FROM pricing_rules WHERE rule_uuid = v_uuid AND rule_name = 'REG_API_CREATE_RULE'),
            'create_pricing_rule creates an active pricing rule through the API function'
        );

        v_id := pg_temp.pricing_regression_insert_rule(
            'REG_CALC_INCREASE',
            'listing',
            v_property_id,
            v_platform_id,
            v_ppl_id,
            'increase',
            jsonb_build_object('subject', 'price', 'operation', jsonb_build_object('do', '+ increase', 'type', 'flat', 'amount', 10)),
            v_d_calc,
            v_d_calc,
            68
        );

        v_calc := calculate_daily_price(
            v_api_key,
            v_property_id,
            v_platform_id,
            v_d_calc,
            100,
            TRUE,
            v_ppl_id,
            NULL,
            NULL,
            NULL
        );

        PERFORM pg_temp.pricing_regression_assert_true((v_calc->>'success')::BOOLEAN, 'calculate_daily_price returns success for available date');
        PERFORM pg_temp.pricing_regression_assert_true((v_calc->>'available')::BOOLEAN, 'calculate_daily_price returns available true for open date');
        PERFORM pg_temp.pricing_regression_assert_eq_numeric((v_calc->>'final_price')::NUMERIC, 110, 'calculate_daily_price applies listing flat increase');

        v_calc := calculate_daily_price(
            v_api_key,
            v_property_id,
            v_platform_id,
            v_d_calc,
            100,
            FALSE,
            v_ppl_id,
            NULL,
            NULL,
            NULL
        );

        PERFORM pg_temp.pricing_regression_assert_true((v_calc->>'cached')::BOOLEAN, 'calculate_daily_price returns cached result on second no-stay call');

        v_calc := calculate_daily_price(
            v_api_key,
            v_property_id,
            v_platform_id,
            v_d_calc,
            100,
            FALSE,
            v_ppl_id,
            5,
            1,
            0
        );

        PERFORM pg_temp.pricing_regression_assert_true(NOT (v_calc->>'cached')::BOOLEAN, 'calculate_daily_price skips cache when stay-adjustment context is supplied');

        INSERT INTO price_overrides(
            property_id,
            platform_id,
            date,
            price,
            override_type,
            reason,
            applied_by,
            is_active
        ) VALUES (
            v_property_id,
            v_platform_id,
            v_d_override,
            222,
            'manual',
            'pricing regression override test',
            'pricing_regression',
            TRUE
        )
        ON CONFLICT (property_id, platform_id, date) DO UPDATE
        SET price = EXCLUDED.price,
            is_active = TRUE,
            expires_at = NULL;

        v_calc := calculate_daily_price(
            v_api_key,
            v_property_id,
            v_platform_id,
            v_d_override,
            100,
            TRUE,
            v_ppl_id,
            NULL,
            NULL,
            NULL
        );

        PERFORM pg_temp.pricing_regression_assert_eq_numeric((v_calc->>'final_price')::NUMERIC, 222, 'manual price override wins over calculated price');

        INSERT INTO ical_events(
            property_id,
            platform_id,
            event_uid,
            start_date,
            end_date,
            status,
            summary,
            ical_source
        ) VALUES (
            v_property_id,
            v_platform_id,
            'pricing-regression-' || gen_random_uuid()::TEXT,
            v_d_blocked,
            v_d_blocked + 1,
            'BLOCKED',
            'Pricing regression blocked date',
            'pricing_regression'
        );

        v_calc := calculate_daily_price(
            v_api_key,
            v_property_id,
            v_platform_id,
            v_d_blocked,
            100,
            TRUE,
            v_ppl_id,
            NULL,
            NULL,
            NULL
        );

        PERFORM pg_temp.pricing_regression_assert_true(NOT (v_calc->>'available')::BOOLEAN, 'calculate_daily_price returns unavailable for blocked iCal date');
        PERFORM pg_temp.pricing_regression_assert_true(v_calc->>'final_price' IS NULL, 'blocked date returns null final_price');
    END IF;

    RAISE NOTICE 'Pricing Engine regression suite completed.';
END $$;

DO $$
DECLARE
    v_pass_count INT;
    v_skip_count INT;
BEGIN
    SELECT COUNT(*) FILTER (WHERE status = 'PASS'),
           COUNT(*) FILTER (WHERE status = 'SKIP')
    INTO v_pass_count, v_skip_count
    FROM pricing_regression_results;

    RAISE NOTICE 'Pricing Engine regression result: % passed, % skipped.', v_pass_count, v_skip_count;
END $$;

TABLE pricing_regression_results ORDER BY id;

ROLLBACK;
