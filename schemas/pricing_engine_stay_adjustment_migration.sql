-- ============================================================================
-- pricing_engine_stay_adjustment_migration.sql
--
-- Purpose:
--   Extend the pricing rule engine with a Stay Adjustment Model, adding
--   support for:
--     • stay_extended   (positive integer — number of nights the stay grew)
--     • stay_contracted (positive integer — number of nights the stay shrank)
--     • net_stay_delta  (DERIVED: stay_extended - stay_contracted, never stored)
--
--   Rule-config conditions evaluated (all top-level in rule_config JSON,
--   all ANDed together):
--     • stay_length   { gte, lte }  — original p_nights
--     • stay_extended               — exact match on p_stay_extended
--     • stay_contracted             — exact match on p_stay_contracted
--     • net_stay      { gte, lte }  — p_nights + (p_stay_extended - p_stay_contracted)
--
-- Functions modified:
--   1. get_applicable_pricing_rules  — adds p_stay_extended / p_stay_contracted
--                                      params + four new WHERE conditions.
--   2. calculate_daily_price         — adds the two new params and forwards
--                                      them into get_applicable_pricing_rules.
--
-- Prerequisites:
--   - pricing-engine.sql must have been applied (both functions must exist).
--
-- Safe to re-run: CREATE OR REPLACE replaces in place with no side-effects.
-- ============================================================================

-- ============================================================================
-- 1. DEPENDENCY VALIDATION
-- ============================================================================

DO $$
BEGIN
    IF to_regclass('public.pricing_rules') IS NULL THEN
        RAISE EXCEPTION
            'Missing table: pricing_rules. Run pricing-engine.sql first.';
    END IF;
END $$;


-- ============================================================================
-- 2. get_applicable_pricing_rules
--    Two new parameters added at the end (both DEFAULT NULL so all existing
--    call-sites continue to work without modification):
--      p_stay_extended   INT DEFAULT NULL
--      p_stay_contracted INT DEFAULT NULL
--
--    Four new WHERE conditions appended inside ranked_rules, each using
--    AND logic so a NULL rule_config field means "condition ignored".
-- ============================================================================

DROP FUNCTION IF EXISTS get_applicable_pricing_rules(
    BIGINT, BIGINT, DATE, VARCHAR, BOOLEAN, BIGINT, INT, TEXT[]
);

CREATE OR REPLACE FUNCTION get_applicable_pricing_rules(
    p_property_id                  BIGINT,
    p_platform_id                  BIGINT,
    p_target_date                  DATE     DEFAULT CURRENT_DATE,
    p_operation_code               VARCHAR  DEFAULT NULL,
    p_check_gaps                   BOOLEAN  DEFAULT TRUE,
    p_platform_property_lookup_id  BIGINT   DEFAULT NULL,
    p_stay_length                  INT      DEFAULT NULL,   -- p_nights (original stay)
    p_booking_classes              TEXT[]   DEFAULT NULL,
    p_stay_extended                INT      DEFAULT NULL,   -- nights the stay grew (>= 0)
    p_stay_contracted              INT      DEFAULT NULL    -- nights the stay shrank (>= 0)
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
BEGIN
    -- -------------------------------------------------------------------------
    -- Normalise legacy 'override' operation code
    -- -------------------------------------------------------------------------
    v_operation_code_normalized := CASE
        WHEN p_operation_code = 'override' THEN 'set'
        ELSE p_operation_code
    END;

    -- -------------------------------------------------------------------------
    -- Input validation for stay adjustment parameters
    -- -------------------------------------------------------------------------
    IF p_stay_extended IS NOT NULL AND p_stay_extended < 0 THEN
        RAISE EXCEPTION 'p_stay_extended must be >= 0, got %', p_stay_extended;
    END IF;
    IF p_stay_contracted IS NOT NULL AND p_stay_contracted < 0 THEN
        RAISE EXCEPTION 'p_stay_contracted must be >= 0, got %', p_stay_contracted;
    END IF;

    -- -------------------------------------------------------------------------
    -- Gap-day lookup
    -- -------------------------------------------------------------------------
    IF p_check_gaps THEN
        SELECT
            TRUE,
            gd.is_last_minute,
            gd.is_long_gap
        INTO
            v_gap_exists,
            v_is_last_minute,
            v_is_long_gap
        FROM gap_days gd
        WHERE gd.property_id = p_property_id
          AND gd.platform_id = p_platform_id
          AND gd.gap_date    = p_target_date;
    END IF;

    -- -------------------------------------------------------------------------
    -- Main rule query
    -- -------------------------------------------------------------------------
    RETURN QUERY
    WITH ranked_rules AS (
        SELECT
            pr.id                                                            AS rule_id,
            pr.rule_uuid,
            CASE WHEN pot.operation_code = 'override'
                 THEN 'set'
                 ELSE pot.operation_code
            END                                                              AS operation_code,
            pot.category                                                     AS operation_category,
            pot.execution_weight,
            pr.priority,
            pr.scope,
            -- Composite score: scope band (thousands) + row priority (0-100)
            CASE
                WHEN pr.scope = 'listing'  THEN 4000 + pr.priority
                WHEN pr.scope = 'property' THEN 3000 + pr.priority
                WHEN pr.scope = 'platform' THEN 2000 + pr.priority
                ELSE                            1000 + pr.priority
            END                                                              AS rule_score,
            jsonb_build_object(
                'rule_id',                       pr.id,
                'rule_uuid',                     pr.rule_uuid,
                'rule_name',                     pr.rule_name,
                'subject',                       pr.rule_config->>'subject',
                'operation',                     pr.rule_config->'operation',
                'rule_config',                   pr.rule_config,
                'priority',                      pr.priority,
                'scope',                         pr.scope,
                'platform_property_lookup_id',   pr.platform_property_lookup_id,
                'metadata',                      pr.rule_config->'metadata'
            )                                                                AS rule_json
        FROM pricing_rules pr
        JOIN pricing_operation_types pot ON pr.operation_id = pot.id
        WHERE pr.status = 'active'
          AND (pr.expires_at IS NULL OR pr.expires_at > NOW())

          -- Operation-code filter
          AND (
              v_operation_code_normalized IS NULL
              OR CASE WHEN pot.operation_code = 'override'
                      THEN 'set'
                      ELSE pot.operation_code
                 END = v_operation_code_normalized
          )

          -- -----------------------------------------------------------------
          -- Scope matching
          -- -----------------------------------------------------------------
          AND (
              (pr.scope = 'listing'
               AND p_platform_property_lookup_id IS NOT NULL
               AND pr.platform_property_lookup_id = p_platform_property_lookup_id)
              OR pr.scope = 'global'
              OR (pr.scope = 'platform'  AND pr.platform_id  = p_platform_id)
              OR (pr.scope = 'property'  AND pr.property_id  = p_property_id)
          )

          -- -----------------------------------------------------------------
          -- Date matching
          -- -----------------------------------------------------------------
          AND (
              (pr.applicable_dates IS NOT NULL
               AND pr.applicable_dates ? p_target_date::TEXT)
              OR
              (pr.start_date IS NOT NULL
               AND pr.end_date IS NOT NULL
               AND p_target_date BETWEEN pr.start_date AND pr.end_date)
              OR
              (pr.day_of_week_pattern IS NOT NULL
               AND matches_dow_pattern(p_target_date, pr.day_of_week_pattern))
          )

          -- -----------------------------------------------------------------
          -- Gap-day conditions  (nested under rule_config.conditions.gap_day)
          -- -----------------------------------------------------------------
          AND (
              pr.rule_config->'conditions'->'gap_day' IS NULL
              OR (
                  v_gap_exists
                  AND (
                      pr.rule_config->'conditions'->'gap_day'->>'is_last_minute' IS NULL
                      OR (pr.rule_config->'conditions'->'gap_day'->>'is_last_minute')::BOOLEAN = v_is_last_minute
                  )
                  AND (
                      pr.rule_config->'conditions'->'gap_day'->>'is_long_gap' IS NULL
                      OR (pr.rule_config->'conditions'->'gap_day'->>'is_long_gap')::BOOLEAN = v_is_long_gap
                  )
              )
          )

          -- -----------------------------------------------------------------
          -- Legacy stay-length conditions  (nested: rule_config.conditions.stay_length)
          -- Kept for backward compatibility with existing rules.
          -- -----------------------------------------------------------------
          AND (
              pr.rule_config->'conditions'->'stay_length' IS NULL
              OR (
                  p_stay_length IS NOT NULL
                  AND (
                      pr.rule_config->'conditions'->'stay_length'->>'gt' IS NULL
                      OR p_stay_length > (pr.rule_config->'conditions'->'stay_length'->>'gt')::INT
                  )
                  AND (
                      pr.rule_config->'conditions'->'stay_length'->>'gte' IS NULL
                      OR p_stay_length >= (pr.rule_config->'conditions'->'stay_length'->>'gte')::INT
                  )
                  AND (
                      pr.rule_config->'conditions'->'stay_length'->>'lt' IS NULL
                      OR p_stay_length < (pr.rule_config->'conditions'->'stay_length'->>'lt')::INT
                  )
                  AND (
                      pr.rule_config->'conditions'->'stay_length'->>'lte' IS NULL
                      OR p_stay_length <= (pr.rule_config->'conditions'->'stay_length'->>'lte')::INT
                  )
                  AND (
                      pr.rule_config->'conditions'->'stay_length'->'between' IS NULL
                      OR (
                          p_stay_length >= (pr.rule_config->'conditions'->'stay_length'->'between'->>'min')::INT
                          AND p_stay_length <= (pr.rule_config->'conditions'->'stay_length'->'between'->>'max')::INT
                      )
                  )
              )
          )

          -- -----------------------------------------------------------------
          -- Booking-class conditions  (nested: rule_config.conditions.booking_class)
          -- -----------------------------------------------------------------
          AND (
              pr.rule_config->'conditions'->'booking_class'->'any_of' IS NULL
              OR (
                  p_booking_classes IS NOT NULL
                  AND EXISTS (
                      SELECT 1
                      FROM jsonb_array_elements_text(
                          pr.rule_config->'conditions'->'booking_class'->'any_of'
                      ) required_class
                      WHERE required_class = ANY(p_booking_classes)
                  )
              )
          )

          -- =================================================================
          -- STAY ADJUSTMENT CONDITIONS (top-level rule_config keys)
          -- All four use AND logic; a missing/null field means "ignore".
          -- =================================================================

          -- -----------------------------------------------------------------
          -- 1. stay_length  { gte, lte }  — matches against p_stay_length (p_nights)
          --    Separate from the legacy nested condition above; uses simpler
          --    gte/lte-only schema defined in the spec.
          -- -----------------------------------------------------------------
          AND (
              pr.rule_config->'stay_length' IS NULL
              OR (
                  p_stay_length IS NOT NULL
                  AND (
                      pr.rule_config->'stay_length'->>'gte' IS NULL
                      OR p_stay_length >= (pr.rule_config->'stay_length'->>'gte')::INT
                  )
                  AND (
                      pr.rule_config->'stay_length'->>'lte' IS NULL
                      OR p_stay_length <= (pr.rule_config->'stay_length'->>'lte')::INT
                  )
              )
          )

          -- -----------------------------------------------------------------
          -- 2. stay_extended — exact match; ignored when field absent
          -- -----------------------------------------------------------------
          AND (
              pr.rule_config->>'stay_extended' IS NULL
              OR (
                  p_stay_extended IS NOT NULL
                  AND p_stay_extended = (pr.rule_config->>'stay_extended')::INT
              )
          )

          -- -----------------------------------------------------------------
          -- 3. stay_contracted — exact match; ignored when field absent
          -- -----------------------------------------------------------------
          AND (
              pr.rule_config->>'stay_contracted' IS NULL
              OR (
                  p_stay_contracted IS NOT NULL
                  AND p_stay_contracted = (pr.rule_config->>'stay_contracted')::INT
              )
          )

          -- -----------------------------------------------------------------
          -- 4. net_stay  { gte, lte }
          --    net_stay_delta = p_stay_extended - p_stay_contracted  (derived, not stored)
          --    net_stay       = p_stay_length   + net_stay_delta
          --    Both component params must be supplied for the derived value
          --    to be meaningful; if either is NULL the condition is skipped.
          -- -----------------------------------------------------------------
          AND (
              pr.rule_config->'net_stay' IS NULL
              OR (
                  p_stay_length IS NOT NULL
                  AND p_stay_extended IS NOT NULL
                  AND p_stay_contracted IS NOT NULL
                  AND (
                      pr.rule_config->'net_stay'->>'gte' IS NULL
                      OR (p_stay_length + (p_stay_extended - p_stay_contracted))
                             >= (pr.rule_config->'net_stay'->>'gte')::INT
                  )
                  AND (
                      pr.rule_config->'net_stay'->>'lte' IS NULL
                      OR (p_stay_length + (p_stay_extended - p_stay_contracted))
                             <= (pr.rule_config->'net_stay'->>'lte')::INT
                  )
              )
          )
    )
    SELECT
        rr.rule_id,
        rr.rule_uuid,
        rr.operation_code,
        rr.operation_category,
        rr.priority,
        rr.scope,
        rr.rule_json
    FROM ranked_rules rr
    ORDER BY rr.rule_score DESC, rr.execution_weight DESC, rr.rule_id ASC;
END;
$$ LANGUAGE plpgsql STABLE;


-- ============================================================================
-- 3. calculate_daily_price
--    Two new optional parameters appended (DEFAULT NULL keeps all existing
--    callers working without modification).  They are forwarded into
--    get_applicable_pricing_rules so stay-adjustment rules are evaluated.
-- ============================================================================

CREATE OR REPLACE FUNCTION calculate_daily_price(
    p_api_key                      TEXT,
    p_property_id                  BIGINT,
    p_platform_id                  BIGINT,
    p_date                         DATE,
    p_base_price                   NUMERIC  DEFAULT NULL,
    p_force_recalculate            BOOLEAN  DEFAULT FALSE,
    p_platform_property_lookup_id  BIGINT   DEFAULT NULL,
    p_stay_length                  INT      DEFAULT NULL,   -- original stay (p_nights)
    p_stay_extended                INT      DEFAULT NULL,   -- nights added  (>= 0)
    p_stay_contracted              INT      DEFAULT NULL    -- nights removed (>= 0)
) RETURNS JSONB AS $$
DECLARE
    v_worker_id       VARCHAR;
    v_cached          RECORD;
    v_base_price      NUMERIC(10,2);
    v_current_price   NUMERIC(10,2);
    v_rule            RECORD;
    v_applied_rules   JSONB    := '[]'::JSONB;
    v_rule_count      INTEGER  := 0;
    v_is_available    BOOLEAN;
    v_override_price  NUMERIC(10,2);
    v_gap_info        RECORD;
    v_cache_duration  INTEGER;
    v_start_time      TIMESTAMPTZ;
    v_min_price       NUMERIC(10,2);
    v_max_price       NUMERIC(10,2);
    -- Derived stay values (computed here for response metadata; never stored)
    v_net_stay_delta  INT;
    v_net_stay        INT;
BEGIN
    v_start_time := clock_timestamp();

    -- -------------------------------------------------------------------------
    -- Input validation for stay adjustment parameters
    -- -------------------------------------------------------------------------
    IF p_stay_extended IS NOT NULL AND p_stay_extended < 0 THEN
        RAISE EXCEPTION 'p_stay_extended must be >= 0, got %', p_stay_extended;
    END IF;
    IF p_stay_contracted IS NOT NULL AND p_stay_contracted < 0 THEN
        RAISE EXCEPTION 'p_stay_contracted must be >= 0, got %', p_stay_contracted;
    END IF;

    -- Compute derived stay values when all inputs are present
    IF p_stay_length IS NOT NULL
       AND p_stay_extended IS NOT NULL
       AND p_stay_contracted IS NOT NULL
    THEN
        v_net_stay_delta := p_stay_extended - p_stay_contracted;
        v_net_stay       := p_stay_length + v_net_stay_delta;
    END IF;

    -- -------------------------------------------------------------------------
    -- Authenticate
    -- -------------------------------------------------------------------------
    v_worker_id := validate_worker_auth(p_api_key);

    -- -------------------------------------------------------------------------
    -- Cache lookup (skip when stay-adjustment context supplied — derived values
    -- influence which rules fire, so the cached entry may not apply)
    -- -------------------------------------------------------------------------
    IF NOT p_force_recalculate
       AND p_stay_extended  IS NULL
       AND p_stay_contracted IS NULL
    THEN
        SELECT * INTO v_cached
        FROM calculated_prices
        WHERE property_id = p_property_id
          AND platform_id = p_platform_id
          AND (
              (p_platform_property_lookup_id IS NULL AND platform_property_lookup_id IS NULL)
              OR platform_property_lookup_id = p_platform_property_lookup_id
          )
          AND date      = p_date
          AND is_valid  = TRUE
          AND valid_until > NOW()
        ORDER BY calculated_at DESC, id DESC
        LIMIT 1;

        IF FOUND THEN
            RETURN jsonb_build_object(
                'success',       TRUE,
                'cached',        TRUE,
                'date',          p_date,
                'available',     v_cached.is_available,
                'final_price',   v_cached.final_price,
                'base_price',    v_cached.base_price,
                'applied_rules', v_cached.applied_rules,
                'is_gap_day',    v_cached.is_gap_day
            );
        END IF;
    END IF;

    -- -------------------------------------------------------------------------
    -- Availability check
    -- -------------------------------------------------------------------------
    SELECT NOT EXISTS(
        SELECT 1 FROM ical_events
        WHERE property_id = p_property_id
          AND platform_id = p_platform_id
          AND status IN ('BOOKED', 'BLOCKED', 'OWNER_HOLD')
          AND p_date BETWEEN start_date AND end_date - 1
    ) INTO v_is_available;

    IF NOT v_is_available THEN
        RETURN jsonb_build_object(
            'success',     TRUE,
            'date',        p_date,
            'available',   FALSE,
            'final_price', NULL
        );
    END IF;

    -- -------------------------------------------------------------------------
    -- Base price
    -- -------------------------------------------------------------------------
    v_base_price := COALESCE(
        p_base_price,
        (SELECT (descrp->>'base_price')::NUMERIC FROM Properties WHERE id = p_property_id),
        100.00
    );
    v_current_price := v_base_price;

    -- -------------------------------------------------------------------------
    -- Global min / max constraints
    -- -------------------------------------------------------------------------
    v_min_price := get_config_int('default_min_price', 50)::NUMERIC;
    v_max_price := get_config_int('default_max_price', 9999)::NUMERIC;

    -- -------------------------------------------------------------------------
    -- Apply rules in priority order
    --   p_stay_extended and p_stay_contracted are forwarded so the four new
    --   stay-adjustment conditions inside get_applicable_pricing_rules are
    --   evaluated properly.
    -- -------------------------------------------------------------------------
    FOR v_rule IN
        SELECT *
        FROM get_applicable_pricing_rules(
            p_property_id,
            p_platform_id,
            p_date,
            NULL,                              -- p_operation_code
            TRUE,                              -- p_check_gaps
            p_platform_property_lookup_id,
            p_stay_length,                     -- p_nights (original stay)
            NULL,                              -- p_booking_classes
            p_stay_extended,                   -- NEW
            p_stay_contracted                  -- NEW
        )
        ORDER BY priority DESC, rule_id ASC
    LOOP
        DECLARE
            v_operation_type TEXT;
            v_amount         NUMERIC;
            v_amount_type    TEXT;
            v_adjustment     NUMERIC := 0;
        BEGIN
            v_operation_type := v_rule.rule_json->'operation'->>'do';
            v_amount         := (v_rule.rule_json->'operation'->>'amount')::NUMERIC;
            v_amount_type    := v_rule.rule_json->'operation'->>'type';

            CASE v_operation_type
                WHEN '+ increase', 'increase' THEN
                    IF v_amount_type IN ('percentage', '%') THEN
                        v_adjustment    := v_current_price * (v_amount / 100.0);
                        v_current_price := v_current_price + v_adjustment;
                    ELSE
                        v_adjustment    := v_amount;
                        v_current_price := v_current_price + v_amount;
                    END IF;

                WHEN '- decrease', 'decrease' THEN
                    IF v_amount_type IN ('percentage', '%') THEN
                        v_adjustment    := -(v_current_price * (v_amount / 100.0));
                        v_current_price := v_current_price - (v_current_price * (v_amount / 100.0));
                    ELSE
                        v_adjustment    := -v_amount;
                        v_current_price := v_current_price - v_amount;
                    END IF;

                WHEN 'override', 'set' THEN
                    v_adjustment    := v_amount - v_current_price;
                    v_current_price := v_amount;

                WHEN 'multiply' THEN
                    v_adjustment    := v_current_price * (v_amount - 1);
                    v_current_price := v_current_price * v_amount;
            END CASE;

            v_applied_rules := v_applied_rules || jsonb_build_object(
                'rule_id',   v_rule.rule_id,
                'rule_uuid', v_rule.rule_uuid,
                'operation', v_rule.operation_code,
                'priority',  v_rule.priority,
                'adjustment', v_adjustment
            );
            v_rule_count := v_rule_count + 1;

            UPDATE pricing_rules
            SET applied_count   = applied_count + 1,
                last_applied_at = NOW()
            WHERE id = v_rule.rule_id;
        END;
    END LOOP;

    -- -------------------------------------------------------------------------
    -- Manual price overrides
    -- -------------------------------------------------------------------------
    SELECT price INTO v_override_price
    FROM price_overrides
    WHERE property_id = p_property_id
      AND platform_id = p_platform_id
      AND date        = p_date
      AND is_active   = TRUE
      AND (expires_at IS NULL OR expires_at > NOW());

    IF FOUND THEN
        v_current_price := v_override_price;
        v_applied_rules := v_applied_rules || jsonb_build_object(
            'type',  'manual_override',
            'price', v_override_price
        );
    END IF;

    -- -------------------------------------------------------------------------
    -- Enforce global min / max
    -- -------------------------------------------------------------------------
    v_current_price := GREATEST(v_min_price, LEAST(v_current_price, v_max_price));

    -- -------------------------------------------------------------------------
    -- Gap-day metadata
    -- -------------------------------------------------------------------------
    SELECT * INTO v_gap_info
    FROM gap_days
    WHERE property_id = p_property_id
      AND platform_id = p_platform_id
      AND gap_date    = p_date;

    -- -------------------------------------------------------------------------
    -- Cache the result
    --   Skip caching when stay-adjustment context was supplied, because the
    --   stay params are not stored in calculated_prices and a future call
    --   with different stay values would incorrectly reuse this entry.
    -- -------------------------------------------------------------------------
    v_cache_duration := get_config_int('cache_duration_minutes', 60);

    IF p_stay_extended IS NULL AND p_stay_contracted IS NULL THEN
        INSERT INTO calculated_prices (
            property_id,
            platform_id,
            platform_property_lookup_id,
            date,
            base_price,
            rule_adjustments,
            final_price,
            applied_rules,
            applied_rule_count,
            is_gap_day,
            gap_length,
            is_available,
            valid_until,
            is_valid,
            calculation_time_ms
        ) VALUES (
            p_property_id,
            p_platform_id,
            p_platform_property_lookup_id,
            p_date,
            v_base_price,
            v_current_price - v_base_price,
            v_current_price,
            v_applied_rules,
            v_rule_count,
            v_gap_info.gap_date IS NOT NULL,
            v_gap_info.gap_length,
            v_is_available,
            NOW() + (v_cache_duration || ' minutes')::INTERVAL,
            TRUE,
            EXTRACT(MILLISECONDS FROM clock_timestamp() - v_start_time)::INTEGER
        )
        ON CONFLICT (property_id, platform_id, date, id)
        DO UPDATE SET
            final_price         = EXCLUDED.final_price,
            applied_rules       = EXCLUDED.applied_rules,
            applied_rule_count  = EXCLUDED.applied_rule_count,
            calculated_at       = NOW(),
            valid_until         = EXCLUDED.valid_until,
            is_valid            = TRUE,
            calculation_time_ms = EXCLUDED.calculation_time_ms;
    END IF;

    -- -------------------------------------------------------------------------
    -- Return result (includes stay-adjustment metadata when supplied)
    -- -------------------------------------------------------------------------
    RETURN jsonb_build_object(
        'success',          TRUE,
        'cached',           FALSE,
        'date',             p_date,
        'available',        v_is_available,
        'base_price',       v_base_price,
        'final_price',      v_current_price,
        'adjustment',       v_current_price - v_base_price,
        'applied_rules',    v_applied_rules,
        'rule_count',       v_rule_count,
        'is_gap_day',       v_gap_info.gap_date IS NOT NULL,
        'gap_length',       v_gap_info.gap_length,
        -- Stay-adjustment metadata (null when not supplied)
        'stay_length',       p_stay_length,
        'stay_extended',     p_stay_extended,
        'stay_contracted',   p_stay_contracted,
        'net_stay_delta',    v_net_stay_delta,
        'net_stay',          v_net_stay,
        'calculation_time_ms',
            EXTRACT(MILLISECONDS FROM clock_timestamp() - v_start_time)::INTEGER
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ============================================================================
-- 4. SMOKE-TEST
--    Runs inside a transaction that is always rolled back, so it produces
--    no permanent side-effects.  Output is visible in psql / migration logs.
-- ============================================================================

DO $$
DECLARE
    v_fn_rule_fetcher   BOOLEAN;
    v_fn_calc_daily     BOOLEAN;
BEGIN
    -- Verify get_applicable_pricing_rules exists with the new signature
    SELECT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'get_applicable_pricing_rules'
          -- 10 parameters after migration
          AND p.pronargs = 10
    ) INTO v_fn_rule_fetcher;

    -- Verify calculate_daily_price exists with the new signature
    SELECT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'calculate_daily_price'
          -- 10 parameters after migration
          AND p.pronargs = 10
    ) INTO v_fn_calc_daily;

    IF NOT v_fn_rule_fetcher THEN
        RAISE EXCEPTION
            'FAIL: get_applicable_pricing_rules with 10 params not found — migration may not have applied';
    END IF;

    IF NOT v_fn_calc_daily THEN
        RAISE EXCEPTION
            'FAIL: calculate_daily_price with 10 params not found — migration may not have applied';
    END IF;

    RAISE NOTICE 'OK: pricing_engine_stay_adjustment_migration verified successfully '
                 '(get_applicable_pricing_rules=10 params, calculate_daily_price=10 params).';
END $$;


-- ============================================================================
-- 5. USAGE EXAMPLES
-- ============================================================================

/*
-- ---------------------------------------------------------------------------
-- A. Create a stay-adjustment rule
--    Fires when: original stay >= 10 nights, extended by exactly 3,
--                contracted by exactly 1, and net stay >= 12.
-- ---------------------------------------------------------------------------
SELECT create_pricing_rule(
    'sk_abc123...',
    1,          -- property_id
    4,          -- platform_id
    'increase',
    '{
        "subject": "price",
        "operation": {
            "do": "+ increase",
            "type": "percentage",
            "amount": 10
        },
        "stay_length":   { "gte": 10 },
        "stay_extended":  3,
        "stay_contracted": 1,
        "net_stay":      { "gte": 12 }
    }'::JSONB,
    NULL,
    '2025-06-01',
    '2025-08-31',
    NULL,   -- all days of week
    80,
    'Stay Extension Premium'
);

-- ---------------------------------------------------------------------------
-- B. Calculate price with stay-adjustment context
--    p_nights=10, extended by 3, contracted by 1  →  net_stay_delta=2, net_stay=12
-- ---------------------------------------------------------------------------
SELECT calculate_daily_price(
    'sk_abc123...',
    1,          -- property_id
    4,          -- platform_id
    '2025-07-15',
    150.00,     -- base_price
    TRUE,       -- force_recalculate (bypass cache — stay context differs per call)
    NULL,       -- platform_property_lookup_id
    10,         -- p_stay_length  (p_nights)
    3,          -- p_stay_extended
    1           -- p_stay_contracted
);
-- Response includes: net_stay_delta=2, net_stay=12, plus normal price fields.

-- ---------------------------------------------------------------------------
-- C. Rule with only a net_stay bound (no exact-match constraints)
-- ---------------------------------------------------------------------------
SELECT create_pricing_rule(
    'sk_abc123...',
    1, 4,
    'decrease',
    '{
        "subject": "price",
        "operation": { "do": "- decrease", "type": "percentage", "amount": 5 },
        "net_stay": { "lte": 7 }
    }'::JSONB,
    NULL, '2025-01-01', '2025-12-31', NULL, 60,
    'Short Net Stay Discount'
);

-- ---------------------------------------------------------------------------
-- D. Zero-adjustment (valid — extended=0 contracted=0 means no change)
-- ---------------------------------------------------------------------------
SELECT calculate_daily_price(
    'sk_abc123...', 1, 4, '2025-07-20',
    150.00, TRUE, NULL,
    10,   -- p_stay_length
    0,    -- p_stay_extended
    0     -- p_stay_contracted
    -- net_stay_delta=0, net_stay=10
);
*/

-- ============================================================================
-- END OF MIGRATION
-- ============================================================================
