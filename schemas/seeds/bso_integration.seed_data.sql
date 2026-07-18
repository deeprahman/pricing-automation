-- ============================================================================
-- BSO END-TO-END INTEGRATION SEED
-- ============================================================================
-- Run after the postClassification worker fixture. This seed creates isolated
-- booking/message/rule rows for the booking-special-operation lifecycle runner.
-- It intentionally uses booking ids 53000001+ and thread ids 93100001+.
-- ============================================================================

BEGIN;

DO $$
BEGIN
    IF to_regclass('public.platforms') IS NULL THEN
        RAISE EXCEPTION 'Missing table: platforms. Run the base schema first.';
    END IF;
    IF to_regclass('public.platform_property_lookup') IS NULL THEN
        RAISE EXCEPTION 'Missing table: platform_property_lookup. Run the base fixture first.';
    END IF;
    IF to_regclass('public.booking_registers') IS NULL THEN
        RAISE EXCEPTION 'Missing table: booking_registers.';
    END IF;
    IF to_regclass('public.messages') IS NULL THEN
        RAISE EXCEPTION 'Missing table: messages.';
    END IF;
    IF to_regclass('public.message_classes') IS NULL THEN
        RAISE EXCEPTION 'Missing table: message_classes.';
    END IF;
    IF to_regclass('public.message_class_lookup') IS NULL THEN
        RAISE EXCEPTION 'Missing table: message_class_lookup.';
    END IF;
    IF to_regclass('public.message_processing_status') IS NULL THEN
        RAISE EXCEPTION 'Missing table: message_processing_status.';
    END IF;
    IF to_regclass('public.pricing_operation_types') IS NULL THEN
        RAISE EXCEPTION 'Missing table: pricing_operation_types.';
    END IF;
    IF to_regclass('public.pricing_rules') IS NULL THEN
        RAISE EXCEPTION 'Missing table: pricing_rules.';
    END IF;
    IF to_regclass('public.booking_applied_rules') IS NULL THEN
        RAISE EXCEPTION 'Missing table: booking_applied_rules.';
    END IF;
    IF to_regclass('public.nightlyrates_listing') IS NULL THEN
        RAISE EXCEPTION 'Missing table: nightlyrates_listing.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'scan_booking_registers_for_extension') THEN
        RAISE EXCEPTION 'Missing function: scan_booking_registers_for_extension.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'scan_booking_registers_for_checkout') THEN
        RAISE EXCEPTION 'Missing function: scan_booking_registers_for_checkout.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM platforms WHERE name = 'OwnerRez' AND type = 'pms') THEN
        RAISE EXCEPTION 'Missing OwnerRez PMS platform from base fixture.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM platforms WHERE name = 'PriceLabs' AND type = 'dpt') THEN
        RAISE EXCEPTION 'Missing PriceLabs DPT platform from base fixture.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM platforms WHERE name = 'Wheelhouse' AND type = 'dpt') THEN
        RAISE EXCEPTION 'Missing Wheelhouse DPT platform from base fixture.';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM platform_property_lookup child
        JOIN platforms child_platform ON child_platform.id = child.platform_id
        JOIN platform_property_lookup parent ON parent.id = child.self
        JOIN platforms parent_platform ON parent_platform.id = parent.platform_id
        WHERE child_platform.name = 'PriceLabs'
          AND child.listing_id = 'pricelabs_prop_1'
          AND parent_platform.name = 'OwnerRez'
          AND parent.listing_id = 'ownerrez_prop_1'
    ) THEN
        RAISE EXCEPTION 'Missing PriceLabs -> OwnerRez linked-list row for property 1.';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM platform_property_lookup child
        JOIN platforms child_platform ON child_platform.id = child.platform_id
        JOIN platform_property_lookup parent ON parent.id = child.self
        JOIN platforms parent_platform ON parent_platform.id = parent.platform_id
        WHERE child_platform.name = 'Wheelhouse'
          AND child.listing_id = 'wheelhouse_prop_5'
          AND parent_platform.name = 'OwnerRez'
          AND parent.listing_id = 'ownerrez_prop_5'
    ) THEN
        RAISE EXCEPTION 'Missing Wheelhouse -> OwnerRez linked-list row for property 5.';
    END IF;
END $$;

DELETE FROM booking_registers
WHERE id BETWEEN 53000001 AND 53000007;

DELETE FROM messages
WHERE platform_id = (SELECT id FROM platforms WHERE name = 'OwnerRez')
  AND thread_id BETWEEN 93100001 AND 93100007;

DELETE FROM nightlyrates_listing
WHERE metadata->>'seed' = 'bso_integration';

WITH seed_classes (name, description) AS (
    VALUES
        ('bso_it_percentage', 'BSO integration category for percentage rules'),
        ('bso_it_flat', 'BSO integration category for flat adjustment rules'),
        ('bso_it_set_fixed', 'BSO integration category for set/fixed rules'),
        ('bso_it_legacy_override', 'BSO integration category for legacy override normalization'),
        ('bso_it_checkout', 'BSO integration category for checkout removal rows')
)
INSERT INTO message_classes (name, description, is_active)
SELECT name, description, TRUE
FROM seed_classes
ON CONFLICT (name) DO UPDATE
SET description = EXCLUDED.description,
    is_active = TRUE,
    updated_at = NOW();

WITH pms AS (
    SELECT id AS platform_id
    FROM platforms
    WHERE name = 'OwnerRez'
),
seed_messages (thread_id, mid, content, class_name) AS (
    VALUES
        (93100001, 98100001, 'BSO integration unchanged percentage booking already extended.', 'bso_it_percentage'),
        (93100002, 98100002, 'BSO integration percentage booking changed after prior extension.', 'bso_it_percentage'),
        (93100003, 98100003, 'BSO integration flat booking changed after prior extension.', 'bso_it_flat'),
        (93100004, 98100004, 'BSO integration fixed set booking changed after prior extension.', 'bso_it_set_fixed'),
        (93100005, 98100005, 'BSO integration legacy override booking changed after prior extension.', 'bso_it_legacy_override'),
        (93100006, 98100006, 'BSO integration checkout booking with active BSO metadata.', 'bso_it_checkout'),
        (93100007, 98100007, 'BSO integration checkout control booking without BSO metadata.', 'bso_it_checkout')
),
upserted_messages AS (
    INSERT INTO messages (
        platform_id,
        thread_id,
        mid,
        content,
        message_timestamp,
        metadata
    )
    SELECT
        pms.platform_id,
        sm.thread_id,
        sm.mid,
        sm.content,
        CURRENT_TIMESTAMP - INTERVAL '2 days',
        jsonb_build_object(
            'seed', 'bso_integration',
            'class_name', sm.class_name,
            'booking_id', (sm.thread_id - 40100000)::TEXT
        )
    FROM seed_messages sm
    CROSS JOIN pms
    ON CONFLICT (platform_id, thread_id, mid) DO UPDATE
    SET content = EXCLUDED.content,
        message_timestamp = EXCLUDED.message_timestamp,
        metadata = EXCLUDED.metadata
    RETURNING id, metadata
)
INSERT INTO message_processing_status (message_id, status, last_error)
SELECT id, 'completed', NULL
FROM upserted_messages
ON CONFLICT (message_id) DO UPDATE
SET status = 'completed',
    last_error = NULL,
    updated_at = NOW();

WITH pms AS (
    SELECT id AS platform_id
    FROM platforms
    WHERE name = 'OwnerRez'
),
seed_messages (thread_id, mid, class_name) AS (
    VALUES
        (93100001, 98100001, 'bso_it_percentage'),
        (93100002, 98100002, 'bso_it_percentage'),
        (93100003, 98100003, 'bso_it_flat'),
        (93100004, 98100004, 'bso_it_set_fixed'),
        (93100005, 98100005, 'bso_it_legacy_override'),
        (93100006, 98100006, 'bso_it_checkout'),
        (93100007, 98100007, 'bso_it_checkout')
)
INSERT INTO message_class_lookup (message_id, class_id, is_primary, source, confidence)
SELECT
    m.id,
    mc.id,
    TRUE,
    'human',
    0.990
FROM seed_messages sm
CROSS JOIN pms
JOIN messages m
  ON m.platform_id = pms.platform_id
 AND m.thread_id = sm.thread_id
 AND m.mid = sm.mid
JOIN message_classes mc
  ON mc.name = sm.class_name
ON CONFLICT (message_id, class_id) DO UPDATE
SET is_primary = TRUE,
    source = 'human',
    confidence = 0.990;

WITH seed_rules (rule_uuid, operation_code, rule_name, priority, rule_config) AS (
    VALUES
        (
            '11111111-5300-4000-8000-000000000001'::uuid,
            'increase',
            'BSO integration percentage increase',
            90,
            '{
                "subject": "price",
                "operation": {"type": "percentage", "amount": 10},
                "conditions": {"booking_category": {"in": ["bso_it_percentage"]}},
                "apply_window": {"applies_from": "departure", "direction": "after", "duration_days": 2},
                "metadata": {"seed": "bso_integration"}
            }'::jsonb
        ),
        (
            '11111111-5300-4000-8000-000000000002'::uuid,
            'increase',
            'BSO integration flat increase',
            89,
            '{
                "subject": "price",
                "operation": {"type": "flat", "amount": 25},
                "conditions": {"booking_category": {"in": ["bso_it_flat"]}},
                "apply_window": {"applies_from": "departure", "direction": "after", "duration_days": 2},
                "metadata": {"seed": "bso_integration"}
            }'::jsonb
        ),
        (
            '11111111-5300-4000-8000-000000000003'::uuid,
            'set',
            'BSO integration set fixed',
            88,
            '{
                "subject": "price",
                "operation": {"type": "fixed", "do": "set", "amount": 180},
                "conditions": {"booking_category": {"in": ["bso_it_set_fixed"]}},
                "apply_window": {"applies_from": "departure", "direction": "after", "duration_days": 2},
                "metadata": {"seed": "bso_integration"}
            }'::jsonb
        ),
        (
            '11111111-5300-4000-8000-000000000004'::uuid,
            'set',
            'BSO integration legacy override normalized to set/fixed',
            87,
            '{
                "subject": "price",
                "operation": {"type": "override", "do": "override", "amount": 210},
                "conditions": {"booking_category": {"in": ["bso_it_legacy_override"]}},
                "apply_window": {"applies_from": "departure", "direction": "after", "duration_days": 2},
                "metadata": {"seed": "bso_integration", "legacy_operation": "override"}
            }'::jsonb
        )
)
INSERT INTO pricing_rules (
    rule_uuid,
    operation_id,
    rule_config,
    start_date,
    end_date,
    rule_name,
    rule_description,
    priority,
    status,
    allow_override,
    requires_approval,
    created_by,
    created_via,
    activated_at
)
SELECT
    sr.rule_uuid,
    pot.id,
    sr.rule_config,
    CURRENT_DATE - 30,
    CURRENT_DATE + 90,
    sr.rule_name,
    'Seeded by bso_integration.seed_data.sql',
    sr.priority,
    'active',
    TRUE,
    FALSE,
    'bso_integration_seed',
    'seed',
    NOW()
FROM seed_rules sr
JOIN pricing_operation_types pot
  ON pot.operation_code = sr.operation_code
ON CONFLICT (rule_uuid) DO UPDATE
SET operation_id = EXCLUDED.operation_id,
    rule_config = EXCLUDED.rule_config,
    start_date = EXCLUDED.start_date,
    end_date = EXCLUDED.end_date,
    rule_name = EXCLUDED.rule_name,
    rule_description = EXCLUDED.rule_description,
    priority = EXCLUDED.priority,
    status = 'active',
    allow_override = TRUE,
    requires_approval = FALSE,
    activated_at = NOW(),
    updated_at = NOW();

WITH pms AS (
    SELECT id AS platform_id
    FROM platforms
    WHERE name = 'OwnerRez'
),
seed_rows (
    id,
    property_id,
    listing_id,
    thread_id,
    arrival,
    departure,
    booked_at,
    guest_id,
    updated_at,
    metadata
) AS (
    VALUES
        (
            53000001,
            1,
            'ownerrez_prop_1',
            93100001,
            CURRENT_DATE + 1,
            CURRENT_DATE + 4,
            CURRENT_TIMESTAMP - INTERVAL '8 days',
            830000001,
            CURRENT_TIMESTAMP - INTERVAL '1 day',
            jsonb_build_object(
                'seed', 'bso_integration',
                'booking_id', '53000001',
                'listing_id', 'ownerrez_prop_1',
                'status', 'booked',
                'scenario', 'unchanged_bso_already_done',
                'bso', jsonb_build_object(
                    'potential_extension', jsonb_build_object(
                        'last_extended', CURRENT_TIMESTAMP + INTERVAL '1 hour'
                    )
                )
            )
        ),
        (
            53000002,
            1,
            'ownerrez_prop_1',
            93100002,
            CURRENT_DATE + 1,
            CURRENT_DATE + 4,
            CURRENT_TIMESTAMP - INTERVAL '7 days',
            830000002,
            CURRENT_TIMESTAMP,
            jsonb_build_object(
                'seed', 'bso_integration',
                'booking_id', '53000002',
                'listing_id', 'ownerrez_prop_1',
                'status', 'booked',
                'scenario', 'changed_requires_percentage_renewal',
                'bso', jsonb_build_object(
                    'potential_extension', jsonb_build_object(
                        'last_extended', CURRENT_TIMESTAMP - INTERVAL '1 day'
                    )
                )
            )
        ),
        (
            53000003,
            5,
            'ownerrez_prop_5',
            93100003,
            CURRENT_DATE + 1,
            CURRENT_DATE + 4,
            CURRENT_TIMESTAMP - INTERVAL '7 days',
            830000003,
            CURRENT_TIMESTAMP,
            jsonb_build_object(
                'seed', 'bso_integration',
                'booking_id', '53000003',
                'listing_id', 'ownerrez_prop_5',
                'status', 'booked',
                'scenario', 'changed_requires_flat_renewal',
                'bso', jsonb_build_object(
                    'potential_extension', jsonb_build_object(
                        'last_extended', CURRENT_TIMESTAMP - INTERVAL '1 day'
                    )
                )
            )
        ),
        (
            53000004,
            5,
            'ownerrez_prop_5',
            93100004,
            CURRENT_DATE + 1,
            CURRENT_DATE + 4,
            CURRENT_TIMESTAMP - INTERVAL '7 days',
            830000004,
            CURRENT_TIMESTAMP,
            jsonb_build_object(
                'seed', 'bso_integration',
                'booking_id', '53000004',
                'listing_id', 'ownerrez_prop_5',
                'status', 'booked',
                'scenario', 'changed_requires_set_fixed_renewal',
                'bso', jsonb_build_object(
                    'potential_extension', jsonb_build_object(
                        'last_extended', CURRENT_TIMESTAMP - INTERVAL '1 day'
                    )
                )
            )
        ),
        (
            53000005,
            5,
            'ownerrez_prop_5',
            93100005,
            CURRENT_DATE + 1,
            CURRENT_DATE + 4,
            CURRENT_TIMESTAMP - INTERVAL '7 days',
            830000005,
            CURRENT_TIMESTAMP,
            jsonb_build_object(
                'seed', 'bso_integration',
                'booking_id', '53000005',
                'listing_id', 'ownerrez_prop_5',
                'status', 'booked',
                'scenario', 'changed_requires_legacy_override_renewal',
                'bso', jsonb_build_object(
                    'potential_extension', jsonb_build_object(
                        'last_extended', CURRENT_TIMESTAMP - INTERVAL '1 day'
                    )
                )
            )
        ),
        (
            53000006,
            1,
            'ownerrez_prop_1',
            93100006,
            CURRENT_DATE - 3,
            CURRENT_DATE,
            CURRENT_TIMESTAMP - INTERVAL '11 days',
            830000006,
            CURRENT_TIMESTAMP - INTERVAL '6 hours',
            jsonb_build_object(
                'seed', 'bso_integration',
                'booking_id', '53000006',
                'listing_id', 'ownerrez_prop_1',
                'status', 'booked',
                'scenario', 'checkout_with_bso_metadata',
                'bso', jsonb_build_object(
                    'potential_extension', jsonb_build_object(
                        'last_extended', CURRENT_TIMESTAMP - INTERVAL '12 hours'
                    )
                )
            )
        ),
        (
            53000007,
            1,
            'ownerrez_prop_1',
            93100007,
            CURRENT_DATE - 3,
            CURRENT_DATE,
            CURRENT_TIMESTAMP - INTERVAL '11 days',
            830000007,
            CURRENT_TIMESTAMP - INTERVAL '6 hours',
            jsonb_build_object(
                'seed', 'bso_integration',
                'booking_id', '53000007',
                'listing_id', 'ownerrez_prop_1',
                'status', 'booked',
                'scenario', 'checkout_control_without_bso_metadata'
            )
        )
)
INSERT INTO booking_registers (
    id,
    type,
    arrival,
    departure,
    booked_at,
    guest_id,
    property_id,
    platform_id,
    ppl_id,
    thread_ids_json,
    metadata,
    created_at,
    updated_at
)
SELECT
    sr.id,
    'booking',
    sr.arrival,
    sr.departure,
    sr.booked_at,
    sr.guest_id,
    sr.property_id,
    pms.platform_id,
    ppl.id,
    jsonb_build_array(sr.thread_id),
    sr.metadata,
    CURRENT_TIMESTAMP - INTERVAL '2 days',
    sr.updated_at
FROM seed_rows sr
CROSS JOIN pms
JOIN platform_property_lookup ppl
  ON ppl.platform_id = pms.platform_id
 AND ppl.properties_ptr = sr.property_id
 AND ppl.listing_id = sr.listing_id;

WITH target_ppl AS (
    SELECT ppl.id AS ppl_id
    FROM platform_property_lookup ppl
    JOIN platforms p ON p.id = ppl.platform_id
    WHERE (p.name = 'OwnerRez' AND ppl.listing_id IN ('ownerrez_prop_1', 'ownerrez_prop_5'))
       OR (p.name = 'PriceLabs' AND ppl.listing_id = 'pricelabs_prop_1')
       OR (p.name = 'Wheelhouse' AND ppl.listing_id = 'wheelhouse_prop_5')
),
seed_dates (date_value) AS (
    VALUES
        (CURRENT_DATE),
        (CURRENT_DATE + 1),
        (CURRENT_DATE + 4),
        (CURRENT_DATE + 5)
)
INSERT INTO nightlyrates_listing (ppl_id, date, rate, rate_type, metadata)
SELECT
    tp.ppl_id,
    sd.date_value,
    150.00,
    'base',
    jsonb_build_object('seed', 'bso_integration', 'source', 'fixture_baseline')
FROM target_ppl tp
CROSS JOIN seed_dates sd
ON CONFLICT (ppl_id, date, rate_type) DO UPDATE
SET rate = EXCLUDED.rate,
    metadata = EXCLUDED.metadata;

WITH seed_sources (
    booking_id,
    target_platform_name,
    target_listing_id,
    rule_uuid,
    category,
    operation,
    instruction_type,
    amount,
    instruction_uuid
) AS (
    VALUES
        (53000001, 'PriceLabs', 'pricelabs_prop_1', '11111111-5300-4000-8000-000000000001'::uuid, 'bso_it_percentage', 'increase', 'percentage', 10, '22222222-5300-4000-8000-000000000001'::uuid),
        (53000002, 'PriceLabs', 'pricelabs_prop_1', '11111111-5300-4000-8000-000000000001'::uuid, 'bso_it_percentage', 'increase', 'percentage', 10, '22222222-5300-4000-8000-000000000002'::uuid),
        (53000003, 'Wheelhouse', 'wheelhouse_prop_5', '11111111-5300-4000-8000-000000000002'::uuid, 'bso_it_flat', 'increase', 'flat', 25, '22222222-5300-4000-8000-000000000003'::uuid),
        (53000004, 'Wheelhouse', 'wheelhouse_prop_5', '11111111-5300-4000-8000-000000000003'::uuid, 'bso_it_set_fixed', 'set', 'fixed', 180, '22222222-5300-4000-8000-000000000004'::uuid),
        (53000005, 'Wheelhouse', 'wheelhouse_prop_5', '11111111-5300-4000-8000-000000000004'::uuid, 'bso_it_legacy_override', 'set', 'fixed', 210, '22222222-5300-4000-8000-000000000005'::uuid),
        (53000006, 'PriceLabs', 'pricelabs_prop_1', '11111111-5300-4000-8000-000000000001'::uuid, 'bso_it_checkout', 'increase', 'percentage', 10, '22222222-5300-4000-8000-000000000006'::uuid)
),
resolved_sources AS (
    SELECT
        ss.*,
        br.property_id,
        br.platform_id AS source_platform_id,
        br.departure,
        p.id AS target_platform_id,
        ppl.listing_id
    FROM seed_sources ss
    JOIN booking_registers br
      ON br.id = ss.booking_id
    JOIN platforms p
      ON p.name = ss.target_platform_name
    JOIN platform_property_lookup ppl
      ON ppl.platform_id = p.id
     AND ppl.listing_id = ss.target_listing_id
)
INSERT INTO booking_applied_rules (
    booking_entry_id,
    property_id,
    platform_id,
    listing_id,
    rule_uuid,
    trigger_category,
    instruction,
    status
)
SELECT
    rs.booking_id,
    rs.property_id,
    rs.target_platform_id,
    rs.listing_id,
    rs.rule_uuid,
    rs.category,
    jsonb_build_object(
        'seed', 'bso_integration_source',
        'instruction_uuid', rs.instruction_uuid::TEXT,
        'booking_entry_id', rs.booking_id,
        'property_id', rs.property_id,
        'source_platform_id', rs.source_platform_id,
        'platform_id', rs.target_platform_id,
        'listing_id', rs.listing_id,
        'rule_uuid', rs.rule_uuid::TEXT,
        'trigger_category', rs.category,
        'operation', rs.operation,
        'subject', 'price',
        'type', rs.instruction_type,
        'amount', rs.amount,
        'dates', jsonb_build_array(rs.departure::TEXT, (rs.departure + 1)::TEXT),
        'remove', FALSE
    ),
    'applied'
FROM resolved_sources rs;

SELECT setval(
    pg_get_serial_sequence('booking_registers', 'id'),
    (SELECT GREATEST(COALESCE(MAX(id), 1), 1) FROM booking_registers),
    TRUE
);

COMMIT;
