-- ============================================================================
-- nightlyrates_listing_remove_metadata_rate_type_migration.sql
--
-- Purpose:
--   Remove metadata.rate_type from nightlyrates_listing and rely solely on the
--   dedicated rate_type column for all rate-type semantics.
--
-- Safe to re-run: yes.
-- ============================================================================

DO $$
BEGIN
    IF to_regclass('public.nightlyrates_listing') IS NULL THEN
        RAISE EXCEPTION 'Missing table: nightlyrates_listing. Run special_operation_assigner_tables.sql first.';
    END IF;
END $$;

ALTER TABLE nightlyrates_listing
    DROP CONSTRAINT IF EXISTS chk_nightlyrates_listing_metadata_rate_type;

UPDATE nightlyrates_listing
SET metadata = CASE
    WHEN jsonb_typeof(COALESCE(metadata, '{}'::jsonb)) = 'object' THEN
        COALESCE(metadata, '{}'::jsonb) - 'rate_type'
    ELSE
        '{}'::jsonb
END
WHERE jsonb_typeof(COALESCE(metadata, '{}'::jsonb)) <> 'object'
   OR (COALESCE(metadata, '{}'::jsonb) ? 'rate_type');
