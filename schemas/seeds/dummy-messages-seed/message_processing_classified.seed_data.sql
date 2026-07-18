-- ============================================================================
-- Dummy Fixture Seed (Post-Classification Stage)
--
-- Applies deterministic message classes and marks processing completed for the
-- message rows created by message_processing.seed_data.sql.
-- ============================================================================

BEGIN;

DO $$
BEGIN
    IF to_regclass('public.messages') IS NULL THEN
        RAISE EXCEPTION 'Missing table: messages. Run message_processing.sql first.';
    END IF;

    IF to_regclass('public.message_classes') IS NULL THEN
        RAISE EXCEPTION 'Missing table: message_classes. Run message_processing.sql first.';
    END IF;

    IF to_regclass('public.message_class_lookup') IS NULL THEN
        RAISE EXCEPTION 'Missing table: message_class_lookup. Run message_processing.sql first.';
    END IF;

    IF to_regclass('public.message_processing_status') IS NULL THEN
        RAISE EXCEPTION 'Missing table: message_processing_status. Run message_processing.sql first.';
    END IF;
END $$;

INSERT INTO public.message_classes (name, description, parent_id, is_active)
VALUES
    ('booking_confirmation', 'Seed class for booking confirmation messages.', NULL, TRUE),
    ('possible_stay_extension', 'Seed class for messages that indicate possible stay extension.', NULL, TRUE),
    ('job_related', 'Seed class for job or business related stays.', NULL, TRUE),
    ('medical_related', 'Seed class for medical related stays.', NULL, TRUE),
    ('insurance_related', 'Seed class for insurance related stays.', NULL, TRUE),
    ('checkout', 'Seed class for checkout related messages.', NULL, TRUE),
    ('unclassified', 'Default class when no better message class is available.', NULL, TRUE)
ON CONFLICT (name) DO UPDATE
SET description = EXCLUDED.description,
    parent_id = EXCLUDED.parent_id,
    is_active = TRUE,
    updated_at = NOW();

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

WITH
    pms AS (
        SELECT id AS platform_id FROM public.platforms WHERE name = 'OwnerRez'
    ),
    target_messages AS (
        SELECT
            m.id AS message_id,
            m.mid,
            m.thread_id,
            CASE
                WHEN m.thread_id BETWEEN 94000001 AND 94000120 THEN (m.thread_id - 94000000)::int
                WHEN m.thread_id BETWEEN 95100001 AND 95100030 THEN (m.thread_id - 95100000)::int
                ELSE 0
            END AS n
        FROM public.messages m
        JOIN pms ON pms.platform_id = m.platform_id
        WHERE m.thread_id BETWEEN 94000001 AND 94000120
           OR m.thread_id BETWEEN 95100001 AND 95100030
    ),
    wanted_classes AS (
        SELECT
            tm.message_id,
            CASE
                WHEN (tm.mid % 10) = 1 THEN 'booking_confirmation'
                WHEN ((tm.n - 1) % 6) = 0 THEN 'possible_stay_extension'
                WHEN ((tm.n - 1) % 6) = 1 THEN 'job_related'
                WHEN ((tm.n - 1) % 6) = 2 THEN 'medical_related'
                WHEN ((tm.n - 1) % 6) = 3 THEN 'insurance_related'
                WHEN ((tm.n - 1) % 6) = 4 THEN 'checkout'
                ELSE 'unclassified'
            END AS class_name,
            CASE WHEN (tm.mid % 10) = 1 THEN 0.980 ELSE 0.930 END::numeric(4,3) AS confidence
        FROM target_messages tm
    )
INSERT INTO public.message_class_lookup (message_id, class_id, is_primary, source, confidence)
SELECT
    wc.message_id,
    mc.id,
    TRUE,
    'human',
    wc.confidence
FROM wanted_classes wc
JOIN public.message_classes mc ON mc.name = wc.class_name
ON CONFLICT (message_id, class_id) DO UPDATE
SET is_primary = TRUE,
    source = 'human',
    confidence = EXCLUDED.confidence;

WITH pms AS (
    SELECT id AS platform_id FROM public.platforms WHERE name = 'OwnerRez'
), target_messages AS (
    SELECT m.id
    FROM public.messages m
    JOIN pms ON pms.platform_id = m.platform_id
    WHERE m.thread_id BETWEEN 94000001 AND 94000120
       OR m.thread_id BETWEEN 95100001 AND 95100030
)
INSERT INTO public.message_processing_status (message_id, status, last_error)
SELECT tm.id, 'completed', NULL
FROM target_messages tm
ON CONFLICT (message_id) DO UPDATE
SET status = 'completed',
    last_error = NULL,
    updated_at = NOW();

COMMIT;
