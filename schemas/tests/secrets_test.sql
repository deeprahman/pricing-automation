-- ============================================
-- ENCRYPTED SECRETS MODULE TEST SUITE
-- Run AFTER:
--   1) schemas/secrets.sql
-- ============================================

BEGIN;

-- --------------------------------------------
-- 0) SANITY CHECKS
-- --------------------------------------------
DO $$
BEGIN
    IF to_regclass('public.secrets') IS NULL THEN
        RAISE EXCEPTION 'Missing table: secrets';
    END IF;
    IF to_regprocedure('set_secret(text,text)') IS NULL THEN
        RAISE EXCEPTION 'Missing function: set_secret(text,text)';
    END IF;
    IF to_regprocedure('get_secret(bigint)') IS NULL THEN
        RAISE EXCEPTION 'Missing function: get_secret(bigint)';
    END IF;
    IF to_regprocedure('update_secret(bigint,text,text)') IS NULL THEN
        RAISE EXCEPTION 'Missing function: update_secret(bigint,text,text)';
    END IF;
    IF to_regprocedure('delete_secret(bigint)') IS NULL THEN
        RAISE EXCEPTION 'Missing function: delete_secret(bigint)';
    END IF;
    IF to_regprocedure('secrets_encrypt_text(text)') IS NULL THEN
        RAISE EXCEPTION 'Missing function: secrets_encrypt_text(text)';
    END IF;
    IF to_regprocedure('secrets_decrypt_text(jsonb)') IS NULL THEN
        RAISE EXCEPTION 'Missing function: secrets_decrypt_text(jsonb)';
    END IF;
END $$;

CREATE TEMP TABLE test_secrets_context (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- --------------------------------------------
-- 1) SET/GET happy path + encrypted raw storage
-- --------------------------------------------
DO $$
DECLARE
    v_id BIGINT;
    v_secret TEXT;
    v_raw JSONB;
BEGIN
    PERFORM set_config('app.secrets_key', 'kms-material-test-key-good', TRUE);
    PERFORM set_config('app.secrets_key_id', 'kms-key-2026-01', TRUE);

    v_id := set_secret(
        'sk_live_secret_abc123',
        'Primary test secret'
    );

    IF v_id IS NULL THEN
        RAISE EXCEPTION 'set_secret returned NULL id';
    END IF;

    INSERT INTO test_secrets_context (key, value)
    VALUES ('secret_id', v_id::TEXT);

    SELECT get_secret(v_id) INTO v_secret;
    IF v_secret <> 'sk_live_secret_abc123' THEN
        RAISE EXCEPTION 'Unexpected get_secret result: %', v_secret;
    END IF;

    SELECT s.secret_payload
    INTO v_raw
    FROM secrets s
    WHERE s.id = v_id;

    IF v_raw IS NULL OR NOT (v_raw ? '_enc_v1') THEN
        RAISE EXCEPTION 'Encrypted payload missing _enc_v1 envelope: %', v_raw;
    END IF;

    IF v_raw->'_enc_v1'->>'kid' <> 'kms-key-2026-01' THEN
        RAISE EXCEPTION 'Encrypted payload missing key id metadata: %', v_raw;
    END IF;

    IF position('sk_live_secret_abc123' IN v_raw::TEXT) > 0 THEN
        RAISE EXCEPTION 'Plaintext leaked into storage: %', v_raw;
    END IF;
END $$;

-- --------------------------------------------
-- 2) Description length > 1000 should fail
-- --------------------------------------------
DO $$
DECLARE
    v_error TEXT;
BEGIN
    PERFORM set_config('app.secrets_key', 'kms-material-test-key-good', TRUE);

    BEGIN
        PERFORM set_secret(
            'desc-limit-check',
            repeat('a', 1001)
        );
        RAISE EXCEPTION 'Expected set_secret description length failure';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
        IF v_error <> 'Description must be at most 1000 characters' THEN
            RAISE EXCEPTION 'Unexpected description error: %', v_error;
        END IF;
    END;
END $$;

-- --------------------------------------------
-- 3) Secret set without key should fail
-- --------------------------------------------
DO $$
DECLARE
    v_error TEXT;
BEGIN
    PERFORM set_config('app.secrets_key', '', TRUE);
    PERFORM set_config('app.secrets_key_id', '', TRUE);

    BEGIN
        PERFORM set_secret(
            'missing-key-write',
            'Should fail without encryption key'
        );
        RAISE EXCEPTION 'Expected set_secret to fail without key';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
        IF v_error <> 'Missing app.secrets_key for secret encryption' THEN
            RAISE EXCEPTION 'Unexpected missing-key write error: %', v_error;
        END IF;
    END;
END $$;

-- --------------------------------------------
-- 4) Encrypted secret get without key should fail
-- --------------------------------------------
DO $$
DECLARE
    v_id BIGINT;
    v_error TEXT;
BEGIN
    SELECT value::BIGINT
    INTO v_id
    FROM test_secrets_context
    WHERE key = 'secret_id';

    PERFORM set_config('app.secrets_key', '', TRUE);

    BEGIN
        PERFORM get_secret(v_id);
        RAISE EXCEPTION 'Expected get_secret to fail without key';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
        IF v_error <> 'Missing app.secrets_key for secret decryption' THEN
            RAISE EXCEPTION 'Unexpected missing-key read error: %', v_error;
        END IF;
    END;
END $$;

-- --------------------------------------------
-- 5) Wrong-key decryption should fail
-- --------------------------------------------
DO $$
DECLARE
    v_id BIGINT;
    v_error TEXT;
BEGIN
    SELECT value::BIGINT
    INTO v_id
    FROM test_secrets_context
    WHERE key = 'secret_id';

    PERFORM set_config('app.secrets_key', 'kms-material-test-key-wrong', TRUE);

    BEGIN
        PERFORM get_secret(v_id);
        RAISE EXCEPTION 'Expected get_secret to fail with wrong key';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
        IF v_error <> 'Failed to decrypt secret value' THEN
            RAISE EXCEPTION 'Unexpected wrong-key error: %', v_error;
        END IF;
    END;
END $$;

-- --------------------------------------------
-- 6) Update success path + read-back
-- --------------------------------------------
DO $$
DECLARE
    v_id BIGINT;
    v_updated BOOLEAN;
    v_secret TEXT;
BEGIN
    SELECT value::BIGINT
    INTO v_id
    FROM test_secrets_context
    WHERE key = 'secret_id';

    PERFORM set_config('app.secrets_key', 'kms-material-test-key-good', TRUE);
    PERFORM set_config('app.secrets_key_id', 'kms-key-2026-02', TRUE);

    v_updated := update_secret(
        v_id,
        'sk_live_secret_updated_987',
        'Updated description'
    );

    IF v_updated IS NOT TRUE THEN
        RAISE EXCEPTION 'Expected update_secret to return TRUE for existing id';
    END IF;

    SELECT get_secret(v_id) INTO v_secret;
    IF v_secret <> 'sk_live_secret_updated_987' THEN
        RAISE EXCEPTION 'Unexpected updated secret read-back: %', v_secret;
    END IF;
END $$;

-- --------------------------------------------
-- 7) Update missing id should return FALSE
-- --------------------------------------------
DO $$
DECLARE
    v_updated BOOLEAN;
BEGIN
    PERFORM set_config('app.secrets_key', 'kms-material-test-key-good', TRUE);

    v_updated := update_secret(
        9223372036854775807,
        'not-found',
        'Missing row update'
    );

    IF v_updated IS NOT FALSE THEN
        RAISE EXCEPTION 'Expected update_secret FALSE for missing id, got: %', v_updated;
    END IF;
END $$;

-- --------------------------------------------
-- 8) Delete success + post-delete checks
-- --------------------------------------------
DO $$
DECLARE
    v_id BIGINT;
    v_deleted_first BOOLEAN;
    v_deleted_second BOOLEAN;
    v_secret TEXT;
BEGIN
    SELECT value::BIGINT
    INTO v_id
    FROM test_secrets_context
    WHERE key = 'secret_id';

    v_deleted_first := delete_secret(v_id);
    IF v_deleted_first IS NOT TRUE THEN
        RAISE EXCEPTION 'Expected first delete_secret to return TRUE';
    END IF;

    SELECT get_secret(v_id) INTO v_secret;
    IF v_secret IS NOT NULL THEN
        RAISE EXCEPTION 'Expected NULL from get_secret after delete, got: %', v_secret;
    END IF;

    v_deleted_second := delete_secret(v_id);
    IF v_deleted_second IS NOT FALSE THEN
        RAISE EXCEPTION 'Expected second delete_secret to return FALSE';
    END IF;
END $$;

ROLLBACK;
