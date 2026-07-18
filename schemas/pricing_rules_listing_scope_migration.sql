-- ============================================================================
-- PRICING RULES — LISTING-LEVEL SCOPE MIGRATION
-- ============================================================================
-- Purpose:
--   Extend pricing_rules to support a fourth scope level: 'listing'.
--   A listing-scoped rule targets one specific platform_property_lookup
--   row (i.e. one listing on one platform), taking precedence over all
--   broader scopes during price calculation.
--
-- Scope hierarchy after this migration (highest → lowest priority):
--   listing  → platform_property_lookup_id IS NOT NULL
--   property → property_id IS NOT NULL
--   platform → platform_id IS NOT NULL
--   global   → all NULL
--
-- Prerequisites:
--   - pricing-engine.sql           (pricing_rules table must exist)
--   - property_platform_sql.sql    (platform_property_lookup must exist)
--
-- Safe to re-run: all steps use IF EXISTS / IF NOT EXISTS guards.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. DEPENDENCY VALIDATION
-- ----------------------------------------------------------------------------

DO $$
BEGIN
    IF to_regclass('public.pricing_rules') IS NULL THEN
        RAISE EXCEPTION
            'Missing table: pricing_rules. Run pricing-engine.sql first.';
    END IF;

    IF to_regclass('public.platform_property_lookup') IS NULL THEN
        RAISE EXCEPTION
            'Missing table: platform_property_lookup. Run property_platform_sql.sql first.';
    END IF;
END $$;


-- ----------------------------------------------------------------------------
-- 2. ADD platform_property_lookup_id COLUMN
--    RESTRICT on delete: a listing must be explicitly de-linked from rules
--    before it can be removed, preventing silent orphan rules.
-- ----------------------------------------------------------------------------

ALTER TABLE pricing_rules
    ADD COLUMN IF NOT EXISTS platform_property_lookup_id BIGINT
        REFERENCES platform_property_lookup(id) ON DELETE RESTRICT;


-- ----------------------------------------------------------------------------
-- 3. REBUILD THE GENERATED scope COLUMN
--    PostgreSQL does not support ALTER on a GENERATED ALWAYS column.
--    We must drop and recreate it with the new CASE expression.
-- ----------------------------------------------------------------------------

-- 3a. Drop dependent index first (it references the scope column)
DROP INDEX IF EXISTS idx_pricing_rules_scope;

-- 3b. Drop the old generated column
ALTER TABLE pricing_rules DROP COLUMN IF EXISTS scope;

-- 3c. Re-add with 'listing' at the top of the hierarchy
ALTER TABLE pricing_rules
    ADD COLUMN scope VARCHAR(20) GENERATED ALWAYS AS (
        CASE
            WHEN platform_property_lookup_id IS NOT NULL THEN 'listing'
            WHEN property_id IS NOT NULL                 THEN 'property'
            WHEN platform_id IS NOT NULL                 THEN 'platform'
            ELSE                                              'global'
        END
    ) STORED;


-- ----------------------------------------------------------------------------
-- 4. REPLACE THE SCOPE HIERARCHY CONSTRAINT
--    New rule: listing scope requires property_id and platform_id on the
--    pricing_rules row to both be NULL — all location context comes from
--    the platform_property_lookup FK, preventing any inconsistency.
-- ----------------------------------------------------------------------------

ALTER TABLE pricing_rules
    DROP CONSTRAINT IF EXISTS valid_scope_hierarchy;

ALTER TABLE pricing_rules
    ADD CONSTRAINT valid_scope_hierarchy CHECK (
        -- Listing: lookup FK set; property/platform on the rule must be NULL
        (   platform_property_lookup_id IS NOT NULL
            AND property_id IS NULL
            AND platform_id IS NULL
        ) OR
        -- Property: can optionally narrow further by platform
        (   property_id IS NOT NULL
            AND platform_property_lookup_id IS NULL
        ) OR
        -- Platform-wide: no property, no listing
        (   platform_id IS NOT NULL
            AND property_id IS NULL
            AND platform_property_lookup_id IS NULL
        ) OR
        -- Global: everything NULL
        (   property_id IS NULL
            AND platform_id IS NULL
            AND platform_property_lookup_id IS NULL
        )
    );


-- ----------------------------------------------------------------------------
-- 5. INDEXES
-- ----------------------------------------------------------------------------

-- Recreate the general scope index (was dropped in step 3a)
CREATE INDEX IF NOT EXISTS idx_pricing_rules_scope
    ON pricing_rules (scope, priority DESC, id ASC)
    WHERE status = 'active';

-- Dedicated index for listing-scope lookups (primary access path for SOA /
-- price-calculation when resolving rules for a specific listing)
CREATE INDEX IF NOT EXISTS idx_pricing_rules_listing
    ON pricing_rules (platform_property_lookup_id, status, priority DESC)
    WHERE status = 'active'
      AND platform_property_lookup_id IS NOT NULL;


-- ----------------------------------------------------------------------------
-- 6. SMOKE-TEST — verify the new structure looks correct
--    Rolled back automatically; output visible in psql / migration logs.
-- ----------------------------------------------------------------------------

DO $$
DECLARE
    v_scope_col_exists   BOOLEAN;
    v_fk_col_exists      BOOLEAN;
    v_constraint_exists  BOOLEAN;
    v_listing_idx_exists BOOLEAN;
    v_scope_idx_exists   BOOLEAN;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'pricing_rules'
          AND column_name = 'platform_property_lookup_id'
    ) INTO v_fk_col_exists;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'pricing_rules'
          AND column_name = 'scope'
    ) INTO v_scope_col_exists;

    SELECT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'public.pricing_rules'::regclass
          AND conname  = 'valid_scope_hierarchy'
    ) INTO v_constraint_exists;

    SELECT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE tablename = 'pricing_rules'
          AND indexname  = 'idx_pricing_rules_listing'
    ) INTO v_listing_idx_exists;

    SELECT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE tablename = 'pricing_rules'
          AND indexname  = 'idx_pricing_rules_scope'
    ) INTO v_scope_idx_exists;

    IF NOT v_fk_col_exists     THEN RAISE EXCEPTION 'FAIL: platform_property_lookup_id column missing'; END IF;
    IF NOT v_scope_col_exists  THEN RAISE EXCEPTION 'FAIL: scope column missing';                       END IF;
    IF NOT v_constraint_exists THEN RAISE EXCEPTION 'FAIL: valid_scope_hierarchy constraint missing';   END IF;
    IF NOT v_listing_idx_exists THEN RAISE EXCEPTION 'FAIL: idx_pricing_rules_listing index missing';   END IF;
    IF NOT v_scope_idx_exists  THEN RAISE EXCEPTION 'FAIL: idx_pricing_rules_scope index missing';      END IF;

    RAISE NOTICE 'OK: pricing_rules listing-scope migration verified successfully.';
END $$;


COMMIT;


-- ============================================================================
-- USAGE EXAMPLES
-- ============================================================================

/*
-- Create a listing-scoped pricing rule
-- (platform_property_lookup_id = 42, which already encodes property + platform)
SELECT create_pricing_rule(
    'sk_abc123...',
    NULL,           -- property_id  → NULL for listing scope
    NULL,           -- platform_id  → NULL for listing scope
    'increase',
    '{
        "subject": "price",
        "operation": {
            "do": "+ increase",
            "type": "percentage",
            "amount": 25
        }
    }'::JSONB,
    NULL,
    '2025-06-01',
    '2025-08-31',
    96,             -- weekends (Sat=32 + Sun=64)
    75,
    'Summer Premium — Listing 42'
);
-- Then set platform_property_lookup_id manually (or extend create_pricing_rule):
UPDATE pricing_rules
SET platform_property_lookup_id = 42
WHERE rule_name = 'Summer Premium — Listing 42';

-- Query all active rules for a specific listing, ordered by priority
SELECT
    pr.rule_uuid,
    pr.scope,
    pr.rule_name,
    pr.priority,
    pr.rule_config,
    ppl.listing_id,
    ppl.name AS listing_name
FROM pricing_rules pr
JOIN platform_property_lookup ppl
  ON ppl.id = pr.platform_property_lookup_id
WHERE pr.platform_property_lookup_id = 42
  AND pr.status = 'active'
ORDER BY pr.priority DESC;

-- Full rule resolution for a listing (listing → property → platform → global)
SELECT
    pr.rule_uuid,
    pr.scope,
    pr.priority,
    pr.rule_config
FROM pricing_rules pr
JOIN platform_property_lookup ppl
  ON ppl.id = pr.platform_property_lookup_id
WHERE pr.status = 'active'
  AND (
      pr.platform_property_lookup_id = 42              -- listing
      OR pr.property_id  = ppl.properties_ptr          -- property
      OR pr.platform_id  = ppl.platform_id             -- platform
      OR (pr.property_id IS NULL
          AND pr.platform_id IS NULL
          AND pr.platform_property_lookup_id IS NULL)  -- global
  )
ORDER BY pr.scope = 'listing'  DESC,
         pr.scope = 'property' DESC,
         pr.scope = 'platform' DESC,
         pr.scope = 'global'   DESC,
         pr.priority DESC;
*/

-- ============================================================================
-- END OF MIGRATION
-- ============================================================================
