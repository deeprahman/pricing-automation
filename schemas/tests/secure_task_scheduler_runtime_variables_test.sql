-- ============================================
-- SECURE TASK SCHEDULER RUNTIME VARIABLES TEST SUITE
-- Run AFTER:
--   1) schemas/secure_task_scheduler.sql
--   2) schemas/secure_task_scheduler_runtime_variables.sql
-- ============================================

BEGIN;

-- --------------------------------------------
-- 0) SANITY CHECKS
-- --------------------------------------------
DO $$
BEGIN
    IF to_regclass('public.runtime_variables') IS NULL THEN
        RAISE EXCEPTION 'Missing table: runtime_variables';
    END IF;
    IF to_regprocedure('set_runtime_variable(text,character varying,jsonb,character varying,text,boolean,timestamp with time zone)') IS NULL THEN
        RAISE EXCEPTION 'Missing function: set_runtime_variable';
    END IF;
    IF to_regprocedure('get_runtime_variable(text,character varying,character varying,boolean,boolean)') IS NULL THEN
        RAISE EXCEPTION 'Missing function: get_runtime_variable';
    END IF;
    IF to_regprocedure('runtime_vars_encrypt_jsonb(jsonb)') IS NULL THEN
        RAISE EXCEPTION 'Missing function: runtime_vars_encrypt_jsonb';
    END IF;
    IF to_regprocedure('runtime_vars_decrypt_jsonb(jsonb,boolean)') IS NULL THEN
        RAISE EXCEPTION 'Missing function: runtime_vars_decrypt_jsonb';
    END IF;
    IF to_regprocedure('validate_runtime_worker_id(character varying)') IS NULL THEN
        RAISE EXCEPTION 'Missing function: validate_runtime_worker_id';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        WHERE c.conname = 'fk_runtime_variables_worker_id'
          AND c.conrelid = 'runtime_variables'::regclass
          AND c.contype = 'f'
          AND c.confdeltype = 'c'
          AND c.confupdtype = 'c'
    ) THEN
        RAISE EXCEPTION 'Missing or invalid FK: fk_runtime_variables_worker_id';
    END IF;
    IF to_regclass('public.idx_runtime_variables_created_by') IS NULL THEN
        RAISE EXCEPTION 'Missing index: idx_runtime_variables_created_by';
    END IF;
END $$;

-- --------------------------------------------
-- 1) TEST CONTEXT
-- --------------------------------------------
CREATE TEMP TABLE test_runtime_context (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

DO $$
DECLARE
    v_worker_id TEXT;
    v_api_key TEXT;
    v_scope TEXT;
BEGIN
    v_worker_id := 'test-runtime-vars-' || txid_current();
    v_scope := 'tenant_runtime_' || txid_current();

    SELECT worker_id, api_key
    INTO v_worker_id, v_api_key
    FROM register_worker(
        v_worker_id,
        'Runtime Vars Test Worker',
        5,
        '30 seconds'::INTERVAL,
        '["default"]'::JSONB
    );

    INSERT INTO test_runtime_context (key, value) VALUES
        ('worker_id', v_worker_id),
        ('api_key', v_api_key),
        ('scope', v_scope);
END $$;

-- --------------------------------------------
-- 2) NON-SECRET SET/GET (WORKER ID AUTH)
-- --------------------------------------------
DO $$
DECLARE
    v_worker_id TEXT;
    v_api_key TEXT;
    v_scope TEXT;
    v_set_value JSONB;
    v_get_value JSONB;
    v_raw_value JSONB;
BEGIN
    SELECT value INTO v_worker_id FROM test_runtime_context WHERE key = 'worker_id';
    SELECT value INTO v_api_key FROM test_runtime_context WHERE key = 'api_key';
    SELECT value INTO v_scope FROM test_runtime_context WHERE key = 'scope';

    SELECT out_variable_value INTO v_set_value
    FROM set_runtime_variable(
        v_worker_id,
        'non_secret_key'::VARCHAR,
        '{"max_retry": 3}'::JSONB,
        v_scope::VARCHAR,
        'Non-secret runtime value'::TEXT,
        FALSE,
        NULL::TIMESTAMPTZ
    );

    IF v_set_value <> '{"max_retry": 3}'::JSONB THEN
        RAISE EXCEPTION 'Non-secret set returned unexpected value: %', v_set_value;
    END IF;

    SELECT get_runtime_variable(
        v_worker_id,
        'non_secret_key'::VARCHAR,
        v_scope::VARCHAR,
        FALSE,
        FALSE
    ) INTO v_get_value;

    IF v_get_value <> '{"max_retry": 3}'::JSONB THEN
        RAISE EXCEPTION 'Non-secret get returned unexpected value: %', v_get_value;
    END IF;

    SELECT variable_value INTO v_raw_value
    FROM runtime_variables
    WHERE variable_scope = v_scope
      AND variable_key = 'non_secret_key';

    IF v_raw_value <> '{"max_retry": 3}'::JSONB THEN
        RAISE EXCEPTION 'Non-secret raw storage changed unexpectedly: %', v_raw_value;
    END IF;
END $$;

-- --------------------------------------------
-- 3) SECRET SET ENCRYPTS STORAGE + SECRET GET DECRYPTS
-- --------------------------------------------
DO $$
DECLARE
    v_worker_id TEXT;
    v_api_key TEXT;
    v_scope TEXT;
    v_set_value JSONB;
    v_get_value JSONB;
    v_raw_value JSONB;
BEGIN
    SELECT value INTO v_worker_id FROM test_runtime_context WHERE key = 'worker_id';
    SELECT value INTO v_api_key FROM test_runtime_context WHERE key = 'api_key';
    SELECT value INTO v_scope FROM test_runtime_context WHERE key = 'scope';

    PERFORM set_config('app.runtime_vars_key', 'kms-material-test-key-1', TRUE);
    PERFORM set_config('app.runtime_vars_key_id', 'kms-key-2026-01', TRUE);

    SELECT out_variable_value INTO v_set_value
    FROM set_runtime_variable(
        v_worker_id,
        'enc_api_key'::VARCHAR,
        '"sk_live_secret_abc"'::JSONB,
        v_scope::VARCHAR,
        'Encrypted API key'::TEXT,
        TRUE,
        NULL::TIMESTAMPTZ
    );

    IF v_set_value <> '"sk_live_secret_abc"'::JSONB THEN
        RAISE EXCEPTION 'Secret set should return decrypted/logical value, got: %', v_set_value;
    END IF;

    SELECT variable_value INTO v_raw_value
    FROM runtime_variables
    WHERE variable_scope = v_scope
      AND variable_key = 'enc_api_key';

    IF NOT (v_raw_value ? '_enc_v1') THEN
        RAISE EXCEPTION 'Encrypted payload missing _enc_v1 envelope: %', v_raw_value;
    END IF;

    IF v_raw_value->'_enc_v1'->>'kid' <> 'kms-key-2026-01' THEN
        RAISE EXCEPTION 'Encrypted payload missing key id metadata: %', v_raw_value;
    END IF;

    IF position('sk_live_secret_abc' IN v_raw_value::TEXT) > 0 THEN
        RAISE EXCEPTION 'Plaintext leaked into storage: %', v_raw_value;
    END IF;

    SELECT get_runtime_variable(
        v_worker_id,
        'enc_api_key'::VARCHAR,
        v_scope::VARCHAR,
        FALSE,
        FALSE
    ) INTO v_get_value;

    IF v_get_value <> '"sk_live_secret_abc"'::JSONB THEN
        RAISE EXCEPTION 'Secret get failed to decrypt value: %', v_get_value;
    END IF;
END $$;

-- --------------------------------------------
-- 4) SECRET SET WITHOUT KEY SHOULD FAIL
-- --------------------------------------------
DO $$
DECLARE
    v_worker_id TEXT;
    v_api_key TEXT;
    v_scope TEXT;
    v_error TEXT;
BEGIN
    SELECT value INTO v_worker_id FROM test_runtime_context WHERE key = 'worker_id';
    SELECT value INTO v_api_key FROM test_runtime_context WHERE key = 'api_key';
    SELECT value INTO v_scope FROM test_runtime_context WHERE key = 'scope';

    PERFORM set_config('app.runtime_vars_key', '', TRUE);
    PERFORM set_config('app.runtime_vars_key_id', '', TRUE);

    BEGIN
        PERFORM set_runtime_variable(
            v_worker_id,
            'secret_without_key'::VARCHAR,
            '"should_fail"'::JSONB,
            v_scope::VARCHAR,
            'Should fail without encryption key'::TEXT,
            TRUE,
            NULL::TIMESTAMPTZ
        );
        RAISE EXCEPTION 'Expected secret set without key to fail';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
        IF v_error <> 'Missing app.runtime_vars_key for secret runtime variable encryption' THEN
            RAISE EXCEPTION 'Unexpected error for missing encryption key: %', v_error;
        END IF;
    END;
END $$;

-- --------------------------------------------
-- 5) ENCRYPTED SECRET GET WITHOUT KEY SHOULD FAIL
-- --------------------------------------------
DO $$
DECLARE
    v_worker_id TEXT;
    v_scope TEXT;
    v_error TEXT;
BEGIN
    SELECT value INTO v_worker_id FROM test_runtime_context WHERE key = 'worker_id';
    SELECT value INTO v_scope FROM test_runtime_context WHERE key = 'scope';

    PERFORM set_config('app.runtime_vars_key', '', TRUE);

    BEGIN
        PERFORM get_runtime_variable(
            v_worker_id,
            'enc_api_key'::VARCHAR,
            v_scope::VARCHAR,
            FALSE,
            FALSE
        );
        RAISE EXCEPTION 'Expected encrypted secret get without key to fail';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
        IF v_error <> 'Missing app.runtime_vars_key for secret runtime variable decryption' THEN
            RAISE EXCEPTION 'Unexpected error for missing decryption key: %', v_error;
        END IF;
    END;
END $$;

-- --------------------------------------------
-- 6) LEGACY PLAIN SECRET ROW (MIXED-MODE COMPATIBILITY)
-- --------------------------------------------
DO $$
DECLARE
    v_api_key TEXT;
    v_scope TEXT;
    v_worker_id TEXT;
    v_value JSONB;
BEGIN
    SELECT value INTO v_api_key FROM test_runtime_context WHERE key = 'api_key';
    SELECT value INTO v_scope FROM test_runtime_context WHERE key = 'scope';
    SELECT value INTO v_worker_id FROM test_runtime_context WHERE key = 'worker_id';

    INSERT INTO runtime_variables (
        variable_scope,
        variable_key,
        variable_value,
        description,
        is_secret,
        expires_at,
        created_by
    ) VALUES (
        v_scope,
        'legacy_plain_secret',
        '{"legacy": true}'::JSONB,
        'Legacy secret row before encryption rollout',
        TRUE,
        NULL,
        v_worker_id
    )
    ON CONFLICT (variable_scope, variable_key)
    DO UPDATE SET
        variable_value = EXCLUDED.variable_value,
        description = EXCLUDED.description,
        is_secret = EXCLUDED.is_secret,
        expires_at = EXCLUDED.expires_at,
        created_by = EXCLUDED.created_by,
        updated_at = NOW();

    PERFORM set_config('app.runtime_vars_key', '', TRUE);
    SELECT get_runtime_variable(
        v_worker_id,
        'legacy_plain_secret'::VARCHAR,
        v_scope::VARCHAR,
        FALSE,
        FALSE
    ) INTO v_value;

    IF v_value <> '{"legacy": true}'::JSONB THEN
        RAISE EXCEPTION 'Legacy plain secret compatibility failed: %', v_value;
    END IF;
END $$;

-- --------------------------------------------
-- 7) FALLBACK TO GLOBAL WITH ENCRYPTED VALUE
-- --------------------------------------------
DO $$
DECLARE
    v_worker_id TEXT;
    v_api_key TEXT;
    v_scope TEXT;
    v_fallback_value JSONB;
BEGIN
    SELECT value INTO v_worker_id FROM test_runtime_context WHERE key = 'worker_id';
    SELECT value INTO v_api_key FROM test_runtime_context WHERE key = 'api_key';
    SELECT value INTO v_scope FROM test_runtime_context WHERE key = 'scope';

    PERFORM set_config('app.runtime_vars_key', 'kms-material-test-key-1', TRUE);
    PERFORM set_config('app.runtime_vars_key_id', 'kms-key-2026-01', TRUE);

    PERFORM set_runtime_variable(
        v_worker_id,
        'global_secret_fallback'::VARCHAR,
        '"global-secret-value"'::JSONB,
        'global'::VARCHAR,
        'Global encrypted fallback secret'::TEXT,
        TRUE,
        NULL::TIMESTAMPTZ
    );

    SELECT get_runtime_variable(
        v_worker_id,
        'global_secret_fallback'::VARCHAR,
        v_scope::VARCHAR,
        TRUE,
        FALSE
    ) INTO v_fallback_value;

    IF v_fallback_value <> '"global-secret-value"'::JSONB THEN
        RAISE EXCEPTION 'Fallback to encrypted global value failed: %', v_fallback_value;
    END IF;
END $$;

-- --------------------------------------------
-- 8) UPSERT TRANSITION: NON-SECRET -> SECRET
-- --------------------------------------------
DO $$
DECLARE
    v_worker_id TEXT;
    v_api_key TEXT;
    v_scope TEXT;
    v_raw_value JSONB;
    v_read_value JSONB;
    v_is_secret BOOLEAN;
BEGIN
    SELECT value INTO v_worker_id FROM test_runtime_context WHERE key = 'worker_id';
    SELECT value INTO v_api_key FROM test_runtime_context WHERE key = 'api_key';
    SELECT value INTO v_scope FROM test_runtime_context WHERE key = 'scope';

    PERFORM set_runtime_variable(
        v_worker_id,
        'mode_switch'::VARCHAR,
        '{"stage": 1}'::JSONB,
        v_scope::VARCHAR,
        'Transition test non-secret to secret'::TEXT,
        FALSE,
        NULL::TIMESTAMPTZ
    );

    PERFORM set_config('app.runtime_vars_key', 'kms-material-test-key-1', TRUE);
    PERFORM set_config('app.runtime_vars_key_id', 'kms-key-2026-01', TRUE);

    PERFORM set_runtime_variable(
        v_worker_id,
        'mode_switch'::VARCHAR,
        '{"stage": 2}'::JSONB,
        v_scope::VARCHAR,
        'Transition test now secret'::TEXT,
        TRUE,
        NULL::TIMESTAMPTZ
    );

    SELECT variable_value, is_secret
    INTO v_raw_value, v_is_secret
    FROM runtime_variables
    WHERE variable_scope = v_scope
      AND variable_key = 'mode_switch';

    IF v_is_secret IS NOT TRUE OR NOT (v_raw_value ? '_enc_v1') THEN
        RAISE EXCEPTION 'Non-secret -> secret transition did not encrypt storage';
    END IF;

    SELECT get_runtime_variable(
        v_worker_id,
        'mode_switch'::VARCHAR,
        v_scope::VARCHAR,
        FALSE,
        FALSE
    ) INTO v_read_value;

    IF v_read_value <> '{"stage": 2}'::JSONB THEN
        RAISE EXCEPTION 'Non-secret -> secret transition decrypt read failed: %', v_read_value;
    END IF;
END $$;

-- --------------------------------------------
-- 9) UPSERT TRANSITION: SECRET -> NON-SECRET
-- --------------------------------------------
DO $$
DECLARE
    v_worker_id TEXT;
    v_api_key TEXT;
    v_scope TEXT;
    v_raw_value JSONB;
    v_read_value JSONB;
    v_is_secret BOOLEAN;
BEGIN
    SELECT value INTO v_worker_id FROM test_runtime_context WHERE key = 'worker_id';
    SELECT value INTO v_api_key FROM test_runtime_context WHERE key = 'api_key';
    SELECT value INTO v_scope FROM test_runtime_context WHERE key = 'scope';

    PERFORM set_config('app.runtime_vars_key', 'kms-material-test-key-1', TRUE);
    PERFORM set_config('app.runtime_vars_key_id', 'kms-key-2026-01', TRUE);

    PERFORM set_runtime_variable(
        v_worker_id,
        'mode_switch_back'::VARCHAR,
        '"secret-v1"'::JSONB,
        v_scope::VARCHAR,
        'Transition test secret to non-secret'::TEXT,
        TRUE,
        NULL::TIMESTAMPTZ
    );

    PERFORM set_config('app.runtime_vars_key', '', TRUE);
    PERFORM set_runtime_variable(
        v_worker_id,
        'mode_switch_back'::VARCHAR,
        '"plain-v2"'::JSONB,
        v_scope::VARCHAR,
        'Transition test now non-secret'::TEXT,
        FALSE,
        NULL::TIMESTAMPTZ
    );

    SELECT variable_value, is_secret
    INTO v_raw_value, v_is_secret
    FROM runtime_variables
    WHERE variable_scope = v_scope
      AND variable_key = 'mode_switch_back';

    IF v_is_secret IS NOT FALSE THEN
        RAISE EXCEPTION 'Secret -> non-secret transition did not update is_secret';
    END IF;
    IF jsonb_typeof(v_raw_value) = 'object' AND (v_raw_value ? '_enc_v1') THEN
        RAISE EXCEPTION 'Secret -> non-secret transition should store plain value, got: %', v_raw_value;
    END IF;

    SELECT get_runtime_variable(
        v_worker_id,
        'mode_switch_back'::VARCHAR,
        v_scope::VARCHAR,
        FALSE,
        FALSE
    ) INTO v_read_value;

    IF v_read_value <> '"plain-v2"'::JSONB THEN
        RAISE EXCEPTION 'Secret -> non-secret transition read failed: %', v_read_value;
    END IF;
END $$;

-- --------------------------------------------
-- 10) EXPIRED VALUE BEHAVIOR (INCLUDE EXPIRED FLAG)
-- --------------------------------------------
DO $$
DECLARE
    v_api_key TEXT;
    v_scope TEXT;
    v_worker_id TEXT;
    v_normal_get JSONB;
    v_include_expired_get JSONB;
BEGIN
    SELECT value INTO v_api_key FROM test_runtime_context WHERE key = 'api_key';
    SELECT value INTO v_scope FROM test_runtime_context WHERE key = 'scope';
    SELECT value INTO v_worker_id FROM test_runtime_context WHERE key = 'worker_id';

    INSERT INTO runtime_variables (
        variable_scope,
        variable_key,
        variable_value,
        description,
        is_secret,
        expires_at,
        created_by,
        created_at
    ) VALUES (
        v_scope,
        'expired_flag_key',
        '"expired-value"'::JSONB,
        'Expired value test',
        FALSE,
        NOW() - INTERVAL '1 minute',
        v_worker_id,
        NOW() - INTERVAL '2 minutes'
    )
    ON CONFLICT (variable_scope, variable_key)
    DO UPDATE SET
        variable_value = EXCLUDED.variable_value,
        description = EXCLUDED.description,
        is_secret = EXCLUDED.is_secret,
        expires_at = EXCLUDED.expires_at,
        created_by = EXCLUDED.created_by,
        created_at = EXCLUDED.created_at,
        updated_at = NOW();

    SELECT get_runtime_variable(
        v_worker_id,
        'expired_flag_key'::VARCHAR,
        v_scope::VARCHAR,
        FALSE,
        FALSE
    ) INTO v_normal_get;

    IF v_normal_get IS NOT NULL THEN
        RAISE EXCEPTION 'Expired variable should not be returned by default';
    END IF;

    SELECT get_runtime_variable(
        v_worker_id,
        'expired_flag_key'::VARCHAR,
        v_scope::VARCHAR,
        FALSE,
        TRUE
    ) INTO v_include_expired_get;

    IF v_include_expired_get <> '"expired-value"'::JSONB THEN
        RAISE EXCEPTION 'include_expired should return expired value: %', v_include_expired_get;
    END IF;
END $$;

-- --------------------------------------------
-- 11) DELETE WITH WORKER ID + INVALID WORKER ID FAILURES
-- --------------------------------------------
DO $$
DECLARE
    v_worker_id TEXT;
    v_api_key TEXT;
    v_scope TEXT;
    v_deleted BOOLEAN;
    v_after_delete JSONB;
    v_error TEXT;
BEGIN
    SELECT value INTO v_worker_id FROM test_runtime_context WHERE key = 'worker_id';
    SELECT value INTO v_api_key FROM test_runtime_context WHERE key = 'api_key';
    SELECT value INTO v_scope FROM test_runtime_context WHERE key = 'scope';

    PERFORM set_runtime_variable(
        v_worker_id,
        'delete_key'::VARCHAR,
        '{"cleanup": true}'::JSONB,
        v_scope::VARCHAR,
        'Delete test row'::TEXT,
        FALSE,
        NULL::TIMESTAMPTZ
    );

    SELECT delete_runtime_variable(
        v_worker_id,
        'delete_key'::VARCHAR,
        v_scope::VARCHAR
    ) INTO v_deleted;

    IF v_deleted IS NOT TRUE THEN
        RAISE EXCEPTION 'Delete by worker_id should return TRUE for existing key';
    END IF;

    SELECT get_runtime_variable(
        v_worker_id,
        'delete_key'::VARCHAR,
        v_scope::VARCHAR,
        FALSE,
        FALSE
    ) INTO v_after_delete;

    IF v_after_delete IS NOT NULL THEN
        RAISE EXCEPTION 'Deleted key should not be readable after delete';
    END IF;

    BEGIN
        PERFORM set_runtime_variable(
            'invalid_worker_id'::TEXT,
            'should_fail_invalid_worker'::VARCHAR,
            '{"x": 1}'::JSONB,
            v_scope::VARCHAR,
            'Invalid worker id should fail'::TEXT,
            FALSE,
            NULL::TIMESTAMPTZ
        );
        RAISE EXCEPTION 'Expected set_runtime_variable to fail for invalid worker_id';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
        IF v_error <> 'Authentication failed: Invalid or inactive worker ID' THEN
            RAISE EXCEPTION 'Unexpected error for invalid worker_id in set: %', v_error;
        END IF;
    END;

    BEGIN
        PERFORM delete_runtime_variable(
            'invalid_worker_id'::TEXT,
            'missing_key'::VARCHAR,
            v_scope::VARCHAR
        );
        RAISE EXCEPTION 'Expected delete_runtime_variable to fail for invalid worker_id';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
        IF v_error <> 'Authentication failed: Invalid or inactive worker ID' THEN
            RAISE EXCEPTION 'Unexpected error for invalid worker_id in delete: %', v_error;
        END IF;
    END;
END $$;

-- --------------------------------------------
-- 12) WRONG KEY DECRYPTION FAILURE
-- --------------------------------------------
DO $$
DECLARE
    v_worker_id TEXT;
    v_api_key TEXT;
    v_scope TEXT;
    v_error TEXT;
BEGIN
    SELECT value INTO v_worker_id FROM test_runtime_context WHERE key = 'worker_id';
    SELECT value INTO v_api_key FROM test_runtime_context WHERE key = 'api_key';
    SELECT value INTO v_scope FROM test_runtime_context WHERE key = 'scope';

    PERFORM set_config('app.runtime_vars_key', 'kms-material-test-key-good', TRUE);
    PERFORM set_config('app.runtime_vars_key_id', 'kms-key-2026-01', TRUE);

    PERFORM set_runtime_variable(
        v_worker_id,
        'wrong_key_secret'::VARCHAR,
        '"decrypt-me"'::JSONB,
        v_scope::VARCHAR,
        'Wrong key decryption test',
        TRUE,
        NULL::TIMESTAMPTZ
    );

    PERFORM set_config('app.runtime_vars_key', 'kms-material-test-key-wrong', TRUE);

    BEGIN
        PERFORM get_runtime_variable(
            v_worker_id,
            'wrong_key_secret'::VARCHAR,
            v_scope::VARCHAR,
            FALSE,
            FALSE
        );
        RAISE EXCEPTION 'Expected wrong-key decryption failure';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
        IF v_error <> 'Failed to decrypt runtime variable value' THEN
            RAISE EXCEPTION 'Unexpected wrong-key error: %', v_error;
        END IF;
    END;
END $$;

-- --------------------------------------------
-- 13) FK CASCADE WHEN WORKER IS DELETED
-- --------------------------------------------
DO $$
DECLARE
    v_worker_id TEXT;
    v_api_key TEXT;
    v_scope TEXT;
    v_count INTEGER;
BEGIN
    v_worker_id := 'test-runtime-vars-cascade-' || txid_current();
    v_scope := 'tenant_runtime_cascade_' || txid_current();

    SELECT worker_id, api_key
    INTO v_worker_id, v_api_key
    FROM register_worker(
        v_worker_id,
        'Runtime Vars Cascade Test Worker',
        5,
        '30 seconds'::INTERVAL,
        '["default"]'::JSONB
    );

    PERFORM set_runtime_variable(
        v_worker_id,
        'cascade_delete_key'::VARCHAR,
        '{"cascade": true}'::JSONB,
        v_scope::VARCHAR,
        'FK cascade delete test',
        FALSE,
        NULL::TIMESTAMPTZ
    );

    SELECT COUNT(*)
    INTO v_count
    FROM runtime_variables
    WHERE variable_scope = v_scope
      AND variable_key = 'cascade_delete_key'
      AND created_by = v_worker_id;

    IF v_count <> 1 THEN
        RAISE EXCEPTION 'Expected runtime variable row before worker delete, found: %', v_count;
    END IF;

    DELETE FROM worker_registry
    WHERE worker_id = v_worker_id;

    SELECT COUNT(*)
    INTO v_count
    FROM runtime_variables
    WHERE variable_scope = v_scope
      AND variable_key = 'cascade_delete_key';

    IF v_count <> 0 THEN
        RAISE EXCEPTION 'Expected runtime variable row to be deleted by FK cascade, found: %', v_count;
    END IF;
END $$;

ROLLBACK;
