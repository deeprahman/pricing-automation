-- ============================================
-- SPECIAL OPERATION ASSIGNER TABLES MODULE
-- Version: 1.0
-- Run AFTER:
--   1) schemas/property_platform_sql.sql
--   2) schemas/booking_registers.sql
--   3) schemas/secure_task_scheduler.sql
--   4) schemas/message_processing.sql
--   5) schemas/pricing-engine.sql
-- ============================================

-- ============================================
-- 1. DEPENDENCY VALIDATION
-- ============================================

DO $$
BEGIN
    IF to_regclass('public.booking_registers') IS NULL THEN
        RAISE EXCEPTION 'Missing table: booking_registers. Run schemas/booking_registers.sql first.';
    END IF;
    IF to_regclass('public.task_queue') IS NULL THEN
        RAISE EXCEPTION 'Missing table: task_queue. Run schemas/secure_task_scheduler.sql first.';
    END IF;
    IF to_regclass('public.platforms') IS NULL THEN
        RAISE EXCEPTION 'Missing table: platforms. Run schemas/property_platform_sql.sql first.';
    END IF;
    IF to_regclass('public.message_classes') IS NULL THEN
        RAISE EXCEPTION 'Missing table: message_classes. Run schemas/message_processing.sql first.';
    END IF;
    IF to_regclass('public.pricing_operation_types') IS NULL THEN
        RAISE EXCEPTION 'Missing table: pricing_operation_types. Run schemas/pricing-engine.sql first.';
    END IF;
    IF to_regclass('public.pricing_rules') IS NULL THEN
        RAISE EXCEPTION 'Missing table: pricing_rules. Run schemas/pricing-engine.sql first.';
    END IF;
END $$;


-- ============================================
-- 2. MESSAGE CLASS -> OPERATION MAPPING
-- ============================================

CREATE TABLE IF NOT EXISTS class_operation_mapping (
    id BIGSERIAL PRIMARY KEY,
    class_id BIGINT NOT NULL REFERENCES message_classes(id) ON DELETE CASCADE,
    operation_type_id BIGINT NOT NULL REFERENCES pricing_operation_types(id) ON DELETE RESTRICT,
    description TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (class_id, operation_type_id)
);

CREATE INDEX IF NOT EXISTS idx_class_operation_mapping_class_active
ON class_operation_mapping (class_id, is_active)
WHERE is_active = TRUE;

CREATE INDEX IF NOT EXISTS idx_class_operation_mapping_operation_active
ON class_operation_mapping (operation_type_id, is_active)
WHERE is_active = TRUE;


-- ============================================
-- 3. SOA APPLIED RULE REGISTER
-- ============================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_type
        WHERE typname = 'applied_rule_status'
    ) THEN
        CREATE TYPE applied_rule_status AS ENUM ('processing', 'applied', 'removed', 'failed');
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS booking_applied_rules (
    id BIGSERIAL PRIMARY KEY,

    -- Booking context
    booking_entry_id BIGINT NOT NULL REFERENCES booking_registers(id) ON DELETE CASCADE,
    property_id BIGINT NOT NULL,
    platform_id INT NOT NULL REFERENCES platforms(id) ON DELETE RESTRICT,
    listing_id TEXT NOT NULL,

    -- Rule reference
    rule_uuid UUID NOT NULL REFERENCES pricing_rules(rule_uuid) ON DELETE RESTRICT,
    trigger_category TEXT NOT NULL,

    -- Exact instruction sent to external service worker
    instruction JSONB NOT NULL,

    -- Lifecycle
    status applied_rule_status NOT NULL DEFAULT 'processing',
    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    removed_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Audit links
    applied_by_task_id BIGINT REFERENCES task_queue(id) ON DELETE SET NULL,
    removed_by_task_id BIGINT REFERENCES task_queue(id) ON DELETE SET NULL,

    CONSTRAINT chk_bar_instruction_object
        CHECK (jsonb_typeof(instruction) = 'object')
);

DO $$
BEGIN
    IF to_regclass('public.booking_applied_rules') IS NOT NULL
       AND EXISTS (
           SELECT 1
           FROM information_schema.columns
           WHERE table_schema = 'public'
             AND table_name = 'booking_applied_rules'
             AND column_name = 'platform_property_id'
       )
       AND NOT EXISTS (
           SELECT 1
           FROM information_schema.columns
           WHERE table_schema = 'public'
             AND table_name = 'booking_applied_rules'
             AND column_name = 'listing_id'
       ) THEN
        ALTER TABLE booking_applied_rules
        RENAME COLUMN platform_property_id TO listing_id;
    END IF;
END $$;

CREATE OR REPLACE FUNCTION set_booking_applied_rules_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_booking_applied_rules_updated_at ON booking_applied_rules;
CREATE TRIGGER trg_booking_applied_rules_updated_at
BEFORE UPDATE ON booking_applied_rules
FOR EACH ROW
EXECUTE FUNCTION set_booking_applied_rules_updated_at();

-- Primary lookup for SOA removal instruction generation
CREATE INDEX IF NOT EXISTS idx_bar_booking_category
ON booking_applied_rules (booking_entry_id, trigger_category, status);

-- Platform-pair lookup
CREATE INDEX IF NOT EXISTS idx_bar_platform_pair
ON booking_applied_rules (booking_entry_id, property_id, platform_id, status);

-- Rule lookup
CREATE INDEX IF NOT EXISTS idx_bar_rule_uuid
ON booking_applied_rules (rule_uuid);

CREATE INDEX IF NOT EXISTS idx_bar_status_updated_id
ON booking_applied_rules (status, updated_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_bar_booking_status_updated_id
ON booking_applied_rules (booking_entry_id, status, updated_at DESC, id DESC);

CREATE OR REPLACE FUNCTION find_booking_applied_instructions_active(
    p_property_id BIGINT DEFAULT NULL,
    p_platform_id INT DEFAULT NULL,
    p_listing_id TEXT DEFAULT NULL
) RETURNS SETOF booking_applied_rules AS $$
DECLARE
    v_listing_id TEXT := NULLIF(BTRIM(p_listing_id), '');
BEGIN
    IF p_property_id IS NULL
       AND p_platform_id IS NULL
       AND v_listing_id IS NULL THEN
        RAISE EXCEPTION 'at least one filter is required: property_id or (platform_id and listing_id)'
            USING ERRCODE = '22023';
    END IF;

    IF (p_platform_id IS NULL AND v_listing_id IS NOT NULL)
       OR (p_platform_id IS NOT NULL AND v_listing_id IS NULL) THEN
        RAISE EXCEPTION 'platform_id and listing_id must be provided together'
            USING ERRCODE = '22023';
    END IF;

    RETURN QUERY
    SELECT bar.*
    FROM booking_applied_rules bar
    WHERE bar.status = 'applied'
      AND COALESCE((bar.instruction->>'remove')::BOOLEAN, FALSE) = FALSE
      AND (p_property_id IS NULL OR bar.property_id = p_property_id)
      AND (
          p_platform_id IS NULL
          OR (
              bar.platform_id = p_platform_id
              AND bar.listing_id = v_listing_id
          )
      )
    ORDER BY bar.id DESC;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION find_booking_applied_rules_audit(
    p_booking_entry_id BIGINT DEFAULT NULL,
    p_status TEXT DEFAULT NULL,
    p_updated_from DATE DEFAULT NULL,
    p_updated_to DATE DEFAULT NULL,
    p_limit INT DEFAULT 100,
    p_cursor BIGINT DEFAULT NULL
) RETURNS SETOF booking_applied_rules AS $$
DECLARE
    v_limit INT := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500);
    v_status TEXT := NULLIF(BTRIM(p_status), '');
BEGIN
    RETURN QUERY
    SELECT bar.*
    FROM booking_applied_rules bar
    WHERE (p_booking_entry_id IS NULL OR bar.booking_entry_id = p_booking_entry_id)
      AND (
          (v_status IS NULL AND bar.status IN ('applied', 'removed'))
          OR (v_status IS NOT NULL AND bar.status = v_status::applied_rule_status)
      )
      AND (p_updated_from IS NULL OR bar.updated_at >= p_updated_from::TIMESTAMPTZ)
      AND (p_updated_to IS NULL OR bar.updated_at < (p_updated_to + 1)::TIMESTAMPTZ)
      AND (p_cursor IS NULL OR bar.id < p_cursor)
    ORDER BY bar.id DESC
    LIMIT v_limit;
END;
$$ LANGUAGE plpgsql STABLE;


-- ============================================
-- 4. ORIGINAL NIGHTLY RATE SNAPSHOTS
-- ============================================

CREATE TABLE IF NOT EXISTS nightlyrates_listing (
    ppl_id BIGINT NOT NULL REFERENCES platform_property_lookup(id) ON DELETE CASCADE,
    date DATE NOT NULL,
    rate NUMERIC(12,2) NOT NULL,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    PRIMARY KEY (ppl_id, date),
    CONSTRAINT chk_nightlyrates_listing_metadata_object
        CHECK (jsonb_typeof(metadata) = 'object')
);

CREATE INDEX IF NOT EXISTS idx_nightlyrates_listing_date
ON nightlyrates_listing (date);

DO $$
BEGIN
    IF to_regclass('public.baserates') IS NOT NULL THEN
        INSERT INTO nightlyrates_listing (ppl_id, date, rate, metadata)
        SELECT
            br.ppl_id,
            (rate_row->>'date')::DATE,
            (COALESCE(rate_row->>'baserate', rate_row->>'rate'))::NUMERIC(12,2),
            jsonb_strip_nulls(
                jsonb_build_object(
                    'legacy_source_table', 'baserates',
                    'legacy_booking_id', b.booking_id
                )
            )
        FROM baserates b
        JOIN booking_registers br ON br.id = b.booking_id
        CROSS JOIN LATERAL jsonb_array_elements(COALESCE(b.rates, '[]'::jsonb)) AS rate_row
        WHERE jsonb_typeof(rate_row) = 'object'
          AND rate_row ? 'date'
          AND COALESCE(rate_row->>'baserate', rate_row->>'rate') IS NOT NULL
          AND (rate_row->>'date') ~ '^\d{4}-\d{2}-\d{2}$'
          AND COALESCE(rate_row->>'baserate', rate_row->>'rate') ~ '^-?[0-9]+(\.[0-9]+)?$'
        ON CONFLICT (ppl_id, date) DO NOTHING;

        DROP TABLE baserates;
    END IF;
END $$;

DROP FUNCTION IF EXISTS set_baserates_updated_at() CASCADE;

CREATE OR REPLACE FUNCTION get_nightlyrates_listing(
    p_platform_id INT DEFAULT NULL,
    p_listing_id TEXT DEFAULT NULL,
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL
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
        ORDER BY nrl.date ASC, nrl.ppl_id ASC
        $fmt$,
        v_listing_column,
        v_listing_column
    );

    RETURN QUERY EXECUTE v_sql
    USING p_platform_id, v_listing_id, p_start_date, p_end_date;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION cleanup_expired_nightlyrates_listing(
    p_retention_days INT DEFAULT 90
) RETURNS BIGINT AS $$
DECLARE
    v_deleted BIGINT := 0;
BEGIN
    IF p_retention_days IS NULL OR p_retention_days < 1 THEN
        RAISE EXCEPTION 'retention_days must be >= 1'
            USING ERRCODE = '22023';
    END IF;

    DELETE FROM nightlyrates_listing
    WHERE date < (CURRENT_DATE - p_retention_days);

    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    RETURN v_deleted;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION ensure_nightlyrates_listing_cleanup_schedule(
    p_job_name TEXT DEFAULT 'nightlyrates-listing-cleanup-90d',
    p_cron TEXT DEFAULT '15 3 * * *',
    p_retention_days INT DEFAULT 90
) RETURNS TEXT AS $$
DECLARE
    v_job_id BIGINT;
    v_command TEXT;
BEGIN
    IF to_regclass('cron.job') IS NULL THEN
        RETURN 'pg_cron extension is not installed; schedule not created';
    END IF;

    IF p_retention_days IS NULL OR p_retention_days < 1 THEN
        RAISE EXCEPTION 'retention_days must be >= 1'
            USING ERRCODE = '22023';
    END IF;

    v_command := format(
        'SELECT cleanup_expired_nightlyrates_listing(%s);',
        p_retention_days
    );

    EXECUTE 'SELECT jobid FROM cron.job WHERE jobname = $1 LIMIT 1'
    INTO v_job_id
    USING p_job_name;

    IF v_job_id IS NOT NULL THEN
        EXECUTE 'SELECT cron.unschedule($1::bigint)'
        USING v_job_id;
    END IF;

    EXECUTE format(
        'SELECT cron.schedule($1, $2, %L)',
        v_command
    )
    INTO v_job_id
    USING p_job_name, p_cron;

    RETURN format('scheduled %s (job id %s)', p_job_name, v_job_id);
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
    PERFORM ensure_nightlyrates_listing_cleanup_schedule();
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'nightlyrates_listing cleanup schedule setup skipped: %', SQLERRM;
END $$;
