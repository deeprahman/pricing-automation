-- ============================================================================
-- pricing_engine_booking_class_position_migration.sql
-- DEPRECATED:
--   This unpatched migration is retained for historical reference only.
--   Do not use it for fresh installs. Use
--   pricing_engine_booking_class_position_migration_patched.sql instead.
--
-- Purpose:
--   Extend pricing rule condition_tree booking_category / booking_class matching
--   with optional class-position checks.
--
-- Adds support for rule_config.condition_tree condition nodes like:
--   {
--     "type": "condition",
--     "condition_name": "booking_category",
--     "comparison_operator": "any_of",
--     "value": ["job_related", "medical_related"],
--     "pos": [0, null]
--   }
--
-- Semantics:
--   - value[i] and pos[i] are aligned.
--   - pos omitted: preserve existing behavior, match by class only.
--   - pos[i] = null: match that class at any position.
--   - pos[i] = N: match only if that class has actual position N.
--   - any_of: at least one value item must pass class + position matching.
--   - all_of: every value item must pass class + position matching.
--
-- Prerequisites:
--   - pricing_engine_condition_tree_migration_patched.sql
--
-- Safe to re-run: yes. Functions are replaced in place.
-- ============================================================================

DO $$
BEGIN
    IF to_regclass('public.pricing_rules') IS NULL THEN
        RAISE EXCEPTION 'Missing table: pricing_rules. Run pricing-engine.sql first.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_proc WHERE proname = 'evaluate_pricing_rule_condition_tree'
    ) THEN
        RAISE EXCEPTION
            'Missing condition-tree functions. Run pricing_engine_condition_tree_migration_patched.sql first.';
    END IF;
END $$;

-- ============================================================================
-- 1. POSITION METADATA VALIDATION
-- ============================================================================

CREATE OR REPLACE FUNCTION validate_pricing_rule_condition_tree_position_metadata(
    p_node JSONB
) RETURNS BOOLEAN AS $$
DECLARE
    v_type TEXT;
    v_condition_name TEXT;
    v_value JSONB;
    v_pos JSONB;
    v_member JSONB;
    v_pos_item JSONB;
BEGIN
    IF p_node IS NULL OR jsonb_typeof(p_node) = 'null' THEN
        RETURN TRUE;
    END IF;

    IF jsonb_typeof(p_node) IS DISTINCT FROM 'object' THEN
        RETURN TRUE;
    END IF;

    v_type := LOWER(COALESCE(p_node->>'type', ''));

    IF v_type = 'group' THEN
        IF jsonb_typeof(p_node->'members') IS DISTINCT FROM 'array' THEN
            RETURN TRUE;
        END IF;

        FOR v_member IN SELECT value FROM jsonb_array_elements(p_node->'members')
        LOOP
            PERFORM validate_pricing_rule_condition_tree_position_metadata(v_member);
        END LOOP;

        RETURN TRUE;
    END IF;

    IF v_type <> 'condition' THEN
        RETURN TRUE;
    END IF;

    v_condition_name := LOWER(COALESCE(p_node->>'condition_name', ''));
    IF v_condition_name NOT IN ('booking_category', 'booking_class') THEN
        RETURN TRUE;
    END IF;

    IF NOT (p_node ? 'pos') THEN
        RETURN TRUE;
    END IF;

    v_value := p_node->'value';
    v_pos := p_node->'pos';

    IF jsonb_typeof(v_value) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'value for % must be an array before pos can be validated', v_condition_name
            USING ERRCODE = '22023';
    END IF;

    IF jsonb_typeof(v_pos) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'pos for % must be an array', v_condition_name
            USING ERRCODE = '22023';
    END IF;

    IF jsonb_array_length(v_pos) <> jsonb_array_length(v_value) THEN
        RAISE EXCEPTION 'pos length must equal value length for %', v_condition_name
            USING ERRCODE = '22023';
    END IF;

    FOR v_pos_item IN SELECT value FROM jsonb_array_elements(v_pos)
    LOOP
        IF jsonb_typeof(v_pos_item) = 'null' THEN
            CONTINUE;
        END IF;

        IF jsonb_typeof(v_pos_item) IS DISTINCT FROM 'number' THEN
            RAISE EXCEPTION 'pos entries for % must be integers or null', v_condition_name
                USING ERRCODE = '22023';
        END IF;

        IF (v_pos_item #>> '{}')::NUMERIC <> FLOOR((v_pos_item #>> '{}')::NUMERIC)
           OR (v_pos_item #>> '{}')::INT < 0 THEN
            RAISE EXCEPTION 'pos entries for % must be non-negative integers or null', v_condition_name
                USING ERRCODE = '22023';
        END IF;
    END LOOP;

    RETURN TRUE;
EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range THEN
        RAISE EXCEPTION 'Invalid pos value in condition_tree for condition_name=%', v_condition_name
            USING ERRCODE = '22023';
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

        PERFORM validate_pricing_rule_condition_tree_position_metadata(
            p_rule_config->'condition_tree'
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

-- ============================================================================
-- 2. POSITION-AWARE BOOKING CATEGORY EVALUATION
-- ============================================================================

CREATE OR REPLACE FUNCTION evaluate_pricing_rule_booking_class_condition(
    p_condition JSONB,
    p_booking_categories TEXT[] DEFAULT NULL,
    p_booking_class_positions JSONB DEFAULT NULL
) RETURNS BOOLEAN AS $$
DECLARE
    v_operator TEXT;
    v_value JSONB;
    v_pos JSONB;
    v_len INT;
    v_index INT;
    v_class_name TEXT;
    v_required_pos_json JSONB;
    v_required_pos INT;
    v_actual_positions JSONB;
    v_class_exists BOOLEAN;
    v_position_matches BOOLEAN;
    v_item_matches BOOLEAN;
BEGIN
    IF p_condition IS NULL OR jsonb_typeof(p_condition) IS DISTINCT FROM 'object' THEN
        RETURN FALSE;
    END IF;

    IF p_booking_categories IS NULL OR array_length(p_booking_categories, 1) IS NULL THEN
        RETURN FALSE;
    END IF;

    v_operator := LOWER(COALESCE(p_condition->>'comparison_operator', ''));
    v_value := p_condition->'value';
    v_pos := p_condition->'pos';

    IF v_operator NOT IN ('any_of', 'all_of') THEN
        RETURN FALSE;
    END IF;

    IF jsonb_typeof(v_value) IS DISTINCT FROM 'array' OR jsonb_array_length(v_value) = 0 THEN
        RETURN FALSE;
    END IF;

    IF v_pos IS NOT NULL AND jsonb_typeof(v_pos) <> 'null' THEN
        IF jsonb_typeof(v_pos) IS DISTINCT FROM 'array' THEN
            RETURN FALSE;
        END IF;
        IF jsonb_array_length(v_pos) <> jsonb_array_length(v_value) THEN
            RETURN FALSE;
        END IF;
    END IF;

    v_len := jsonb_array_length(v_value);

    FOR v_index IN 0..(v_len - 1)
    LOOP
        v_class_name := v_value->>v_index;
        v_class_exists := v_class_name = ANY(p_booking_categories);
        v_position_matches := TRUE;

        IF v_pos IS NOT NULL AND jsonb_typeof(v_pos) <> 'null' THEN
            v_required_pos_json := v_pos->v_index;

            IF v_required_pos_json IS NOT NULL AND jsonb_typeof(v_required_pos_json) <> 'null' THEN
                v_position_matches := FALSE;

                IF jsonb_typeof(v_required_pos_json) = 'number'
                   AND p_booking_class_positions IS NOT NULL
                   AND jsonb_typeof(p_booking_class_positions) = 'object'
                   AND p_booking_class_positions ? v_class_name THEN
                    v_required_pos := (v_required_pos_json #>> '{}')::INT;
                    v_actual_positions := p_booking_class_positions->v_class_name;

                    IF jsonb_typeof(v_actual_positions) = 'array' THEN
                        SELECT EXISTS (
                            SELECT 1
                            FROM jsonb_array_elements_text(v_actual_positions) AS actual(raw_pos)
                            WHERE actual.raw_pos::INT = v_required_pos
                        ) INTO v_position_matches;
                    END IF;
                END IF;
            END IF;
        END IF;

        v_item_matches := v_class_exists AND v_position_matches;

        IF v_operator = 'any_of' AND v_item_matches THEN
            RETURN TRUE;
        END IF;

        IF v_operator = 'all_of' AND NOT v_item_matches THEN
            RETURN FALSE;
        END IF;
    END LOOP;

    RETURN v_operator = 'all_of';
EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range THEN
        RETURN FALSE;
END;
$$ LANGUAGE plpgsql STABLE;

DROP FUNCTION IF EXISTS evaluate_pricing_rule_unit_condition(
    JSONB, INT, INT, INT, TEXT[], DATE, DATE, DATE
);

CREATE OR REPLACE FUNCTION evaluate_pricing_rule_unit_condition(
    p_condition JSONB,
    p_stay_length INT DEFAULT NULL,
    p_stay_extended INT DEFAULT NULL,
    p_stay_contracted INT DEFAULT NULL,
    p_booking_categories TEXT[] DEFAULT NULL,
    p_booking_class_positions JSONB DEFAULT NULL,
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
BEGIN
    IF p_condition IS NULL OR jsonb_typeof(p_condition) IS DISTINCT FROM 'object' THEN
        RETURN FALSE;
    END IF;

    v_condition_name := LOWER(COALESCE(p_condition->>'condition_name', ''));
    v_operator := LOWER(COALESCE(p_condition->>'comparison_operator', ''));
    v_value := p_condition->'value';

    IF v_condition_name IN ('stay_length', 'stay_extended', 'stay_contracted', 'net_stay') THEN
        CASE v_condition_name
            WHEN 'stay_length' THEN v_actual_number := p_stay_length;
            WHEN 'stay_extended' THEN v_actual_number := p_stay_extended;
            WHEN 'stay_contracted' THEN v_actual_number := p_stay_contracted;
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
            WHEN 'eq' THEN RETURN v_actual_number = (v_value #>> '{}')::NUMERIC;
            WHEN 'gt' THEN RETURN v_actual_number > (v_value #>> '{}')::NUMERIC;
            WHEN 'gte' THEN RETURN v_actual_number >= (v_value #>> '{}')::NUMERIC;
            WHEN 'lt' THEN RETURN v_actual_number < (v_value #>> '{}')::NUMERIC;
            WHEN 'lte' THEN RETURN v_actual_number <= (v_value #>> '{}')::NUMERIC;
            WHEN 'between' THEN
                RETURN v_actual_number >= (v_value->>'min')::NUMERIC
                   AND v_actual_number <= (v_value->>'max')::NUMERIC;
            ELSE RETURN FALSE;
        END CASE;
    END IF;

    IF v_condition_name IN ('booking_category', 'booking_class') THEN
        RETURN evaluate_pricing_rule_booking_class_condition(
            p_condition,
            p_booking_categories,
            p_booking_class_positions
        );
    END IF;

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
            WHEN 'eq' THEN RETURN v_actual_date = (v_value #>> '{}')::DATE;
            WHEN 'gt' THEN RETURN v_actual_date > (v_value #>> '{}')::DATE;
            WHEN 'gte' THEN RETURN v_actual_date >= (v_value #>> '{}')::DATE;
            WHEN 'lt' THEN RETURN v_actual_date < (v_value #>> '{}')::DATE;
            WHEN 'lte' THEN RETURN v_actual_date <= (v_value #>> '{}')::DATE;
            WHEN 'between' THEN
                RETURN v_actual_date >= (v_value->>'min')::DATE
                   AND v_actual_date <= (v_value->>'max')::DATE;
            ELSE RETURN FALSE;
        END CASE;
    END IF;

    RETURN FALSE;
EXCEPTION
    WHEN invalid_text_representation OR invalid_datetime_format OR numeric_value_out_of_range THEN
        RETURN FALSE;
END;
$$ LANGUAGE plpgsql STABLE;

DROP FUNCTION IF EXISTS evaluate_pricing_rule_condition_tree(
    JSONB, INT, INT, INT, TEXT[], DATE, DATE, DATE
);

CREATE OR REPLACE FUNCTION evaluate_pricing_rule_condition_tree(
    p_condition_tree JSONB,
    p_stay_length INT DEFAULT NULL,
    p_stay_extended INT DEFAULT NULL,
    p_stay_contracted INT DEFAULT NULL,
    p_booking_categories TEXT[] DEFAULT NULL,
    p_booking_class_positions JSONB DEFAULT NULL,
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
            p_booking_class_positions,
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
                p_booking_class_positions,
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
                p_booking_class_positions,
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
-- 3. GET APPLICABLE RULES WITH CLASS POSITION PARAMETER
-- ============================================================================

DROP FUNCTION IF EXISTS get_applicable_pricing_rules(
    BIGINT, BIGINT, DATE, VARCHAR, BOOLEAN, BIGINT, INT, TEXT[], INT, INT, DATE, DATE
);

DROP FUNCTION IF EXISTS get_applicable_pricing_rules(
    BIGINT, BIGINT, DATE, VARCHAR, BOOLEAN, BIGINT, INT, TEXT[], INT, INT, DATE, DATE, JSONB
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
    p_departure_date               DATE     DEFAULT NULL,
    p_booking_class_positions      JSONB    DEFAULT NULL
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

    v_max_stay_adj_rules := COALESCE(get_config('max_stay_adjustment_rules', '1')::INT, 1);

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

          AND (
              (pr.scope = 'listing'
               AND p_platform_property_lookup_id IS NOT NULL
               AND pr.platform_property_lookup_id = p_platform_property_lookup_id)
              OR pr.scope = 'global'
              OR (pr.scope = 'platform' AND pr.platform_id = p_platform_id)
              OR (pr.scope = 'property' AND pr.property_id = p_property_id)
          )

          AND (
              (pr.applicable_dates IS NOT NULL
               AND pr.applicable_dates ? p_target_date::TEXT)
              OR (pr.start_date IS NOT NULL AND pr.end_date IS NOT NULL
                  AND p_target_date BETWEEN pr.start_date AND pr.end_date)
              OR (pr.day_of_week_pattern IS NOT NULL
                  AND matches_dow_pattern(p_target_date, pr.day_of_week_pattern))
          )

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

          AND (
              pr.rule_config->'conditions'->'gap_day' IS NULL
              OR (v_gap_exists
                  AND (pr.rule_config->'conditions'->'gap_day'->>'is_last_minute' IS NULL
                       OR (pr.rule_config->'conditions'->'gap_day'->>'is_last_minute')::BOOLEAN = v_is_last_minute)
                  AND (pr.rule_config->'conditions'->'gap_day'->>'is_long_gap' IS NULL
                       OR (pr.rule_config->'conditions'->'gap_day'->>'is_long_gap')::BOOLEAN = v_is_long_gap))
          )

          AND (
              pr.rule_config->'conditions'->'stay_length' IS NULL
              OR evaluate_pricing_rule_number_condition_json(
                    pr.rule_config->'conditions'->'stay_length',
                    p_stay_length
                 )
          )

          AND (
              pr.rule_config->'conditions'->'booking_class'->'any_of' IS NULL
              OR (p_booking_classes IS NOT NULL
                  AND EXISTS (
                      SELECT 1
                      FROM jsonb_array_elements_text(pr.rule_config->'conditions'->'booking_class'->'any_of') rc
                      WHERE rc = ANY(p_booking_classes)))
          )

          AND evaluate_pricing_rule_number_condition_json(pr.rule_config->'stay_length', p_stay_length)
          AND evaluate_pricing_rule_number_condition_json(pr.rule_config->'stay_extended', p_stay_extended)
          AND evaluate_pricing_rule_number_condition_json(pr.rule_config->'stay_contracted', p_stay_contracted)
          AND evaluate_pricing_rule_number_condition_json(
                pr.rule_config->'net_stay',
                CASE
                    WHEN p_stay_length IS NULL THEN NULL
                    ELSE p_stay_length + COALESCE(p_stay_extended, 0) - COALESCE(p_stay_contracted, 0)
                END
          )

          AND (
              pr.rule_config->'condition_tree' IS NULL
              OR jsonb_typeof(pr.rule_config->'condition_tree') = 'null'
              OR evaluate_pricing_rule_condition_tree(
                    pr.rule_config->'condition_tree',
                    p_stay_length,
                    p_stay_extended,
                    p_stay_contracted,
                    p_booking_classes,
                    p_booking_class_positions,
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

    SELECT rr.rule_id, rr.rule_uuid, rr.operation_code, rr.operation_category,
           rr.priority, rr.scope, rr.rule_json
    FROM ranked_rules rr
    WHERE rr.is_stay_adj = FALSE

    UNION ALL

    SELECT sa.rule_id, sa.rule_uuid, sa.operation_code, sa.operation_category,
           sa.priority, sa.scope, sa.rule_json
    FROM stay_adj_ranked sa
    WHERE sa.stay_adj_rank <= v_max_stay_adj_rules

    ORDER BY
        CASE scope
            WHEN 'listing'  THEN 4000
            WHEN 'property' THEN 3000
            WHEN 'platform' THEN 2000
            ELSE                 1000
        END + priority DESC,
        rule_id ASC;
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- 4. SMOKE TESTS FOR PURE FUNCTIONS
-- ============================================================================

DO $$
BEGIN
    IF NOT evaluate_pricing_rule_booking_class_condition(
        '{"condition_name":"booking_category","comparison_operator":"any_of","value":["job_related","medical_related"],"pos":[0,3]}'::jsonb,
        ARRAY['job_related','medical_related']::TEXT[],
        '{"job_related":[0],"medical_related":[2]}'::jsonb
    ) THEN
        RAISE EXCEPTION 'FAIL: any_of should pass when one class has matching position';
    END IF;

    IF evaluate_pricing_rule_booking_class_condition(
        '{"condition_name":"booking_category","comparison_operator":"all_of","value":["job_related","medical_related"],"pos":[0,3]}'::jsonb,
        ARRAY['job_related','medical_related']::TEXT[],
        '{"job_related":[0],"medical_related":[2]}'::jsonb
    ) THEN
        RAISE EXCEPTION 'FAIL: all_of should fail when one class has wrong position';
    END IF;

    IF NOT evaluate_pricing_rule_booking_class_condition(
        '{"condition_name":"booking_category","comparison_operator":"any_of","value":["job_related","medical_related"],"pos":[0,null]}'::jsonb,
        ARRAY['job_related','medical_related']::TEXT[],
        '{"job_related":[1],"medical_related":[2]}'::jsonb
    ) THEN
        RAISE EXCEPTION 'FAIL: null position should ignore actual position';
    END IF;

    RAISE NOTICE 'OK: booking class position condition migration applied.';
END $$;
