-- ============================================================================
-- pricing_engine_condition_tree_migration_patched.sql
--
-- Purpose:
--   Add a production-ready, versioned nested condition tree model to the pricing
--   rule engine while preserving legacy pricing rule behavior.
--
-- Adds support for:
--   1) rule_config.conditions_version = 2
--   2) rule_config.condition_tree recursive AND/OR groups
--   3) comparison operators for stay_extended / stay_contracted / net_stay
--   4) derived net_stay evaluation
--   5) booking category matching through condition_tree
--   6) arrival/departure/target date conditions through condition_tree
--   7) apply_window enforcement for arrival/departure-relative pricing windows
--   8) validation trigger on pricing_rules.rule_config
--
-- Design notes:
--   - This migration intentionally does not replace legacy rule_config.conditions.
--   - New rules should use condition_tree with conditions_version = 2.
--   - Existing legacy rules continue to work through the legacy predicates in
--     get_applicable_pricing_rules(...).
--   - condition_tree is evaluated after indexed filters such as status, scope,
--     operation, date range, and day-of-week matching.
--
-- Prerequisites:
--   - pricing-engine.sql
--   - pricing_rules_listing_scope_migration.sql, if listing scope is used
--   - pricing_engine_stay_adjustment_migration.sql
--   - pricing_engine_conflict_guard_migration_patched.sql, recommended
--
-- Safe to re-run: yes. Functions and triggers are replaced in place.
-- ============================================================================

-- ============================================================================
-- 1. DEPENDENCY VALIDATION
-- ============================================================================

DO $$
BEGIN
    IF to_regclass('public.pricing_rules') IS NULL THEN
        RAISE EXCEPTION 'Missing table: pricing_rules. Run pricing-engine.sql first.';
    END IF;

    IF to_regclass('public.pricing_operation_types') IS NULL THEN
        RAISE EXCEPTION 'Missing table: pricing_operation_types. Run pricing-engine.sql first.';
    END IF;

    IF to_regclass('public.pricing_config') IS NULL THEN
        RAISE EXCEPTION 'Missing table: pricing_config. Run pricing-engine.sql first.';
    END IF;
END $$;

-- ============================================================================
-- 2. CONFIGURATION
-- ============================================================================

INSERT INTO pricing_config (key, value, value_type, description, category)
VALUES
    ('condition_tree_max_depth', '5', 'integer',
     'Maximum recursive depth allowed in pricing rule condition_tree.', 'pricing'),
    ('condition_tree_max_members_per_group', '20', 'integer',
     'Maximum members allowed in any one condition_tree group.', 'pricing'),
    ('condition_tree_max_conditions_per_rule', '50', 'integer',
     'Maximum unit conditions allowed in one condition_tree.', 'pricing'),
    ('max_apply_window_duration_days', '31', 'integer',
     'Maximum duration_days allowed in rule_config.apply_window.', 'pricing')
ON CONFLICT (key) DO NOTHING;

-- ============================================================================
-- 3. CONDITION TREE UTILITY FUNCTIONS
-- ============================================================================

CREATE OR REPLACE FUNCTION pricing_rule_condition_tree_has_condition_names(
    p_node JSONB,
    p_condition_names TEXT[]
) RETURNS BOOLEAN AS $$
DECLARE
    v_type TEXT;
    v_member JSONB;
BEGIN
    IF p_node IS NULL OR jsonb_typeof(p_node) = 'null' THEN
        RETURN FALSE;
    END IF;

    IF jsonb_typeof(p_node) IS DISTINCT FROM 'object' THEN
        RETURN FALSE;
    END IF;

    v_type := LOWER(COALESCE(p_node->>'type', ''));

    IF v_type = 'condition' THEN
        RETURN LOWER(COALESCE(p_node->>'condition_name', '')) = ANY(p_condition_names);
    ELSIF v_type = 'group' THEN
        IF jsonb_typeof(p_node->'members') IS DISTINCT FROM 'array' THEN
            RETURN FALSE;
        END IF;

        FOR v_member IN SELECT value FROM jsonb_array_elements(p_node->'members')
        LOOP
            IF pricing_rule_condition_tree_has_condition_names(v_member, p_condition_names) THEN
                RETURN TRUE;
            END IF;
        END LOOP;
    END IF;

    RETURN FALSE;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION evaluate_pricing_rule_number_condition_json(
    p_condition JSONB,
    p_actual NUMERIC
) RETURNS BOOLEAN AS $$
DECLARE
    v_seen_operator BOOLEAN := FALSE;
    v_type TEXT;
BEGIN
    IF p_condition IS NULL OR jsonb_typeof(p_condition) = 'null' THEN
        RETURN TRUE;
    END IF;

    IF p_actual IS NULL THEN
        RETURN FALSE;
    END IF;

    v_type := jsonb_typeof(p_condition);

    -- Backward-compatible exact numeric form, for example: "stay_extended": 2
    IF v_type = 'number' THEN
        RETURN p_actual = (p_condition::TEXT)::NUMERIC;
    END IF;

    -- Comparison-object form, for example: "stay_extended": {"gt": 0}
    IF v_type <> 'object' THEN
        RETURN FALSE;
    END IF;

    IF p_condition ? 'eq' THEN
        v_seen_operator := TRUE;
        IF p_actual <> (p_condition->>'eq')::NUMERIC THEN RETURN FALSE; END IF;
    END IF;

    IF p_condition ? 'gt' THEN
        v_seen_operator := TRUE;
        IF p_actual <= (p_condition->>'gt')::NUMERIC THEN RETURN FALSE; END IF;
    END IF;

    IF p_condition ? 'gte' THEN
        v_seen_operator := TRUE;
        IF p_actual < (p_condition->>'gte')::NUMERIC THEN RETURN FALSE; END IF;
    END IF;

    IF p_condition ? 'lt' THEN
        v_seen_operator := TRUE;
        IF p_actual >= (p_condition->>'lt')::NUMERIC THEN RETURN FALSE; END IF;
    END IF;

    IF p_condition ? 'lte' THEN
        v_seen_operator := TRUE;
        IF p_actual > (p_condition->>'lte')::NUMERIC THEN RETURN FALSE; END IF;
    END IF;

    IF p_condition ? 'between' THEN
        v_seen_operator := TRUE;
        IF jsonb_typeof(p_condition->'between') IS DISTINCT FROM 'object'
           OR NOT (p_condition->'between' ? 'min')
           OR NOT (p_condition->'between' ? 'max') THEN
            RETURN FALSE;
        END IF;

        IF p_actual < (p_condition->'between'->>'min')::NUMERIC
           OR p_actual > (p_condition->'between'->>'max')::NUMERIC THEN
            RETURN FALSE;
        END IF;
    END IF;

    RETURN v_seen_operator;
EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range THEN
        RETURN FALSE;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ============================================================================
-- 4. CONDITION TREE VALIDATION
-- ============================================================================

CREATE OR REPLACE FUNCTION validate_pricing_rule_condition_tree_node(
    p_node JSONB,
    p_depth INT,
    p_max_depth INT,
    p_max_members_per_group INT
) RETURNS INT AS $$
DECLARE
    v_type TEXT;
    v_eval_operator TEXT;
    v_members JSONB;
    v_member JSONB;
    v_count INT := 0;
    v_condition_name TEXT;
    v_comparison_operator TEXT;
    v_value JSONB;
    v_text_value TEXT;
    v_min_date DATE;
    v_max_date DATE;
BEGIN
    IF p_node IS NULL OR jsonb_typeof(p_node) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'condition_tree node must be a JSON object'
            USING ERRCODE = '22023';
    END IF;

    IF p_depth > p_max_depth THEN
        RAISE EXCEPTION 'condition_tree exceeds max depth %', p_max_depth
            USING ERRCODE = '22023';
    END IF;

    v_type := LOWER(COALESCE(p_node->>'type', ''));

    IF v_type = 'group' THEN
        v_eval_operator := LOWER(COALESCE(p_node->>'evaluation_operator', ''));

        IF v_eval_operator NOT IN ('and', 'or') THEN
            RAISE EXCEPTION 'condition_tree group evaluation_operator must be "and" or "or"'
                USING ERRCODE = '22023';
        END IF;

        v_members := p_node->'members';

        IF jsonb_typeof(v_members) IS DISTINCT FROM 'array' THEN
            RAISE EXCEPTION 'condition_tree group members must be a JSON array'
                USING ERRCODE = '22023';
        END IF;

        IF jsonb_array_length(v_members) = 0 THEN
            RAISE EXCEPTION 'condition_tree group members must be non-empty'
                USING ERRCODE = '22023';
        END IF;

        IF jsonb_array_length(v_members) > p_max_members_per_group THEN
            RAISE EXCEPTION 'condition_tree group has % members, max allowed is %',
                jsonb_array_length(v_members), p_max_members_per_group
                USING ERRCODE = '22023';
        END IF;

        FOR v_member IN SELECT value FROM jsonb_array_elements(v_members)
        LOOP
            v_count := v_count + validate_pricing_rule_condition_tree_node(
                v_member,
                p_depth + 1,
                p_max_depth,
                p_max_members_per_group
            );
        END LOOP;

        RETURN v_count;
    END IF;

    IF v_type <> 'condition' THEN
        RAISE EXCEPTION 'condition_tree node type must be "group" or "condition"'
            USING ERRCODE = '22023';
    END IF;

    v_condition_name := LOWER(COALESCE(p_node->>'condition_name', ''));
    v_comparison_operator := LOWER(COALESCE(p_node->>'comparison_operator', ''));
    v_value := p_node->'value';

    IF v_condition_name = '' THEN
        RAISE EXCEPTION 'condition_name is required'
            USING ERRCODE = '22023';
    END IF;

    IF v_comparison_operator = '' THEN
        RAISE EXCEPTION 'comparison_operator is required for condition_name=%', v_condition_name
            USING ERRCODE = '22023';
    END IF;

    -- Number conditions
    IF v_condition_name IN ('stay_length', 'stay_extended', 'stay_contracted', 'net_stay') THEN
        IF v_comparison_operator NOT IN ('eq', 'gt', 'gte', 'lt', 'lte', 'between') THEN
            RAISE EXCEPTION 'Invalid operator % for numeric condition %', v_comparison_operator, v_condition_name
                USING ERRCODE = '22023';
        END IF;

        IF v_comparison_operator = 'between' THEN
            IF jsonb_typeof(v_value) IS DISTINCT FROM 'object'
               OR NOT (v_value ? 'min')
               OR NOT (v_value ? 'max')
               OR jsonb_typeof(v_value->'min') IS DISTINCT FROM 'number'
               OR jsonb_typeof(v_value->'max') IS DISTINCT FROM 'number' THEN
                RAISE EXCEPTION 'between value for % must be an object with numeric min and max', v_condition_name
                    USING ERRCODE = '22023';
            END IF;

            IF (v_value->>'min')::NUMERIC > (v_value->>'max')::NUMERIC THEN
                RAISE EXCEPTION 'between min cannot be greater than max for %', v_condition_name
                    USING ERRCODE = '22023';
            END IF;
        ELSE
            IF jsonb_typeof(v_value) IS DISTINCT FROM 'number' THEN
                RAISE EXCEPTION 'value for % with operator % must be numeric', v_condition_name, v_comparison_operator
                    USING ERRCODE = '22023';
            END IF;
        END IF;

        RETURN 1;
    END IF;

    -- Array category conditions. booking_class is accepted as an alias for legacy callers.
    IF v_condition_name IN ('booking_category', 'booking_class') THEN
        IF v_comparison_operator NOT IN ('any_of', 'all_of') THEN
            RAISE EXCEPTION 'Invalid operator % for array condition %', v_comparison_operator, v_condition_name
                USING ERRCODE = '22023';
        END IF;

        IF jsonb_typeof(v_value) IS DISTINCT FROM 'array' THEN
            RAISE EXCEPTION 'value for % must be a non-empty string array', v_condition_name
                USING ERRCODE = '22023';
        END IF;

        IF jsonb_array_length(v_value) = 0 THEN
            RAISE EXCEPTION 'value for % must be a non-empty string array', v_condition_name
                USING ERRCODE = '22023';
        END IF;

        FOR v_member IN SELECT value FROM jsonb_array_elements(v_value)
        LOOP
            IF jsonb_typeof(v_member) IS DISTINCT FROM 'string' THEN
                RAISE EXCEPTION 'value array for % must contain strings only', v_condition_name
                    USING ERRCODE = '22023';
            END IF;

            v_text_value := v_member #>> '{}';

            IF BTRIM(v_text_value) = '' THEN
                RAISE EXCEPTION 'value array for % cannot contain empty strings', v_condition_name
                    USING ERRCODE = '22023';
            END IF;
        END LOOP;

        RETURN 1;
    END IF;

    -- Date conditions
    IF v_condition_name IN ('arrival_date', 'departure_date', 'target_date') THEN
        IF v_comparison_operator NOT IN ('eq', 'gt', 'gte', 'lt', 'lte', 'between') THEN
            RAISE EXCEPTION 'Invalid operator % for date condition %', v_comparison_operator, v_condition_name
                USING ERRCODE = '22023';
        END IF;

        IF v_comparison_operator = 'between' THEN
            IF jsonb_typeof(v_value) IS DISTINCT FROM 'object'
               OR NOT (v_value ? 'min')
               OR NOT (v_value ? 'max') THEN
                RAISE EXCEPTION 'between value for % must be an object with min and max', v_condition_name
                    USING ERRCODE = '22023';
            END IF;

            v_min_date := (v_value->>'min')::DATE;
            v_max_date := (v_value->>'max')::DATE;

            IF v_min_date > v_max_date THEN
                RAISE EXCEPTION 'between min cannot be greater than max for %', v_condition_name
                    USING ERRCODE = '22023';
            END IF;
        ELSE
            IF jsonb_typeof(v_value) IS DISTINCT FROM 'string' THEN
                RAISE EXCEPTION 'value for date condition % must be an ISO date string', v_condition_name
                    USING ERRCODE = '22023';
            END IF;

            PERFORM (v_value #>> '{}')::DATE;
        END IF;

        RETURN 1;
    END IF;

    RAISE EXCEPTION 'Unsupported condition_name: %', v_condition_name
        USING ERRCODE = '22023';
EXCEPTION
    WHEN invalid_datetime_format THEN
        RAISE EXCEPTION 'Invalid date value in condition_tree for condition_name=%', v_condition_name
            USING ERRCODE = '22007';
    WHEN invalid_text_representation OR numeric_value_out_of_range THEN
        RAISE EXCEPTION 'Invalid numeric/date value in condition_tree for condition_name=%', v_condition_name
            USING ERRCODE = '22023';
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION validate_pricing_rule_condition_tree(
    p_condition_tree JSONB,
    p_max_depth INT DEFAULT 5,
    p_max_members_per_group INT DEFAULT 20,
    p_max_conditions INT DEFAULT 50
) RETURNS BOOLEAN AS $$
DECLARE
    v_count INT;
BEGIN
    IF p_condition_tree IS NULL OR jsonb_typeof(p_condition_tree) = 'null' THEN
        RETURN TRUE;
    END IF;

    v_count := validate_pricing_rule_condition_tree_node(
        p_condition_tree,
        1,
        p_max_depth,
        p_max_members_per_group
    );

    IF v_count > p_max_conditions THEN
        RAISE EXCEPTION 'condition_tree has % unit conditions, max allowed is %', v_count, p_max_conditions
            USING ERRCODE = '22023';
    END IF;

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ============================================================================
-- 5. CONDITION TREE EVALUATION
-- ============================================================================

CREATE OR REPLACE FUNCTION evaluate_pricing_rule_unit_condition(
    p_condition JSONB,
    p_stay_length INT DEFAULT NULL,
    p_stay_extended INT DEFAULT NULL,
    p_stay_contracted INT DEFAULT NULL,
    p_booking_categories TEXT[] DEFAULT NULL,
    p_arrival_date DATE DEFAULT NULL,
    p_departure_date DATE DEFAULT NULL,
    p_target_date DATE DEFAULT NULL
) RETURNS BOOLEAN AS $$
DECLARE
    v_condition_name TEXT;
    v_operator TEXT;
    v_value JSONB;
    v_actual_number NUMERIC;
    v_actual_date DATE;
    v_result BOOLEAN;
BEGIN
    IF p_condition IS NULL OR jsonb_typeof(p_condition) IS DISTINCT FROM 'object' THEN
        RETURN FALSE;
    END IF;

    v_condition_name := LOWER(COALESCE(p_condition->>'condition_name', ''));
    v_operator := LOWER(COALESCE(p_condition->>'comparison_operator', ''));
    v_value := p_condition->'value';

    -- Number conditions
    IF v_condition_name IN ('stay_length', 'stay_extended', 'stay_contracted', 'net_stay') THEN
        CASE v_condition_name
            WHEN 'stay_length' THEN
                v_actual_number := p_stay_length;
            WHEN 'stay_extended' THEN
                v_actual_number := p_stay_extended;
            WHEN 'stay_contracted' THEN
                v_actual_number := p_stay_contracted;
            WHEN 'net_stay' THEN
                IF p_stay_length IS NULL THEN
                    RETURN FALSE;
                END IF;
                v_actual_number := p_stay_length + COALESCE(p_stay_extended, 0) - COALESCE(p_stay_contracted, 0);
        END CASE;

        IF v_actual_number IS NULL THEN
            RETURN FALSE;
        END IF;

        CASE v_operator
            WHEN 'eq' THEN
                RETURN v_actual_number = (v_value #>> '{}')::NUMERIC;
            WHEN 'gt' THEN
                RETURN v_actual_number > (v_value #>> '{}')::NUMERIC;
            WHEN 'gte' THEN
                RETURN v_actual_number >= (v_value #>> '{}')::NUMERIC;
            WHEN 'lt' THEN
                RETURN v_actual_number < (v_value #>> '{}')::NUMERIC;
            WHEN 'lte' THEN
                RETURN v_actual_number <= (v_value #>> '{}')::NUMERIC;
            WHEN 'between' THEN
                RETURN v_actual_number >= (v_value->>'min')::NUMERIC
                   AND v_actual_number <= (v_value->>'max')::NUMERIC;
            ELSE
                RETURN FALSE;
        END CASE;
    END IF;

    -- Booking category / class conditions
    IF v_condition_name IN ('booking_category', 'booking_class') THEN
        IF p_booking_categories IS NULL OR array_length(p_booking_categories, 1) IS NULL THEN
            RETURN FALSE;
        END IF;

        IF v_operator = 'any_of' THEN
            SELECT EXISTS (
                SELECT 1
                FROM jsonb_array_elements_text(v_value) AS configured(value)
                WHERE configured.value = ANY(p_booking_categories)
            ) INTO v_result;
            RETURN v_result;
        ELSIF v_operator = 'all_of' THEN
            SELECT NOT EXISTS (
                SELECT 1
                FROM jsonb_array_elements_text(v_value) AS configured(value)
                WHERE NOT configured.value = ANY(p_booking_categories)
            ) INTO v_result;
            RETURN v_result;
        ELSE
            RETURN FALSE;
        END IF;
    END IF;

    -- Date conditions
    IF v_condition_name IN ('arrival_date', 'departure_date', 'target_date') THEN
        CASE v_condition_name
            WHEN 'arrival_date' THEN v_actual_date := p_arrival_date;
            WHEN 'departure_date' THEN v_actual_date := p_departure_date;
            WHEN 'target_date' THEN v_actual_date := p_target_date;
        END CASE;

        IF v_actual_date IS NULL THEN
            RETURN FALSE;
        END IF;

        CASE v_operator
            WHEN 'eq' THEN
                RETURN v_actual_date = (v_value #>> '{}')::DATE;
            WHEN 'gt' THEN
                RETURN v_actual_date > (v_value #>> '{}')::DATE;
            WHEN 'gte' THEN
                RETURN v_actual_date >= (v_value #>> '{}')::DATE;
            WHEN 'lt' THEN
                RETURN v_actual_date < (v_value #>> '{}')::DATE;
            WHEN 'lte' THEN
                RETURN v_actual_date <= (v_value #>> '{}')::DATE;
            WHEN 'between' THEN
                RETURN v_actual_date >= (v_value->>'min')::DATE
                   AND v_actual_date <= (v_value->>'max')::DATE;
            ELSE
                RETURN FALSE;
        END CASE;
    END IF;

    RETURN FALSE;
EXCEPTION
    WHEN invalid_text_representation OR invalid_datetime_format OR numeric_value_out_of_range THEN
        RETURN FALSE;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION evaluate_pricing_rule_condition_tree(
    p_condition_tree JSONB,
    p_stay_length INT DEFAULT NULL,
    p_stay_extended INT DEFAULT NULL,
    p_stay_contracted INT DEFAULT NULL,
    p_booking_categories TEXT[] DEFAULT NULL,
    p_arrival_date DATE DEFAULT NULL,
    p_departure_date DATE DEFAULT NULL,
    p_target_date DATE DEFAULT NULL
) RETURNS BOOLEAN AS $$
DECLARE
    v_type TEXT;
    v_operator TEXT;
    v_member JSONB;
BEGIN
    IF p_condition_tree IS NULL OR jsonb_typeof(p_condition_tree) = 'null' THEN
        RETURN TRUE;
    END IF;

    IF jsonb_typeof(p_condition_tree) IS DISTINCT FROM 'object' THEN
        RETURN FALSE;
    END IF;

    v_type := LOWER(COALESCE(p_condition_tree->>'type', ''));

    IF v_type = 'condition' THEN
        RETURN evaluate_pricing_rule_unit_condition(
            p_condition_tree,
            p_stay_length,
            p_stay_extended,
            p_stay_contracted,
            p_booking_categories,
            p_arrival_date,
            p_departure_date,
            p_target_date
        );
    END IF;

    IF v_type <> 'group' THEN
        RETURN FALSE;
    END IF;

    v_operator := LOWER(COALESCE(p_condition_tree->>'evaluation_operator', ''));

    IF jsonb_typeof(p_condition_tree->'members') IS DISTINCT FROM 'array' THEN
        RETURN FALSE;
    END IF;

    IF v_operator = 'and' THEN
        FOR v_member IN SELECT value FROM jsonb_array_elements(p_condition_tree->'members')
        LOOP
            IF NOT evaluate_pricing_rule_condition_tree(
                v_member,
                p_stay_length,
                p_stay_extended,
                p_stay_contracted,
                p_booking_categories,
                p_arrival_date,
                p_departure_date,
                p_target_date
            ) THEN
                RETURN FALSE;
            END IF;
        END LOOP;
        RETURN TRUE;
    ELSIF v_operator = 'or' THEN
        FOR v_member IN SELECT value FROM jsonb_array_elements(p_condition_tree->'members')
        LOOP
            IF evaluate_pricing_rule_condition_tree(
                v_member,
                p_stay_length,
                p_stay_extended,
                p_stay_contracted,
                p_booking_categories,
                p_arrival_date,
                p_departure_date,
                p_target_date
            ) THEN
                RETURN TRUE;
            END IF;
        END LOOP;
        RETURN FALSE;
    END IF;

    RETURN FALSE;
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- 6. APPLY WINDOW VALIDATION / EVALUATION
-- ============================================================================

CREATE OR REPLACE FUNCTION evaluate_rule_apply_window(
    p_apply_window JSONB,
    p_target_date DATE,
    p_arrival_date DATE DEFAULT NULL,
    p_departure_date DATE DEFAULT NULL
) RETURNS BOOLEAN AS $$
DECLARE
    v_applies_from TEXT;
    v_duration_days INT;
    v_base_date DATE;
BEGIN
    IF p_apply_window IS NULL OR jsonb_typeof(p_apply_window) = 'null' THEN
        RETURN TRUE;
    END IF;

    IF p_target_date IS NULL THEN
        RETURN FALSE;
    END IF;

    IF jsonb_typeof(p_apply_window) IS DISTINCT FROM 'object' THEN
        RETURN FALSE;
    END IF;

    v_applies_from := LOWER(COALESCE(p_apply_window->>'applies_from', ''));
    v_duration_days := (p_apply_window->>'duration_days')::INT;

    IF v_duration_days < 1 THEN
        RETURN FALSE;
    END IF;

    IF v_applies_from = 'arrival' THEN
        v_base_date := p_arrival_date;
    ELSIF v_applies_from = 'departure' THEN
        v_base_date := p_departure_date;
    ELSE
        RETURN FALSE;
    END IF;

    IF v_base_date IS NULL THEN
        RETURN FALSE;
    END IF;

    -- Inclusive count. duration_days = 3 means base date, base + 1, base + 2.
    RETURN p_target_date >= v_base_date
       AND p_target_date <  v_base_date + v_duration_days;
EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range THEN
        RETURN FALSE;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION validate_pricing_rule_v2_rule_config(
    p_rule_config JSONB
) RETURNS BOOLEAN AS $$
DECLARE
    v_version INT;
    v_max_depth INT := COALESCE(get_config_int('condition_tree_max_depth', 5), 5);
    v_max_members INT := COALESCE(get_config_int('condition_tree_max_members_per_group', 20), 20);
    v_max_conditions INT := COALESCE(get_config_int('condition_tree_max_conditions_per_rule', 50), 50);
    v_max_apply_window_days INT := COALESCE(get_config_int('max_apply_window_duration_days', 31), 31);
    v_apply_window JSONB;
    v_duration_days INT;
    v_applies_from TEXT;
BEGIN
    IF p_rule_config IS NULL OR jsonb_typeof(p_rule_config) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'rule_config must be a JSON object'
            USING ERRCODE = '22023';
    END IF;

    IF p_rule_config->'condition_tree' IS NOT NULL
       AND jsonb_typeof(p_rule_config->'condition_tree') IS DISTINCT FROM 'null' THEN

        v_version := COALESCE((p_rule_config->>'conditions_version')::INT, 1);

        IF v_version <> 2 THEN
            RAISE EXCEPTION 'condition_tree requires conditions_version = 2'
                USING ERRCODE = '22023';
        END IF;

        PERFORM validate_pricing_rule_condition_tree(
            p_rule_config->'condition_tree',
            v_max_depth,
            v_max_members,
            v_max_conditions
        );
    END IF;

    v_apply_window := p_rule_config->'apply_window';

    IF v_apply_window IS NOT NULL AND jsonb_typeof(v_apply_window) IS DISTINCT FROM 'null' THEN
        IF jsonb_typeof(v_apply_window) IS DISTINCT FROM 'object' THEN
            RAISE EXCEPTION 'apply_window must be a JSON object'
                USING ERRCODE = '22023';
        END IF;

        v_applies_from := LOWER(COALESCE(v_apply_window->>'applies_from', ''));
        IF v_applies_from NOT IN ('arrival', 'departure') THEN
            RAISE EXCEPTION 'apply_window.applies_from must be arrival or departure'
                USING ERRCODE = '22023';
        END IF;

        v_duration_days := (v_apply_window->>'duration_days')::INT;

        IF v_duration_days < 1 THEN
            RAISE EXCEPTION 'apply_window.duration_days must be >= 1'
                USING ERRCODE = '22023';
        END IF;

        IF v_duration_days > v_max_apply_window_days THEN
            RAISE EXCEPTION 'apply_window.duration_days % exceeds max allowed %',
                v_duration_days, v_max_apply_window_days
                USING ERRCODE = '22023';
        END IF;
    END IF;

    RETURN TRUE;
EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range THEN
        RAISE EXCEPTION 'Invalid numeric value in rule_config validation'
            USING ERRCODE = '22023';
END;
$$ LANGUAGE plpgsql STABLE;

-- Validate all future pricing_rules writes, including direct INSERT/UPDATE and
-- create_pricing_rule(...), without rewriting the large create_pricing_rule body.
CREATE OR REPLACE FUNCTION validate_pricing_rules_rule_config_v2_trg()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM validate_pricing_rule_v2_rule_config(NEW.rule_config);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_pricing_rules_validate_rule_config_v2 ON pricing_rules;

CREATE TRIGGER trg_pricing_rules_validate_rule_config_v2
    BEFORE INSERT OR UPDATE OF rule_config ON pricing_rules
    FOR EACH ROW
    EXECUTE FUNCTION validate_pricing_rules_rule_config_v2_trg();

-- ============================================================================
-- 7. GET APPLICABLE RULES WITH CONDITION TREE + APPLY WINDOW
-- ============================================================================

-- Drop the 10-argument version so the new 12-argument version with defaults can
-- serve old 10-argument call sites without overload ambiguity.
DROP FUNCTION IF EXISTS get_applicable_pricing_rules(
    BIGINT, BIGINT, DATE, VARCHAR, BOOLEAN, BIGINT, INT, TEXT[], INT, INT
);

CREATE OR REPLACE FUNCTION get_applicable_pricing_rules(
    p_property_id                  BIGINT,
    p_platform_id                  BIGINT,
    p_target_date                  DATE     DEFAULT CURRENT_DATE,
    p_operation_code               VARCHAR  DEFAULT NULL,
    p_check_gaps                   BOOLEAN  DEFAULT TRUE,
    p_platform_property_lookup_id  BIGINT   DEFAULT NULL,
    p_stay_length                  INT      DEFAULT NULL,
    p_booking_classes              TEXT[]   DEFAULT NULL,
    p_stay_extended                INT      DEFAULT NULL,
    p_stay_contracted              INT      DEFAULT NULL,
    p_arrival_date                 DATE     DEFAULT NULL,
    p_departure_date               DATE     DEFAULT NULL
) RETURNS TABLE (
    rule_id            BIGINT,
    rule_uuid          UUID,
    operation_code     VARCHAR,
    operation_category operation_category,
    priority           INTEGER,
    scope              VARCHAR,
    rule_json          JSONB
) AS $$
DECLARE
    v_gap_exists                  BOOLEAN := FALSE;
    v_is_last_minute              BOOLEAN := FALSE;
    v_is_long_gap                 BOOLEAN := FALSE;
    v_operation_code_normalized   VARCHAR;
    v_max_stay_adj_rules          INT;
BEGIN
    v_operation_code_normalized := CASE
        WHEN p_operation_code = 'override' THEN 'set'
        ELSE p_operation_code
    END;

    IF p_stay_extended IS NOT NULL AND p_stay_extended < 0 THEN
        RAISE EXCEPTION 'p_stay_extended must be >= 0, got %', p_stay_extended
            USING ERRCODE = '22023';
    END IF;

    IF p_stay_contracted IS NOT NULL AND p_stay_contracted < 0 THEN
        RAISE EXCEPTION 'p_stay_contracted must be >= 0, got %', p_stay_contracted
            USING ERRCODE = '22023';
    END IF;

    v_max_stay_adj_rules := COALESCE(
        get_config('max_stay_adjustment_rules', '1')::INT,
        1
    );

    IF p_check_gaps THEN
        SELECT TRUE, gd.is_last_minute, gd.is_long_gap
          INTO v_gap_exists, v_is_last_minute, v_is_long_gap
          FROM gap_days gd
         WHERE gd.property_id = p_property_id
           AND gd.platform_id = p_platform_id
           AND gd.gap_date    = p_target_date;
    END IF;

    RETURN QUERY
    WITH ranked_rules AS (
        SELECT
            pr.id AS rule_id,
            pr.rule_uuid,
            CASE WHEN pot.operation_code = 'override' THEN 'set'
                 ELSE pot.operation_code
            END AS operation_code,
            pot.category AS operation_category,
            pot.execution_weight,
            pr.priority,
            pr.scope,
            CASE
                WHEN pr.scope = 'listing'  THEN 4000 + pr.priority
                WHEN pr.scope = 'property' THEN 3000 + pr.priority
                WHEN pr.scope = 'platform' THEN 2000 + pr.priority
                ELSE                            1000 + pr.priority
            END AS rule_score,
            (
                pr.rule_config ? 'stay_length'
                OR pr.rule_config ? 'stay_extended'
                OR pr.rule_config ? 'stay_contracted'
                OR pr.rule_config ? 'net_stay'
                OR pricing_rule_condition_tree_has_condition_names(
                    pr.rule_config->'condition_tree',
                    ARRAY['stay_length', 'stay_extended', 'stay_contracted', 'net_stay']::TEXT[]
                )
            ) AS is_stay_adj,
            jsonb_build_object(
                'rule_id',                     pr.id,
                'rule_uuid',                   pr.rule_uuid,
                'rule_name',                   pr.rule_name,
                'subject',                     pr.rule_config->>'subject',
                'operation',                   pr.rule_config->'operation',
                'rule_config',                 pr.rule_config,
                'priority',                    pr.priority,
                'scope',                       pr.scope,
                'platform_property_lookup_id', pr.platform_property_lookup_id,
                'metadata',                    pr.rule_config->'metadata'
            ) AS rule_json
        FROM pricing_rules pr
        JOIN pricing_operation_types pot ON pr.operation_id = pot.id
        WHERE pr.status = 'active'
          AND (pr.expires_at IS NULL OR pr.expires_at > NOW())

          AND (
              v_operation_code_normalized IS NULL
              OR CASE WHEN pot.operation_code = 'override' THEN 'set'
                      ELSE pot.operation_code
                 END = v_operation_code_normalized
          )

          -- Scope matching
          AND (
              (pr.scope = 'listing'
               AND p_platform_property_lookup_id IS NOT NULL
               AND pr.platform_property_lookup_id = p_platform_property_lookup_id)
              OR pr.scope = 'global'
              OR (pr.scope = 'platform' AND pr.platform_id = p_platform_id)
              OR (pr.scope = 'property' AND pr.property_id = p_property_id)
          )

          -- Date matching using the existing date mechanisms.
          AND (
              (pr.applicable_dates IS NOT NULL
               AND pr.applicable_dates ? p_target_date::TEXT)
              OR (pr.start_date IS NOT NULL AND pr.end_date IS NOT NULL
                  AND p_target_date BETWEEN pr.start_date AND pr.end_date)
              OR (pr.day_of_week_pattern IS NOT NULL
                  AND matches_dow_pattern(p_target_date, pr.day_of_week_pattern))
          )

          -- Enforce arrival/departure-relative apply window when present.
          AND (
              pr.rule_config->'apply_window' IS NULL
              OR jsonb_typeof(pr.rule_config->'apply_window') = 'null'
              OR evaluate_rule_apply_window(
                    pr.rule_config->'apply_window',
                    p_target_date,
                    p_arrival_date,
                    p_departure_date
                 )
          )

          -- Legacy gap-day conditions
          AND (
              pr.rule_config->'conditions'->'gap_day' IS NULL
              OR (v_gap_exists
                  AND (pr.rule_config->'conditions'->'gap_day'->>'is_last_minute' IS NULL
                       OR (pr.rule_config->'conditions'->'gap_day'->>'is_last_minute')::BOOLEAN = v_is_last_minute)
                  AND (pr.rule_config->'conditions'->'gap_day'->>'is_long_gap' IS NULL
                       OR (pr.rule_config->'conditions'->'gap_day'->>'is_long_gap')::BOOLEAN = v_is_long_gap))
          )

          -- Legacy nested stay-length condition
          AND (
              pr.rule_config->'conditions'->'stay_length' IS NULL
              OR evaluate_pricing_rule_number_condition_json(
                    pr.rule_config->'conditions'->'stay_length',
                    p_stay_length
                 )
          )

          -- Legacy booking-class conditions
          AND (
              pr.rule_config->'conditions'->'booking_class'->'any_of' IS NULL
              OR (p_booking_classes IS NOT NULL
                  AND EXISTS (
                      SELECT 1
                      FROM jsonb_array_elements_text(pr.rule_config->'conditions'->'booking_class'->'any_of') rc
                      WHERE rc = ANY(p_booking_classes)))
          )

          -- Legacy/top-level stay-adjustment conditions with comparison-object support.
          AND evaluate_pricing_rule_number_condition_json(
                pr.rule_config->'stay_length',
                p_stay_length
          )

          AND evaluate_pricing_rule_number_condition_json(
                pr.rule_config->'stay_extended',
                p_stay_extended
          )

          AND evaluate_pricing_rule_number_condition_json(
                pr.rule_config->'stay_contracted',
                p_stay_contracted
          )

          AND evaluate_pricing_rule_number_condition_json(
                pr.rule_config->'net_stay',
                CASE
                    WHEN p_stay_length IS NULL THEN NULL
                    ELSE p_stay_length + COALESCE(p_stay_extended, 0) - COALESCE(p_stay_contracted, 0)
                END
          )

          -- Versioned condition tree. New rules should prefer this model.
          AND (
              pr.rule_config->'condition_tree' IS NULL
              OR jsonb_typeof(pr.rule_config->'condition_tree') = 'null'
              OR evaluate_pricing_rule_condition_tree(
                    pr.rule_config->'condition_tree',
                    p_stay_length,
                    p_stay_extended,
                    p_stay_contracted,
                    p_booking_classes,
                    p_arrival_date,
                    p_departure_date,
                    p_target_date
                 )
          )
    ),

    stay_adj_ranked AS (
        SELECT
            rr.*,
            ROW_NUMBER() OVER (
                PARTITION BY rr.operation_category
                ORDER BY rr.rule_score DESC, rr.execution_weight DESC, rr.rule_id ASC
            ) AS stay_adj_rank
        FROM ranked_rules rr
        WHERE rr.is_stay_adj = TRUE
    )

    SELECT out_rules.rule_id,
           out_rules.rule_uuid,
           out_rules.operation_code,
           out_rules.operation_category,
           out_rules.priority,
           out_rules.scope,
           out_rules.rule_json
    FROM (
        SELECT rr.rule_id, rr.rule_uuid, rr.operation_code, rr.operation_category,
               rr.priority, rr.scope, rr.rule_json
        FROM ranked_rules rr
        WHERE rr.is_stay_adj = FALSE

        UNION ALL

        SELECT sa.rule_id, sa.rule_uuid, sa.operation_code, sa.operation_category,
               sa.priority, sa.scope, sa.rule_json
        FROM stay_adj_ranked sa
        WHERE sa.stay_adj_rank <= v_max_stay_adj_rules
    ) out_rules
    ORDER BY
        CASE out_rules.scope
            WHEN 'listing'  THEN 4000
            WHEN 'property' THEN 3000
            WHEN 'platform' THEN 2000
            ELSE                 1000
        END + out_rules.priority DESC,
        out_rules.rule_id ASC;
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- 8. SMOKE TESTS
-- ============================================================================

DO $$
DECLARE
    v_fn_exists BOOLEAN;
    v_trigger_exists BOOLEAN;
BEGIN
    SELECT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'get_applicable_pricing_rules'
          AND p.pronargs = 12
    ) INTO v_fn_exists;

    IF NOT v_fn_exists THEN
        RAISE EXCEPTION 'FAIL: get_applicable_pricing_rules with 12 parameters was not created';
    END IF;

    SELECT EXISTS (
        SELECT 1
        FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        WHERE c.relname = 'pricing_rules'
          AND t.tgname = 'trg_pricing_rules_validate_rule_config_v2'
    ) INTO v_trigger_exists;

    IF NOT v_trigger_exists THEN
        RAISE EXCEPTION 'FAIL: pricing_rules v2 validation trigger was not created';
    END IF;

    PERFORM validate_pricing_rule_condition_tree(
        '{
            "type": "group",
            "evaluation_operator": "and",
            "members": [
                {
                    "type": "group",
                    "evaluation_operator": "or",
                    "members": [
                        {
                            "type": "condition",
                            "condition_name": "stay_length",
                            "comparison_operator": "between",
                            "value": {"min": 10, "max": 20}
                        },
                        {
                            "type": "condition",
                            "condition_name": "stay_extended",
                            "comparison_operator": "gt",
                            "value": 0
                        }
                    ]
                },
                {
                    "type": "condition",
                    "condition_name": "booking_category",
                    "comparison_operator": "any_of",
                    "value": ["medical", "job", "insurance", "pet"]
                }
            ]
        }'::JSONB
    );

    IF NOT evaluate_pricing_rule_condition_tree(
        '{
            "type": "group",
            "evaluation_operator": "and",
            "members": [
                {
                    "type": "condition",
                    "condition_name": "stay_extended",
                    "comparison_operator": "gt",
                    "value": 0
                },
                {
                    "type": "condition",
                    "condition_name": "booking_category",
                    "comparison_operator": "any_of",
                    "value": ["pet"]
                }
            ]
        }'::JSONB,
        20,
        2,
        0,
        ARRAY['pet']::TEXT[],
        DATE '2026-06-01',
        DATE '2026-06-21',
        DATE '2026-06-21'
    ) THEN
        RAISE EXCEPTION 'FAIL: condition_tree evaluator smoke test returned false';
    END IF;

    IF NOT evaluate_rule_apply_window(
        '{"applies_from":"departure","duration_days":3}'::JSONB,
        DATE '2026-06-23',
        DATE '2026-06-01',
        DATE '2026-06-21'
    ) THEN
        RAISE EXCEPTION 'FAIL: apply_window smoke test expected true';
    END IF;

    IF evaluate_rule_apply_window(
        '{"applies_from":"departure","duration_days":3}'::JSONB,
        DATE '2026-06-24',
        DATE '2026-06-01',
        DATE '2026-06-21'
    ) THEN
        RAISE EXCEPTION 'FAIL: apply_window smoke test expected false';
    END IF;

    RAISE NOTICE 'OK: pricing_engine_condition_tree_migration verified successfully.';
END $$;

-- ============================================================================
-- 9. EXAMPLE CREATE_PRICING_RULE CALL
-- ============================================================================

/*
SELECT create_pricing_rule(
    p_api_key        => 'sk_your_worker_api_key',
    p_property_id    => 101,
    p_platform_id    => 1,
    p_operation_code => 'increase',
    p_rule_config    => '{
        "subject": "price",
        "operation": {
            "do": "increase",
            "type": "percentage",
            "amount": 30
        },
        "apply_window": {
            "applies_from": "departure",
            "duration_days": 3
        },
        "conditions_version": 2,
        "condition_tree": {
            "type": "group",
            "evaluation_operator": "and",
            "members": [
                {
                    "type": "group",
                    "evaluation_operator": "or",
                    "members": [
                        {
                            "type": "condition",
                            "condition_name": "stay_length",
                            "comparison_operator": "between",
                            "value": {"min": 10, "max": 20}
                        },
                        {
                            "type": "condition",
                            "condition_name": "stay_extended",
                            "comparison_operator": "gt",
                            "value": 0
                        }
                    ]
                },
                {
                    "type": "condition",
                    "condition_name": "booking_category",
                    "comparison_operator": "any_of",
                    "value": ["medical", "job", "insurance", "pet"]
                }
            ]
        }
    }'::JSONB,
    p_dates          => NULL,
    p_start_date     => DATE '2026-01-01',
    p_end_date       => DATE '2026-12-31',
    p_dow_pattern    => NULL,
    p_priority       => 80,
    p_rule_name      => 'V2 nested condition rule example'
);

-- Example match lookup. Since apply_window is departure-relative, pass arrival
-- and departure dates when calling get_applicable_pricing_rules.
SELECT *
FROM get_applicable_pricing_rules(
    p_property_id                 => 101,
    p_platform_id                 => 1,
    p_target_date                 => DATE '2026-06-23',
    p_operation_code              => 'increase',
    p_check_gaps                  => TRUE,
    p_platform_property_lookup_id => NULL,
    p_stay_length                 => 20,
    p_booking_classes             => ARRAY['pet']::TEXT[],
    p_stay_extended               => 2,
    p_stay_contracted             => 0,
    p_arrival_date                => DATE '2026-06-01',
    p_departure_date              => DATE '2026-06-21'
);
*/

-- ============================================================================
-- END OF MIGRATION
-- ============================================================================
