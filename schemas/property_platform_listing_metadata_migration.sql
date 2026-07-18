-- ============================================================================
-- PLATFORM PROPERTY LOOKUP LISTING METADATA MIGRATION
-- ============================================================================
-- Run against an existing auto_pws database that already has:
--   - properties
--   - platform_property_lookup
--
-- Purpose:
--   - Add listing-level `name` and `metadata` columns when missing
--   - Add metadata validation/indexes
--   - Best-effort backfill listing metadata from properties.descrp only when
--     the target lookup row is unambiguous
-- ============================================================================

BEGIN;

DO $$
BEGIN
    IF to_regclass('public.platform_property_lookup') IS NULL THEN
        RAISE EXCEPTION 'Missing table: platform_property_lookup';
    END IF;
    IF to_regclass('public.properties') IS NULL THEN
        RAISE EXCEPTION 'Missing table: properties';
    END IF;
END $$;

ALTER TABLE platform_property_lookup
    ADD COLUMN IF NOT EXISTS name TEXT;

ALTER TABLE platform_property_lookup
    ADD COLUMN IF NOT EXISTS metadata JSONB NOT NULL DEFAULT '{}'::jsonb;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.platform_property_lookup'::regclass
          AND conname = 'chk_platform_property_lookup_metadata_object'
    ) THEN
        ALTER TABLE platform_property_lookup
            ADD CONSTRAINT chk_platform_property_lookup_metadata_object
            CHECK (jsonb_typeof(metadata) = 'object');
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_platform_property_lookup_metadata_gin
ON platform_property_lookup USING GIN (metadata);

WITH lookup_counts AS (
    SELECT properties_ptr, COUNT(*) AS lookup_count
    FROM platform_property_lookup
    GROUP BY properties_ptr
),
backfill_candidates AS (
    SELECT
        ppl.id AS lookup_id,
        ppl.listing_id,
        ppl.name AS existing_name,
        COALESCE(ppl.metadata, '{}'::jsonb) AS existing_metadata,
        p.descrp,
        lc.lookup_count,
        CASE
            WHEN jsonb_typeof(p.descrp->'raw') = 'object'
            THEN NULLIF(BTRIM(p.descrp#>>'{raw,id}'), '')
            ELSE NULL
        END AS raw_listing_id
    FROM platform_property_lookup ppl
    JOIN properties p ON p.id = ppl.properties_ptr
    JOIN lookup_counts lc ON lc.properties_ptr = ppl.properties_ptr
    WHERE ppl.name IS NULL
       OR COALESCE(ppl.metadata, '{}'::jsonb) = '{}'::jsonb
),
resolved_backfill AS (
    SELECT
        bc.lookup_id,
        COALESCE(
            NULLIF(BTRIM(bc.existing_name), ''),
            NULLIF(BTRIM(bc.descrp->>'name'), ''),
            NULLIF(BTRIM(bc.descrp->>'title'), ''),
            NULLIF(BTRIM(bc.descrp->>'label'), '')
        ) AS listing_name,
        jsonb_strip_nulls(
            jsonb_build_object(
                'name',
                    COALESCE(
                        NULLIF(BTRIM(bc.descrp->>'name'), ''),
                        NULLIF(BTRIM(bc.descrp->>'title'), ''),
                        NULLIF(BTRIM(bc.descrp->>'label'), '')
                    ),
                'amenities',
                    CASE
                        WHEN jsonb_typeof(bc.descrp->'amenities') = 'array'
                        THEN bc.descrp->'amenities'
                        WHEN jsonb_typeof(bc.descrp#>'{raw,amenities}') = 'array'
                        THEN bc.descrp#>'{raw,amenities}'
                        WHEN jsonb_typeof(bc.descrp#>'{raw,amenity_call_outs}') = 'array'
                        THEN bc.descrp#>'{raw,amenity_call_outs}'
                        ELSE NULL
                    END,
                'city', NULLIF(BTRIM(bc.descrp->>'city'), ''),
                'state', NULLIF(BTRIM(bc.descrp->>'state'), ''),
                'country', NULLIF(BTRIM(bc.descrp->>'country'), ''),
                'timezone', NULLIF(BTRIM(bc.descrp->>'timezone'), ''),
                'currency_code', NULLIF(BTRIM(bc.descrp->>'currency_code'), ''),
                'public_url', NULLIF(BTRIM(bc.descrp->>'public_url'), ''),
                'raw',
                    CASE
                        WHEN jsonb_typeof(bc.descrp->'raw') = 'object'
                        THEN bc.descrp->'raw'
                        ELSE NULL
                    END
            )
        ) AS listing_metadata
    FROM backfill_candidates bc
    WHERE bc.lookup_count = 1
       OR (bc.raw_listing_id IS NOT NULL AND bc.raw_listing_id = bc.listing_id)
)
UPDATE platform_property_lookup ppl
SET name = COALESCE(ppl.name, rb.listing_name),
    metadata = COALESCE(ppl.metadata, '{}'::jsonb) || rb.listing_metadata,
    updated_at = CURRENT_TIMESTAMP
FROM resolved_backfill rb
WHERE ppl.id = rb.lookup_id
  AND rb.listing_metadata <> '{}'::jsonb;

UPDATE platform_property_lookup
SET metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object('name', name)),
    updated_at = CURRENT_TIMESTAMP
WHERE name IS NOT NULL
  AND NOT (COALESCE(metadata, '{}'::jsonb) ? 'name');

COMMIT;
