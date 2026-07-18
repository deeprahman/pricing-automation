-- ============================================
-- ENCRYPTED SECRETS MODULE
-- Version: 1.0
-- ============================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";


-- ============================================
-- 1) TABLE
-- ============================================

CREATE TABLE IF NOT EXISTS secrets (
    id BIGSERIAL PRIMARY KEY,
    secret_payload JSONB NOT NULL,
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_secrets_description_length
        CHECK (description IS NULL OR char_length(description) <= 1000),
    CONSTRAINT chk_secrets_payload_shape
        CHECK (jsonb_typeof(secret_payload) = 'object' AND secret_payload ? '_enc_v1')
);

CREATE INDEX IF NOT EXISTS idx_secrets_created_at
ON secrets(created_at DESC);


-- ============================================
-- 2) TRIGGER
-- ============================================

CREATE OR REPLACE FUNCTION set_secrets_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_secrets_updated_at ON secrets;
CREATE TRIGGER trg_secrets_updated_at
BEFORE UPDATE ON secrets
FOR EACH ROW
EXECUTE FUNCTION set_secrets_updated_at();


-- ============================================
-- 3) ENCRYPT / DECRYPT HELPERS
-- ============================================

DROP FUNCTION IF EXISTS secrets_encrypt_text(TEXT);
CREATE OR REPLACE FUNCTION secrets_encrypt_text(
    p_plain TEXT
) RETURNS JSONB AS $$
DECLARE
    v_key TEXT;
    v_key_id TEXT;
    v_ciphertext BYTEA;
BEGIN
    v_key := current_setting('app.secrets_key', TRUE);
    IF v_key IS NULL OR length(trim(v_key)) = 0 THEN
        RAISE EXCEPTION 'Missing app.secrets_key for secret encryption';
    END IF;

    v_key_id := current_setting('app.secrets_key_id', TRUE);
    IF v_key_id IS NULL OR length(trim(v_key_id)) = 0 THEN
        v_key_id := 'default';
    END IF;

    v_ciphertext := pgp_sym_encrypt(
        COALESCE(p_plain, ''),
        v_key,
        'cipher-algo=aes256,compress-algo=0'
    );

    RETURN jsonb_build_object(
        '_enc_v1',
        jsonb_build_object(
            'alg', 'pgp_sym_encrypt',
            'kid', v_key_id,
            'ct', encode(v_ciphertext, 'base64')
        )
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


DROP FUNCTION IF EXISTS secrets_decrypt_text(JSONB);
CREATE OR REPLACE FUNCTION secrets_decrypt_text(
    p_stored JSONB
) RETURNS TEXT AS $$
DECLARE
    v_key TEXT;
    v_envelope JSONB;
    v_ciphertext_b64 TEXT;
    v_plaintext TEXT;
BEGIN
    IF p_stored IS NULL THEN
        RETURN NULL;
    END IF;

    IF jsonb_typeof(p_stored) <> 'object' OR NOT (p_stored ? '_enc_v1') THEN
        RAISE EXCEPTION 'Invalid encrypted secret format';
    END IF;

    v_envelope := p_stored->'_enc_v1';
    IF jsonb_typeof(v_envelope) <> 'object'
       OR (v_envelope->>'alg') IS DISTINCT FROM 'pgp_sym_encrypt' THEN
        RAISE EXCEPTION 'Invalid encrypted secret format';
    END IF;

    v_ciphertext_b64 := v_envelope->>'ct';
    IF v_ciphertext_b64 IS NULL OR length(trim(v_ciphertext_b64)) = 0 THEN
        RAISE EXCEPTION 'Invalid encrypted secret format';
    END IF;

    v_key := current_setting('app.secrets_key', TRUE);
    IF v_key IS NULL OR length(trim(v_key)) = 0 THEN
        RAISE EXCEPTION 'Missing app.secrets_key for secret decryption';
    END IF;

    BEGIN
        v_plaintext := pgp_sym_decrypt(
            decode(v_ciphertext_b64, 'base64'),
            v_key
        );
        RETURN v_plaintext;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'Failed to decrypt secret value';
    END;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ============================================
-- 4) CRUD FUNCTIONS
-- ============================================

DROP FUNCTION IF EXISTS set_secret(TEXT, TEXT);
CREATE OR REPLACE FUNCTION set_secret(
    p_secret TEXT,
    p_description TEXT
) RETURNS BIGINT AS $$
DECLARE
    v_id BIGINT;
BEGIN
    IF p_secret IS NULL THEN
        RAISE EXCEPTION 'Secret cannot be NULL';
    END IF;

    IF p_description IS NOT NULL AND char_length(p_description) > 1000 THEN
        RAISE EXCEPTION 'Description must be at most 1000 characters';
    END IF;

    INSERT INTO secrets (secret_payload, description)
    VALUES (
        secrets_encrypt_text(p_secret),
        p_description
    )
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


DROP FUNCTION IF EXISTS get_secret(BIGINT);
CREATE OR REPLACE FUNCTION get_secret(
    p_id BIGINT
) RETURNS TEXT AS $$
DECLARE
    v_stored JSONB;
BEGIN
    SELECT s.secret_payload
    INTO v_stored
    FROM secrets s
    WHERE s.id = p_id;

    IF v_stored IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN secrets_decrypt_text(v_stored);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


DROP FUNCTION IF EXISTS update_secret(BIGINT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION update_secret(
    p_id BIGINT,
    p_secret TEXT,
    p_description TEXT
) RETURNS BOOLEAN AS $$
BEGIN
    IF p_secret IS NULL THEN
        RAISE EXCEPTION 'Secret cannot be NULL';
    END IF;

    IF p_description IS NOT NULL AND char_length(p_description) > 1000 THEN
        RAISE EXCEPTION 'Description must be at most 1000 characters';
    END IF;

    UPDATE secrets s
    SET
        secret_payload = secrets_encrypt_text(p_secret),
        description = p_description
    WHERE s.id = p_id;

    RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


DROP FUNCTION IF EXISTS delete_secret(BIGINT);
CREATE OR REPLACE FUNCTION delete_secret(
    p_id BIGINT
) RETURNS BOOLEAN AS $$
BEGIN
    DELETE FROM secrets
    WHERE id = p_id;

    RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
