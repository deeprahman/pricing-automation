-- ============================================================================
-- pricing_engine_set_operation_migration.sql
--
-- Purpose:
--   Canonicalize legacy absolute pricing rules from `override` to `set`
--   and normalize legacy rule_config operation payloads from `override`
--   to canonical `fixed` / `set`.
-- ============================================================================

DO $$
DECLARE
    v_set_operation_id BIGINT;
    v_override_operation_id BIGINT;
    v_rules_repointed INTEGER := 0;
BEGIN
    IF to_regclass('public.pricing_operation_types') IS NULL THEN
        RAISE EXCEPTION
            'Missing table: pricing_operation_types. Run pricing-engine.sql first.';
    END IF;

    IF to_regclass('public.pricing_rules') IS NULL THEN
        RAISE EXCEPTION
            'Missing table: pricing_rules. Run pricing-engine.sql first.';
    END IF;

    INSERT INTO pricing_operation_types (
        operation_code,
        operation_name,
        category,
        description,
        execution_weight,
        is_active
    )
    VALUES (
        'set',
        'Price Set',
        'pricing',
        'Set absolute price',
        90,
        TRUE
    )
    ON CONFLICT (operation_code) DO UPDATE
    SET operation_name = EXCLUDED.operation_name,
        category = EXCLUDED.category,
        description = EXCLUDED.description,
        execution_weight = EXCLUDED.execution_weight,
        is_active = TRUE,
        updated_at = NOW()
    RETURNING id INTO v_set_operation_id;

    SELECT id
    INTO v_override_operation_id
    FROM pricing_operation_types
    WHERE operation_code = 'override'
    LIMIT 1;

    IF v_override_operation_id IS NOT NULL THEN
        UPDATE pricing_rules
        SET operation_id = v_set_operation_id
        WHERE operation_id = v_override_operation_id;
        GET DIAGNOSTICS v_rules_repointed = ROW_COUNT;

        UPDATE pricing_operation_types
        SET is_active = FALSE,
            updated_at = NOW()
        WHERE id = v_override_operation_id;
    END IF;

    UPDATE pricing_rules
    SET rule_config = jsonb_set(rule_config, '{operation,type}', to_jsonb('fixed'::TEXT), TRUE)
    WHERE jsonb_typeof(rule_config) = 'object'
      AND jsonb_typeof(rule_config->'operation') = 'object'
      AND rule_config->'operation'->>'type' = 'override';

    UPDATE pricing_rules
    SET rule_config = jsonb_set(rule_config, '{operation,do}', to_jsonb('set'::TEXT), TRUE)
    WHERE jsonb_typeof(rule_config) = 'object'
      AND jsonb_typeof(rule_config->'operation') = 'object'
      AND rule_config->'operation'->>'do' = 'override';

    UPDATE pricing_rules
    SET rule_config = jsonb_set(rule_config, '{operation,type}', to_jsonb('fixed'::TEXT), TRUE)
    WHERE operation_id = v_set_operation_id
      AND jsonb_typeof(rule_config) = 'object'
      AND jsonb_typeof(rule_config->'operation') = 'object'
      AND COALESCE(rule_config->'operation'->>'type', '') = '';

    UPDATE pricing_rules
    SET rule_config = jsonb_set(rule_config, '{operation,do}', to_jsonb('set'::TEXT), TRUE)
    WHERE operation_id = v_set_operation_id
      AND jsonb_typeof(rule_config) = 'object'
      AND jsonb_typeof(rule_config->'operation') = 'object'
      AND COALESCE(rule_config->'operation'->>'do', '') = '';

    RAISE NOTICE
        'OK: pricing_engine_set_operation_migration applied (set_operation_id=%, repointed_rules=%)',
        v_set_operation_id,
        v_rules_repointed;
END $$;

DO $$
DECLARE
    v_set_exists BOOLEAN := FALSE;
    v_override_refs INTEGER := 0;
BEGIN
    SELECT EXISTS(
        SELECT 1
        FROM pricing_operation_types
        WHERE operation_code = 'set'
    ) INTO v_set_exists;

    IF NOT v_set_exists THEN
        RAISE EXCEPTION 'FAIL: canonical set operation is missing';
    END IF;

    SELECT COUNT(*)
    INTO v_override_refs
    FROM pricing_rules pr
    JOIN pricing_operation_types pot ON pot.id = pr.operation_id
    WHERE pot.operation_code = 'override';

    IF v_override_refs <> 0 THEN
        RAISE EXCEPTION
            'FAIL: % pricing_rules rows still reference override operation', v_override_refs;
    END IF;

    RAISE NOTICE 'OK: canonical set operation verified successfully.';
END $$;
