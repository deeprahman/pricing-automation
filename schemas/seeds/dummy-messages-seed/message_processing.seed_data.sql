-- ============================================================================
-- Dummy Fixture Seed (Message Ingestion Stage)
--
-- Simulates internal message ingestion only:
--   - inserts/upserts messages via store_message_items
--   - inserts/updates message_thread_progress via set_thread_progress_row
--
-- No final message classifications are written here.
-- ============================================================================

BEGIN;

DO $$
BEGIN
    IF to_regclass('public.booking_registers') IS NULL THEN
        RAISE EXCEPTION 'Missing table: booking_registers. Run booking_registers.sql first.';
    END IF;

    IF to_regclass('public.messages') IS NULL THEN
        RAISE EXCEPTION 'Missing table: messages. Run message_processing.sql first.';
    END IF;

    IF to_regclass('public.message_class_lookup') IS NULL THEN
        RAISE EXCEPTION 'Missing table: message_class_lookup. Run message_processing.sql first.';
    END IF;

    IF to_regclass('public.message_processing_status') IS NULL THEN
        RAISE EXCEPTION 'Missing table: message_processing_status. Run message_processing.sql first.';
    END IF;

    IF to_regclass('public.message_thread_progress') IS NULL THEN
        RAISE EXCEPTION 'Missing table: message_thread_progress. Run message_processing.sql first.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'store_message_items'
          AND p.pronargs = 1
    ) THEN
        RAISE EXCEPTION 'Missing function: store_message_items(JSONB).';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'set_thread_progress_row'
          AND p.pronargs = 1
    ) THEN
        RAISE EXCEPTION 'Missing function: set_thread_progress_row(JSONB).';
    END IF;
END $$;

WITH pms AS (
    SELECT id AS platform_id FROM public.platforms WHERE name = 'OwnerRez'
), target_messages AS (
    SELECT m.id
    FROM public.messages m
    JOIN pms ON pms.platform_id = m.platform_id
    WHERE m.thread_id BETWEEN 94000001 AND 94000120
       OR m.thread_id BETWEEN 95100001 AND 95100030
)
DELETE FROM public.message_class_lookup mcl
USING target_messages tm
WHERE mcl.message_id = tm.id;

WITH pms AS (
    SELECT id AS platform_id FROM public.platforms WHERE name = 'OwnerRez'
), target_messages AS (
    SELECT m.id
    FROM public.messages m
    JOIN pms ON pms.platform_id = m.platform_id
    WHERE m.thread_id BETWEEN 94000001 AND 94000120
       OR m.thread_id BETWEEN 95100001 AND 95100030
)
DELETE FROM public.message_processing_status mps
USING target_messages tm
WHERE mps.message_id = tm.id;

WITH pms AS (
    SELECT id AS platform_id FROM public.platforms WHERE name = 'OwnerRez'
)
DELETE FROM public.message_thread_progress mtp
USING pms
WHERE mtp.platform_id = pms.platform_id
  AND (
      mtp.thread_id BETWEEN 94000001 AND 94000120
      OR mtp.thread_id BETWEEN 95100001 AND 95100030
  );

WITH pms AS (
    SELECT id AS platform_id FROM public.platforms WHERE name = 'OwnerRez'
)
DELETE FROM public.messages m
USING pms
WHERE m.platform_id = pms.platform_id
  AND (
      m.thread_id BETWEEN 94000001 AND 94000120
      OR m.thread_id BETWEEN 95100001 AND 95100030
  );

WITH
    pms AS (
        SELECT id AS platform_id FROM public.platforms WHERE name = 'OwnerRez'
    ),
    target_bookings AS (
        SELECT
            br.id AS booking_id,
            (br.thread_ids_json->>0)::bigint AS thread_id,
            CASE
                WHEN br.id BETWEEN 54000001 AND 54000120 THEN 'extension'
                WHEN br.id BETWEEN 55000001 AND 55000030 THEN 'static'
                ELSE 'other'
            END AS cohort,
            CASE
                WHEN br.id BETWEEN 54000001 AND 54000120 THEN (br.id - 54000000)::int
                WHEN br.id BETWEEN 55000001 AND 55000030 THEN (br.id - 55000000)::int
                ELSE 0
            END AS n,
            pms.platform_id
        FROM public.booking_registers br
        CROSS JOIN pms
        WHERE br.id BETWEEN 54000001 AND 54000120
           OR br.id BETWEEN 55000001 AND 55000030
    )
SELECT public.store_message_items(
    jsonb_build_object(
        'platform_id', tb.platform_id,
        'thread_id', tb.thread_id,
        'booking_id', tb.booking_id,
        'items', jsonb_build_array(
            jsonb_build_object(
                'id', CASE
                    WHEN tb.cohort = 'extension' THEN (97000000 + (tb.n * 10) + 1)
                    ELSE (98000000 + (tb.n * 10) + 1)
                END,
                'body', 'Booking confirmation for seed booking ' || tb.booking_id::text,
                'date_utc', to_char(CURRENT_TIMESTAMP - INTERVAL '3 days', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                'from_role', 'guest'
            ),
            jsonb_build_object(
                'id', CASE
                    WHEN tb.cohort = 'extension' THEN (97000000 + (tb.n * 10) + 2)
                    ELSE (98000000 + (tb.n * 10) + 2)
                END,
                'body', 'Fixture scenario message for seed booking ' || tb.booking_id::text,
                'date_utc', to_char(CURRENT_TIMESTAMP - INTERVAL '2 days', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                'from_role', 'guest'
            )
        )
    )
)
FROM target_bookings tb
WHERE tb.cohort IN ('extension', 'static');

WITH pms AS (
    SELECT id AS platform_id FROM public.platforms WHERE name = 'OwnerRez'
)
UPDATE public.messages m
SET metadata = COALESCE(m.metadata, '{}'::jsonb) || jsonb_build_object(
        'seed', 'dummy_messages_seed_v2',
        'message_kind', CASE WHEN (m.mid % 10) = 1 THEN 'confirmation' ELSE 'scenario' END,
        'fixture_booking_id', (m.metadata->>'booking_id')::bigint
    )
FROM pms
WHERE m.platform_id = pms.platform_id
  AND (
      m.thread_id BETWEEN 94000001 AND 94000120
      OR m.thread_id BETWEEN 95100001 AND 95100030
  );

WITH
    pms AS (
        SELECT id AS platform_id FROM public.platforms WHERE name = 'OwnerRez'
    ),
    target_bookings AS (
        SELECT
            br.id AS booking_id,
            (br.thread_ids_json->>0)::bigint AS thread_id,
            CASE
                WHEN br.id BETWEEN 54000001 AND 54000120 THEN 'extension'
                ELSE 'static'
            END AS cohort,
            CASE
                WHEN br.id BETWEEN 54000001 AND 54000120 THEN (br.id - 54000000)::int
                ELSE (br.id - 55000000)::int
            END AS n,
            pms.platform_id
        FROM public.booking_registers br
        CROSS JOIN pms
        WHERE br.id BETWEEN 54000001 AND 54000120
           OR br.id BETWEEN 55000001 AND 55000030
    )
SELECT public.set_thread_progress_row(
    jsonb_build_object(
        'platform_id', tb.platform_id,
        'thread_id', tb.thread_id,
        'booking_id', tb.booking_id,
        'last_seen_mid', CASE
            WHEN tb.cohort = 'extension' THEN (97000000 + (tb.n * 10) + 2)
            ELSE (98000000 + (tb.n * 10) + 2)
        END,
        'last_seen_date_utc', CURRENT_TIMESTAMP,
        'offset', 0,
        'limit', 20,
        'total', 2
    )
)
FROM target_bookings tb;

COMMIT;
