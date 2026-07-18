-- ============================================
-- BOOKING SCANNER 1 — SEED DATA
-- Version: 1.0
-- Run AFTER: schemas/scanner_for_extension.sql
-- ============================================
-- Assumes window: 2026-02-23 to 2026-02-25 (today ± 2 days)
-- Each seed booking is crafted to demonstrate a specific scanner behavior.
-- ============================================


-- ============================================
-- 0. SEED PREREQUISITES: platform + property mapping
-- ============================================
-- bookings validates (platform_id, property_id) against platform_property_lookup.
-- Seed deterministic mapping rows first so booking inserts are valid.

INSERT INTO platforms (id, name, type, is_active)
VALUES (12, 'scanner_seed_platform', 'pms', TRUE)
ON CONFLICT (id) DO UPDATE
SET name = EXCLUDED.name,
    type = EXCLUDED.type,
    is_active = TRUE;

INSERT INTO properties (id, descrp)
VALUES
    (201, '{"latitude":"25.1201","longitude":"-80.1201","name":"Scanner Seed Property 201"}'::JSONB),
    (202, '{"latitude":"25.1202","longitude":"-80.1202","name":"Scanner Seed Property 202"}'::JSONB),
    (203, '{"latitude":"25.1203","longitude":"-80.1203","name":"Scanner Seed Property 203"}'::JSONB),
    (204, '{"latitude":"25.1204","longitude":"-80.1204","name":"Scanner Seed Property 204"}'::JSONB),
    (205, '{"latitude":"25.1205","longitude":"-80.1205","name":"Scanner Seed Property 205"}'::JSONB),
    (206, '{"latitude":"25.1206","longitude":"-80.1206","name":"Scanner Seed Property 206"}'::JSONB),
    (207, '{"latitude":"25.1207","longitude":"-80.1207","name":"Scanner Seed Property 207"}'::JSONB),
    (208, '{"latitude":"25.1208","longitude":"-80.1208","name":"Scanner Seed Property 208"}'::JSONB)
ON CONFLICT (id) DO UPDATE
SET descrp = EXCLUDED.descrp;

INSERT INTO platform_property_lookup (properties_ptr, platform_id, platform_property_id)
VALUES
    (201, 12, 'scanner_seed_prop_201'),
    (202, 12, 'scanner_seed_prop_202'),
    (203, 12, 'scanner_seed_prop_203'),
    (204, 12, 'scanner_seed_prop_204'),
    (205, 12, 'scanner_seed_prop_205'),
    (206, 12, 'scanner_seed_prop_206'),
    (207, 12, 'scanner_seed_prop_207'),
    (208, 12, 'scanner_seed_prop_208')
ON CONFLICT (platform_id, properties_ptr) DO UPDATE
SET platform_property_id = EXCLUDED.platform_property_id;


-- ============================================
-- 1. SEED: bookings
-- ============================================
-- Scenario legend:
--   B1  → INCLUDE: arrival is in window, no prior BSO
--   B2  → INCLUDE: day before departure is in window, no prior BSO
--   B3  → INCLUDE: booking WAS extended before, but has since been updated (departure changed)
--   B4  → EXCLUDE: no date in window (past booking, fully outside)
--   B5  → EXCLUDE: updated_at < last_extended (unchanged since last extension op)
--   B6  → EXCLUDE: no date in window (future booking, outside window)
--   B7  → INCLUDE: both arrival AND departure-1 fall in window (short stay)
--   B8  → INCLUDE: metadata exists but bso key absent — treated as never extended

INSERT INTO bookings (id, type, arrival, departure, booked_at, guest_id, property_id, platform_id, thread_ids_json, updated_at, created_at)
VALUES
    -- B1: arrival = 2026-02-23 (window start) → INCLUDE
    (1001, 'booking', '2026-02-23', '2026-02-28', '2026-01-10 10:00:00+00', 101, 201, 12, '[20001]'::jsonb,
     '2026-02-20 08:00:00+00', '2026-01-10 10:00:00+00'),

    -- B2: departure - 1 = 2026-02-24 (in window) → INCLUDE
    (1002, 'booking', '2026-02-18', '2026-02-25', '2026-01-12 11:00:00+00', 102, 202, 12, '[20002]'::jsonb,
     '2026-02-19 09:00:00+00', '2026-01-12 11:00:00+00'),

    -- B3: was extended, but booking was updated AFTER last_extended → INCLUDE
    --     updated_at (2026-02-22) > last_extended (2026-02-15) → not excluded
    (1003, 'booking', '2026-02-23', '2026-03-01', '2026-01-15 09:00:00+00', 103, 203, 12, '[20003]'::jsonb,
     '2026-02-22 14:00:00+00', '2026-01-15 09:00:00+00'),

    -- B4: arrival = 2026-01-01, departure = 2026-01-10 → fully outside window → EXCLUDE
    (1004, 'booking', '2026-01-01', '2026-01-10', '2025-12-01 08:00:00+00', 104, 204, 12, '[20004]'::jsonb,
     '2025-12-01 08:00:00+00', '2025-12-01 08:00:00+00'),

    -- B5: was extended, updated_at < last_extended → nothing changed → EXCLUDE
    --     updated_at (2026-02-10) < last_extended (2026-02-18)
    (1005, 'booking', '2026-02-24', '2026-03-02', '2026-01-20 10:00:00+00', 105, 205, 12, '[20005]'::jsonb,
     '2026-02-10 08:00:00+00', '2026-01-20 10:00:00+00'),

    -- B6: arrival = 2026-03-15, future booking → outside window → EXCLUDE
    (1006, 'booking', '2026-03-15', '2026-03-22', '2026-02-01 12:00:00+00', 106, 206, 12, '[20006]'::jsonb,
     '2026-02-01 12:00:00+00', '2026-02-01 12:00:00+00'),

    -- B7: arrival = 2026-02-24, departure = 2026-02-26 (departure-1 = 2026-02-25)
    --     Both dates in window → INCLUDE
    (1007, 'booking', '2026-02-24', '2026-02-26', '2026-02-05 08:00:00+00', 107, 207, 12, '[20007]'::jsonb,
     '2026-02-20 10:00:00+00', '2026-02-05 08:00:00+00'),

    -- B8: arrival = 2026-02-25 (window end), metadata exists but no bso → INCLUDE
    (1008, 'booking', '2026-02-25', '2026-03-03', '2026-02-08 09:00:00+00', 108, 208, 12, '[20008]'::jsonb,
     '2026-02-21 11:00:00+00', '2026-02-08 09:00:00+00');


-- ============================================
-- 2. SEED: bookings_metadata
-- ============================================

-- B1: No metadata at all (LEFT JOIN returns NULL) → INCLUDE
-- (no insert needed)

-- B2: Metadata exists, no bso key → INCLUDE
INSERT INTO bookings_metadata (booking_entry_id, metadata, version, source)
VALUES (1002, '{"notes": "guest requests late checkout"}'::JSONB, 1, 'seed');

-- B3: Has bso with last_extended = 2026-02-15, but booking updated 2026-02-22 → INCLUDE
INSERT INTO bookings_metadata (booking_entry_id, metadata, version, source)
VALUES (1003, '{
    "bso": {
        "potential_extension": {
            "is_extended": 1,
            "last_extended": "2026-02-15T10:00:00+00:00",
            "bso_id": 301
        }
    }
}'::JSONB, 2, 'seed');

-- B4: Outside window entirely — metadata irrelevant, but added for realism
INSERT INTO bookings_metadata (booking_entry_id, metadata, version, source)
VALUES (1004, '{
    "bso": {
        "potential_extension": {
            "is_extended": 1,
            "last_extended": "2026-01-08T10:00:00+00:00",
            "bso_id": 302
        }
    }
}'::JSONB, 1, 'seed');

-- B5: last_extended = 2026-02-18, updated_at = 2026-02-10 → updated_at < last_extended → EXCLUDE
INSERT INTO bookings_metadata (booking_entry_id, metadata, version, source)
VALUES (1005, '{
    "bso": {
        "potential_extension": {
            "is_extended": 1,
            "last_extended": "2026-02-18T12:00:00+00:00",
            "bso_id": 303
        }
    }
}'::JSONB, 3, 'seed');

-- B6: Outside window — metadata irrelevant
INSERT INTO bookings_metadata (booking_entry_id, metadata, version, source)
VALUES (1006, '{}'::JSONB, 1, 'seed');

-- B7: No prior extension metadata → INCLUDE
INSERT INTO bookings_metadata (booking_entry_id, metadata, version, source)
VALUES (1007, '{"notes": "short stay"}'::JSONB, 1, 'seed');

-- B8: Metadata with unrelated keys, no bso → INCLUDE
INSERT INTO bookings_metadata (booking_entry_id, metadata, version, source)
VALUES (1008, '{"vip": true, "cleaning_notes": "use eco products"}'::JSONB, 1, 'seed');
