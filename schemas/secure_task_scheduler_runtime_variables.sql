-- ============================================
-- SECURE TASK SCHEDULER RUNTIME VARIABLES MODULE
-- Version: 1.2
-- Run AFTER: secure_task_scheduler.sql
-- ============================================

-- ============================================
-- 1. DEPENDENCY VALIDATION
-- ============================================

DO $$
BEGIN
    IF to_regclass('public.worker_registry') IS NULL THEN
        RAISE EXCEPTION 'Missing table: worker_registry. Run secure_task_scheduler.sql first.';
    END IF;
    IF to_regprocedure('update_updated_at_column()') IS NULL THEN
        RAISE EXCEPTION 'Missing function: update_updated_at_column(). Run secure_task_scheduler.sql first.';
    END IF;
    IF to_regprocedure('check_rate_limit(character varying,character varying,integer,integer)') IS NULL THEN
        RAISE EXCEPTION 'Missing function: check_rate_limit(...). Run secure_task_scheduler.sql first.';
    END IF;
END $$;


-- ============================================
-- 2. TABLE
-- ============================================

CREATE TABLE IF NOT EXISTS runtime_variables (
    id BIGSERIAL PRIMARY KEY,
    variable_scope VARCHAR(50) NOT NULL DEFAULT 'global',
    variable_key VARCHAR(150) NOT NULL,
    variable_value JSONB NOT NULL DEFAULT 'null'::JSONB,
    description TEXT,
    is_secret BOOLEAN DEFAULT FALSE,
    expires_at TIMESTAMPTZ,
    created_by VARCHAR(100),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT valid_runtime_variable_scope CHECK (variable_scope ~ '^[a-z0-9_-]+$'),
    CONSTRAINT valid_runtime_variable_key CHECK (variable_key ~ '^[a-zA-Z0-9_.:-]+$'),
    CONSTRAINT valid_runtime_variable_expiry CHECK (expires_at IS NULL OR expires_at > created_at),
    UNIQUE(variable_scope, variable_key)
);

DO $$
BEGIN
    -- Legacy-safe cleanup before adding FK.
    UPDATE runtime_variables rv
    SET created_by = NULL
    WHERE rv.created_by IS NOT NULL
      AND NOT EXISTS (
          SELECT 1
          FROM worker_registry wr
          WHERE wr.worker_id = rv.created_by
      );

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'fk_runtime_variables_worker_id'
          AND conrelid = 'runtime_variables'::regclass
    ) THEN
        ALTER TABLE runtime_variables
            ADD CONSTRAINT fk_runtime_variables_worker_id
            FOREIGN KEY (created_by)
            REFERENCES worker_registry(worker_id)
            ON DELETE CASCADE
            ON UPDATE CASCADE;
    END IF;
END $$;


-- ============================================
-- 3. PERFORMANCE INDEXES
-- ============================================

CREATE INDEX IF NOT EXISTS idx_runtime_variables_lookup
ON runtime_variables(variable_scope, variable_key);

CREATE INDEX IF NOT EXISTS idx_runtime_variables_expires_at
ON runtime_variables(expires_at)
WHERE expires_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_runtime_variables_created_by
ON runtime_variables(created_by);


-- ============================================
-- 4. TRIGGERS
-- ============================================

DROP TRIGGER IF EXISTS update_runtime_variables_updated_at ON runtime_variables;
CREATE TRIGGER update_runtime_variables_updated_at
BEFORE UPDATE ON runtime_variables
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();


-- ============================================
-- 5. RUNTIME VARIABLE FUNCTIONS
-- ============================================

DROP FUNCTION IF EXISTS runtime_vars_encrypt_jsonb(JSONB);
CREATE OR REPLACE FUNCTION runtime_vars_encrypt_jsonb(
    p_plain JSONB
) RETURNS JSONB AS $$
DECLARE
    v_key TEXT;
    v_key_id TEXT;
    v_ciphertext BYTEA;
BEGIN
    v_key := current_setting('app.runtime_vars_key', TRUE);
    IF v_key IS NULL OR length(trim(v_key)) = 0 THEN
        RAISE EXCEPTION 'Missing app.runtime_vars_key for secret runtime variable encryption';
    END IF;

    v_key_id := current_setting('app.runtime_vars_key_id', TRUE);
    IF v_key_id IS NULL OR length(trim(v_key_id)) = 0 THEN
        v_key_id := 'default';
    END IF;

    v_ciphertext := pgp_sym_encrypt(
        COALESCE(p_plain, 'null'::JSONB)::TEXT,
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


DROP FUNCTION IF EXISTS runtime_vars_decrypt_jsonb(JSONB, BOOLEAN);
CREATE OR REPLACE FUNCTION runtime_vars_decrypt_jsonb(
    p_stored JSONB,
    p_is_secret BOOLEAN
) RETURNS JSONB AS $$
DECLARE
    v_key TEXT;
    v_envelope JSONB;
    v_ciphertext_b64 TEXT;
    v_plaintext TEXT;
BEGIN
    IF NOT COALESCE(p_is_secret, FALSE) THEN
        RETURN p_stored;
    END IF;

    IF p_stored IS NULL THEN
        RETURN NULL;
    END IF;

    -- Mixed-mode read for backwards compatibility:
    -- secret rows that are still plain JSONB are returned as-is.
    IF jsonb_typeof(p_stored) <> 'object' OR NOT (p_stored ? '_enc_v1') THEN
        RETURN p_stored;
    END IF;

    v_envelope := p_stored->'_enc_v1';
    IF jsonb_typeof(v_envelope) <> 'object'
       OR (v_envelope->>'alg') IS DISTINCT FROM 'pgp_sym_encrypt' THEN
        RAISE EXCEPTION 'Invalid encrypted runtime variable format';
    END IF;

    v_ciphertext_b64 := v_envelope->>'ct';
    IF v_ciphertext_b64 IS NULL OR length(trim(v_ciphertext_b64)) = 0 THEN
        RAISE EXCEPTION 'Invalid encrypted runtime variable format';
    END IF;

    v_key := current_setting('app.runtime_vars_key', TRUE);
    IF v_key IS NULL OR length(trim(v_key)) = 0 THEN
        RAISE EXCEPTION 'Missing app.runtime_vars_key for secret runtime variable decryption';
    END IF;

    BEGIN
        v_plaintext := pgp_sym_decrypt(
            decode(v_ciphertext_b64, 'base64'),
            v_key
        );
        RETURN v_plaintext::JSONB;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'Failed to decrypt runtime variable value';
    END;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


DROP FUNCTION IF EXISTS validate_runtime_worker_id(VARCHAR);
CREATE OR REPLACE FUNCTION validate_runtime_worker_id(
    p_worker_id VARCHAR
) RETURNS VARCHAR AS $$
DECLARE
    v_worker_id VARCHAR;
BEGIN
    IF p_worker_id IS NULL OR length(trim(p_worker_id)) = 0 THEN
        RAISE EXCEPTION 'Worker ID cannot be empty';
    END IF;

    SELECT wr.worker_id
    INTO v_worker_id
    FROM worker_registry wr
    WHERE wr.worker_id = trim(p_worker_id)
      AND wr.is_active = TRUE
    LIMIT 1;

    IF v_worker_id IS NULL THEN
        RAISE EXCEPTION 'Authentication failed: Invalid or inactive worker ID';
    END IF;

    RETURN v_worker_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


DROP FUNCTION IF EXISTS set_runtime_variable(
    TEXT,
    VARCHAR,
    JSONB,
    VARCHAR,
    TEXT,
    BOOLEAN,
    TIMESTAMPTZ
);
CREATE OR REPLACE FUNCTION set_runtime_variable(
    p_worker_id TEXT,
    p_variable_key VARCHAR,
    p_variable_value JSONB,
    p_variable_scope VARCHAR DEFAULT 'global',
    p_description TEXT DEFAULT NULL,
    p_is_secret BOOLEAN DEFAULT FALSE,
    p_expires_at TIMESTAMPTZ DEFAULT NULL
) RETURNS TABLE (
    out_variable_scope VARCHAR,
    out_variable_key VARCHAR,
    out_variable_value JSONB,
    out_is_secret BOOLEAN,
    out_expires_at TIMESTAMPTZ,
    out_updated_at TIMESTAMPTZ
) AS $$
DECLARE
    v_valid_worker_id VARCHAR;
    v_stored_variable_value JSONB;
BEGIN
    v_valid_worker_id := validate_runtime_worker_id(p_worker_id);
    PERFORM check_rate_limit(v_valid_worker_id, 'runtime_var_set', 10000, 60);

    IF p_variable_key IS NULL OR length(trim(p_variable_key)) = 0 THEN
        RAISE EXCEPTION 'Variable key cannot be empty';
    END IF;

    IF p_variable_scope IS NULL OR length(trim(p_variable_scope)) = 0 THEN
        RAISE EXCEPTION 'Variable scope cannot be empty';
    END IF;

    IF p_expires_at IS NOT NULL AND p_expires_at <= NOW() THEN
        RAISE EXCEPTION 'expires_at must be in the future';
    END IF;

    v_stored_variable_value := COALESCE(p_variable_value, 'null'::JSONB);
    IF p_is_secret THEN
        v_stored_variable_value := runtime_vars_encrypt_jsonb(v_stored_variable_value);
    END IF;

    RETURN QUERY
    INSERT INTO runtime_variables (
        variable_scope,
        variable_key,
        variable_value,
        description,
        is_secret,
        expires_at,
        created_by
    ) VALUES (
        p_variable_scope,
        p_variable_key,
        v_stored_variable_value,
        p_description,
        p_is_secret,
        p_expires_at,
        v_valid_worker_id
    )
    ON CONFLICT (variable_scope, variable_key)
    DO UPDATE SET
        variable_value = EXCLUDED.variable_value,
        description = EXCLUDED.description,
        is_secret = EXCLUDED.is_secret,
        expires_at = EXCLUDED.expires_at,
        created_by = EXCLUDED.created_by,
        updated_at = NOW()
    RETURNING
        runtime_variables.variable_scope AS out_variable_scope,
        runtime_variables.variable_key AS out_variable_key,
        runtime_vars_decrypt_jsonb(
            runtime_variables.variable_value,
            runtime_variables.is_secret
        ) AS out_variable_value,
        runtime_variables.is_secret AS out_is_secret,
        runtime_variables.expires_at AS out_expires_at,
        runtime_variables.updated_at AS out_updated_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


DROP FUNCTION IF EXISTS get_runtime_variable(
    TEXT,
    VARCHAR,
    VARCHAR,
    BOOLEAN,
    BOOLEAN
);
CREATE OR REPLACE FUNCTION get_runtime_variable(
    p_worker_id TEXT,
    p_variable_key VARCHAR,
    p_variable_scope VARCHAR DEFAULT 'global',
    p_fallback_to_global BOOLEAN DEFAULT FALSE,
    p_include_expired BOOLEAN DEFAULT FALSE
) RETURNS JSONB AS $$
DECLARE
    v_worker_id VARCHAR;
    v_variable_value JSONB;
    v_is_secret BOOLEAN;
BEGIN
    v_worker_id := validate_runtime_worker_id(p_worker_id);
    PERFORM check_rate_limit(v_worker_id, 'runtime_var_get', 20000, 60);

    IF p_variable_key IS NULL OR length(trim(p_variable_key)) = 0 THEN
        RAISE EXCEPTION 'Variable key cannot be empty';
    END IF;

    IF p_variable_scope IS NULL OR length(trim(p_variable_scope)) = 0 THEN
        RAISE EXCEPTION 'Variable scope cannot be empty';
    END IF;

    SELECT rv.variable_value, rv.is_secret
    INTO v_variable_value, v_is_secret
    FROM runtime_variables rv
    WHERE rv.variable_scope = p_variable_scope
      AND rv.variable_key = p_variable_key
      AND (
          p_include_expired
          OR rv.expires_at IS NULL
          OR rv.expires_at > NOW()
      )
    LIMIT 1;

    IF v_variable_value IS NULL
       AND p_fallback_to_global
       AND p_variable_scope <> 'global' THEN
        SELECT rv.variable_value, rv.is_secret
        INTO v_variable_value, v_is_secret
        FROM runtime_variables rv
        WHERE rv.variable_scope = 'global'
          AND rv.variable_key = p_variable_key
          AND (
              p_include_expired
              OR rv.expires_at IS NULL
              OR rv.expires_at > NOW()
          )
        LIMIT 1;
    END IF;

    RETURN runtime_vars_decrypt_jsonb(v_variable_value, v_is_secret);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


DROP FUNCTION IF EXISTS delete_runtime_variable(
    TEXT,
    VARCHAR,
    VARCHAR
);
CREATE OR REPLACE FUNCTION delete_runtime_variable(
    p_worker_id TEXT,
    p_variable_key VARCHAR,
    p_variable_scope VARCHAR DEFAULT 'global'
) RETURNS BOOLEAN AS $$
DECLARE
    v_valid_worker_id VARCHAR;
BEGIN
    v_valid_worker_id := validate_runtime_worker_id(p_worker_id);
    PERFORM check_rate_limit(v_valid_worker_id, 'runtime_var_delete', 10000, 60);

    IF p_variable_key IS NULL OR length(trim(p_variable_key)) = 0 THEN
        RAISE EXCEPTION 'Variable key cannot be empty';
    END IF;

    IF p_variable_scope IS NULL OR length(trim(p_variable_scope)) = 0 THEN
        RAISE EXCEPTION 'Variable scope cannot be empty';
    END IF;

    DELETE FROM runtime_variables
    WHERE variable_scope = p_variable_scope
      AND variable_key = p_variable_key;

    RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ============================================
-- 6. QUICK TUTORIAL: SET / GET / UPDATE / DELETE
-- ============================================

/*
Simple meaning of each field:
- p_worker_id:
  Worker identity used for SET/GET/UPDATE/DELETE operations.
  API key is not required in this runtime variables module.
- p_variable_scope:
  "Where this value belongs".
  Use 'global' for default values shared by everyone.
  Use tenant scopes like 'tenant_acme' for customer-specific overrides.
- p_variable_key:
  The variable name (example: 'max_retry_count').
- p_variable_value:
  The value stored as JSONB (number, string, object, array, boolean, or null).
- p_description:
  Human note explaining what this variable is for.
- p_is_secret:
  TRUE means sensitive value (password/token). Values are encrypted at rest.
  Secret reads/writes require:
    SET LOCAL app.runtime_vars_key = '<kms-fetched-secret-key>';
    SET LOCAL app.runtime_vars_key_id = '<optional-key-id>';
  FALSE means normal non-sensitive value.
- p_expires_at:
  Optional expiry time. After this time, normal get calls ignore the value.

What scope does in practice:
- You can store the same key in different scopes.
- Example:
  global.max_retry_count = 3
  tenant_acme.max_retry_count = 5
- A worker for tenant_acme can read tenant value first, then fallback to global.

-- 1) SET (create new variable in tenant scope)
SELECT * FROM set_runtime_variable(
    'your_worker_id',
    'max_retry_count'::VARCHAR,
    '3'::JSONB,
    'tenant_acme'::VARCHAR,
    'Retry count for ACME'::TEXT,
    FALSE,
    NULL::TIMESTAMPTZ
);

-- 2) GET (read exact scope + key)
-- GET authenticates with worker_id (must be active).
SELECT get_runtime_variable(
    'your_worker_id',
    'max_retry_count'::VARCHAR,
    'tenant_acme'::VARCHAR,
    FALSE,
    FALSE
);

-- 2b) GET with fallback (if tenant value is missing, read global)
SELECT get_runtime_variable(
    'your_worker_id',
    'max_retry_count'::VARCHAR,
    'tenant_acme'::VARCHAR,
    TRUE,
    FALSE
);

-- 3) UPDATE (same scope + key, new value)
SELECT * FROM set_runtime_variable(
    'your_worker_id',
    'max_retry_count'::VARCHAR,
    '5'::JSONB,
    'tenant_acme'::VARCHAR,
    'Retry count for ACME'::TEXT,
    FALSE,
    NULL::TIMESTAMPTZ
);

-- 4) DELETE
SELECT delete_runtime_variable(
    'your_worker_id',
    'max_retry_count'::VARCHAR,
    'tenant_acme'::VARCHAR
);

-- 5) VERIFY (should return NULL after delete)
SELECT get_runtime_variable(
    'your_worker_id',
    'max_retry_count'::VARCHAR,
    'tenant_acme'::VARCHAR,
    FALSE,
    FALSE
);

-- 5b) Optional: view raw row details directly from table
-- (helps understand created_by, is_secret, expires_at, timestamps)
SELECT
    variable_scope,
    variable_key,
    variable_value,
    description,
    is_secret,
    expires_at,
    created_by,
    created_at,
    updated_at
FROM runtime_variables
WHERE variable_scope = 'tenant_acme'
  AND variable_key = 'max_retry_count';

-- 6) SECRET VALUE EXAMPLE (automatic encrypt/decrypt)
BEGIN;
SET LOCAL app.runtime_vars_key = 'kms_fetched_runtime_key_material';
SET LOCAL app.runtime_vars_key_id = 'kms-key-2026-01';

SELECT * FROM set_runtime_variable(
    'your_worker_id',
    'third_party_api_key'::VARCHAR,
    '"live_api_key_123"'::JSONB,
    'tenant_acme'::VARCHAR,
    'Encrypted API key for tenant ACME'::TEXT,
    TRUE,
    NULL::TIMESTAMPTZ
);

-- Returned value is decrypted JSONB; row in table is encrypted envelope.
SELECT get_runtime_variable(
    'your_worker_id',
    'third_party_api_key'::VARCHAR,
    'tenant_acme'::VARCHAR,
    FALSE,
    FALSE
);
COMMIT;
*/
