-- ============================================================================
-- pricing_engine_target_rate_type_and_season_window_migration.sql
--
-- Purpose:
--   1) Extend rule_config validation to support:
--      - operation.target_rate_type (base/recommended/minimum/maximum)
--      - season_window (year-agnostic month-day windows, including wrap windows)
--   2) Extend get_applicable_pricing_rules(...) to evaluate season_window.
--
-- Safe to re-run: yes.
-- ============================================================================

DO $$
BEGIN
    IF to_regclass('public.pricing_rules') IS NULL THEN
        RAISE EXCEPTION 'Missing table: pricing_rules. Run pricing-engine.sql first.';
    END IF;
END $$;

CREATE OR REPLACE FUNCTION normalize_pricing_target_rate_type(
    p_value TEXT
) RETURNS TEXT AS $$
DECLARE
    v_value TEXT := LOWER(COALESCE(NULLIF(BTRIM(p_value), ''), ''));
BEGIN
    IF v_value = '' THEN
        RETURN NULL;
    END IF;
    IF v_value IN ('base', 'recommended', 'minimum', 'maximum') THEN
        RETURN v_value;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION is_valid_mmdd(
    p_mmdd TEXT
) RETURNS BOOLEAN AS $$
DECLARE
    v_month INT;
    v_day INT;
BEGIN
    IF p_mmdd IS NULL OR p_mmdd !~ '^\d{2}-\d{2}$' THEN
        RETURN FALSE;
    END IF;

    v_month := SUBSTRING(p_mmdd, 1, 2)::INT;
    v_day := SUBSTRING(p_mmdd, 4, 2)::INT;
    PERFORM make_date(2000, v_month, v_day);
    RETURN TRUE;
EXCEPTION
    WHEN OTHERS THEN
        RETURN FALSE;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION matches_month_day_window(
    p_date DATE,
    p_start_mmdd TEXT,
    p_end_mmdd TEXT
) RETURNS BOOLEAN AS $$
DECLARE
    v_target_mmdd TEXT;
    v_start_mmdd TEXT;
    v_end_mmdd TEXT;
BEGIN
    IF p_date IS NULL THEN
        RETURN FALSE;
    END IF;

    v_start_mmdd := LOWER(COALESCE(NULLIF(BTRIM(p_start_mmdd), ''), ''));
    v_end_mmdd := LOWER(COALESCE(NULLIF(BTRIM(p_end_mmdd), ''), ''));
    IF NOT is_valid_mmdd(v_start_mmdd) OR NOT is_valid_mmdd(v_end_mmdd) THEN
        RETURN FALSE;
    END IF;

    v_target_mmdd := TO_CHAR(p_date, 'MM-DD');
    IF v_start_mmdd <= v_end_mmdd THEN
        RETURN v_target_mmdd BETWEEN v_start_mmdd AND v_end_mmdd;
    END IF;

    -- Wrapping window, e.g. Dec-10 -> Mar-21.
    RETURN v_target_mmdd >= v_start_mmdd OR v_target_mmdd <= v_end_mmdd;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION evaluate_pricing_rule_season_window(
    p_season_window JSONB,
    p_target_date DATE,
    p_arrival_date DATE DEFAULT NULL,
    p_departure_date DATE DEFAULT NULL
) RETURNS BOOLEAN AS $$
DECLARE
    v_applies_to TEXT;
    v_start_mmdd TEXT;
    v_end_mmdd TEXT;
    v_eval_date DATE;
BEGIN
    IF p_season_window IS NULL OR jsonb_typeof(p_season_window) = 'null' THEN
        RETURN TRUE;
    END IF;

    IF jsonb_typeof(p_season_window) IS DISTINCT FROM 'object' THEN
        RETURN FALSE;
    END IF;

    v_applies_to := LOWER(COALESCE(p_season_window->>'applies_to', 'target_date'));
    IF v_applies_to NOT IN ('target_date', 'arrival_date', 'departure_date') THEN
        RETURN FALSE;
    END IF;

    v_start_mmdd := p_season_window->>'start_mmdd';
    v_end_mmdd := p_season_window->>'end_mmdd';
    IF NOT is_valid_mmdd(v_start_mmdd) OR NOT is_valid_mmdd(v_end_mmdd) THEN
        RETURN FALSE;
    END IF;

    v_eval_date := CASE v_applies_to
        WHEN 'arrival_date' THEN p_arrival_date
        WHEN 'departure_date' THEN p_departure_date
        ELSE p_target_date
    END;

    RETURN matches_month_day_window(v_eval_date, v_start_mmdd, v_end_mmdd);
END;
$$ LANGUAGE plpgsql STABLE;

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
    v_operation JSONB;
    v_target_rate_type TEXT;
    v_season_window JSONB;
    v_season_applies_to TEXT;
    v_start_mmdd TEXT;
    v_end_mmdd TEXT;
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

    v_operation := p_rule_config->'operation';
    IF v_operation IS NOT NULL AND jsonb_typeof(v_operation) IS DISTINCT FROM 'null' THEN
        IF jsonb_typeof(v_operation) IS DISTINCT FROM 'object' THEN
            RAISE EXCEPTION 'operation must be a JSON object'
                USING ERRCODE = '22023';
        END IF;

        v_target_rate_type := normalize_pricing_target_rate_type(v_operation->>'target_rate_type');
        IF (v_operation ? 'target_rate_type') AND v_target_rate_type IS NULL THEN
            RAISE EXCEPTION 'operation.target_rate_type must be one of: base, recommended, minimum, maximum'
                USING ERRCODE = '22023';
        END IF;
    END IF;

    v_season_window := p_rule_config->'season_window';
    IF v_season_window IS NOT NULL AND jsonb_typeof(v_season_window) IS DISTINCT FROM 'null' THEN
        IF jsonb_typeof(v_season_window) IS DISTINCT FROM 'object' THEN
            RAISE EXCEPTION 'season_window must be a JSON object'
                USING ERRCODE = '22023';
        END IF;

        v_season_applies_to := LOWER(COALESCE(v_season_window->>'applies_to', 'target_date'));
        IF v_season_applies_to NOT IN ('target_date', 'arrival_date', 'departure_date') THEN
            RAISE EXCEPTION 'season_window.applies_to must be one of: target_date, arrival_date, departure_date'
                USING ERRCODE = '22023';
        END IF;

        v_start_mmdd := v_season_window->>'start_mmdd';
        v_end_mmdd := v_season_window->>'end_mmdd';

        IF NOT is_valid_mmdd(v_start_mmdd) THEN
            RAISE EXCEPTION 'season_window.start_mmdd must be a valid MM-DD value'
                USING ERRCODE = '22023';
        END IF;
        IF NOT is_valid_mmdd(v_end_mmdd) THEN
            RAISE EXCEPTION 'season_window.end_mmdd must be a valid MM-DD value'
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
              pr.rule_config->'season_window' IS NULL
              OR jsonb_typeof(pr.rule_config->'season_window') = 'null'
              OR evaluate_pricing_rule_season_window(
                    pr.rule_config->'season_window',
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
