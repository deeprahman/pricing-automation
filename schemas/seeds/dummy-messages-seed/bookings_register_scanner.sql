-- ============================================================================
-- Dummy Fixture Seed (Scanner States)
--
-- Applies extension-scanner metadata states and needs_scan overrides over the
-- 54000001..54000120 cohort from bookings_register_base.sql.
-- ============================================================================

BEGIN;

DO $$
BEGIN
    IF to_regclass('public.booking_registers') IS NULL THEN
        RAISE EXCEPTION 'Missing table: booking_registers. Run booking_registers.sql first.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'booking_registers'
          AND column_name = 'needs_scan'
    ) THEN
        RAISE EXCEPTION 'Missing column: booking_registers.needs_scan. Run needs-scan migrations first.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'mark_booking_register_extension_needs_scan'
          AND p.pronargs = 1
    ) THEN
        RAISE EXCEPTION 'Missing function: mark_booking_register_extension_needs_scan(BIGINT).';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'mark_booking_register_extension_scanned'
          AND p.pronargs = 1
    ) THEN
        RAISE EXCEPTION 'Missing function: mark_booking_register_extension_scanned(BIGINT).';
    END IF;

    IF (SELECT COUNT(*) FROM public.booking_registers WHERE id BETWEEN 54000001 AND 54000120) < 120 THEN
        RAISE EXCEPTION 'Expected base cohort 54000001..54000120. Run bookings_register_base.sql first.';
    END IF;
END $$;

UPDATE public.booking_registers br
SET metadata = COALESCE(br.metadata, '{}'::jsonb)
    || jsonb_build_object(
        'bso',
        COALESCE(br.metadata->'bso', '{}'::jsonb)
        || jsonb_build_object(
            'potential_extension',
            COALESCE(br.metadata->'bso'->'potential_extension', '{}'::jsonb)
            || jsonb_build_object('last_extended', to_jsonb(br.updated_at - INTERVAL '1 day'))
        )
    )
WHERE br.id BETWEEN 54000001 AND 54000030;

UPDATE public.booking_registers br
SET metadata = COALESCE(br.metadata, '{}'::jsonb)
    || jsonb_build_object(
        'bso',
        COALESCE(br.metadata->'bso', '{}'::jsonb)
        || jsonb_build_object(
            'potential_extension',
            COALESCE(br.metadata->'bso'->'potential_extension', '{}'::jsonb)
            || jsonb_build_object('last_extended', to_jsonb(br.updated_at))
        )
    )
WHERE br.id BETWEEN 54000031 AND 54000040;

UPDATE public.booking_registers br
SET metadata = COALESCE(br.metadata, '{}'::jsonb)
    || jsonb_build_object(
        'bso',
        COALESCE(br.metadata->'bso', '{}'::jsonb)
        || jsonb_build_object(
            'potential_extension',
            COALESCE(br.metadata->'bso'->'potential_extension', '{}'::jsonb)
            || jsonb_build_object('last_extended', to_jsonb(br.updated_at + INTERVAL '1 day'))
        )
    )
WHERE br.id BETWEEN 54000041 AND 54000060;

-- Keep rows 54000061..54000090 without last_extended.
UPDATE public.booking_registers br
SET metadata = br.metadata #- '{bso,potential_extension,last_extended}'
WHERE br.id BETWEEN 54000061 AND 54000090;

-- Outside-window rows intentionally carry mixed last_extended relations.
UPDATE public.booking_registers br
SET metadata = COALESCE(br.metadata, '{}'::jsonb)
    || jsonb_build_object(
        'bso',
        COALESCE(br.metadata->'bso', '{}'::jsonb)
        || jsonb_build_object(
            'potential_extension',
            COALESCE(br.metadata->'bso'->'potential_extension', '{}'::jsonb)
            || jsonb_build_object(
                'last_extended',
                CASE
                    WHEN br.id BETWEEN 54000091 AND 54000098 THEN to_jsonb(br.updated_at - INTERVAL '1 day')
                    WHEN br.id BETWEEN 54000099 AND 54000105 THEN to_jsonb(br.updated_at + INTERVAL '1 day')
                    WHEN br.id BETWEEN 54000106 AND 54000113 THEN to_jsonb(br.updated_at - INTERVAL '1 day')
                    ELSE to_jsonb(br.updated_at + INTERVAL '1 day')
                END
            )
        )
    )
WHERE br.id BETWEEN 54000091 AND 54000120;

WITH targets AS (
    SELECT id
    FROM public.booking_registers
    WHERE id BETWEEN 54000001 AND 54000120
)
SELECT public.mark_booking_register_extension_scanned(id)
FROM targets;

WITH targets AS (
    SELECT id
    FROM public.booking_registers
    WHERE id BETWEEN 54000001 AND 54000120
      AND COALESCE((metadata->>'target_needs_scan')::smallint, 0) = 1
)
SELECT public.mark_booking_register_extension_needs_scan(id)
FROM targets;

COMMIT;
