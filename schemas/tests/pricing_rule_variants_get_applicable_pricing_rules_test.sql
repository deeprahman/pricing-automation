-- ============================================================================
-- Pricing rule variants seed + expectation checks
-- ============================================================================
-- Purpose
--   Inserts a controlled set of pricing-rule variants for:
--     - 30 percent or flat 30 increase
--     - 5 consecutive target dates from departure, inclusive
--     - booking_class any_of/all_of with optional class positions
--     - stay_length > 15
--     - stay_extended > 0
--     - condition presence/absence variants
--     - listing/property/platform/global scope ordering
--     - priority ordering
--
-- Run after the current pricing migrations, especially:
--   1. property_platform_sql.sql
--   2. pricing-engine.sql
--   3. pricing_rules_listing_scope_migration.sql
--   4. pricing_engine_condition_tree_migration_patched.sql
--   5. pricing_engine_booking_class_position_migration_patched.sql
--
-- The script is idempotent for this fixture. It deletes and recreates only rules
-- tagged with metadata.fixture_key = pricing_rule_variants_departure_window_v1.
-- Existing non-fixture rules are not touched.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Dependency validation
-- ----------------------------------------------------------------------------
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

    IF to_regclass('public.pricing_rules') IS NULL THEN
        RAISE EXCEPTION 'Missing table: pricing_rules. Run pricing-engine.sql first.';
    END IF;

    IF to_regclass('public.pricing_operation_types') IS NULL THEN
        RAISE EXCEPTION 'Missing table: pricing_operation_types. Run pricing-engine.sql first.';
    END IF;

    IF to_regclass('public.pricing_config') IS NULL THEN
        RAISE EXCEPTION 'Missing table: pricing_config. Run pricing-engine.sql first.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'get_applicable_pricing_rules'
          AND p.pronargs = 13
    ) THEN
        RAISE EXCEPTION
            'Missing get_applicable_pricing_rules with 13 args. Run booking-class-position migration first.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pricing_operation_types
        WHERE operation_code = 'increase'
          AND is_active = TRUE
    ) THEN
        RAISE EXCEPTION 'Missing active increase operation in pricing_operation_types.';
    END IF;
END $$;

-- ----------------------------------------------------------------------------
-- 2. Fixture context
-- ----------------------------------------------------------------------------
CREATE TEMP TABLE _pricing_rule_variant_fixture_context (
    fixture_key TEXT NOT NULL,
    property_id BIGINT NOT NULL,
    platform_id BIGINT NOT NULL,
    platform_property_lookup_id BIGINT NOT NULL,
    operation_id BIGINT NOT NULL
) ON COMMIT DROP;

DO $$
DECLARE
    v_fixture_key TEXT := 'pricing_rule_variants_departure_window_v1';
    v_property_id BIGINT;
    v_platform_id BIGINT;
    v_lookup_id BIGINT;
    v_operation_id BIGINT;
BEGIN
    INSERT INTO platforms (name, type, metadata)
    VALUES (
        'Pricing Rule Fixture PMS',
        'pms',
        jsonb_build_object('fixture_key', v_fixture_key)
    )
    ON CONFLICT (name) DO UPDATE
    SET type = EXCLUDED.type,
        metadata = COALESCE(platforms.metadata, '{}'::jsonb) || EXCLUDED.metadata,
        is_active = TRUE,
        updated_at = CURRENT_TIMESTAMP
    RETURNING id INTO v_platform_id;

    SELECT id
    INTO v_property_id
    FROM properties
    WHERE descrp->>'latitude' = '25.761700'
      AND descrp->>'longitude' = '-80.191800'
    LIMIT 1;

    IF v_property_id IS NULL THEN
        INSERT INTO properties (descrp)
        VALUES (
            jsonb_build_object(
                'name', 'Pricing Rule Fixture Property',
                'street', '100 Fixture Way',
                'city', 'Miami',
                'state', 'FL',
                'country', 'US',
                'latitude', '25.761700',
                'longitude', '-80.191800',
                'fixture_key', v_fixture_key
            )
        )
        RETURNING id INTO v_property_id;
    END IF;

    INSERT INTO platform_property_lookup (
        properties_ptr,
        platform_id,
        listing_id,
        name,
        metadata
    )
    VALUES (
        v_property_id,
        v_platform_id,
        'fixture_listing_pricing_rule_variants_v1',
        'Pricing Rule Fixture Listing',
        jsonb_build_object('fixture_key', v_fixture_key)
    )
    ON CONFLICT (platform_id, listing_id) DO UPDATE
    SET properties_ptr = EXCLUDED.properties_ptr,
        name = EXCLUDED.name,
        metadata = COALESCE(platform_property_lookup.metadata, '{}'::jsonb) || EXCLUDED.metadata,
        updated_at = CURRENT_TIMESTAMP
    RETURNING id INTO v_lookup_id;

    SELECT id
    INTO v_operation_id
    FROM pricing_operation_types
    WHERE operation_code = 'increase'
      AND is_active = TRUE
    LIMIT 1;

    DELETE FROM pricing_rules
    WHERE rule_config->'metadata'->>'fixture_key' = v_fixture_key;

    INSERT INTO _pricing_rule_variant_fixture_context (
        fixture_key,
        property_id,
        platform_id,
        platform_property_lookup_id,
        operation_id
    )
    VALUES (
        v_fixture_key,
        v_property_id,
        v_platform_id,
        v_lookup_id,
        v_operation_id
    );
END $$;

-- ----------------------------------------------------------------------------
-- 3. Rule specs
-- ----------------------------------------------------------------------------
CREATE TEMP TABLE _pricing_rule_variant_specs (
    rule_name TEXT PRIMARY KEY,
    scope_kind TEXT NOT NULL CHECK (scope_kind IN ('listing', 'property', 'platform', 'global')),
    departure_date DATE NOT NULL,
    priority INTEGER NOT NULL CHECK (priority BETWEEN 0 AND 100),
    rule_config JSONB NOT NULL
) ON COMMIT DROP;

INSERT INTO _pricing_rule_variant_specs (rule_name, scope_kind, departure_date, priority, rule_config)
VALUES
(
    'PRV01_listing_any_class_pct30',
    'listing',
    DATE '2036-01-10',
    90,
    '{
        "subject": "price",
        "operation": {"do": "+ increase", "type": "percentage", "amount": 30},
        "apply_window": {"applies_from": "departure", "duration_days": 5},
        "conditions_version": 2,
        "condition_tree": {
            "type": "condition",
            "condition_name": "booking_class",
            "comparison_operator": "any_of",
            "value": ["job_related", "medical_related"],
            "pos": [0, null]
        },
        "metadata": {
            "fixture_key": "pricing_rule_variants_departure_window_v1",
            "variant_key": "any_class_pct30",
            "notes": "Matches job_related at position 0 or medical_related at any position."
        }
    }'::jsonb
),
(
    'PRV02_property_all_class_flat30',
    'property',
    DATE '2036-01-20',
    80,
    '{
        "subject": "price",
        "operation": {"do": "+ increase", "type": "flat", "amount": 30},
        "apply_window": {"applies_from": "departure", "duration_days": 5},
        "conditions_version": 2,
        "condition_tree": {
            "type": "condition",
            "condition_name": "booking_class",
            "comparison_operator": "all_of",
            "value": ["job_related", "medical_related"],
            "pos": [0, null]
        },
        "metadata": {
            "fixture_key": "pricing_rule_variants_departure_window_v1",
            "variant_key": "all_class_flat30",
            "notes": "Requires job_related at position 0 and medical_related at any position."
        }
    }'::jsonb
),
(
    'PRV03_platform_stay_length_gt15_pct30',
    'platform',
    DATE '2036-01-30',
    70,
    '{
        "subject": "price",
        "operation": {"do": "+ increase", "type": "percentage", "amount": 30},
        "apply_window": {"applies_from": "departure", "duration_days": 5},
        "conditions_version": 2,
        "condition_tree": {
            "type": "condition",
            "condition_name": "stay_length",
            "comparison_operator": "gt",
            "value": 15
        },
        "metadata": {
            "fixture_key": "pricing_rule_variants_departure_window_v1",
            "variant_key": "stay_length_gt15_pct30"
        }
    }'::jsonb
),
(
    'PRV04_global_stay_extended_gt0_flat30',
    'global',
    DATE '2036-02-09',
    60,
    '{
        "subject": "price",
        "operation": {"do": "+ increase", "type": "flat", "amount": 30},
        "apply_window": {"applies_from": "departure", "duration_days": 5},
        "conditions_version": 2,
        "condition_tree": {
            "type": "condition",
            "condition_name": "stay_extended",
            "comparison_operator": "gt",
            "value": 0
        },
        "metadata": {
            "fixture_key": "pricing_rule_variants_departure_window_v1",
            "variant_key": "stay_extended_gt0_flat30"
        }
    }'::jsonb
),
(
    'PRV05_listing_any_class_and_stay_length_pct30',
    'listing',
    DATE '2036-02-19',
    88,
    '{
        "subject": "price",
        "operation": {"do": "+ increase", "type": "percentage", "amount": 30},
        "apply_window": {"applies_from": "departure", "duration_days": 5},
        "conditions_version": 2,
        "condition_tree": {
            "type": "group",
            "evaluation_operator": "and",
            "members": [
                {
                    "type": "condition",
                    "condition_name": "booking_class",
                    "comparison_operator": "any_of",
                    "value": ["job_related", "medical_related"],
                    "pos": [0, null]
                },
                {
                    "type": "condition",
                    "condition_name": "stay_length",
                    "comparison_operator": "gt",
                    "value": 15
                }
            ]
        },
        "metadata": {
            "fixture_key": "pricing_rule_variants_departure_window_v1",
            "variant_key": "any_class_and_stay_length_pct30"
        }
    }'::jsonb
),
(
    'PRV06_property_any_class_and_stay_extended_flat30',
    'property',
    DATE '2036-03-01',
    78,
    '{
        "subject": "price",
        "operation": {"do": "+ increase", "type": "flat", "amount": 30},
        "apply_window": {"applies_from": "departure", "duration_days": 5},
        "conditions_version": 2,
        "condition_tree": {
            "type": "group",
            "evaluation_operator": "and",
            "members": [
                {
                    "type": "condition",
                    "condition_name": "booking_class",
                    "comparison_operator": "any_of",
                    "value": ["job_related", "medical_related"],
                    "pos": [0, null]
                },
                {
                    "type": "condition",
                    "condition_name": "stay_extended",
                    "comparison_operator": "gt",
                    "value": 0
                }
            ]
        },
        "metadata": {
            "fixture_key": "pricing_rule_variants_departure_window_v1",
            "variant_key": "any_class_and_stay_extended_flat30"
        }
    }'::jsonb
),
(
    'PRV07_platform_stay_length_and_stay_extended_pct30',
    'platform',
    DATE '2036-03-11',
    68,
    '{
        "subject": "price",
        "operation": {"do": "+ increase", "type": "percentage", "amount": 30},
        "apply_window": {"applies_from": "departure", "duration_days": 5},
        "conditions_version": 2,
        "condition_tree": {
            "type": "group",
            "evaluation_operator": "and",
            "members": [
                {"type": "condition", "condition_name": "stay_length", "comparison_operator": "gt", "value": 15},
                {"type": "condition", "condition_name": "stay_extended", "comparison_operator": "gt", "value": 0}
            ]
        },
        "metadata": {
            "fixture_key": "pricing_rule_variants_departure_window_v1",
            "variant_key": "stay_length_and_stay_extended_pct30"
        }
    }'::jsonb
),
(
    'PRV08_global_any_or_stay_length_or_stay_extended_pct30',
    'global',
    DATE '2036-03-21',
    58,
    '{
        "subject": "price",
        "operation": {"do": "+ increase", "type": "percentage", "amount": 30},
        "apply_window": {"applies_from": "departure", "duration_days": 5},
        "conditions_version": 2,
        "condition_tree": {
            "type": "group",
            "evaluation_operator": "or",
            "members": [
                {
                    "type": "condition",
                    "condition_name": "booking_class",
                    "comparison_operator": "any_of",
                    "value": ["job_related", "medical_related"],
                    "pos": [0, null]
                },
                {"type": "condition", "condition_name": "stay_length", "comparison_operator": "gt", "value": 15},
                {"type": "condition", "condition_name": "stay_extended", "comparison_operator": "gt", "value": 0}
            ]
        },
        "metadata": {
            "fixture_key": "pricing_rule_variants_departure_window_v1",
            "variant_key": "any_or_stay_length_or_stay_extended_pct30"
        }
    }'::jsonb
),
(
    'PRV09_listing_all_class_and_stay_length_and_stay_extended_flat30',
    'listing',
    DATE '2036-03-31',
    86,
    '{
        "subject": "price",
        "operation": {"do": "+ increase", "type": "flat", "amount": 30},
        "apply_window": {"applies_from": "departure", "duration_days": 5},
        "conditions_version": 2,
        "condition_tree": {
            "type": "group",
            "evaluation_operator": "and",
            "members": [
                {
                    "type": "condition",
                    "condition_name": "booking_class",
                    "comparison_operator": "all_of",
                    "value": ["job_related", "medical_related"],
                    "pos": [0, null]
                },
                {"type": "condition", "condition_name": "stay_length", "comparison_operator": "gt", "value": 15},
                {"type": "condition", "condition_name": "stay_extended", "comparison_operator": "gt", "value": 0}
            ]
        },
        "metadata": {
            "fixture_key": "pricing_rule_variants_departure_window_v1",
            "variant_key": "all_class_and_stay_length_and_stay_extended_flat30"
        }
    }'::jsonb
),
(
    'PRV10_listing_no_conditions_pct30',
    'listing',
    DATE '2036-04-10',
    84,
    '{
        "subject": "price",
        "operation": {"do": "+ increase", "type": "percentage", "amount": 30},
        "apply_window": {"applies_from": "departure", "duration_days": 5},
        "conditions_version": 2,
        "metadata": {
            "fixture_key": "pricing_rule_variants_departure_window_v1",
            "variant_key": "no_conditions_pct30"
        }
    }'::jsonb
),
(
    'PRV11_scope_global_booking_only_flat30',
    'global',
    DATE '2036-05-01',
    10,
    '{
        "subject": "price",
        "operation": {"do": "+ increase", "type": "flat", "amount": 30},
        "apply_window": {"applies_from": "departure", "duration_days": 5},
        "conditions_version": 2,
        "condition_tree": {
            "type": "condition",
            "condition_name": "booking_class",
            "comparison_operator": "any_of",
            "value": ["job_related", "medical_related"],
            "pos": [0, null]
        },
        "metadata": {"fixture_key": "pricing_rule_variants_departure_window_v1", "variant_key": "scope_global"}
    }'::jsonb
),
(
    'PRV12_scope_platform_booking_only_flat30',
    'platform',
    DATE '2036-05-01',
    20,
    '{
        "subject": "price",
        "operation": {"do": "+ increase", "type": "flat", "amount": 30},
        "apply_window": {"applies_from": "departure", "duration_days": 5},
        "conditions_version": 2,
        "condition_tree": {
            "type": "condition",
            "condition_name": "booking_class",
            "comparison_operator": "any_of",
            "value": ["job_related", "medical_related"],
            "pos": [0, null]
        },
        "metadata": {"fixture_key": "pricing_rule_variants_departure_window_v1", "variant_key": "scope_platform"}
    }'::jsonb
),
(
    'PRV13_scope_property_booking_only_flat30',
    'property',
    DATE '2036-05-01',
    30,
    '{
        "subject": "price",
        "operation": {"do": "+ increase", "type": "flat", "amount": 30},
        "apply_window": {"applies_from": "departure", "duration_days": 5},
        "conditions_version": 2,
        "condition_tree": {
            "type": "condition",
            "condition_name": "booking_class",
            "comparison_operator": "any_of",
            "value": ["job_related", "medical_related"],
            "pos": [0, null]
        },
        "metadata": {"fixture_key": "pricing_rule_variants_departure_window_v1", "variant_key": "scope_property"}
    }'::jsonb
),
(
    'PRV14_scope_listing_booking_only_flat30',
    'listing',
    DATE '2036-05-01',
    40,
    '{
        "subject": "price",
        "operation": {"do": "+ increase", "type": "flat", "amount": 30},
        "apply_window": {"applies_from": "departure", "duration_days": 5},
        "conditions_version": 2,
        "condition_tree": {
            "type": "condition",
            "condition_name": "booking_class",
            "comparison_operator": "any_of",
            "value": ["job_related", "medical_related"],
            "pos": [0, null]
        },
        "metadata": {"fixture_key": "pricing_rule_variants_departure_window_v1", "variant_key": "scope_listing"}
    }'::jsonb
),
(
    'PRV15_priority_low_booking_only_flat30',
    'listing',
    DATE '2036-05-20',
    15,
    '{
        "subject": "price",
        "operation": {"do": "+ increase", "type": "flat", "amount": 30},
        "apply_window": {"applies_from": "departure", "duration_days": 5},
        "conditions_version": 2,
        "condition_tree": {
            "type": "condition",
            "condition_name": "booking_class",
            "comparison_operator": "any_of",
            "value": ["job_related", "medical_related"],
            "pos": [0, null]
        },
        "metadata": {"fixture_key": "pricing_rule_variants_departure_window_v1", "variant_key": "priority_low"}
    }'::jsonb
),
(
    'PRV16_priority_high_booking_only_pct30',
    'listing',
    DATE '2036-05-20',
    95,
    '{
        "subject": "price",
        "operation": {"do": "+ increase", "type": "percentage", "amount": 30},
        "apply_window": {"applies_from": "departure", "duration_days": 5},
        "conditions_version": 2,
        "condition_tree": {
            "type": "condition",
            "condition_name": "booking_class",
            "comparison_operator": "any_of",
            "value": ["job_related", "medical_related"],
            "pos": [0, null]
        },
        "metadata": {"fixture_key": "pricing_rule_variants_departure_window_v1", "variant_key": "priority_high"}
    }'::jsonb
);

-- ----------------------------------------------------------------------------
-- 4. Insert rules
-- ----------------------------------------------------------------------------
INSERT INTO pricing_rules (
    rule_uuid,
    property_id,
    platform_id,
    platform_property_lookup_id,
    operation_id,
    rule_config,
    start_date,
    end_date,
    priority,
    rule_name,
    created_by,
    created_via,
    status,
    activated_at,
    allow_override
)
SELECT
    gen_random_uuid(),
    CASE WHEN s.scope_kind = 'property' THEN c.property_id ELSE NULL END,
    CASE WHEN s.scope_kind = 'platform' THEN c.platform_id ELSE NULL END,
    CASE WHEN s.scope_kind = 'listing' THEN c.platform_property_lookup_id ELSE NULL END,
    c.operation_id,
    s.rule_config,
    s.departure_date,
    s.departure_date + 4,
    s.priority,
    s.rule_name,
    'fixture',
    'sql_seed',
    'active',
    NOW(),
    TRUE
FROM _pricing_rule_variant_specs s
CROSS JOIN _pricing_rule_variant_fixture_context c
ORDER BY s.rule_name;

-- ----------------------------------------------------------------------------
-- 5. Expected versus actual checks
-- ----------------------------------------------------------------------------
CREATE TEMP TABLE _pricing_rule_variant_expectations (
    case_name TEXT PRIMARY KEY,
    target_date DATE NOT NULL,
    arrival_date DATE NOT NULL,
    departure_date DATE NOT NULL,
    stay_length INT,
    booking_classes TEXT[],
    stay_extended INT,
    stay_contracted INT,
    booking_class_positions JSONB,
    expected_rule_names TEXT[] NOT NULL,
    actual_rule_names TEXT[]
) ON COMMIT DROP;

INSERT INTO _pricing_rule_variant_expectations (
    case_name,
    target_date,
    arrival_date,
    departure_date,
    stay_length,
    booking_classes,
    stay_extended,
    stay_contracted,
    booking_class_positions,
    expected_rule_names
)
VALUES
(
    'case_01_any_of_job_at_pos0_matches',
    DATE '2036-01-11', DATE '2035-12-25', DATE '2036-01-10',
    NULL,
    ARRAY['job_related']::TEXT[],
    NULL, 0,
    '{"job_related": [0]}'::jsonb,
    ARRAY['PRV01_listing_any_class_pct30']::TEXT[]
),
(
    'case_02_any_of_medical_pos_null_matches_any_position',
    DATE '2036-01-12', DATE '2035-12-25', DATE '2036-01-10',
    NULL,
    ARRAY['medical_related']::TEXT[],
    NULL, 0,
    '{"medical_related": [7]}'::jsonb,
    ARRAY['PRV01_listing_any_class_pct30']::TEXT[]
),
(
    'case_03_any_of_job_wrong_position_does_not_match',
    DATE '2036-01-13', DATE '2035-12-25', DATE '2036-01-10',
    NULL,
    ARRAY['job_related']::TEXT[],
    NULL, 0,
    '{"job_related": [2]}'::jsonb,
    ARRAY[]::TEXT[]
),
(
    'case_04_all_of_both_classes_match',
    DATE '2036-01-21', DATE '2036-01-01', DATE '2036-01-20',
    NULL,
    ARRAY['job_related', 'medical_related']::TEXT[],
    NULL, 0,
    '{"job_related": [0], "medical_related": [3]}'::jsonb,
    ARRAY['PRV02_property_all_class_flat30']::TEXT[]
),
(
    'case_05_all_of_missing_medical_does_not_match',
    DATE '2036-01-22', DATE '2036-01-01', DATE '2036-01-20',
    NULL,
    ARRAY['job_related']::TEXT[],
    NULL, 0,
    '{"job_related": [0]}'::jsonb,
    ARRAY[]::TEXT[]
),
(
    'case_06_stay_length_gt15_matches',
    DATE '2036-01-31', DATE '2036-01-14', DATE '2036-01-30',
    16,
    NULL,
    NULL, 0,
    NULL,
    ARRAY['PRV03_platform_stay_length_gt15_pct30']::TEXT[]
),
(
    'case_07_stay_length_15_does_not_match_gt15',
    DATE '2036-02-01', DATE '2036-01-15', DATE '2036-01-30',
    15,
    NULL,
    NULL, 0,
    NULL,
    ARRAY[]::TEXT[]
),
(
    'case_08_stay_extended_gt0_matches',
    DATE '2036-02-10', DATE '2036-01-25', DATE '2036-02-09',
    NULL,
    NULL,
    1, 0,
    NULL,
    ARRAY['PRV04_global_stay_extended_gt0_flat30']::TEXT[]
),
(
    'case_09_stay_extended_zero_does_not_match_gt0',
    DATE '2036-02-11', DATE '2036-01-25', DATE '2036-02-09',
    NULL,
    NULL,
    0, 0,
    NULL,
    ARRAY[]::TEXT[]
),
(
    'case_10_any_class_and_stay_length_both_match',
    DATE '2036-02-20', DATE '2036-02-03', DATE '2036-02-19',
    16,
    ARRAY['medical_related']::TEXT[],
    NULL, 0,
    '{"medical_related": [9]}'::jsonb,
    ARRAY['PRV05_listing_any_class_and_stay_length_pct30']::TEXT[]
),
(
    'case_11_any_class_and_stay_length_missing_stay_fails',
    DATE '2036-02-21', DATE '2036-02-03', DATE '2036-02-19',
    NULL,
    ARRAY['medical_related']::TEXT[],
    NULL, 0,
    '{"medical_related": [9]}'::jsonb,
    ARRAY[]::TEXT[]
),
(
    'case_12_any_class_and_stay_extended_both_match',
    DATE '2036-03-02', DATE '2036-02-14', DATE '2036-03-01',
    NULL,
    ARRAY['job_related']::TEXT[],
    2, 0,
    '{"job_related": [0]}'::jsonb,
    ARRAY['PRV06_property_any_class_and_stay_extended_flat30']::TEXT[]
),
(
    'case_13_stay_length_and_stay_extended_both_match',
    DATE '2036-03-12', DATE '2036-02-24', DATE '2036-03-11',
    16,
    NULL,
    1, 0,
    NULL,
    ARRAY['PRV07_platform_stay_length_and_stay_extended_pct30']::TEXT[]
),
(
    'case_14_stay_length_and_stay_extended_missing_extended_fails',
    DATE '2036-03-13', DATE '2036-02-24', DATE '2036-03-11',
    16,
    NULL,
    0, 0,
    NULL,
    ARRAY[]::TEXT[]
),
(
    'case_15_or_group_matches_by_stay_length_only',
    DATE '2036-03-22', DATE '2036-03-05', DATE '2036-03-21',
    16,
    ARRAY['unrelated']::TEXT[],
    0, 0,
    '{"unrelated": [0]}'::jsonb,
    ARRAY['PRV08_global_any_or_stay_length_or_stay_extended_pct30']::TEXT[]
),
(
    'case_16_or_group_matches_by_booking_class_only',
    DATE '2036-03-23', DATE '2036-03-05', DATE '2036-03-21',
    5,
    ARRAY['medical_related']::TEXT[],
    0, 0,
    '{"medical_related": [2]}'::jsonb,
    ARRAY['PRV08_global_any_or_stay_length_or_stay_extended_pct30']::TEXT[]
),
(
    'case_17_all_class_and_stay_length_and_extended_all_match',
    DATE '2036-04-01', DATE '2036-03-15', DATE '2036-03-31',
    16,
    ARRAY['job_related', 'medical_related']::TEXT[],
    3, 0,
    '{"job_related": [0], "medical_related": [8]}'::jsonb,
    ARRAY['PRV09_listing_all_class_and_stay_length_and_stay_extended_flat30']::TEXT[]
),
(
    'case_18_no_conditions_matches_with_minimal_args',
    DATE '2036-04-11', DATE '2036-03-31', DATE '2036-04-10',
    NULL,
    NULL,
    NULL, NULL,
    NULL,
    ARRAY['PRV10_listing_no_conditions_pct30']::TEXT[]
),
(
    'case_19_apply_window_departure_plus_4_included',
    DATE '2036-04-14', DATE '2036-03-31', DATE '2036-04-10',
    NULL,
    NULL,
    NULL, NULL,
    NULL,
    ARRAY['PRV10_listing_no_conditions_pct30']::TEXT[]
),
(
    'case_20_apply_window_departure_plus_5_excluded',
    DATE '2036-04-15', DATE '2036-03-31', DATE '2036-04-10',
    NULL,
    NULL,
    NULL, NULL,
    NULL,
    ARRAY[]::TEXT[]
),
(
    'case_21_scope_order_listing_property_platform_global',
    DATE '2036-05-02', DATE '2036-04-15', DATE '2036-05-01',
    NULL,
    ARRAY['job_related']::TEXT[],
    NULL, 0,
    '{"job_related": [0]}'::jsonb,
    ARRAY[
        'PRV14_scope_listing_booking_only_flat30',
        'PRV13_scope_property_booking_only_flat30',
        'PRV12_scope_platform_booking_only_flat30',
        'PRV11_scope_global_booking_only_flat30'
    ]::TEXT[]
),
(
    'case_22_priority_order_within_same_scope',
    DATE '2036-05-21', DATE '2036-05-04', DATE '2036-05-20',
    NULL,
    ARRAY['job_related']::TEXT[],
    NULL, 0,
    '{"job_related": [0]}'::jsonb,
    ARRAY[
        'PRV16_priority_high_booking_only_pct30',
        'PRV15_priority_low_booking_only_flat30'
    ]::TEXT[]
);

WITH actuals AS (
    SELECT
        e.case_name,
        ARRAY(
            SELECT r.rule_json->>'rule_name'
            FROM _pricing_rule_variant_fixture_context c
            CROSS JOIN LATERAL get_applicable_pricing_rules(
                c.property_id,
                c.platform_id,
                e.target_date,
                'increase',
                FALSE,
                c.platform_property_lookup_id,
                e.stay_length,
                e.booking_classes,
                e.stay_extended,
                e.stay_contracted,
                e.arrival_date,
                e.departure_date,
                e.booking_class_positions
            ) AS r
            WHERE r.rule_json->'metadata'->>'fixture_key' = c.fixture_key
            ORDER BY
                CASE r.scope
                    WHEN 'listing'  THEN 4000
                    WHEN 'property' THEN 3000
                    WHEN 'platform' THEN 2000
                    ELSE                 1000
                END + r.priority DESC,
                r.rule_id ASC
        ) AS actual_rule_names
    FROM _pricing_rule_variant_expectations e
)
UPDATE _pricing_rule_variant_expectations e
SET actual_rule_names = a.actual_rule_names
FROM actuals a
WHERE a.case_name = e.case_name;

DO $$
DECLARE
    v_failed_count INT;
    v_failure_rows TEXT;
BEGIN
    SELECT COUNT(*)
    INTO v_failed_count
    FROM _pricing_rule_variant_expectations
    WHERE expected_rule_names IS DISTINCT FROM actual_rule_names;

    IF v_failed_count > 0 THEN
        SELECT string_agg(
            format(
                '%s | expected=%s | actual=%s',
                case_name,
                expected_rule_names::TEXT,
                actual_rule_names::TEXT
            ),
            E'\n'
            ORDER BY case_name
        )
        INTO v_failure_rows
        FROM _pricing_rule_variant_expectations
        WHERE expected_rule_names IS DISTINCT FROM actual_rule_names;

        RAISE EXCEPTION 'Pricing rule fixture expectation mismatch:%\n%', v_failed_count, v_failure_rows;
    END IF;

    RAISE NOTICE 'OK: all % pricing rule fixture expectation checks passed.',
        (SELECT COUNT(*) FROM _pricing_rule_variant_expectations);
END $$;

-- Useful manual inspection query. Uncomment after running if you want the full matrix.
-- SELECT
--     case_name,
--     expected_rule_names,
--     actual_rule_names
-- FROM _pricing_rule_variant_expectations
-- ORDER BY case_name;

COMMIT;

-- ============================================================================
-- End
-- ============================================================================
