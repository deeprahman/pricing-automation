-- ============================================================================
-- message_thread_primary_classes_position_migration.sql
--
-- Purpose:
--   Extend get_thread_primary_classes(p_platform_id, p_thread_id) so it returns
--   the first message position and platform message id (messages.mid) for each
--   unique primary class in a thread.
--
-- Adds output columns:
--   - class_pos   INT[]     zero-based position of the first message for class
--   - ids_message BIGINT[]  messages.mid of the first message for class
--
-- Notes:
--   - No changes are made to the messages table.
--   - Thread position is computed dynamically from active messages only.
--   - messages.id is used for joins to message_class_lookup.message_id.
--   - messages.mid is returned in ids_message because it is the platform/source
--     message identifier.
--   - Final arrays are ordered by class_name and are aligned by array index.
--
-- Prerequisites:
--   - message_processing.sql
--
-- Safe to re-run: yes.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. Dependency validation
-- ============================================================================
DO $$
BEGIN
    IF to_regclass('public.messages') IS NULL THEN
        RAISE EXCEPTION 'Missing table: messages. Run message_processing.sql first.';
    END IF;

    IF to_regclass('public.message_class_lookup') IS NULL THEN
        RAISE EXCEPTION 'Missing table: message_class_lookup. Run message_processing.sql first.';
    END IF;

    IF to_regclass('public.message_classes') IS NULL THEN
        RAISE EXCEPTION 'Missing table: message_classes. Run message_processing.sql first.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'messages'
          AND column_name = 'mid'
    ) THEN
        RAISE EXCEPTION 'Missing column: messages.mid';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'messages'
          AND column_name = 'message_timestamp'
    ) THEN
        RAISE EXCEPTION 'Missing column: messages.message_timestamp';
    END IF;
END $$;

-- ============================================================================
-- 2. Replace function
--    The return type changes, so DROP is required before CREATE.
-- ============================================================================
DROP FUNCTION IF EXISTS public.get_thread_primary_classes(INT, BIGINT);

CREATE OR REPLACE FUNCTION public.get_thread_primary_classes(
    p_platform_id INT,
    p_thread_id BIGINT
)
RETURNS TABLE (
    platform_id INT,
    thread_id BIGINT,
    classes TEXT[],
    class_pos INT[],
    ids_message BIGINT[]
)
LANGUAGE sql
STABLE
AS $$
    WITH ordered_messages AS (
        SELECT
            m.id AS message_id,
            m.mid AS message_mid,
            (
                ROW_NUMBER() OVER (
                    ORDER BY m.message_timestamp ASC, m.mid ASC, m.id ASC
                ) - 1
            )::INT AS message_pos
        FROM public.messages m
        WHERE m.platform_id = p_platform_id
          AND m.thread_id = p_thread_id
          AND m.deleted_at IS NULL
    ),
    class_hits AS (
        SELECT
            mc.name AS class_name,
            om.message_pos,
            om.message_mid,
            om.message_id
        FROM ordered_messages om
        JOIN public.message_class_lookup mcl
          ON mcl.message_id = om.message_id
         AND mcl.is_primary = TRUE
        JOIN public.message_classes mc
          ON mc.id = mcl.class_id
        WHERE mc.name IS NOT NULL
    ),
    first_class_hits AS (
        SELECT DISTINCT ON (class_name)
            class_name,
            message_pos,
            message_mid
        FROM class_hits
        ORDER BY class_name ASC, message_pos ASC, message_mid ASC, message_id ASC
    )
    SELECT
        p_platform_id AS platform_id,
        p_thread_id AS thread_id,
        COALESCE(array_agg(class_name ORDER BY class_name ASC), ARRAY[]::TEXT[]) AS classes,
        COALESCE(array_agg(message_pos ORDER BY class_name ASC), ARRAY[]::INT[]) AS class_pos,
        COALESCE(array_agg(message_mid ORDER BY class_name ASC), ARRAY[]::BIGINT[]) AS ids_message
    FROM first_class_hits;
$$;

-- ============================================================================
-- 3. Signature verification
-- ============================================================================
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'get_thread_primary_classes'
          AND p.pronargs = 2
    ) THEN
        RAISE EXCEPTION 'Failed to create get_thread_primary_classes(INT, BIGINT)';
    END IF;

    RAISE NOTICE 'OK: get_thread_primary_classes now returns classes, class_pos, and ids_message.';
END $$;

COMMIT;
