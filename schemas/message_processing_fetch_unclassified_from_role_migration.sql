-- message_processing_fetch_unclassified_from_role_migration.sql
-- Adds optional from_role filtering to fetch_unclassified_messages() without rebuilding data.

BEGIN;

CREATE INDEX IF NOT EXISTS idx_messages_from_role_active
ON messages ((metadata->>'from_role'), id)
WHERE deleted_at IS NULL;

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

COMMIT;
