-- Backfill Wheelhouse listing metadata so provider-required channel is available
-- at top level while preserving the original imported API payload under raw.

UPDATE platform_property_lookup ppl
SET metadata = jsonb_set(
        COALESCE(ppl.metadata, '{}'::jsonb),
        '{channel}',
        to_jsonb(NULLIF(BTRIM(ppl.metadata #>> '{raw,channel}'), '')),
        true
    ),
    updated_at = CURRENT_TIMESTAMP
FROM platforms p
WHERE p.id = ppl.platform_id
  AND LOWER(p.name) = 'wheelhouse'
  AND NOT (COALESCE(ppl.metadata, '{}'::jsonb) ? 'channel')
  AND NULLIF(BTRIM(ppl.metadata #>> '{raw,channel}'), '') IS NOT NULL;

