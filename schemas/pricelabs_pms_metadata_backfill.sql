-- Backfill PriceLabs listing metadata so provider-required PMS is available at
-- top level while preserving the original imported API payload under raw.

UPDATE platform_property_lookup ppl
SET metadata = jsonb_set(
        COALESCE(ppl.metadata, '{}'::jsonb),
        '{pms}',
        to_jsonb(NULLIF(BTRIM(ppl.metadata #>> '{raw,pms}'), '')),
        true
    ),
    updated_at = CURRENT_TIMESTAMP
FROM platforms p
WHERE p.id = ppl.platform_id
  AND LOWER(p.name) = 'pricelabs'
  AND NOT (COALESCE(ppl.metadata, '{}'::jsonb) ? 'pms')
  AND NULLIF(BTRIM(ppl.metadata #>> '{raw,pms}'), '') IS NOT NULL;
