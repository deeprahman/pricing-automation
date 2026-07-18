-- ============================================================================
-- POST-CLASSIFICATION SEED — Rocky Creek L4 live future booking threads
-- ============================================================================
-- Applies targeted primary classifications and completed processing status to
-- the live future-booking message set created by:
--   schemas/seeds/db-live/test_data_future_bookings_seed.sql
-- ============================================================================

BEGIN;

DO $$
DECLARE
    v_missing_classes TEXT;
    v_missing_messages TEXT;
BEGIN
    IF to_regclass('public.messages') IS NULL THEN
        RAISE EXCEPTION 'Missing table: messages. Install schemas/message_processing.sql first.';
    END IF;
    IF to_regclass('public.message_classes') IS NULL THEN
        RAISE EXCEPTION 'Missing table: message_classes. Install schemas/message_processing.sql first.';
    END IF;
    IF to_regclass('public.message_class_lookup') IS NULL THEN
        RAISE EXCEPTION 'Missing table: message_class_lookup. Install schemas/message_processing.sql first.';
    END IF;
    IF to_regclass('public.message_processing_status') IS NULL THEN
        RAISE EXCEPTION 'Missing table: message_processing_status. Install schemas/message_processing.sql first.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM platforms WHERE name = 'OwnerRez') THEN
        RAISE EXCEPTION 'OwnerRez platform not found. Run the live listing seed first.';
    END IF;

    WITH required_classes(name) AS (
        VALUES
            ('booking_confirmation'),
            ('checkout'),
            ('job_related'),
            ('medical_related'),
            ('unclassified')
    )
    SELECT string_agg(rc.name, ', ' ORDER BY rc.name)
      INTO v_missing_classes
      FROM required_classes rc
     WHERE NOT EXISTS (
         SELECT 1
         FROM message_classes mc
         WHERE mc.name = rc.name
     );

    IF v_missing_classes IS NOT NULL THEN
        RAISE EXCEPTION 'Required live fixture message classes are missing: %', v_missing_classes;
    END IF;

    WITH
        pms AS (
            SELECT id AS platform_id
            FROM platforms
            WHERE name = 'OwnerRez'
        ),
        expected_messages(thread_id, mid) AS (
            VALUES
                (95000001, 97000010),
                (95000001, 97000011),
                (95000001, 97000016),
                (95000001, 97000017),
                (95000002, 97000020),
                (95000002, 97000021),
                (95000002, 97000026),
                (95000002, 97000027),
                (95000003, 97000030),
                (95000003, 97000031),
                (95000003, 97000036),
                (95000004, 97000040),
                (95000004, 97000041),
                (95000004, 97000046),
                (95000004, 97000048)
        ),
        missing AS (
            SELECT format('%s/%s', em.thread_id, em.mid) AS ref
            FROM expected_messages em
            CROSS JOIN pms p
            LEFT JOIN messages m
              ON m.platform_id = p.platform_id
             AND m.thread_id = em.thread_id
             AND m.mid = em.mid
            WHERE m.id IS NULL
        )
    SELECT string_agg(ref, ', ' ORDER BY ref)
      INTO v_missing_messages
      FROM missing;

    IF v_missing_messages IS NOT NULL THEN
        RAISE EXCEPTION 'Expected live fixture messages are missing: %', v_missing_messages;
    END IF;
END $$;

WITH
    pms AS (
        SELECT id AS platform_id
        FROM platforms
        WHERE name = 'OwnerRez'
    ),
    live_messages AS (
        SELECT m.id AS message_id
        FROM messages m
        JOIN pms p ON p.platform_id = m.platform_id
        WHERE (m.thread_id, m.mid) IN (
            (95000001, 97000010),
            (95000001, 97000011),
            (95000001, 97000016),
            (95000001, 97000017),
            (95000002, 97000020),
            (95000002, 97000021),
            (95000002, 97000026),
            (95000002, 97000027),
            (95000003, 97000030),
            (95000003, 97000031),
            (95000003, 97000036),
            (95000004, 97000040),
            (95000004, 97000041),
            (95000004, 97000046),
            (95000004, 97000048)
        )
    )
DELETE FROM message_class_lookup mcl
USING live_messages lm
WHERE mcl.message_id = lm.message_id;

WITH
    pms AS (
        SELECT id AS platform_id
        FROM platforms
        WHERE name = 'OwnerRez'
    ),
    live_messages AS (
        SELECT m.id AS message_id
        FROM messages m
        JOIN pms p ON p.platform_id = m.platform_id
        WHERE (m.thread_id, m.mid) IN (
            (95000001, 97000010),
            (95000001, 97000011),
            (95000001, 97000016),
            (95000001, 97000017),
            (95000002, 97000020),
            (95000002, 97000021),
            (95000002, 97000026),
            (95000002, 97000027),
            (95000003, 97000030),
            (95000003, 97000031),
            (95000003, 97000036),
            (95000004, 97000040),
            (95000004, 97000041),
            (95000004, 97000046),
            (95000004, 97000048)
        )
    )
DELETE FROM message_processing_status mps
USING live_messages lm
WHERE mps.message_id = lm.message_id;

WITH
    pms AS (
        SELECT id AS platform_id
        FROM platforms
        WHERE name = 'OwnerRez'
    ),
    class_ids AS (
        SELECT name, id
        FROM message_classes
        WHERE name IN (
            'booking_confirmation',
            'checkout',
            'job_related',
            'medical_related',
            'unclassified'
        )
    ),
    label_data(thread_id, mid, class_name, confidence) AS (
        VALUES
            (95000001, 97000010, 'booking_confirmation', 0.95),
            (95000001, 97000011, 'unclassified', 0.50),
            (95000001, 97000016, 'unclassified', 0.50),
            (95000001, 97000017, 'medical_related', 0.97),
            (95000002, 97000020, 'booking_confirmation', 0.95),
            (95000002, 97000021, 'unclassified', 0.50),
            (95000002, 97000026, 'unclassified', 0.50),
            (95000002, 97000027, 'job_related', 0.97),
            (95000003, 97000030, 'booking_confirmation', 0.95),
            (95000003, 97000031, 'unclassified', 0.50),
            (95000003, 97000036, 'unclassified', 0.50),
            (95000004, 97000040, 'booking_confirmation', 0.95),
            (95000004, 97000041, 'unclassified', 0.50),
            (95000004, 97000046, 'unclassified', 0.50),
            (95000004, 97000048, 'checkout', 0.95)
    )
INSERT INTO message_class_lookup (message_id, class_id, is_primary, source, confidence)
SELECT
    m.id AS message_id,
    c.id AS class_id,
    TRUE AS is_primary,
    'auto' AS source,
    ld.confidence
FROM label_data ld
JOIN pms p ON TRUE
JOIN messages m
  ON m.platform_id = p.platform_id
 AND m.thread_id = ld.thread_id
 AND m.mid = ld.mid
JOIN class_ids c
  ON c.name = ld.class_name
ON CONFLICT (message_id, class_id) DO UPDATE
SET is_primary = EXCLUDED.is_primary,
    source = EXCLUDED.source,
    confidence = EXCLUDED.confidence;

WITH
    pms AS (
        SELECT id AS platform_id
        FROM platforms
        WHERE name = 'OwnerRez'
    ),
    live_messages AS (
        SELECT m.id AS message_id
        FROM messages m
        JOIN pms p ON p.platform_id = m.platform_id
        WHERE (m.thread_id, m.mid) IN (
            (95000001, 97000010),
            (95000001, 97000011),
            (95000001, 97000016),
            (95000001, 97000017),
            (95000002, 97000020),
            (95000002, 97000021),
            (95000002, 97000026),
            (95000002, 97000027),
            (95000003, 97000030),
            (95000003, 97000031),
            (95000003, 97000036),
            (95000004, 97000040),
            (95000004, 97000041),
            (95000004, 97000046),
            (95000004, 97000048)
        )
    )
INSERT INTO message_processing_status (message_id, status, last_error)
SELECT lm.message_id, 'completed', NULL
FROM live_messages lm
ON CONFLICT (message_id) DO UPDATE
SET status = 'completed',
    last_error = NULL;

COMMIT;
