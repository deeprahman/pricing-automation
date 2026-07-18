-- ============================================================================
-- pricing_engine_rule_guard_migration.sql
--
-- Purpose:
--   Add a same-scope / same-priority semantic rule guard for pricing_rules.
--
--   The existing conflict guard catches structural overlap:
--     scope target + operation category + date window + day-of-week pattern.
--
--   This migration adds semantic overlap detection for condition domains so that
--   two active rules with the same precedence cannot both match the same booking
--   context unless an explicit metadata escape hatch is supplied.
--
--   Supported condition families:
--     - booking_category / booking_class with any_of / all_of
--     - optional position-aware category matching via "pos"
--     - stay_length / stay_extended / stay_contracted / net_stay numeric ranges
--     - arrival_date / departure_date / target_date date ranges
--     - recursive condition_tree AND / OR groups, converted to DNF internally
--
-- Safety model:
--   - proven non-overlap => allow
--   - proven overlap     => block for same scope + same priority
--   - unknown            => treat as overlap
--
-- Notes:
--   - This migration adds validation for condition_tree category/class "pos".
--   - The overlap guard is conservative for category positions because message
--     class positions can be thread-local. The same class at two different
--     positions is treated as possibly satisfiable unless the runtime model is
--     later tightened with thread_id-aware matching.
--   - Existing legacy rules remain valid.
--
-- Prerequisites:
--   - pricing-engine.sql
--   - pricing_engine_condition_tree_migration_patched.sql recommended
--   - pricing_engine_conflict_guard_migration_patched.sql recommended
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

    IF to_regclass('public.pricing_rule_audit') IS NULL THEN
        RAISE EXCEPTION 'Missing table: pricing_rule_audit. Run pricing-engine.sql first.';
    END IF;

    IF to_regclass('public.pricing_operation_types') IS NULL THEN
        RAISE EXCEPTION 'Missing table: pricing_operation_types. Run pricing-engine.sql first.';
    END IF;
END $$;

-- ============================================================================
-- 2. POSITION VALIDATION FOR BOOKING CATEGORY / CLASS CONDITIONS
-- ============================================================================

CREATE OR REPLACE FUNCTION validate_pricing_rule_category_position_node(
    p_node JSONB
) RETURNS BOOLEAN AS $$
DECLARE
    v_type TEXT;
    v_member JSONB;
    v_condition_name TEXT;
    v_value JSONB;
    v_pos JSONB;
    v_pos_member JSONB;
    v_pos_num NUMERIC;
BEGIN
    IF p_node IS NULL OR jsonb_typeof(p_node) = 'null' THEN
        RETURN TRUE;
    END IF;

    IF jsonb_typeof(p_node) IS DISTINCT FROM 'object' THEN
        RETURN TRUE;
    END IF;

    v_type := LOWER(COALESCE(p_node->>'type', ''));

    IF v_type = 'group' THEN
        IF jsonb_typeof(p_node->'members') = 'array' THEN
            FOR v_member IN SELECT value FROM jsonb_array_elements(p_node->'members')
            LOOP
                PERFORM validate_pricing_rule_category_position_node(v_member);
            END LOOP;
        END IF;
        RETURN TRUE;
    END IF;

    IF v_type <> 'condition' THEN
        RETURN TRUE;
    END IF;

    v_condition_name := LOWER(COALESCE(p_node->>'condition_name', ''));

    IF v_condition_name NOT IN ('booking_category', 'booking_class') THEN
        RETURN TRUE;
    END IF;

    v_pos := p_node->'pos';
    IF v_pos IS NULL OR jsonb_typeof(v_pos) = 'null' THEN
        RETURN TRUE;
    END IF;

    v_value := p_node->'value';

    IF jsonb_typeof(v_pos) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'pos for % must be an array when present', v_condition_name
            USING ERRCODE = '22023';
    END IF;

    IF jsonb_typeof(v_value) IS DISTINCT FROM 'array' THEN
        -- Base condition-tree validation owns the value error. Return here to
        -- avoid masking its message.
        RETURN TRUE;
    END IF;

    IF jsonb_array_length(v_pos) <> jsonb_array_length(v_value) THEN
        RAISE EXCEPTION 'pos length (%) must equal value length (%) for %',
            jsonb_array_length(v_pos),
            jsonb_array_length(v_value),
            v_condition_name
            USING ERRCODE = '22023';
    END IF;

    FOR v_pos_member IN SELECT value FROM jsonb_array_elements(v_pos)
    LOOP
        IF jsonb_typeof(v_pos_member) = 'null' THEN
            CONTINUE;
        END IF;

        IF jsonb_typeof(v_pos_member) IS DISTINCT FROM 'number' THEN
            RAISE EXCEPTION 'pos entries for % must be null or non-negative integers', v_condition_name
                USING ERRCODE = '22023';
        END IF;

        v_pos_num := (v_pos_member #>> '{}')::NUMERIC;
        IF v_pos_num < 0 OR v_pos_num <> TRUNC(v_pos_num) THEN
            RAISE EXCEPTION 'pos entries for % must be null or non-negative integers', v_condition_name
                USING ERRCODE = '22023';
        END IF;
    END LOOP;

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION validate_pricing_rule_category_positions_trg()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.rule_config IS NOT NULL
       AND jsonb_typeof(NEW.rule_config) = 'object'
       AND NEW.rule_config->'condition_tree' IS NOT NULL
       AND jsonb_typeof(NEW.rule_config->'condition_tree') IS DISTINCT FROM 'null' THEN
        PERFORM validate_pricing_rule_category_position_node(NEW.rule_config->'condition_tree');
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_pricing_rules_validate_category_positions ON pricing_rules;

CREATE TRIGGER trg_pricing_rules_validate_category_positions
    BEFORE INSERT OR UPDATE OF rule_config ON pricing_rules
    FOR EACH ROW
    EXECUTE FUNCTION validate_pricing_rule_category_positions_trg();

-- ============================================================================
-- 3. INTERVAL HELPERS
-- ============================================================================

CREATE OR REPLACE FUNCTION pricing_rule_make_interval(
    p_min NUMERIC DEFAULT NULL,
    p_min_inclusive BOOLEAN DEFAULT FALSE,
    p_max NUMERIC DEFAULT NULL,
    p_max_inclusive BOOLEAN DEFAULT FALSE
) RETURNS JSONB AS $$
BEGIN
    RETURN jsonb_build_object(
        'min', p_min,
        'min_inclusive', COALESCE(p_min_inclusive, FALSE),
        'max', p_max,
        'max_inclusive', COALESCE(p_max_inclusive, FALSE)
    );
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION pricing_rule_make_date_interval(
    p_min DATE DEFAULT NULL,
    p_min_inclusive BOOLEAN DEFAULT FALSE,
    p_max DATE DEFAULT NULL,
    p_max_inclusive BOOLEAN DEFAULT FALSE
) RETURNS JSONB AS $$
BEGIN
    RETURN jsonb_build_object(
        'min', CASE WHEN p_min IS NULL THEN NULL ELSE p_min::TEXT END,
        'min_inclusive', COALESCE(p_min_inclusive, FALSE),
        'max', CASE WHEN p_max IS NULL THEN NULL ELSE p_max::TEXT END,
        'max_inclusive', COALESCE(p_max_inclusive, FALSE)
    );
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION pricing_rule_interval_intersection(
    p_left JSONB,
    p_right JSONB
) RETURNS JSONB AS $$
DECLARE
    l_min NUMERIC := NULLIF(p_left->>'min', '')::NUMERIC;
    l_max NUMERIC := NULLIF(p_left->>'max', '')::NUMERIC;
    r_min NUMERIC := NULLIF(p_right->>'min', '')::NUMERIC;
    r_max NUMERIC := NULLIF(p_right->>'max', '')::NUMERIC;
    l_min_inc BOOLEAN := COALESCE((p_left->>'min_inclusive')::BOOLEAN, FALSE);
    l_max_inc BOOLEAN := COALESCE((p_left->>'max_inclusive')::BOOLEAN, FALSE);
    r_min_inc BOOLEAN := COALESCE((p_right->>'min_inclusive')::BOOLEAN, FALSE);
    r_max_inc BOOLEAN := COALESCE((p_right->>'max_inclusive')::BOOLEAN, FALSE);
    v_min NUMERIC;
    v_max NUMERIC;
    v_min_inc BOOLEAN;
    v_max_inc BOOLEAN;
BEGIN
    IF l_min IS NULL THEN
        v_min := r_min;
        v_min_inc := r_min_inc;
    ELSIF r_min IS NULL THEN
        v_min := l_min;
        v_min_inc := l_min_inc;
    ELSIF l_min > r_min THEN
        v_min := l_min;
        v_min_inc := l_min_inc;
    ELSIF r_min > l_min THEN
        v_min := r_min;
        v_min_inc := r_min_inc;
    ELSE
        v_min := l_min;
        v_min_inc := l_min_inc AND r_min_inc;
    END IF;

    IF l_max IS NULL THEN
        v_max := r_max;
        v_max_inc := r_max_inc;
    ELSIF r_max IS NULL THEN
        v_max := l_max;
        v_max_inc := l_max_inc;
    ELSIF l_max < r_max THEN
        v_max := l_max;
        v_max_inc := l_max_inc;
    ELSIF r_max < l_max THEN
        v_max := r_max;
        v_max_inc := r_max_inc;
    ELSE
        v_max := l_max;
        v_max_inc := l_max_inc AND r_max_inc;
    END IF;

    IF v_min IS NOT NULL AND v_max IS NOT NULL THEN
        IF v_min > v_max THEN
            RETURN NULL;
        END IF;
        IF v_min = v_max AND NOT (v_min_inc AND v_max_inc) THEN
            RETURN NULL;
        END IF;
    END IF;

    RETURN pricing_rule_make_interval(v_min, v_min_inc, v_max, v_max_inc);
EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range THEN
        -- Unknown/malformed intervals are treated as non-restrictive by returning
        -- a full interval. This keeps the final guard conservative.
        RETURN pricing_rule_make_interval(NULL, FALSE, NULL, FALSE);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION pricing_rule_date_interval_intersection(
    p_left JSONB,
    p_right JSONB
) RETURNS JSONB AS $$
DECLARE
    l_min DATE := NULLIF(p_left->>'min', '')::DATE;
    l_max DATE := NULLIF(p_left->>'max', '')::DATE;
    r_min DATE := NULLIF(p_right->>'min', '')::DATE;
    r_max DATE := NULLIF(p_right->>'max', '')::DATE;
    l_min_inc BOOLEAN := COALESCE((p_left->>'min_inclusive')::BOOLEAN, FALSE);
    l_max_inc BOOLEAN := COALESCE((p_left->>'max_inclusive')::BOOLEAN, FALSE);
    r_min_inc BOOLEAN := COALESCE((p_right->>'min_inclusive')::BOOLEAN, FALSE);
    r_max_inc BOOLEAN := COALESCE((p_right->>'max_inclusive')::BOOLEAN, FALSE);
    v_min DATE;
    v_max DATE;
    v_min_inc BOOLEAN;
    v_max_inc BOOLEAN;
BEGIN
    IF l_min IS NULL THEN
        v_min := r_min;
        v_min_inc := r_min_inc;
    ELSIF r_min IS NULL THEN
        v_min := l_min;
        v_min_inc := l_min_inc;
    ELSIF l_min > r_min THEN
        v_min := l_min;
        v_min_inc := l_min_inc;
    ELSIF r_min > l_min THEN
        v_min := r_min;
        v_min_inc := r_min_inc;
    ELSE
        v_min := l_min;
        v_min_inc := l_min_inc AND r_min_inc;
    END IF;

    IF l_max IS NULL THEN
        v_max := r_max;
        v_max_inc := r_max_inc;
    ELSIF r_max IS NULL THEN
        v_max := l_max;
        v_max_inc := l_max_inc;
    ELSIF l_max < r_max THEN
        v_max := l_max;
        v_max_inc := l_max_inc;
    ELSIF r_max < l_max THEN
        v_max := r_max;
        v_max_inc := r_max_inc;
    ELSE
        v_max := l_max;
        v_max_inc := l_max_inc AND r_max_inc;
    END IF;

    IF v_min IS NOT NULL AND v_max IS NOT NULL THEN
        IF v_min > v_max THEN
            RETURN NULL;
        END IF;
        IF v_min = v_max AND NOT (v_min_inc AND v_max_inc) THEN
            RETURN NULL;
        END IF;
    END IF;

    RETURN pricing_rule_make_date_interval(v_min, v_min_inc, v_max, v_max_inc);
EXCEPTION
    WHEN invalid_datetime_format OR invalid_text_representation THEN
        RETURN pricing_rule_make_date_interval(NULL, FALSE, NULL, FALSE);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ============================================================================
-- 4. CONDITION NORMALIZATION HELPERS
-- ============================================================================

CREATE OR REPLACE FUNCTION pricing_rule_numeric_interval_from_unit_condition(
    p_condition JSONB
) RETURNS JSONB AS $$
DECLARE
    v_operator TEXT := LOWER(COALESCE(p_condition->>'comparison_operator', ''));
    v_value JSONB := p_condition->'value';
    v_num NUMERIC;
BEGIN
    IF v_operator = 'eq' THEN
        v_num := (v_value #>> '{}')::NUMERIC;
        RETURN pricing_rule_make_interval(v_num, TRUE, v_num, TRUE);
    ELSIF v_operator = 'gt' THEN
        v_num := (v_value #>> '{}')::NUMERIC;
        RETURN pricing_rule_make_interval(v_num, FALSE, NULL, FALSE);
    ELSIF v_operator = 'gte' THEN
        v_num := (v_value #>> '{}')::NUMERIC;
        RETURN pricing_rule_make_interval(v_num, TRUE, NULL, FALSE);
    ELSIF v_operator = 'lt' THEN
        v_num := (v_value #>> '{}')::NUMERIC;
        RETURN pricing_rule_make_interval(NULL, FALSE, v_num, FALSE);
    ELSIF v_operator = 'lte' THEN
        v_num := (v_value #>> '{}')::NUMERIC;
        RETURN pricing_rule_make_interval(NULL, FALSE, v_num, TRUE);
    ELSIF v_operator = 'between' THEN
        RETURN pricing_rule_make_interval(
            (v_value->>'min')::NUMERIC,
            TRUE,
            (v_value->>'max')::NUMERIC,
            TRUE
        );
    END IF;

    RETURN pricing_rule_make_interval(NULL, FALSE, NULL, FALSE);
EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range THEN
        RETURN pricing_rule_make_interval(NULL, FALSE, NULL, FALSE);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION pricing_rule_numeric_interval_from_legacy_json(
    p_value JSONB
) RETURNS JSONB AS $$
DECLARE
    v_interval JSONB := pricing_rule_make_interval(NULL, FALSE, NULL, FALSE);
    v_next JSONB;
BEGIN
    IF p_value IS NULL OR jsonb_typeof(p_value) = 'null' THEN
        RETURN v_interval;
    END IF;

    IF jsonb_typeof(p_value) = 'number' THEN
        RETURN pricing_rule_make_interval((p_value #>> '{}')::NUMERIC, TRUE, (p_value #>> '{}')::NUMERIC, TRUE);
    END IF;

    IF jsonb_typeof(p_value) IS DISTINCT FROM 'object' THEN
        RETURN v_interval;
    END IF;

    IF p_value ? 'between' THEN
        v_next := pricing_rule_make_interval(
            (p_value->'between'->>'min')::NUMERIC,
            TRUE,
            (p_value->'between'->>'max')::NUMERIC,
            TRUE
        );
        v_interval := pricing_rule_interval_intersection(v_interval, v_next);
        IF v_interval IS NULL THEN RETURN NULL; END IF;
    END IF;

    IF p_value ? 'gt' THEN
        v_next := pricing_rule_make_interval((p_value->>'gt')::NUMERIC, FALSE, NULL, FALSE);
        v_interval := pricing_rule_interval_intersection(v_interval, v_next);
        IF v_interval IS NULL THEN RETURN NULL; END IF;
    END IF;

    IF p_value ? 'gte' THEN
        v_next := pricing_rule_make_interval((p_value->>'gte')::NUMERIC, TRUE, NULL, FALSE);
        v_interval := pricing_rule_interval_intersection(v_interval, v_next);
        IF v_interval IS NULL THEN RETURN NULL; END IF;
    END IF;

    IF p_value ? 'lt' THEN
        v_next := pricing_rule_make_interval(NULL, FALSE, (p_value->>'lt')::NUMERIC, FALSE);
        v_interval := pricing_rule_interval_intersection(v_interval, v_next);
        IF v_interval IS NULL THEN RETURN NULL; END IF;
    END IF;

    IF p_value ? 'lte' THEN
        v_next := pricing_rule_make_interval(NULL, FALSE, (p_value->>'lte')::NUMERIC, TRUE);
        v_interval := pricing_rule_interval_intersection(v_interval, v_next);
        IF v_interval IS NULL THEN RETURN NULL; END IF;
    END IF;

    RETURN v_interval;
EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range THEN
        RETURN pricing_rule_make_interval(NULL, FALSE, NULL, FALSE);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION pricing_rule_date_interval_from_unit_condition(
    p_condition JSONB
) RETURNS JSONB AS $$
DECLARE
    v_operator TEXT := LOWER(COALESCE(p_condition->>'comparison_operator', ''));
    v_value JSONB := p_condition->'value';
    v_date DATE;
BEGIN
    IF v_operator = 'eq' THEN
        v_date := (v_value #>> '{}')::DATE;
        RETURN pricing_rule_make_date_interval(v_date, TRUE, v_date, TRUE);
    ELSIF v_operator = 'gt' THEN
        v_date := (v_value #>> '{}')::DATE;
        RETURN pricing_rule_make_date_interval(v_date, FALSE, NULL, FALSE);
    ELSIF v_operator = 'gte' THEN
        v_date := (v_value #>> '{}')::DATE;
        RETURN pricing_rule_make_date_interval(v_date, TRUE, NULL, FALSE);
    ELSIF v_operator = 'lt' THEN
        v_date := (v_value #>> '{}')::DATE;
        RETURN pricing_rule_make_date_interval(NULL, FALSE, v_date, FALSE);
    ELSIF v_operator = 'lte' THEN
        v_date := (v_value #>> '{}')::DATE;
        RETURN pricing_rule_make_date_interval(NULL, FALSE, v_date, TRUE);
    ELSIF v_operator = 'between' THEN
        RETURN pricing_rule_make_date_interval(
            (v_value->>'min')::DATE,
            TRUE,
            (v_value->>'max')::DATE,
            TRUE
        );
    END IF;

    RETURN pricing_rule_make_date_interval(NULL, FALSE, NULL, FALSE);
EXCEPTION
    WHEN invalid_datetime_format OR invalid_text_representation THEN
        RETURN pricing_rule_make_date_interval(NULL, FALSE, NULL, FALSE);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION pricing_rule_category_items_from_unit_condition(
    p_condition JSONB
) RETURNS JSONB AS $$
DECLARE
    v_value JSONB := p_condition->'value';
    v_pos JSONB := p_condition->'pos';
    v_item JSONB;
    v_pos_item JSONB;
    v_pos_int INT;
    v_result JSONB := '[]'::JSONB;
    v_idx INT;
BEGIN
    IF jsonb_typeof(v_value) IS DISTINCT FROM 'array' THEN
        RETURN v_result;
    END IF;

    FOR v_item, v_idx IN
        SELECT value, ordinality::INT
        FROM jsonb_array_elements(v_value) WITH ORDINALITY
    LOOP
        v_pos_int := NULL;

        IF jsonb_typeof(v_pos) = 'array' THEN
            v_pos_item := v_pos -> (v_idx - 1);
            IF v_pos_item IS NOT NULL AND jsonb_typeof(v_pos_item) = 'number' THEN
                v_pos_int := (v_pos_item #>> '{}')::INT;
            END IF;
        END IF;

        IF jsonb_typeof(v_item) = 'string' AND BTRIM(v_item #>> '{}') <> '' THEN
            v_result := v_result || jsonb_build_array(
                jsonb_build_object(
                    'class', BTRIM(v_item #>> '{}'),
                    'pos', v_pos_int
                )
            );
        END IF;
    END LOOP;

    RETURN v_result;
EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range THEN
        RETURN v_result;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ============================================================================
-- 5. DNF CONVERSION
-- ============================================================================

CREATE OR REPLACE FUNCTION pricing_rule_unit_condition_to_dnf(
    p_condition JSONB
) RETURNS JSONB AS $$
DECLARE
    v_condition_name TEXT;
    v_operator TEXT;
    v_interval JSONB;
    v_items JSONB;
    v_item JSONB;
    v_result JSONB := '[]'::JSONB;
BEGIN
    IF p_condition IS NULL OR jsonb_typeof(p_condition) IS DISTINCT FROM 'object' THEN
        RETURN jsonb_build_array(jsonb_build_object('unknown', TRUE));
    END IF;

    v_condition_name := LOWER(COALESCE(p_condition->>'condition_name', ''));
    v_operator := LOWER(COALESCE(p_condition->>'comparison_operator', ''));

    IF v_condition_name IN ('booking_category', 'booking_class') THEN
        v_items := pricing_rule_category_items_from_unit_condition(p_condition);

        IF jsonb_array_length(v_items) = 0 THEN
            RETURN jsonb_build_array(jsonb_build_object('unknown', TRUE));
        END IF;

        IF v_operator = 'any_of' THEN
            FOR v_item IN SELECT value FROM jsonb_array_elements(v_items)
            LOOP
                v_result := v_result || jsonb_build_array(
                    jsonb_build_object('categories', jsonb_build_array(v_item))
                );
            END LOOP;
            RETURN v_result;
        ELSIF v_operator = 'all_of' THEN
            RETURN jsonb_build_array(jsonb_build_object('categories', v_items));
        ELSE
            RETURN jsonb_build_array(jsonb_build_object('unknown', TRUE));
        END IF;
    END IF;

    IF v_condition_name IN ('stay_length', 'stay_extended', 'stay_contracted', 'net_stay') THEN
        v_interval := pricing_rule_numeric_interval_from_unit_condition(p_condition);
        IF v_interval IS NULL THEN
            RETURN '[]'::JSONB;
        END IF;
        RETURN jsonb_build_array(
            jsonb_build_object('numeric', jsonb_build_object(v_condition_name, v_interval))
        );
    END IF;

    IF v_condition_name IN ('arrival_date', 'departure_date', 'target_date') THEN
        v_interval := pricing_rule_date_interval_from_unit_condition(p_condition);
        IF v_interval IS NULL THEN
            RETURN '[]'::JSONB;
        END IF;
        RETURN jsonb_build_array(
            jsonb_build_object('date', jsonb_build_object(v_condition_name, v_interval))
        );
    END IF;

    RETURN jsonb_build_array(jsonb_build_object('unknown', TRUE));
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION pricing_rule_merge_branches(
    p_left JSONB,
    p_right JSONB
) RETURNS JSONB AS $$
DECLARE
    v_result JSONB := '{}'::JSONB;
    v_numeric JSONB := COALESCE(p_left->'numeric', '{}'::JSONB);
    v_dates JSONB := COALESCE(p_left->'date', '{}'::JSONB);
    v_categories JSONB := COALESCE(p_left->'categories', '[]'::JSONB);
    v_key TEXT;
    v_value JSONB;
    v_existing JSONB;
    v_intersection JSONB;
    v_unknown BOOLEAN := COALESCE((p_left->>'unknown')::BOOLEAN, FALSE)
                         OR COALESCE((p_right->>'unknown')::BOOLEAN, FALSE);
BEGIN
    FOR v_key, v_value IN SELECT key, value FROM jsonb_each(COALESCE(p_right->'numeric', '{}'::JSONB))
    LOOP
        v_existing := v_numeric->v_key;
        IF v_existing IS NULL OR jsonb_typeof(v_existing) = 'null' THEN
            v_numeric := jsonb_set(v_numeric, ARRAY[v_key], v_value, TRUE);
        ELSE
            v_intersection := pricing_rule_interval_intersection(v_existing, v_value);
            IF v_intersection IS NULL THEN
                RETURN NULL;
            END IF;
            v_numeric := jsonb_set(v_numeric, ARRAY[v_key], v_intersection, TRUE);
        END IF;
    END LOOP;

    FOR v_key, v_value IN SELECT key, value FROM jsonb_each(COALESCE(p_right->'date', '{}'::JSONB))
    LOOP
        v_existing := v_dates->v_key;
        IF v_existing IS NULL OR jsonb_typeof(v_existing) = 'null' THEN
            v_dates := jsonb_set(v_dates, ARRAY[v_key], v_value, TRUE);
        ELSE
            v_intersection := pricing_rule_date_interval_intersection(v_existing, v_value);
            IF v_intersection IS NULL THEN
                RETURN NULL;
            END IF;
            v_dates := jsonb_set(v_dates, ARRAY[v_key], v_intersection, TRUE);
        END IF;
    END LOOP;

    v_categories := v_categories || COALESCE(p_right->'categories', '[]'::JSONB);

    IF jsonb_typeof(v_numeric) = 'object' AND v_numeric <> '{}'::JSONB THEN
        v_result := jsonb_set(v_result, '{numeric}', v_numeric, TRUE);
    END IF;

    IF jsonb_typeof(v_dates) = 'object' AND v_dates <> '{}'::JSONB THEN
        v_result := jsonb_set(v_result, '{date}', v_dates, TRUE);
    END IF;

    IF jsonb_typeof(v_categories) = 'array' AND jsonb_array_length(v_categories) > 0 THEN
        v_result := jsonb_set(v_result, '{categories}', v_categories, TRUE);
    END IF;

    IF v_unknown THEN
        v_result := jsonb_set(v_result, '{unknown}', 'true'::JSONB, TRUE);
    END IF;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION pricing_rule_and_dnf(
    p_left JSONB,
    p_right JSONB
) RETURNS JSONB AS $$
DECLARE
    v_left_branch JSONB;
    v_right_branch JSONB;
    v_merged JSONB;
    v_result JSONB := '[]'::JSONB;
BEGIN
    IF jsonb_typeof(p_left) IS DISTINCT FROM 'array'
       OR jsonb_typeof(p_right) IS DISTINCT FROM 'array' THEN
        RETURN jsonb_build_array(jsonb_build_object('unknown', TRUE));
    END IF;

    IF jsonb_array_length(p_left) = 0 OR jsonb_array_length(p_right) = 0 THEN
        RETURN '[]'::JSONB;
    END IF;

    FOR v_left_branch IN SELECT value FROM jsonb_array_elements(p_left)
    LOOP
        FOR v_right_branch IN SELECT value FROM jsonb_array_elements(p_right)
        LOOP
            v_merged := pricing_rule_merge_branches(v_left_branch, v_right_branch);
            IF v_merged IS NOT NULL THEN
                v_result := v_result || jsonb_build_array(v_merged);
            END IF;
        END LOOP;
    END LOOP;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION pricing_rule_condition_tree_to_dnf(
    p_tree JSONB
) RETURNS JSONB AS $$
DECLARE
    v_type TEXT;
    v_operator TEXT;
    v_member JSONB;
    v_member_dnf JSONB;
    v_result JSONB;
BEGIN
    IF p_tree IS NULL OR jsonb_typeof(p_tree) = 'null' THEN
        RETURN jsonb_build_array('{}'::JSONB);
    END IF;

    IF jsonb_typeof(p_tree) IS DISTINCT FROM 'object' THEN
        RETURN jsonb_build_array(jsonb_build_object('unknown', TRUE));
    END IF;

    v_type := LOWER(COALESCE(p_tree->>'type', ''));

    IF v_type = 'condition' THEN
        RETURN pricing_rule_unit_condition_to_dnf(p_tree);
    END IF;

    IF v_type <> 'group' THEN
        RETURN jsonb_build_array(jsonb_build_object('unknown', TRUE));
    END IF;

    v_operator := LOWER(COALESCE(p_tree->>'evaluation_operator', ''));

    IF jsonb_typeof(p_tree->'members') IS DISTINCT FROM 'array'
       OR jsonb_array_length(p_tree->'members') = 0 THEN
        RETURN jsonb_build_array(jsonb_build_object('unknown', TRUE));
    END IF;

    IF v_operator = 'and' THEN
        v_result := jsonb_build_array('{}'::JSONB);
        FOR v_member IN SELECT value FROM jsonb_array_elements(p_tree->'members')
        LOOP
            v_member_dnf := pricing_rule_condition_tree_to_dnf(v_member);
            v_result := pricing_rule_and_dnf(v_result, v_member_dnf);
        END LOOP;
        RETURN v_result;
    ELSIF v_operator = 'or' THEN
        v_result := '[]'::JSONB;
        FOR v_member IN SELECT value FROM jsonb_array_elements(p_tree->'members')
        LOOP
            v_result := v_result || pricing_rule_condition_tree_to_dnf(v_member);
        END LOOP;
        RETURN v_result;
    END IF;

    RETURN jsonb_build_array(jsonb_build_object('unknown', TRUE));
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION pricing_rule_interval_branch(
    p_dimension TEXT,
    p_interval JSONB,
    p_kind TEXT DEFAULT 'numeric'
) RETURNS JSONB AS $$
BEGIN
    IF p_interval IS NULL THEN
        RETURN '[]'::JSONB;
    END IF;

    IF p_kind = 'date' THEN
        RETURN jsonb_build_array(jsonb_build_object('date', jsonb_build_object(p_dimension, p_interval)));
    END IF;

    RETURN jsonb_build_array(jsonb_build_object('numeric', jsonb_build_object(p_dimension, p_interval)));
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION pricing_rule_config_to_dnf(
    p_config JSONB
) RETURNS JSONB AS $$
DECLARE
    v_result JSONB := jsonb_build_array('{}'::JSONB);
    v_fragment JSONB;
    v_conditions JSONB;
    v_interval JSONB;
    v_key TEXT;
BEGIN
    IF p_config IS NULL OR jsonb_typeof(p_config) IS DISTINCT FROM 'object' THEN
        RETURN jsonb_build_array(jsonb_build_object('unknown', TRUE));
    END IF;

    IF p_config->'condition_tree' IS NOT NULL
       AND jsonb_typeof(p_config->'condition_tree') IS DISTINCT FROM 'null' THEN
        v_result := pricing_rule_and_dnf(v_result, pricing_rule_condition_tree_to_dnf(p_config->'condition_tree'));
    END IF;

    v_conditions := p_config->'conditions';

    -- Legacy / current booking category forms.
    IF jsonb_typeof(v_conditions) = 'object' THEN
        IF jsonb_typeof(v_conditions->'booking_category'->'in') = 'array' THEN
            v_fragment := pricing_rule_unit_condition_to_dnf(
                jsonb_build_object(
                    'type', 'condition',
                    'condition_name', 'booking_category',
                    'comparison_operator', 'any_of',
                    'value', v_conditions->'booking_category'->'in'
                )
            );
            v_result := pricing_rule_and_dnf(v_result, v_fragment);
        END IF;

        IF jsonb_typeof(v_conditions->'booking_class'->'any_of') = 'array' THEN
            v_fragment := pricing_rule_unit_condition_to_dnf(
                jsonb_build_object(
                    'type', 'condition',
                    'condition_name', 'booking_class',
                    'comparison_operator', 'any_of',
                    'value', v_conditions->'booking_class'->'any_of'
                )
            );
            v_result := pricing_rule_and_dnf(v_result, v_fragment);
        END IF;

        IF jsonb_typeof(v_conditions->'booking_class'->'all_of') = 'array' THEN
            v_fragment := pricing_rule_unit_condition_to_dnf(
                jsonb_build_object(
                    'type', 'condition',
                    'condition_name', 'booking_class',
                    'comparison_operator', 'all_of',
                    'value', v_conditions->'booking_class'->'all_of'
                )
            );
            v_result := pricing_rule_and_dnf(v_result, v_fragment);
        END IF;

        IF v_conditions->'stay_length' IS NOT NULL
           AND jsonb_typeof(v_conditions->'stay_length') IS DISTINCT FROM 'null' THEN
            v_interval := pricing_rule_numeric_interval_from_legacy_json(v_conditions->'stay_length');
            v_result := pricing_rule_and_dnf(v_result, pricing_rule_interval_branch('stay_length', v_interval));
        END IF;
    END IF;

    -- Top-level stay adjustment fields. These are supported by the existing
    -- pricing migrations and are also treated as guard constraints.
    FOREACH v_key IN ARRAY ARRAY['stay_length', 'stay_extended', 'stay_contracted', 'net_stay']
    LOOP
        IF p_config->v_key IS NOT NULL AND jsonb_typeof(p_config->v_key) IS DISTINCT FROM 'null' THEN
            v_interval := pricing_rule_numeric_interval_from_legacy_json(p_config->v_key);
            v_result := pricing_rule_and_dnf(v_result, pricing_rule_interval_branch(v_key, v_interval));
        END IF;
    END LOOP;

    RETURN v_result;
EXCEPTION
    WHEN OTHERS THEN
        -- Conservative fallback: unknown condition structure can overlap.
        RETURN jsonb_build_array(jsonb_build_object('unknown', TRUE));
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- 6. OVERLAP FUNCTIONS
-- ============================================================================

CREATE OR REPLACE FUNCTION pricing_rule_branches_overlap(
    p_left_branch JSONB,
    p_right_branch JSONB
) RETURNS BOOLEAN AS $$
BEGIN
    RETURN pricing_rule_merge_branches(p_left_branch, p_right_branch) IS NOT NULL;
EXCEPTION
    WHEN OTHERS THEN
        RETURN TRUE;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION pricing_rule_configs_overlap_reason(
    p_left_config JSONB,
    p_right_config JSONB
) RETURNS JSONB AS $$
DECLARE
    v_left_dnf JSONB;
    v_right_dnf JSONB;
    v_left_branch JSONB;
    v_right_branch JSONB;
    v_merged JSONB;
BEGIN
    v_left_dnf := pricing_rule_config_to_dnf(p_left_config);
    v_right_dnf := pricing_rule_config_to_dnf(p_right_config);

    IF jsonb_typeof(v_left_dnf) IS DISTINCT FROM 'array'
       OR jsonb_typeof(v_right_dnf) IS DISTINCT FROM 'array' THEN
        RETURN jsonb_build_object(
            'overlap', TRUE,
            'reason_code', 'unknown_condition_shape',
            'details', 'DNF conversion returned a non-array value'
        );
    END IF;

    IF jsonb_array_length(v_left_dnf) = 0 OR jsonb_array_length(v_right_dnf) = 0 THEN
        RETURN jsonb_build_object(
            'overlap', FALSE,
            'reason_code', 'condition_domain_empty',
            'details', 'At least one rule condition has no satisfiable branches'
        );
    END IF;

    FOR v_left_branch IN SELECT value FROM jsonb_array_elements(v_left_dnf)
    LOOP
        FOR v_right_branch IN SELECT value FROM jsonb_array_elements(v_right_dnf)
        LOOP
            v_merged := pricing_rule_merge_branches(v_left_branch, v_right_branch);
            IF v_merged IS NOT NULL THEN
                RETURN jsonb_build_object(
                    'overlap', TRUE,
                    'reason_code',
                        CASE
                            WHEN COALESCE((v_merged->>'unknown')::BOOLEAN, FALSE) THEN 'condition_overlap_or_unknown'
                            ELSE 'condition_domain_overlap'
                        END,
                    'left_branch', v_left_branch,
                    'right_branch', v_right_branch,
                    'combined_branch', v_merged
                );
            END IF;
        END LOOP;
    END LOOP;

    RETURN jsonb_build_object(
        'overlap', FALSE,
        'reason_code', 'condition_domain_disjoint',
        'details', 'No satisfiable branch pair exists'
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'overlap', TRUE,
            'reason_code', 'overlap_checker_error',
            'details', SQLERRM
        );
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION pricing_rule_configs_overlap(
    p_left_config JSONB,
    p_right_config JSONB
) RETURNS BOOLEAN AS $$
DECLARE
    v_reason JSONB;
BEGIN
    v_reason := pricing_rule_configs_overlap_reason(p_left_config, p_right_config);
    RETURN COALESCE((v_reason->>'overlap')::BOOLEAN, TRUE);
EXCEPTION
    WHEN OTHERS THEN
        RETURN TRUE;
END;
$$ LANGUAGE plpgsql STABLE;


CREATE OR REPLACE FUNCTION pricing_rule_config_has_condition_names(
    p_config JSONB,
    p_condition_names TEXT[]
) RETURNS BOOLEAN AS $$
DECLARE
    v_node JSONB;
    v_type TEXT;
    v_member JSONB;
BEGIN
    IF p_config IS NULL OR jsonb_typeof(p_config) IS DISTINCT FROM 'object' THEN
        RETURN FALSE;
    END IF;

    -- Top-level stay-adjustment fields used by earlier migrations.
    IF EXISTS (
        SELECT 1
        FROM unnest(p_condition_names) AS names(condition_name)
        WHERE p_config ? names.condition_name
    ) THEN
        RETURN TRUE;
    END IF;

    IF jsonb_typeof(p_config->'conditions') = 'object'
       AND EXISTS (
           SELECT 1
           FROM unnest(p_condition_names) AS names(condition_name)
           WHERE p_config->'conditions' ? names.condition_name
       ) THEN
        RETURN TRUE;
    END IF;

    v_node := p_config->'condition_tree';
    IF v_node IS NULL OR jsonb_typeof(v_node) = 'null' THEN
        RETURN FALSE;
    END IF;

    IF jsonb_typeof(v_node) IS DISTINCT FROM 'object' THEN
        RETURN FALSE;
    END IF;

    v_type := LOWER(COALESCE(v_node->>'type', ''));

    IF v_type = 'condition' THEN
        RETURN LOWER(COALESCE(v_node->>'condition_name', '')) = ANY(p_condition_names);
    END IF;

    IF v_type = 'group' AND jsonb_typeof(v_node->'members') = 'array' THEN
        FOR v_member IN SELECT value FROM jsonb_array_elements(v_node->'members')
        LOOP
            IF pricing_rule_config_has_condition_names(
                jsonb_build_object('condition_tree', v_member),
                p_condition_names
            ) THEN
                RETURN TRUE;
            END IF;
        END LOOP;
    END IF;

    RETURN FALSE;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ============================================================================
-- 7. REPLACE CONFLICT GUARD WITH SAME-PRIORITY SEMANTIC GUARD
-- ============================================================================

CREATE OR REPLACE FUNCTION check_pricing_rule_conflict()
RETURNS TRIGGER AS $$
DECLARE
    v_new_scope                    VARCHAR(20);
    v_new_category                 operation_category;
    v_new_is_stay_adj              BOOLEAN;
    v_conflict                     RECORD;
    v_any_hard_block               BOOLEAN := FALSE;
    v_hard_block_uuid              UUID;
    v_hard_block_name              VARCHAR;
    v_hard_block_reason            TEXT;
    v_same_priority_overlap_reason JSONB;
    v_same_priority_overlap        BOOLEAN;
    v_allow_same_priority_overlap  BOOLEAN;
    v_should_block                 BOOLEAN;
BEGIN
    -- Only guard active rules. Deactivations / archives never create conflicts.
    IF NEW.status <> 'active' THEN
        RETURN NEW;
    END IF;

    v_new_scope := CASE
        WHEN NEW.platform_property_lookup_id IS NOT NULL THEN 'listing'
        WHEN NEW.property_id                 IS NOT NULL THEN 'property'
        WHEN NEW.platform_id                 IS NOT NULL THEN 'platform'
        ELSE                                                  'global'
    END;

    SELECT category
      INTO v_new_category
      FROM pricing_operation_types
     WHERE id = NEW.operation_id;

    v_new_is_stay_adj := pricing_rule_config_has_condition_names(
        COALESCE(NEW.rule_config, '{}'::JSONB),
        ARRAY['stay_length', 'stay_extended', 'stay_contracted', 'net_stay']::TEXT[]
    );

    v_allow_same_priority_overlap := LOWER(COALESCE(NEW.rule_config->'metadata'->>'allow_same_priority_overlap', 'false'))
                                     IN ('true', '1', 'yes');

    FOR v_conflict IN
        SELECT
            pr.id,
            pr.rule_uuid,
            pr.rule_name,
            pr.allow_override,
            pr.start_date,
            pr.end_date,
            pr.day_of_week_pattern,
            pr.priority,
            pr.rule_config,
            pricing_rule_config_has_condition_names(
                COALESCE(pr.rule_config, '{}'::JSONB),
                ARRAY['stay_length', 'stay_extended', 'stay_contracted', 'net_stay']::TEXT[]
            ) AS is_stay_adj
        FROM pricing_rules pr
        JOIN pricing_operation_types pot ON pot.id = pr.operation_id
        WHERE pr.status = 'active'
          AND (TG_OP = 'INSERT' OR pr.id <> NEW.id)
          AND pot.category = v_new_category
          AND CASE v_new_scope
              WHEN 'listing' THEN
                  pr.platform_property_lookup_id = NEW.platform_property_lookup_id
              WHEN 'property' THEN
                  pr.property_id = NEW.property_id
                  AND pr.platform_property_lookup_id IS NULL
                  AND (
                      NEW.platform_id IS NULL
                      OR pr.platform_id IS NULL
                      OR pr.platform_id = NEW.platform_id
                  )
              WHEN 'platform' THEN
                  pr.platform_id = NEW.platform_id
                  AND pr.property_id IS NULL
                  AND pr.platform_property_lookup_id IS NULL
              ELSE
                  pr.property_id                 IS NULL
                  AND pr.platform_id             IS NULL
                  AND pr.platform_property_lookup_id IS NULL
          END
          AND COALESCE(pr.start_date, '-infinity'::DATE) <= COALESCE(NEW.end_date, 'infinity'::DATE)
          AND COALESCE(pr.end_date, 'infinity'::DATE) >= COALESCE(NEW.start_date, '-infinity'::DATE)
          AND (
              NEW.day_of_week_pattern IS NULL
              OR pr.day_of_week_pattern IS NULL
              OR (NEW.day_of_week_pattern & pr.day_of_week_pattern) > 0
          )
    LOOP
        v_same_priority_overlap := FALSE;
        v_same_priority_overlap_reason := NULL;

        IF v_conflict.priority = NEW.priority THEN
            v_same_priority_overlap_reason := pricing_rule_configs_overlap_reason(
                COALESCE(v_conflict.rule_config, '{}'::JSONB),
                COALESCE(NEW.rule_config, '{}'::JSONB)
            );
            v_same_priority_overlap := COALESCE((v_same_priority_overlap_reason->>'overlap')::BOOLEAN, TRUE);
        END IF;

        v_should_block := (NOT v_conflict.allow_override)
                          OR (v_same_priority_overlap AND NOT v_allow_same_priority_overlap);

        IF v_should_block AND NOT v_any_hard_block THEN
            v_any_hard_block := TRUE;
            v_hard_block_uuid := v_conflict.rule_uuid;
            v_hard_block_name := v_conflict.rule_name;
            v_hard_block_reason := CASE
                WHEN v_same_priority_overlap AND NOT v_allow_same_priority_overlap THEN
                    'same scope, operation category, priority, date/day window, and overlapping condition domain'
                ELSE
                    'existing rule has allow_override = FALSE'
            END;
        END IF;

        INSERT INTO pricing_rule_audit (
            rule_id,
            rule_uuid,
            operation,
            actor_id,
            actor_type,
            old_values,
            new_values,
            success,
            error_message
        ) VALUES (
            CASE WHEN TG_OP = 'UPDATE' THEN NEW.id ELSE NULL END,
            NEW.rule_uuid,
            'conflict_resolve',
            COALESCE(NEW.created_by, 'system'),
            'system',
            jsonb_build_object(
                'existing_rule_id', v_conflict.id,
                'existing_rule_uuid', v_conflict.rule_uuid,
                'existing_rule_name', v_conflict.rule_name,
                'existing_start_date', v_conflict.start_date,
                'existing_end_date', v_conflict.end_date,
                'existing_priority', v_conflict.priority,
                'existing_allow_override', v_conflict.allow_override
            ),
            jsonb_build_object(
                'incoming_rule_name', NEW.rule_name,
                'incoming_scope', v_new_scope,
                'incoming_category', v_new_category::TEXT,
                'incoming_priority', NEW.priority,
                'same_priority_condition_overlap', v_same_priority_overlap,
                'same_priority_overlap_reason', v_same_priority_overlap_reason,
                'allow_same_priority_overlap', v_allow_same_priority_overlap,
                'resolution',
                    CASE
                        WHEN v_same_priority_overlap AND NOT v_allow_same_priority_overlap THEN
                            'blocked_same_priority_condition_overlap'
                        WHEN NOT v_conflict.allow_override THEN
                            'blocked'
                        WHEN v_same_priority_overlap AND v_allow_same_priority_overlap THEN
                            'allowed_same_priority_condition_overlap_explicit'
                        WHEN v_new_is_stay_adj AND v_conflict.is_stay_adj THEN
                            'stay_adj_advisory_stacking_risk'
                        ELSE
                            'allowed_by_priority_or_nonsemantic_overlap'
                    END
            ),
            NOT v_should_block,
            CASE
                WHEN v_same_priority_overlap AND NOT v_allow_same_priority_overlap THEN
                    format(
                        'Blocked by rule %s (%s): same scope/priority condition overlap. Reason: %s',
                        v_conflict.rule_uuid,
                        v_conflict.rule_name,
                        COALESCE(v_same_priority_overlap_reason::TEXT, '{}')
                    )
                WHEN NOT v_conflict.allow_override THEN
                    format(
                        'Blocked by rule %s (%s): allow_override = FALSE',
                        v_conflict.rule_uuid,
                        v_conflict.rule_name
                    )
                WHEN v_same_priority_overlap AND v_allow_same_priority_overlap THEN
                    'Same-priority condition overlap allowed by rule_config.metadata.allow_same_priority_overlap'
                WHEN v_new_is_stay_adj AND v_conflict.is_stay_adj THEN
                    format(
                        'Stay-adjustment overlap with rule %s (%s): verify stacking intent.',
                        v_conflict.rule_uuid,
                        v_conflict.rule_name
                    )
                ELSE NULL
            END
        );
    END LOOP;

    IF v_any_hard_block THEN
        RAISE EXCEPTION
            'Rule conflict: incoming rule "%" conflicts with existing rule % ("%"). Reason: %.',
            COALESCE(NEW.rule_name, NEW.rule_uuid::TEXT),
            v_hard_block_uuid,
            v_hard_block_name,
            v_hard_block_reason;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS guard_pricing_rule_conflicts ON pricing_rules;

CREATE TRIGGER guard_pricing_rule_conflicts
BEFORE INSERT OR UPDATE ON pricing_rules
FOR EACH ROW
EXECUTE FUNCTION check_pricing_rule_conflict();

-- ============================================================================
-- 8. SMOKE CHECKS FOR HELPER FUNCTIONS
-- ============================================================================

DO $$
DECLARE
    v_reason JSONB;
BEGIN
    -- Overlap: stay_length >= 4 intersects stay_length between 2 and 6.
    v_reason := pricing_rule_configs_overlap_reason(
        jsonb_build_object(
            'conditions_version', 2,
            'condition_tree', jsonb_build_object(
                'type', 'condition',
                'condition_name', 'stay_length',
                'comparison_operator', 'gte',
                'value', 4
            )
        ),
        jsonb_build_object(
            'conditions_version', 2,
            'condition_tree', jsonb_build_object(
                'type', 'condition',
                'condition_name', 'stay_length',
                'comparison_operator', 'between',
                'value', jsonb_build_object('min', 2, 'max', 6)
            )
        )
    );

    IF COALESCE((v_reason->>'overlap')::BOOLEAN, FALSE) IS NOT TRUE THEN
        RAISE EXCEPTION 'FAIL: expected stay_length overlap smoke check to be true. Got %', v_reason;
    END IF;

    -- Non-overlap: stay_length < 4 does not intersect stay_length >= 4.
    v_reason := pricing_rule_configs_overlap_reason(
        jsonb_build_object(
            'conditions_version', 2,
            'condition_tree', jsonb_build_object(
                'type', 'condition',
                'condition_name', 'stay_length',
                'comparison_operator', 'lt',
                'value', 4
            )
        ),
        jsonb_build_object(
            'conditions_version', 2,
            'condition_tree', jsonb_build_object(
                'type', 'condition',
                'condition_name', 'stay_length',
                'comparison_operator', 'gte',
                'value', 4
            )
        )
    );

    IF COALESCE((v_reason->>'overlap')::BOOLEAN, TRUE) IS NOT FALSE THEN
        RAISE EXCEPTION 'FAIL: expected stay_length disjoint smoke check to be false. Got %', v_reason;
    END IF;

    RAISE NOTICE 'OK: pricing_engine_rule_guard_migration smoke checks passed.';
END $$;

-- ============================================================================
-- END OF MIGRATION
-- ============================================================================
