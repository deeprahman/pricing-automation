-- ============================================================================
-- DEFAULT MESSAGE CLASSES
-- ============================================================================
-- Run AFTER: message_processing.sql
--
-- Installs the baseline message classification categories required by the
-- messaging workers and admin UI. These are reference defaults, not demo data.
-- ============================================================================

DO $$
BEGIN
    IF to_regclass('public.message_classes') IS NULL THEN
        RAISE EXCEPTION 'Missing table: message_classes. Run message_processing.sql first.';
    END IF;
END $$;

INSERT INTO message_classes (name, description, parent_id, is_active) VALUES
    (
        'booking_initiation',
        'Messages indicating initial interest or intent to book. Keywords: interested, want to book, reserve, visiting',
        NULL,
        TRUE
    ),
    (
        'booking_confirmation',
        'Messages containing booking confirmation details with check-in/check-out dates. Keywords: Confirmation, Check-in, Check-out',
        NULL,
        TRUE
    ),
    (
        'checkout',
        'Messages related to departure, vacating, or returning keys. Keywords: checkout, return, vacated',
        NULL,
        TRUE
    ),
    (
        'job_related',
        'Indicates the stay is related to work or business purposes (e.g., job assignments, work teams, business travel, or project-based stays).',
        NULL,
        TRUE
    ),
    (
        'medical_related',
        'A message indicates the stay is for medical reasons (e.g., procedures, treatment, recovery, or patient care).',
        NULL,
        TRUE
    ),
    (
        'stay_extension_related',
        'Indicates the guest is requesting, considering, or discussing extending their current stay.',
        NULL,
        TRUE
    ),
    (
        'pet_related',
        'A message indicates the guest has pets or emotional support animals accompanying them during the stay.',
        NULL,
        TRUE
    ),
    (
        'house_hunting_related',
        'A message clearly indicates the guest is staying in a short-term rental property while actively seeking permanent housing—such as applying for a lease, touring properties, meeting landlords or agents, awaiting approval, or staying between leases. The classification applies only when the guest''s temporary stay is explicitly linked to their search for long-term accommodation, not for general vacation or leisure purposes.',
        NULL,
        TRUE
    ),
    (
        'insurance_claim_related',
        'A message indicates the stay is due to an insurance claim (e.g., displacement, repairs, or temporary housing covered by insurance).',
        NULL,
        TRUE
    ),
    (
        'unclassified',
        'Default category for messages that do not match any defined classification patterns. Used when no keywords or patterns from other categories are detected.',
        NULL,
        TRUE
    )
ON CONFLICT (name) DO UPDATE
    SET description = EXCLUDED.description,
        parent_id   = EXCLUDED.parent_id,
        is_active   = EXCLUDED.is_active,
        updated_at  = NOW();