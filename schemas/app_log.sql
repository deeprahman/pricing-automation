-- ============================================================
--  n8n Logging System — Database Schema
--  Compatible with: PostgreSQL 13+
--  Run this ONCE before importing the workflow
-- ============================================================

-- Drop table if you want a clean slate (careful in production!)
-- DROP TABLE IF EXISTS app_logs;

CREATE TABLE IF NOT EXISTS app_logs (
    id              BIGSERIAL PRIMARY KEY,

    -- Core log fields
    level           VARCHAR(10)     NOT NULL DEFAULT 'INFO'
                        CHECK (level IN ('DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL')),
    message         TEXT            NOT NULL,

    -- Source context
    source          VARCHAR(100),           -- e.g. 'n8n', 'api-gateway', 'cron-job'
    workflow_id     VARCHAR(100),           -- n8n workflow ID
    workflow_name   VARCHAR(255),           -- human-readable workflow name
    execution_id    VARCHAR(100),           -- n8n execution ID

    -- Payload / metadata (flexible JSON column)
    metadata        JSONB           DEFAULT '{}'::jsonb,

    -- Error details (populated when level = 'ERROR' / 'FATAL')
    error_code      VARCHAR(50),
    error_stack     TEXT,

    -- Request context (optional, useful for HTTP-triggered workflows)
    request_id      VARCHAR(100),
    user_id         VARCHAR(100),
    ip_address      INET,

    -- Timestamps
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

-- ── Indexes ────────────────────────────────────────────────
-- Fast filtering by log level
CREATE INDEX IF NOT EXISTS idx_logs_level
    ON app_logs (level);

-- Fast filtering by time window (most common query pattern)
CREATE INDEX IF NOT EXISTS idx_logs_created_at
    ON app_logs (created_at DESC);

-- Fast filtering by source or workflow
CREATE INDEX IF NOT EXISTS idx_logs_source
    ON app_logs (source);

CREATE INDEX IF NOT EXISTS idx_logs_workflow_name
    ON app_logs (workflow_name);

-- GIN index for flexible JSON metadata queries
CREATE INDEX IF NOT EXISTS idx_logs_metadata
    ON app_logs USING GIN (metadata);

-- Composite: common dashboard query (level + time range)
CREATE INDEX IF NOT EXISTS idx_logs_level_time
    ON app_logs (level, created_at DESC);

-- ── Auto-update `updated_at` ───────────────────────────────
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_logs_updated_at ON app_logs;

CREATE TRIGGER trg_logs_updated_at
    BEFORE UPDATE ON app_logs
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- ── Optional: auto-purge logs older than 90 days ──────────
-- (Requires pg_cron extension. Install separately if needed.)
-- SELECT cron.schedule('purge-old-logs', '0 3 * * *',
--     $$DELETE FROM app_logs WHERE created_at < NOW() - INTERVAL '90 days'$$
-- );

-- ── Verification ──────────────────────────────────────────
SELECT 'app_logs table ready ✓' AS status;