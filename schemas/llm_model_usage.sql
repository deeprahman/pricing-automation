-- ============================================================================
-- LLM Model Usage Tracking
-- ============================================================================
-- Purpose:
--   - Persist per-request LLM token usage and diagnostics for workers.
--   - Support cost and reliability monitoring by model/action/time.
-- ============================================================================

CREATE TABLE IF NOT EXISTS llm_model_usage (
    id BIGSERIAL PRIMARY KEY,
    worker_name TEXT NOT NULL,
    action_name TEXT NOT NULL,
    task_uuid TEXT NULL,
    provider TEXT NOT NULL,
    model TEXT NOT NULL,
    prompt_tokens INT NULL,
    completion_tokens INT NULL,
    total_tokens INT NULL,
    success BOOLEAN NOT NULL DEFAULT FALSE,
    error_code TEXT NULL,
    error_message TEXT NULL,
    latency_ms INT NULL,
    response_id TEXT NULL,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_llm_model_usage_prompt_tokens_non_negative
        CHECK (prompt_tokens IS NULL OR prompt_tokens >= 0),
    CONSTRAINT chk_llm_model_usage_completion_tokens_non_negative
        CHECK (completion_tokens IS NULL OR completion_tokens >= 0),
    CONSTRAINT chk_llm_model_usage_total_tokens_non_negative
        CHECK (total_tokens IS NULL OR total_tokens >= 0),
    CONSTRAINT chk_llm_model_usage_latency_non_negative
        CHECK (latency_ms IS NULL OR latency_ms >= 0)
);

CREATE INDEX IF NOT EXISTS idx_llm_model_usage_created_at
ON llm_model_usage (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_llm_model_usage_worker_action_created_at
ON llm_model_usage (worker_name, action_name, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_llm_model_usage_provider_model_created_at
ON llm_model_usage (provider, model, created_at DESC);


-- ============================================================================
-- LLM Model Pricing
-- ============================================================================
-- Purpose:
--   - Store editable pricing inputs for usage cost estimates.
--   - Keep pricing separate from usage history so historical usage can be
--     re-estimated when prices are corrected or updated.
-- ============================================================================

CREATE TABLE IF NOT EXISTS llm_model_pricing (
    id BIGSERIAL PRIMARY KEY,
    provider TEXT NOT NULL,
    model TEXT NOT NULL,
    input_price_per_1m_tokens NUMERIC(12, 6) NOT NULL DEFAULT 0,
    output_price_per_1m_tokens NUMERIC(12, 6) NOT NULL DEFAULT 0,
    currency TEXT NOT NULL DEFAULT 'USD',
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_llm_model_pricing_provider_non_blank
        CHECK (btrim(provider) <> ''),
    CONSTRAINT chk_llm_model_pricing_model_non_blank
        CHECK (btrim(model) <> ''),
    CONSTRAINT chk_llm_model_pricing_input_non_negative
        CHECK (input_price_per_1m_tokens >= 0),
    CONSTRAINT chk_llm_model_pricing_output_non_negative
        CHECK (output_price_per_1m_tokens >= 0),
    CONSTRAINT chk_llm_model_pricing_currency_non_blank
        CHECK (btrim(currency) <> ''),
    CONSTRAINT uq_llm_model_pricing_provider_model
        UNIQUE (provider, model)
);

CREATE INDEX IF NOT EXISTS idx_llm_model_pricing_active_provider_model
ON llm_model_pricing (provider, model)
WHERE is_active = TRUE;

CREATE OR REPLACE FUNCTION set_llm_model_pricing_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_llm_model_pricing_updated_at ON llm_model_pricing;
CREATE TRIGGER trg_llm_model_pricing_updated_at
BEFORE UPDATE ON llm_model_pricing
FOR EACH ROW
EXECUTE FUNCTION set_llm_model_pricing_updated_at();


-- ============================================================================
-- LLM Provider Configuration
-- ============================================================================
-- Purpose:
--   - Store runtime LLM provider configuration outside the property/platform
--     integration registry.
--   - Keep API key values encrypted in secrets; this table stores only pointers
--     plus non-secret provider/model settings.
-- ============================================================================

CREATE TABLE IF NOT EXISTS llm_providers (
    id BIGSERIAL PRIMARY KEY,
    provider_key TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    enabled BOOLEAN NOT NULL DEFAULT FALSE,
    use_case TEXT NOT NULL DEFAULT 'message_classifier',
    api_base_url TEXT NULL,
    api_key_secret_id BIGINT NULL,
    selected_model TEXT NOT NULL,
    allowed_models JSONB NOT NULL DEFAULT '[]'::jsonb,
    timeout_seconds INT NOT NULL DEFAULT 60,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_llm_providers_provider_key_non_blank
        CHECK (btrim(provider_key) <> ''),
    CONSTRAINT chk_llm_providers_display_name_non_blank
        CHECK (btrim(display_name) <> ''),
    CONSTRAINT chk_llm_providers_selected_model_non_blank
        CHECK (btrim(selected_model) <> ''),
    CONSTRAINT chk_llm_providers_allowed_models_array
        CHECK (jsonb_typeof(allowed_models) = 'array'),
    CONSTRAINT chk_llm_providers_timeout_range
        CHECK (timeout_seconds BETWEEN 1 AND 600),
    CONSTRAINT chk_llm_providers_metadata_object
        CHECK (jsonb_typeof(metadata) = 'object')
);

CREATE INDEX IF NOT EXISTS idx_llm_providers_active_use_case
ON llm_providers (use_case, enabled, is_active);

CREATE OR REPLACE FUNCTION set_llm_providers_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_llm_providers_updated_at ON llm_providers;
CREATE TRIGGER trg_llm_providers_updated_at
BEFORE UPDATE ON llm_providers
FOR EACH ROW
EXECUTE FUNCTION set_llm_providers_updated_at();

INSERT INTO llm_providers (
    provider_key,
    display_name,
    is_active,
    enabled,
    use_case,
    api_base_url,
    api_key_secret_id,
    selected_model,
    allowed_models,
    timeout_seconds,
    metadata
) VALUES (
    'openai',
    'OpenAI',
    TRUE,
    TRUE,
    'message_classifier',
    'https://api.openai.com',
    NULL,
    'gpt-5-nano',
    '["gpt-5-nano", "gpt-5-mini", "gpt-5.1-mini"]'::jsonb,
    60,
    '{"credential": {"label": "API Key", "auth_type": "Bearer Token"}}'::jsonb
)
ON CONFLICT (provider_key) DO UPDATE
SET
    display_name = EXCLUDED.display_name,
    is_active = EXCLUDED.is_active,
    enabled = CASE
        WHEN llm_providers.enabled IS NULL THEN EXCLUDED.enabled
        ELSE llm_providers.enabled
    END,
    use_case = EXCLUDED.use_case,
    api_base_url = EXCLUDED.api_base_url,
    selected_model = COALESCE(NULLIF(llm_providers.selected_model, ''), EXCLUDED.selected_model),
    allowed_models = CASE
        WHEN jsonb_array_length(llm_providers.allowed_models) = 0 THEN EXCLUDED.allowed_models
        ELSE llm_providers.allowed_models
    END,
    timeout_seconds = COALESCE(llm_providers.timeout_seconds, EXCLUDED.timeout_seconds),
    metadata = llm_providers.metadata || EXCLUDED.metadata;

INSERT INTO llm_providers (
    provider_key,
    display_name,
    is_active,
    enabled,
    use_case,
    api_base_url,
    api_key_secret_id,
    selected_model,
    allowed_models,
    timeout_seconds,
    metadata
) VALUES (
    'ollama',
    'Ollama',
    TRUE,
    FALSE,
    'message_classifier',
    'http://host.docker.internal:11550',
    NULL,
    'llama3.2:3b',
    '["llama3.2:3b", "llama3.2:1b"]'::jsonb,
    120,
    '{"credential": {"required": false, "label": "No API key required", "auth_type": "none"}}'::jsonb
)
ON CONFLICT (provider_key) DO UPDATE
SET
    display_name = EXCLUDED.display_name,
    is_active = EXCLUDED.is_active,
    use_case = EXCLUDED.use_case,
    api_base_url = COALESCE(NULLIF(llm_providers.api_base_url, ''), EXCLUDED.api_base_url),
    selected_model = COALESCE(NULLIF(llm_providers.selected_model, ''), EXCLUDED.selected_model),
    allowed_models = CASE
        WHEN jsonb_array_length(llm_providers.allowed_models) = 0 THEN EXCLUDED.allowed_models
        ELSE llm_providers.allowed_models
    END,
    timeout_seconds = COALESCE(llm_providers.timeout_seconds, EXCLUDED.timeout_seconds),
    metadata = llm_providers.metadata || EXCLUDED.metadata;
