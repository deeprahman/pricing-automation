-- ============================================================================
-- MESSAGE CLASSIFICATION + SEARCH SCHEMA
-- ============================================================================
-- Purpose:
--   - Store platform messages grouped into threads
--   - Assign one primary class (plus optional secondary tags) per message
--   - Track current processing status per message
--   - Support fast "thread contains class" queries
--   - Soft-delete unclassified messages after processing
--
-- Notes:
--   - Threads are scoped within platform_id.
--   - platform_id is stored as INT and may be an external identifier.
--     We add a best-effort FK to platforms(id) only if platforms exists
--     in the same database at install time.
-- ============================================================================

-- ============================================
-- 1. ENUMERATIONS
-- ============================================

DROP TYPE IF EXISTS message_processing_state CASCADE;
CREATE TYPE message_processing_state AS ENUM (
    'pending',
    'processing',
    'completed',
    'failed'
);

DROP TYPE IF EXISTS message_class_source CASCADE;
CREATE TYPE message_class_source AS ENUM (
    'auto',
    'human'
);

-- ============================================
-- 2. TRIGGER FUNCTIONS
-- ============================================

CREATE OR REPLACE FUNCTION mcs_set_modified_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.modified_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION mcs_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================
-- 3. TABLES
-- ============================================

-- Tracks per-thread fetch progress for message pagination
DROP TABLE IF EXISTS message_thread_progress CASCADE;
CREATE TABLE message_thread_progress (
    platform_id INT NOT NULL,
    thread_id BIGINT NOT NULL,
    booking_id BIGINT NOT NULL,
    last_seen_mid BIGINT NULL,
    last_seen_date_utc TIMESTAMPTZ NULL,
    "offset" INT NOT NULL DEFAULT 0,
    "limit" INT NOT NULL DEFAULT 20,
    total INT NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_message_thread_progress PRIMARY KEY (platform_id, thread_id),
    CONSTRAINT chk_message_thread_progress_offset CHECK ("offset" >= 0),
    CONSTRAINT chk_message_thread_progress_limit CHECK ("limit" > 0),
    CONSTRAINT chk_message_thread_progress_total CHECK (total >= 0)
);

CREATE INDEX idx_message_thread_progress_booking
ON message_thread_progress (booking_id);

DROP TRIGGER IF EXISTS trg_message_thread_progress_set_updated_at ON message_thread_progress;
CREATE TRIGGER trg_message_thread_progress_set_updated_at
BEFORE UPDATE ON message_thread_progress
FOR EACH ROW
EXECUTE FUNCTION mcs_set_updated_at();

-- ============================================
-- 3.1 HELPER FUNCTIONS
-- ============================================

-- Thread progress helpers: fetch / upsert / delete
-- get_thread_progress_row(p_platform_id, p_thread_id)
--   - Returns the matching message_thread_progress row as JSONB or NULL when missing.
-- set_thread_progress_row(p_data JSONB)
--   - Expects JSON keys: platform_id, thread_id, booking_id (required);
--     last_seen_mid, last_seen_date_utc, offset, limit, total (optional).
--   - Inserts or updates the row; returns (platform_id, thread_id).
-- del_thread_progress_row(p_platform_id, p_thread_id)
--   - Deletes the matching row; returns TRUE when a row was removed, else FALSE.

CREATE OR REPLACE FUNCTION get_thread_progress_row(
    p_platform_id INT,
    p_thread_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_row JSONB;
BEGIN
    SELECT row_to_json(mtp)::jsonb
    INTO v_row
    FROM message_thread_progress mtp
    WHERE mtp.platform_id = p_platform_id
      AND mtp.thread_id = p_thread_id;

    RETURN v_row;
END;
$$;

CREATE OR REPLACE FUNCTION set_thread_progress_row(
    p_data JSONB
)
RETURNS TABLE(platform_id INT, thread_id BIGINT)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_platform_id INT := (p_data->>'platform_id')::INT;
    v_thread_id   BIGINT := (p_data->>'thread_id')::BIGINT;
    v_booking_id  BIGINT := (p_data->>'booking_id')::BIGINT;
    v_last_seen_mid BIGINT := NULLIF(p_data->>'last_seen_mid', '')::BIGINT;
    v_last_seen_date_utc TIMESTAMPTZ := NULLIF(p_data->>'last_seen_date_utc', '')::TIMESTAMPTZ;
    v_offset INT := COALESCE(NULLIF(p_data->>'offset', '')::INT, 0);
    v_limit INT := COALESCE(NULLIF(p_data->>'limit', '')::INT, 20);
    v_total INT := COALESCE(NULLIF(p_data->>'total', '')::INT, 0);
BEGIN
    IF v_platform_id IS NULL OR v_thread_id IS NULL OR v_booking_id IS NULL THEN
        RAISE EXCEPTION 'platform_id, thread_id, and booking_id are required in set_thread_progress_row()';
    END IF;

    INSERT INTO message_thread_progress (
        platform_id, thread_id, booking_id, last_seen_mid, last_seen_date_utc, "offset", "limit", total
    )
    VALUES (
        v_platform_id, v_thread_id, v_booking_id, v_last_seen_mid, v_last_seen_date_utc, v_offset, v_limit, v_total
    )
    ON CONFLICT ON CONSTRAINT pk_message_thread_progress DO UPDATE
    SET booking_id = EXCLUDED.booking_id,
        last_seen_mid = EXCLUDED.last_seen_mid,
        last_seen_date_utc = EXCLUDED.last_seen_date_utc,
        "offset" = EXCLUDED."offset",
        "limit" = EXCLUDED."limit",
        total = EXCLUDED.total;

    RETURN QUERY SELECT v_platform_id, v_thread_id;
END;
$$;

CREATE OR REPLACE FUNCTION del_thread_progress_row(
    p_platform_id INT,
    p_thread_id BIGINT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_deleted INT;
BEGIN
    DELETE FROM message_thread_progress
    WHERE platform_id = p_platform_id
      AND thread_id = p_thread_id;

    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    RETURN v_deleted > 0;
END;
$$;

-- Core message store (ingestion)
DROP TABLE IF EXISTS messages CASCADE;
CREATE TABLE messages (
    id BIGSERIAL PRIMARY KEY,

    platform_id INT NOT NULL,
    thread_id BIGINT NOT NULL,
    mid BIGINT NOT NULL,

    content TEXT NOT NULL,
    message_timestamp TIMESTAMPTZ NOT NULL,
    previous_message_id BIGINT NULL,

    metadata JSONB NOT NULL DEFAULT '{}'::JSONB,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    modified_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    deleted_at TIMESTAMPTZ NULL,
    deleted_reason TEXT NULL,

    CONSTRAINT uq_messages_platform_thread_mid UNIQUE (platform_id, thread_id, mid),
    CONSTRAINT fk_messages_previous_message
        FOREIGN KEY (previous_message_id)
        REFERENCES messages(id)
        ON DELETE SET NULL
);

CREATE INDEX idx_messages_platform_thread
ON messages (platform_id, thread_id);

-- Optimizes "thread contains class" queries while ignoring soft-deleted messages.
CREATE INDEX idx_messages_platform_thread_active
ON messages (platform_id, thread_id)
WHERE deleted_at IS NULL;

CREATE INDEX idx_messages_thread_order
ON messages (platform_id, thread_id, message_timestamp DESC);

-- Optimizes the default guest-only unclassified scan path.
CREATE INDEX IF NOT EXISTS idx_messages_from_role_active
ON messages ((metadata->>'from_role'), id)
WHERE deleted_at IS NULL;

-- Index to accelerate created_at + id scans on active messages.
CREATE INDEX IF NOT EXISTS idx_messages_created_at_active
ON messages (created_at, id)
WHERE deleted_at IS NULL;

CREATE TRIGGER trg_messages_set_modified_at
BEFORE UPDATE ON messages
FOR EACH ROW
EXECUTE FUNCTION mcs_set_modified_at();

-- Class registry (hierarchical taxonomy)
DROP TABLE IF EXISTS message_classes CASCADE;
CREATE TABLE message_classes (
    id BIGSERIAL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    description TEXT NOT NULL,
    parent_id BIGINT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT fk_message_classes_parent
        FOREIGN KEY (parent_id)
        REFERENCES message_classes(id)
        ON DELETE SET NULL
);

COMMENT ON COLUMN message_classes.description IS
    'Describes the purpose of the class; this description may be used elsewhere.';

CREATE INDEX idx_message_classes_parent
ON message_classes (parent_id);

CREATE TRIGGER trg_message_classes_set_updated_at
BEFORE UPDATE ON message_classes
FOR EACH ROW
EXECUTE FUNCTION mcs_set_updated_at();

-- Classification records (one primary + optional secondary tags)
DROP TABLE IF EXISTS message_class_lookup CASCADE;
CREATE TABLE message_class_lookup (
    id BIGSERIAL PRIMARY KEY,
    message_id BIGINT NOT NULL,
    class_id BIGINT NOT NULL,

    is_primary BOOLEAN NOT NULL DEFAULT FALSE,
    source message_class_source NOT NULL DEFAULT 'auto',
    confidence NUMERIC(4,3) NULL,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_message_class_lookup_message
        FOREIGN KEY (message_id)
        REFERENCES messages(id)
        ON DELETE CASCADE,
    CONSTRAINT fk_message_class_lookup_class
        FOREIGN KEY (class_id)
        REFERENCES message_classes(id)
        ON DELETE RESTRICT,
    CONSTRAINT uq_message_class_lookup UNIQUE (message_id, class_id),
    CONSTRAINT chk_message_class_confidence
        CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1))
);

-- Enforce exactly one primary class at most (0..1) per message.
CREATE UNIQUE INDEX uq_message_class_primary_per_message
ON message_class_lookup (message_id)
WHERE is_primary = TRUE;

CREATE INDEX idx_message_class_lookup_message
ON message_class_lookup (message_id);

CREATE INDEX idx_message_class_lookup_message_primary
ON message_class_lookup (message_id)
WHERE is_primary = TRUE;

CREATE INDEX idx_message_class_lookup_class_message
ON message_class_lookup (class_id, message_id);

-- Returns unique primary class names for active messages in a thread.
CREATE OR REPLACE FUNCTION get_thread_primary_classes(
    p_platform_id INT,
    p_thread_id BIGINT
)
RETURNS TABLE (
    platform_id INT,
    thread_id BIGINT,
    classes TEXT[]
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        p_platform_id AS platform_id,
        p_thread_id AS thread_id,
        COALESCE(
            array_agg(DISTINCT mc.name ORDER BY mc.name)
                FILTER (WHERE mc.name IS NOT NULL),
            ARRAY[]::TEXT[]
        ) AS classes
    FROM messages m
    LEFT JOIN message_class_lookup mcl
      ON mcl.message_id = m.id
     AND mcl.is_primary = TRUE
    LEFT JOIN message_classes mc
      ON mc.id = mcl.class_id
    WHERE m.platform_id = p_platform_id
      AND m.thread_id = p_thread_id
      AND m.deleted_at IS NULL;
$$;

-- Current processing status (current-only)
DROP TABLE IF EXISTS message_processing_status CASCADE;
CREATE TABLE message_processing_status (
    message_id BIGINT PRIMARY KEY,
    status message_processing_state NOT NULL DEFAULT 'pending',
    last_error TEXT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT fk_message_processing_status_message
        FOREIGN KEY (message_id)
        REFERENCES messages(id)
        ON DELETE CASCADE
);

CREATE INDEX idx_message_processing_status_status_updated
ON message_processing_status (status, updated_at DESC);

CREATE TRIGGER trg_message_processing_status_set_updated_at
BEFORE UPDATE ON message_processing_status
FOR EACH ROW
EXECUTE FUNCTION mcs_set_updated_at();

-- Convenience: create a status row automatically on message ingest.
CREATE OR REPLACE FUNCTION mcs_init_message_status()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO message_processing_status (message_id, status)
    VALUES (NEW.id, 'pending')
    ON CONFLICT (message_id) DO NOTHING;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_messages_init_status ON messages;
CREATE TRIGGER trg_messages_init_status
AFTER INSERT ON messages
FOR EACH ROW
EXECUTE FUNCTION mcs_init_message_status();

-- Reset processing state when message content changes.
CREATE OR REPLACE FUNCTION mcs_reset_message_status_on_content_change()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO message_processing_status (message_id, status, last_error)
    VALUES (NEW.id, 'pending', NULL)
    ON CONFLICT (message_id) DO UPDATE
    SET status = 'pending',
        last_error = NULL;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_messages_reset_status_on_content_change ON messages;
CREATE TRIGGER trg_messages_reset_status_on_content_change
AFTER UPDATE OF content ON messages
FOR EACH ROW
WHEN (OLD.content IS DISTINCT FROM NEW.content)
EXECUTE FUNCTION mcs_reset_message_status_on_content_change();

CREATE OR REPLACE FUNCTION store_message_items(
    p_data JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_platform_id INT := (p_data->>'platform_id')::INT;
    v_thread_id BIGINT := (p_data->>'thread_id')::BIGINT;
    v_booking_id BIGINT := (p_data->>'booking_id')::BIGINT;
    v_items JSONB := COALESCE(p_data->'items', '[]'::JSONB);
    v_processed_count INT := 0;
BEGIN
    IF v_platform_id IS NULL OR v_thread_id IS NULL OR v_booking_id IS NULL THEN
        RAISE EXCEPTION 'platform_id, thread_id, and booking_id are required in store_message_items()';
    END IF;

    IF jsonb_typeof(v_items) <> 'array' THEN
        RAISE EXCEPTION 'items must be a JSON array in store_message_items()';
    END IF;

    INSERT INTO messages (
        platform_id,
        thread_id,
        mid,
        content,
        message_timestamp,
        metadata
    )
    SELECT
        v_platform_id,
        v_thread_id,
        (item->>'id')::BIGINT,
        item->>'body',
        (item->>'date_utc')::TIMESTAMPTZ,
        jsonb_strip_nulls(
            jsonb_build_object(
                'booking_id', v_booking_id,
                'from_role', item->>'from_role',
                'from_contact_id', NULLIF(item->>'from_contact_id', '')::BIGINT,
                'is_draft', CASE
                    WHEN item ? 'is_draft' THEN (item->>'is_draft')::BOOLEAN
                    ELSE NULL
                END
            )
        )
    FROM jsonb_array_elements(v_items) AS item
    ON CONFLICT (platform_id, thread_id, mid) DO UPDATE
    SET content = EXCLUDED.content,
        message_timestamp = EXCLUDED.message_timestamp,
        metadata = EXCLUDED.metadata;

    GET DIAGNOSTICS v_processed_count = ROW_COUNT;

    RETURN jsonb_build_object(
        'processed_count', v_processed_count,
        'platform_id', v_platform_id,
        'thread_id', v_thread_id,
        'booking_id', v_booking_id
    );
END;
$$;

-- Fetch pending messages and atomically claim them for processing.
-- Parameters:
--   p_limit : max rows to claim
--   p_from_role : optional sender role filter; NULL claims all roles
--
-- Notes:
-- - Ignores message_class_lookup and uses message_processing_status as the source of truth.
-- - Claims only active rows whose status is pending.
-- - FOR UPDATE SKIP LOCKED avoids double-picking under concurrency.
DROP FUNCTION IF EXISTS fetch_unclassified_messages(integer);
CREATE OR REPLACE FUNCTION fetch_unclassified_messages(
    p_limit integer,
    p_from_role text DEFAULT NULL
)
RETURNS TABLE (
    message_id      bigint,
    content         text
)
LANGUAGE plpgsql
VOLATILE
AS $$
BEGIN
    IF p_limit IS NULL OR p_limit < 1 THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH candidates AS (
        SELECT mps.message_id
        FROM message_processing_status mps
        JOIN messages m
          ON m.id = mps.message_id
        WHERE m.deleted_at IS NULL
          AND mps.status = 'pending'
          AND btrim(m.content) <> ''
          AND (p_from_role IS NULL OR m.metadata->>'from_role' = p_from_role)
        ORDER BY m.id ASC
        LIMIT p_limit
        FOR UPDATE OF mps SKIP LOCKED
    ),
    claimed AS (
        UPDATE message_processing_status mps
        SET status = 'processing',
            last_error = NULL
        FROM candidates c
        WHERE mps.message_id = c.message_id
        RETURNING mps.message_id
    )
    SELECT m.id AS message_id,
           m.content
    FROM claimed c
    JOIN messages m
      ON m.id = c.message_id
    ORDER BY m.id ASC;
END;
$$;

-- Reset stale processing rows so they can be claimed again.
CREATE OR REPLACE FUNCTION requeue_stale_processing_messages(
    p_stale_after interval DEFAULT '15 minutes'
)
RETURNS TABLE (
    message_id bigint
)
LANGUAGE sql
VOLATILE
AS $$
    WITH reclaimed AS (
        UPDATE message_processing_status mps
        SET status = 'pending',
            last_error = 'processing timeout'
        WHERE mps.status = 'processing'
          AND mps.updated_at < clock_timestamp() - COALESCE(p_stale_after, '15 minutes'::interval)
        RETURNING mps.message_id
    )
    SELECT r.message_id
    FROM reclaimed r
    ORDER BY r.message_id ASC;
$$;

-- ============================================
-- 4. BEST-EFFORT FK TO PLATFORMS (OPTIONAL)
-- ============================================

DO $$
BEGIN
    -- If platforms exists in this DB, enforce referential integrity.
    IF to_regclass('platforms') IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1
            FROM pg_constraint
            WHERE conname = 'fk_messages_platform'
        ) THEN
            EXECUTE 'ALTER TABLE messages ' ||
                    'ADD CONSTRAINT fk_messages_platform ' ||
                    'FOREIGN KEY (platform_id) REFERENCES platforms(id) ' ||
                    'ON DELETE RESTRICT';
        END IF;
    END IF;
END $$;
