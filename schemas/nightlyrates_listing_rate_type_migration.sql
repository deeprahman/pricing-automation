-- ============================================================================
-- nightlyrates_listing_rate_type_migration.sql
--
-- Purpose:
--   Extend nightlyrates_listing snapshots to support multiple baseline rate
--   types per (listing, date): base, recommended, minimum, maximum.
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
    ADD COLUMN IF NOT EXISTS rate_type TEXT;

UPDATE nightlyrates_listing
SET rate_type = LOWER(
    COALESCE(
        NULLIF(BTRIM(metadata->>'rate_type'), ''),
        'base'
    )
)
WHERE rate_type IS NULL;

UPDATE nightlyrates_listing
SET rate_type = CASE
    WHEN LOWER(rate_type) IN ('base', 'recommended', 'minimum', 'maximum') THEN LOWER(rate_type)
    ELSE 'base'
END;

ALTER TABLE nightlyrates_listing
    ALTER COLUMN rate_type SET NOT NULL;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'nightlyrates_listing_pkey'
          AND conrelid = 'public.nightlyrates_listing'::regclass
    ) THEN
        ALTER TABLE nightlyrates_listing
            DROP CONSTRAINT nightlyrates_listing_pkey;
    END IF;
END $$;

ALTER TABLE nightlyrates_listing
    ADD CONSTRAINT nightlyrates_listing_pkey PRIMARY KEY (ppl_id, date, rate_type);

ALTER TABLE nightlyrates_listing
    DROP CONSTRAINT IF EXISTS chk_nightlyrates_listing_rate_type;

ALTER TABLE nightlyrates_listing
    ADD CONSTRAINT chk_nightlyrates_listing_rate_type
    CHECK (rate_type IN ('base', 'recommended', 'minimum', 'maximum'));

ALTER TABLE nightlyrates_listing
    DROP CONSTRAINT IF EXISTS chk_nightlyrates_listing_metadata_rate_type;

ALTER TABLE nightlyrates_listing
    ADD CONSTRAINT chk_nightlyrates_listing_metadata_rate_type
    CHECK (
        jsonb_typeof(metadata) = 'object'
        AND (metadata ? 'rate_type')
        AND LOWER(metadata->>'rate_type') = rate_type
    );

UPDATE nightlyrates_listing
SET metadata = jsonb_set(
        COALESCE(metadata, '{}'::jsonb),
        '{rate_type}',
        to_jsonb(rate_type),
        true
    );

CREATE INDEX IF NOT EXISTS idx_nightlyrates_listing_ppl_date_rate_type
ON nightlyrates_listing (ppl_id, date, rate_type);

CREATE INDEX IF NOT EXISTS idx_nightlyrates_listing_date_rate_type
ON nightlyrates_listing (date, rate_type);

DROP FUNCTION IF EXISTS get_nightlyrates_listing(
    INT,
    TEXT,
    DATE,
    DATE
);

CREATE OR REPLACE FUNCTION get_nightlyrates_listing(
    p_platform_id INT DEFAULT NULL,
    p_listing_id TEXT DEFAULT NULL,
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL,
    p_rate_type TEXT DEFAULT 'base'
) RETURNS TABLE (
    ppl_id BIGINT,
    platform_id INT,
    listing_id TEXT,
    date DATE,
    rate NUMERIC(12,2),
    metadata JSONB
) AS $$
DECLARE
    v_listing_id TEXT := NULLIF(BTRIM(p_listing_id), '');
    v_rate_type TEXT := LOWER(COALESCE(NULLIF(BTRIM(p_rate_type), ''), 'base'));
    v_listing_column TEXT;
    v_sql TEXT;
BEGIN
    IF (p_platform_id IS NULL AND v_listing_id IS NOT NULL)
       OR (p_platform_id IS NOT NULL AND v_listing_id IS NULL) THEN
        RAISE EXCEPTION 'platform_id and listing_id must be provided together'
            USING ERRCODE = '22023';
    END IF;

    IF p_start_date IS NOT NULL
       AND p_end_date IS NOT NULL
       AND p_start_date > p_end_date THEN
        RAISE EXCEPTION 'start_date cannot be after end_date'
            USING ERRCODE = '22007';
    END IF;

    IF p_platform_id IS NULL
       AND p_start_date IS NULL
       AND p_end_date IS NULL THEN
        RAISE EXCEPTION 'at least one filter is required: (platform_id and listing_id) or date range'
            USING ERRCODE = '22023';
    END IF;

    IF v_rate_type NOT IN ('base', 'recommended', 'minimum', 'maximum') THEN
        RAISE EXCEPTION 'invalid rate_type: %', v_rate_type
            USING ERRCODE = '22023';
    END IF;

    SELECT column_name
    INTO v_listing_column
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'platform_property_lookup'
      AND column_name IN ('listing_id', 'platform_property_id')
    ORDER BY CASE column_name WHEN 'listing_id' THEN 0 ELSE 1 END
    LIMIT 1;

    IF v_listing_column IS NULL THEN
        RAISE EXCEPTION 'platform_property_lookup listing identifier column is missing';
    END IF;

    v_sql := format(
        $fmt$
        SELECT
            nrl.ppl_id,
            ppl.platform_id,
            ppl.%I::TEXT AS listing_id,
            nrl.date,
            nrl.rate,
            nrl.metadata
        FROM nightlyrates_listing nrl
        JOIN platform_property_lookup ppl
          ON ppl.id = nrl.ppl_id
        WHERE ($1::INT IS NULL OR ppl.platform_id = $1::INT)
          AND ($2::TEXT IS NULL OR ppl.%I::TEXT = $2::TEXT)
          AND ($3::DATE IS NULL OR nrl.date >= $3::DATE)
          AND ($4::DATE IS NULL OR nrl.date <= $4::DATE)
          AND nrl.rate_type = $5::TEXT
        ORDER BY nrl.date ASC, nrl.ppl_id ASC
        $fmt$,
        v_listing_column,
        v_listing_column
    );

    RETURN QUERY EXECUTE v_sql
    USING p_platform_id, v_listing_id, p_start_date, p_end_date, v_rate_type;
END;
$$ LANGUAGE plpgsql STABLE;
