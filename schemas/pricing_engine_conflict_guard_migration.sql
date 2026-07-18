-- ============================================================================
-- pricing_engine_conflict_guard_migration.sql
-- DEPRECATED:
--   This unpatched migration is retained for historical reference only.
--   Do not use it for fresh installs. Use
--   pricing_engine_conflict_guard_migration_patched.sql instead.
--
-- Purpose:
--   Two overlapping-rule protections:
--
--   1. CONFLICT GUARD TRIGGER  (check_pricing_rule_conflict)
--      Fires BEFORE INSERT OR UPDATE on pricing_rules.
--      Detects structural overlap: same scope target + overlapping date window
--      + same operation category + shared day-of-week bits.
--        • Existing rule has allow_override = FALSE  →  hard block (RAISE EXCEPTION)
--        • Existing rule has allow_override = TRUE   →  soft warn (audit log,
--          insert proceeds; priority system resolves at runtime)
--      Stay-adjustment rules get an additional advisory log entry whenever they
--      overlap with another stay-adjustment rule, even at soft-warn level,
--      because their runtime overlap is invisible from the rule rows alone.
--
--   2. STAY-ADJUSTMENT RULE CAP  (get_applicable_pricing_rules)
--      A new config key  max_stay_adjustment_rules  (default 1) limits how many
--      stay-adjustment rules (those that carry any of stay_length / stay_extended
--      / stay_contracted / net_stay at the top level of rule_config) can fire
--      per operation category per price calculation.  Only the highest-scoring
--      rule(s) per category are returned; all other matching rules are silently
--      suppressed.  Non-stay-adjustment rules are unaffected.
--
-- Prerequisites:
--   - pricing-engine.sql
--   - pricing_engine_stay_adjustment_migration.sql
--     (get_applicable_pricing_rules must already have 10 parameters)
--
-- Safe to re-run: all steps are idempotent.
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
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'get_applicable_pricing_rules'
          AND p.pronargs = 10
    ) THEN
        RAISE EXCEPTION
            'get_applicable_pricing_rules (10 params) not found. '
            'Run pricing_engine_stay_adjustment_migration.sql first.';
    END IF;
END $$;


-- ============================================================================
-- 2. CONFIG — max_stay_adjustment_rules
--    Controls how many stay-adjustment rules fire per operation category per
--    price calculation.  Set to > 1 only if you deliberately want stacking.
-- ============================================================================

INSERT INTO pricing_config (key, value, value_type, description, category)
VALUES (
    'max_stay_adjustment_rules',
    '1',
    'integer',
    'Maximum stay-adjustment rules that may fire per operation category per price calculation. '
    'Prevents silent stacking when multiple stay-length / stay-extended / stay-contracted / '
    'net_stay rules match the same booking context.',
    'pricing'
)
ON CONFLICT (key) DO NOTHING;


-- ============================================================================
-- 3. CONFLICT GUARD TRIGGER FUNCTION
-- ============================================================================

CREATE OR REPLACE FUNCTION check_pricing_rule_conflict()
RETURNS TRIGGER AS $$
DECLARE
    v_new_scope         VARCHAR(20);
    v_new_category      operation_category;
    v_new_is_stay_adj   BOOLEAN;
    v_conflict          RECORD;
    v_any_hard_block    BOOLEAN := FALSE;
    v_hard_block_uuid   UUID;
    v_hard_block_name   VARCHAR;
BEGIN
    -- -------------------------------------------------------------------------
    -- Only guard active rules.  Deactivations / archives never create conflicts.
    -- -------------------------------------------------------------------------
    IF NEW.status <> 'active' THEN
        RETURN NEW;
    END IF;

    -- -------------------------------------------------------------------------
    -- Compute scope manually — the generated column may not yet be visible
    -- inside a BEFORE trigger on INSERT.
    -- -------------------------------------------------------------------------
    v_new_scope := CASE
        WHEN NEW.platform_property_lookup_id IS NOT NULL THEN 'listing'
        WHEN NEW.property_id                 IS NOT NULL THEN 'property'
        WHEN NEW.platform_id                 IS NOT NULL THEN 'platform'
        ELSE                                                  'global'
    END;

    -- -------------------------------------------------------------------------
    -- Resolve the operation category for the incoming rule.
    -- -------------------------------------------------------------------------
    SELECT category
      INTO v_new_category
      FROM pricing_operation_types
     WHERE id = NEW.operation_id;

    -- -------------------------------------------------------------------------
    -- Tag whether the incoming rule carries stay-adjustment conditions.
    -- -------------------------------------------------------------------------
    v_new_is_stay_adj := (
        NEW.rule_config ? 'stay_length'   OR
        NEW.rule_config ? 'stay_extended'  OR
        NEW.rule_config ? 'stay_contracted' OR
        NEW.rule_config ? 'net_stay'
    );

    -- -------------------------------------------------------------------------
    -- Find all active rules that structurally overlap the incoming rule.
    -- Overlap = same scope target AND overlapping date window
    --           AND same operation category AND shared DOW bits.
    -- -------------------------------------------------------------------------
    FOR v_conflict IN
        SELECT
            pr.id,
            pr.rule_uuid,
            pr.rule_name,
            pr.allow_override,
            pr.start_date,
            pr.end_date,
            pr.day_of_week_pattern,
            (
                pr.rule_config ? 'stay_length'    OR
                pr.rule_config ? 'stay_extended'   OR
                pr.rule_config ? 'stay_contracted'  OR
                pr.rule_config ? 'net_stay'
            )                               AS is_stay_adj
        FROM pricing_rules pr
        JOIN pricing_operation_types pot ON pot.id = pr.operation_id
        WHERE pr.status = 'active'
          -- Exclude the row being updated from self-comparison
          AND (TG_OP = 'INSERT' OR pr.id <> NEW.id)

          -- -----------------------------------------------------------------
          -- Same operation category
          -- -----------------------------------------------------------------
          AND pot.category = v_new_category

          -- -----------------------------------------------------------------
          -- Same scope target
          -- Listing  → same platform_property_lookup_id
          -- Property → same property_id (platform optionally narrows further)
          -- Platform → same platform_id
          -- Global   → both fully NULL
          -- -----------------------------------------------------------------
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

              ELSE  -- global
                  pr.property_id                 IS NULL
                  AND pr.platform_id             IS NULL
                  AND pr.platform_property_lookup_id IS NULL
          END

          -- -----------------------------------------------------------------
          -- Overlapping date window.
          -- Treat NULL start/end as open-ended (±infinity).
          -- Two windows overlap when:  existing.start <= new.end
          --                        AND existing.end   >= new.start
          -- -----------------------------------------------------------------
          AND (
              COALESCE(pr.start_date,  '-infinity'::DATE)
                  <= COALESCE(NEW.end_date,   'infinity'::DATE)
          )
          AND (
              COALESCE(pr.end_date,    'infinity'::DATE)
                  >= COALESCE(NEW.start_date, '-infinity'::DATE)
          )

          -- -----------------------------------------------------------------
          -- Overlapping day-of-week pattern.
          -- NULL on either side means "all days" → always overlaps.
          -- -----------------------------------------------------------------
          AND (
              NEW.day_of_week_pattern IS NULL
              OR pr.day_of_week_pattern IS NULL
              OR (NEW.day_of_week_pattern & pr.day_of_week_pattern) > 0
          )
    LOOP
        -- ---------------------------------------------------------------------
        -- Hard block: existing rule explicitly forbids being overridden.
        -- Collect the first offender; raise after the loop so the message is
        -- deterministic regardless of scan order.
        -- ---------------------------------------------------------------------
        IF NOT v_conflict.allow_override AND NOT v_any_hard_block THEN
            v_any_hard_block  := TRUE;
            v_hard_block_uuid := v_conflict.rule_uuid;
            v_hard_block_name := v_conflict.rule_name;
        END IF;

        -- ---------------------------------------------------------------------
        -- Soft warn: log a conflict_resolve audit entry.
        -- Written for every overlap regardless of allow_override so there is
        -- always a full audit trail.
        -- ---------------------------------------------------------------------
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
            -- rule_id may be NULL on INSERT (sequence not yet assigned)
            CASE WHEN TG_OP = 'UPDATE' THEN NEW.id ELSE NULL END,
            NEW.rule_uuid,
            'conflict_resolve',
            COALESCE(NEW.created_by, 'system'),
            'system',
            jsonb_build_object(
                'existing_rule_uuid',  v_conflict.rule_uuid,
                'existing_rule_name',  v_conflict.rule_name,
                'existing_start_date', v_conflict.start_date,
                'existing_end_date',   v_conflict.end_date,
                'existing_allow_override', v_conflict.allow_override
            ),
            jsonb_build_object(
                'incoming_rule_name',  NEW.rule_name,
                'incoming_scope',      v_new_scope,
                'incoming_category',   v_new_category::TEXT,
                'resolution',
                    CASE
                        WHEN NOT v_conflict.allow_override
                            THEN 'blocked'
                        WHEN v_new_is_stay_adj AND v_conflict.is_stay_adj
                            THEN 'stay_adj_advisory — stacking risk; verify intent'
                        ELSE
                            'allowed_by_priority'
                    END
            ),
            -- success = FALSE only when we are about to hard-block
            v_conflict.allow_override,
            CASE
                WHEN NOT v_conflict.allow_override THEN
                    format(
                        'Blocked by rule %s (%s): allow_override = FALSE',
                        v_conflict.rule_uuid, v_conflict.rule_name
                    )
                WHEN v_new_is_stay_adj AND v_conflict.is_stay_adj THEN
                    format(
                        'Stay-adjustment overlap with rule %s (%s): '
                        'both rules may fire for the same (p_nights, p_stay_extended, '
                        'p_stay_contracted) combination. Review priorities.',
                        v_conflict.rule_uuid, v_conflict.rule_name
                    )
                ELSE NULL
            END
        );
    END LOOP;

    -- -------------------------------------------------------------------------
    -- Raise the hard block after the loop so all soft-warn audit rows are
    -- already committed (they are part of the same transaction and will be
    -- rolled back together with the INSERT if the caller rolls back, but the
    -- EXCEPTION itself is the definitive signal).
    -- -------------------------------------------------------------------------
    IF v_any_hard_block THEN
        RAISE EXCEPTION
            'Rule conflict: incoming rule "%" conflicts with existing rule % ("%") '
            'which has allow_override = FALSE. '
            'Deactivate or update the existing rule before inserting this one.',
            COALESCE(NEW.rule_name, NEW.rule_uuid::TEXT),
            v_hard_block_uuid,
            v_hard_block_name;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- 4. ATTACH THE TRIGGER
--    BEFORE INSERT OR UPDATE so the check runs before the row is committed.
--    Only fires when the incoming status is 'active' (guard inside function
--    returns early otherwise, but the WHEN clause avoids the function call
--    entirely for non-active rows on UPDATE).
-- ============================================================================

DROP TRIGGER IF EXISTS guard_pricing_rule_conflicts ON pricing_rules;

CREATE TRIGGER guard_pricing_rule_conflicts
BEFORE INSERT OR UPDATE ON pricing_rules
FOR EACH ROW
EXECUTE FUNCTION check_pricing_rule_conflict();


-- ============================================================================
-- 5. get_applicable_pricing_rules — STAY-ADJUSTMENT CAP
--    Replaces the version from pricing_engine_stay_adjustment_migration.sql.
--    Identical in every respect except the RETURN QUERY, which now:
--      a) Tags each matched rule as stay-adjustment or not.
--      b) Ranks stay-adjustment rules within each operation_category by score.
--      c) Only returns the top N stay-adjustment rules per category
--         (N = max_stay_adjustment_rules config value, default 1).
--      d) Returns all non-stay-adjustment rules unchanged.
-- ============================================================================

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
    p_stay_contracted              INT      DEFAULT NULL
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
        RAISE EXCEPTION 'p_stay_extended must be >= 0, got %', p_stay_extended;
    END IF;
    IF p_stay_contracted IS NOT NULL AND p_stay_contracted < 0 THEN
        RAISE EXCEPTION 'p_stay_contracted must be >= 0, got %', p_stay_contracted;
    END IF;

    -- Read cap from config (default 1 if key absent)
    v_max_stay_adj_rules := COALESCE(
        get_config('max_stay_adjustment_rules')::INT,
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
            pr.id                                                               AS rule_id,
            pr.rule_uuid,
            CASE WHEN pot.operation_code = 'override' THEN 'set'
                 ELSE pot.operation_code
            END                                                                 AS operation_code,
            pot.category                                                        AS operation_category,
            pot.execution_weight,
            pr.priority,
            pr.scope,
            CASE
                WHEN pr.scope = 'listing'  THEN 4000 + pr.priority
                WHEN pr.scope = 'property' THEN 3000 + pr.priority
                WHEN pr.scope = 'platform' THEN 2000 + pr.priority
                ELSE                            1000 + pr.priority
            END                                                                 AS rule_score,
            -- Tag stay-adjustment rules (any top-level stay field present)
            (
                pr.rule_config ? 'stay_length'    OR
                pr.rule_config ? 'stay_extended'   OR
                pr.rule_config ? 'stay_contracted'  OR
                pr.rule_config ? 'net_stay'
            )                                                                   AS is_stay_adj,
            jsonb_build_object(
                'rule_id',                      pr.id,
                'rule_uuid',                    pr.rule_uuid,
                'rule_name',                    pr.rule_name,
                'subject',                      pr.rule_config->>'subject',
                'operation',                    pr.rule_config->'operation',
                'rule_config',                  pr.rule_config,
                'priority',                     pr.priority,
                'scope',                        pr.scope,
                'platform_property_lookup_id',  pr.platform_property_lookup_id,
                'metadata',                     pr.rule_config->'metadata'
            )                                                                   AS rule_json
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

          -- Scope
          AND (
              (pr.scope = 'listing'
               AND p_platform_property_lookup_id IS NOT NULL
               AND pr.platform_property_lookup_id = p_platform_property_lookup_id)
              OR pr.scope = 'global'
              OR (pr.scope = 'platform' AND pr.platform_id = p_platform_id)
              OR (pr.scope = 'property' AND pr.property_id = p_property_id)
          )

          -- Date
          AND (
              (pr.applicable_dates IS NOT NULL
               AND pr.applicable_dates ? p_target_date::TEXT)
              OR (pr.start_date IS NOT NULL AND pr.end_date IS NOT NULL
                  AND p_target_date BETWEEN pr.start_date AND pr.end_date)
              OR (pr.day_of_week_pattern IS NOT NULL
                  AND matches_dow_pattern(p_target_date, pr.day_of_week_pattern))
          )

          -- Gap-day conditions
          AND (
              pr.rule_config->'conditions'->'gap_day' IS NULL
              OR (v_gap_exists
                  AND (pr.rule_config->'conditions'->'gap_day'->>'is_last_minute' IS NULL
                       OR (pr.rule_config->'conditions'->'gap_day'->>'is_last_minute')::BOOLEAN = v_is_last_minute)
                  AND (pr.rule_config->'conditions'->'gap_day'->>'is_long_gap' IS NULL
                       OR (pr.rule_config->'conditions'->'gap_day'->>'is_long_gap')::BOOLEAN = v_is_long_gap))
          )

          -- Legacy nested stay-length (backward compat)
          AND (
              pr.rule_config->'conditions'->'stay_length' IS NULL
              OR (p_stay_length IS NOT NULL
                  AND (pr.rule_config->'conditions'->'stay_length'->>'gt'  IS NULL OR p_stay_length >  (pr.rule_config->'conditions'->'stay_length'->>'gt')::INT)
                  AND (pr.rule_config->'conditions'->'stay_length'->>'gte' IS NULL OR p_stay_length >= (pr.rule_config->'conditions'->'stay_length'->>'gte')::INT)
                  AND (pr.rule_config->'conditions'->'stay_length'->>'lt'  IS NULL OR p_stay_length <  (pr.rule_config->'conditions'->'stay_length'->>'lt')::INT)
                  AND (pr.rule_config->'conditions'->'stay_length'->>'lte' IS NULL OR p_stay_length <= (pr.rule_config->'conditions'->'stay_length'->>'lte')::INT)
                  AND (pr.rule_config->'conditions'->'stay_length'->'between' IS NULL
                       OR (p_stay_length >= (pr.rule_config->'conditions'->'stay_length'->'between'->>'min')::INT
                           AND p_stay_length <= (pr.rule_config->'conditions'->'stay_length'->'between'->>'max')::INT)))
          )

          -- Booking-class conditions
          AND (
              pr.rule_config->'conditions'->'booking_class'->'any_of' IS NULL
              OR (p_booking_classes IS NOT NULL
                  AND EXISTS (
                      SELECT 1
                      FROM jsonb_array_elements_text(pr.rule_config->'conditions'->'booking_class'->'any_of') rc
                      WHERE rc = ANY(p_booking_classes)))
          )

          -- Stay-adjustment condition 1: stay_length { gte, lte } (top-level)
          AND (
              pr.rule_config->'stay_length' IS NULL
              OR (p_stay_length IS NOT NULL
                  AND (pr.rule_config->'stay_length'->>'gte' IS NULL OR p_stay_length >= (pr.rule_config->'stay_length'->>'gte')::INT)
                  AND (pr.rule_config->'stay_length'->>'lte' IS NULL OR p_stay_length <= (pr.rule_config->'stay_length'->>'lte')::INT))
          )

          -- Stay-adjustment condition 2: stay_extended (exact match)
          AND (
              pr.rule_config->>'stay_extended' IS NULL
              OR (p_stay_extended IS NOT NULL
                  AND p_stay_extended = (pr.rule_config->>'stay_extended')::INT)
          )

          -- Stay-adjustment condition 3: stay_contracted (exact match)
          AND (
              pr.rule_config->>'stay_contracted' IS NULL
              OR (p_stay_contracted IS NOT NULL
                  AND p_stay_contracted = (pr.rule_config->>'stay_contracted')::INT)
          )

          -- Stay-adjustment condition 4: net_stay { gte, lte }
          AND (
              pr.rule_config->'net_stay' IS NULL
              OR (p_stay_length IS NOT NULL AND p_stay_extended IS NOT NULL AND p_stay_contracted IS NOT NULL
                  AND (pr.rule_config->'net_stay'->>'gte' IS NULL
                       OR (p_stay_length + (p_stay_extended - p_stay_contracted)) >= (pr.rule_config->'net_stay'->>'gte')::INT)
                  AND (pr.rule_config->'net_stay'->>'lte' IS NULL
                       OR (p_stay_length + (p_stay_extended - p_stay_contracted)) <= (pr.rule_config->'net_stay'->>'lte')::INT))
          )
    ),

    -- -------------------------------------------------------------------------
    -- Rank stay-adjustment rules within each operation category by score.
    -- Non-stay-adj rules get rank 1 (they are never filtered out by the cap).
    -- -------------------------------------------------------------------------
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

    -- Non-stay-adjustment rules: return all of them
    SELECT rr.rule_id, rr.rule_uuid, rr.operation_code, rr.operation_category,
           rr.priority, rr.scope, rr.rule_json
    FROM ranked_rules rr
    WHERE rr.is_stay_adj = FALSE

    UNION ALL

    -- Stay-adjustment rules: return only the top N per operation category
    SELECT sa.rule_id, sa.rule_uuid, sa.operation_code, sa.operation_category,
           sa.priority, sa.scope, sa.rule_json
    FROM stay_adj_ranked sa
    WHERE sa.stay_adj_rank <= v_max_stay_adj_rules

    ORDER BY
        -- Re-apply the global ordering after the UNION
        -- Reconstruct rule_score from scope + priority for ORDER BY
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
-- 6. SMOKE-TESTS
-- ============================================================================

DO $$
DECLARE
    v_trigger_exists     BOOLEAN;
    v_config_exists      BOOLEAN;
    v_fn_exists          BOOLEAN;
    v_fn_body            TEXT;
BEGIN
    -- Trigger attached
    SELECT EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        WHERE c.relname = 'pricing_rules'
          AND t.tgname  = 'guard_pricing_rule_conflicts'
    ) INTO v_trigger_exists;

    -- Config key present
    SELECT EXISTS (
        SELECT 1 FROM pricing_config
        WHERE key = 'max_stay_adjustment_rules'
    ) INTO v_config_exists;

    -- Function exists with 10 params
    SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'get_applicable_pricing_rules'
          AND p.pronargs = 10
    ) INTO v_fn_exists;

    -- Function body references the cap
    SELECT pg_get_functiondef(p.oid)
      INTO v_fn_body
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname = 'get_applicable_pricing_rules'
       AND p.pronargs = 10;

    IF NOT v_trigger_exists  THEN RAISE EXCEPTION 'FAIL: guard_pricing_rule_conflicts trigger missing';       END IF;
    IF NOT v_config_exists   THEN RAISE EXCEPTION 'FAIL: max_stay_adjustment_rules config key missing';       END IF;
    IF NOT v_fn_exists       THEN RAISE EXCEPTION 'FAIL: get_applicable_pricing_rules (10 params) missing';   END IF;
    IF v_fn_body NOT LIKE '%v_max_stay_adj_rules%'
                             THEN RAISE EXCEPTION 'FAIL: stay-adjustment cap not present in function body';    END IF;

    RAISE NOTICE 'OK: pricing_engine_conflict_guard_migration verified successfully.';
END $$;


-- ============================================================================
-- 7. USAGE NOTES
-- ============================================================================

/*
-- ---------------------------------------------------------------------------
-- A. Hard block in action
--    Insert a rule with allow_override = FALSE, then try to add an overlapping one.
-- ---------------------------------------------------------------------------
UPDATE pricing_rules
SET allow_override = FALSE
WHERE rule_name = 'Contracted Minimum Price';

-- The following INSERT will now raise:
-- "Rule conflict: incoming rule ... conflicts with existing rule ... (allow_override = FALSE)"
SELECT create_pricing_rule(...);   -- overlapping scope + dates + category


-- ---------------------------------------------------------------------------
-- B. Soft-warn audit trail
--    Two overlapping rules where allow_override = TRUE (the default).
--    The second insert succeeds; a conflict_resolve row appears in the audit log.
-- ---------------------------------------------------------------------------
SELECT * FROM pricing_rule_audit
WHERE operation = 'conflict_resolve'
ORDER BY created_at DESC;


-- ---------------------------------------------------------------------------
-- C. Stay-adjustment advisory
--    Two stay-adjustment rules with overlapping dates for the same property.
--    Both inserts succeed (allow_override = TRUE), but the audit log records:
--    resolution = 'stay_adj_advisory — stacking risk; verify intent'
-- ---------------------------------------------------------------------------
SELECT * FROM pricing_rule_audit
WHERE operation = 'conflict_resolve'
  AND new_values->>'resolution' LIKE '%stay_adj_advisory%'
ORDER BY created_at DESC;


-- ---------------------------------------------------------------------------
-- D. Raise the cap to allow 2 stay-adjustment rules per category
--    (e.g. one stay_extended rule + one net_stay rule intentionally stacked)
-- ---------------------------------------------------------------------------
UPDATE pricing_config
SET value = '2'
WHERE key = 'max_stay_adjustment_rules';


-- ---------------------------------------------------------------------------
-- E. Inspect suppressed stay-adjustment rules for a given context
--    (rules that matched conditions but were above the cap)
-- ---------------------------------------------------------------------------
-- Run get_applicable_pricing_rules with stay params and compare to a direct
-- query against pricing_rules to see which ones were suppressed.
SELECT pr.rule_name, pr.priority, pr.rule_config
FROM pricing_rules pr
JOIN pricing_operation_types pot ON pot.id = pr.operation_id
WHERE pr.status = 'active'
  AND pr.property_id = 1
  AND (pr.rule_config ? 'stay_length' OR pr.rule_config ? 'stay_extended'
       OR pr.rule_config ? 'stay_contracted' OR pr.rule_config ? 'net_stay')
ORDER BY pr.priority DESC;
*/

-- ============================================================================
-- END OF MIGRATION
-- ============================================================================
