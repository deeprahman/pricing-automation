-- ============================================================================
-- SEED — Rocky Creek L4  ·  Future Bookings + Message Threads
-- ============================================================================
-- Target property : Rocky Creek L4 - 2/2
--                   370 Sunshine Dr Apt L4, Coconut Creek, FL 33066
-- Platform        : OwnerRez (PMS)  —  listing_id '370435'
-- PPL             : resolved at runtime via platforms + platform_property_lookup
-- ============================================================================
-- Booking IDs : 54000001 – 54000004
-- Thread IDs  : 95000001 – 95000004
-- Message IDs : 97000010, 97000011, 97000016, 97000017
--               97000020, 97000021, 97000026, 97000027
--               97000030, 97000031, 97000036
--               97000040, 97000041, 97000046, 97000048
-- Guest IDs   : 830000001 – 830000004
-- ============================================================================
--
-- Date layout  (B = CURRENT_DATE + 91, i.e. first arrival > 90-day horizon):
--
--   Booking 1  arrival B+0   departure B+3    gap →  5 nights
--   Booking 2  arrival B+8   departure B+11   gap →  5 nights
--   Booking 3  arrival B+16  departure B+19   gap →  5 nights
--   Booking 4  arrival B+24  departure B+27
--
-- ============================================================================
-- Run AFTER : schema + platform/property/lookup seed that places OwnerRez
--             and listing_id '370435' in platform_property_lookup.
-- Safe to re-run : ON CONFLICT … DO UPDATE / DO NOTHING throughout.
-- ============================================================================

BEGIN;

-- ============================================================================
-- DEPENDENCY VALIDATION
-- ============================================================================
DO $$
BEGIN
    IF to_regclass('public.booking_registers') IS NULL THEN
        RAISE EXCEPTION 'Missing table: booking_registers.';
    END IF;
    IF to_regclass('public.messages') IS NULL THEN
        RAISE EXCEPTION 'Missing table: messages.';
    END IF;
    IF to_regclass('public.message_thread_progress') IS NULL THEN
        RAISE EXCEPTION 'Missing table: message_thread_progress.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM platforms WHERE name = 'OwnerRez') THEN
        RAISE EXCEPTION 'OwnerRez platform not found. Run the platform seed first.';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM platform_property_lookup ppl
        JOIN platforms p ON p.id = ppl.platform_id
        WHERE p.name = 'OwnerRez'
          AND ppl.listing_id = '370435'
    ) THEN
        RAISE EXCEPTION 'listing_id 370435 not found for OwnerRez. Run the platform-property seed first.';
    END IF;
END $$;


-- ============================================================================
-- §1  BOOKINGS  +  §2  MESSAGES  +  §3  THREAD PROGRESS
-- ============================================================================

DO $$
DECLARE
    -- Date anchor: all arrivals are ≥ CURRENT_DATE + 91 (beyond 90-day horizon)
    B           DATE := CURRENT_DATE + 91;

    pms_id      INT;
    ppl_id_val  INT;

    -- Human-readable date strings used inside message bodies
    arr1  TEXT;  dep1  TEXT;
    arr2  TEXT;  dep2  TEXT;
    arr3  TEXT;  dep3  TEXT;
    arr4  TEXT;  dep4  TEXT;

BEGIN
    SELECT p.id, ppl.id
      INTO pms_id, ppl_id_val
      FROM platforms p
      JOIN platform_property_lookup ppl ON ppl.platform_id = p.id
     WHERE p.name        = 'OwnerRez'
       AND ppl.listing_id = '370435'
     LIMIT 1;

    arr1 := TO_CHAR(B,      'Mon DD, YYYY');   dep1 := TO_CHAR(B + 3,  'Mon DD, YYYY');
    arr2 := TO_CHAR(B + 8,  'Mon DD, YYYY');   dep2 := TO_CHAR(B + 11, 'Mon DD, YYYY');
    arr3 := TO_CHAR(B + 16, 'Mon DD, YYYY');   dep3 := TO_CHAR(B + 19, 'Mon DD, YYYY');
    arr4 := TO_CHAR(B + 24, 'Mon DD, YYYY');   dep4 := TO_CHAR(B + 27, 'Mon DD, YYYY');

    -- ── §1  BOOKINGS ─────────────────────────────────────────────────────────

    INSERT INTO booking_registers (
        id, type, arrival, departure, booked_at,
        guest_id, property_id, platform_id, ppl_id,
        thread_ids_json, metadata
    ) VALUES
        (54000001, 'booking',
            B,      B + 3,  NOW() - INTERVAL '3 hours',
            830000001, 1, pms_id, ppl_id_val,
            '[95000001]'::jsonb,
            jsonb_build_object('listing_id', '370435')),

        (54000002, 'booking',
            B + 8,  B + 11, NOW() - INTERVAL '2 hours',
            830000002, 1, pms_id, ppl_id_val,
            '[95000002]'::jsonb,
            jsonb_build_object('listing_id', '370435')),

        (54000003, 'booking',
            B + 16, B + 19, NOW() - INTERVAL '1 hour',
            830000003, 1, pms_id, ppl_id_val,
            '[95000003]'::jsonb,
            jsonb_build_object('listing_id', '370435')),

        (54000004, 'booking',
            B + 24, B + 27, NOW() - INTERVAL '30 minutes',
            830000004, 1, pms_id, ppl_id_val,
            '[95000004]'::jsonb,
            jsonb_build_object('listing_id', '370435'))

    ON CONFLICT (id) DO UPDATE
        SET type            = EXCLUDED.type,
            arrival         = EXCLUDED.arrival,
            departure       = EXCLUDED.departure,
            booked_at       = EXCLUDED.booked_at,
            guest_id        = EXCLUDED.guest_id,
            property_id     = EXCLUDED.property_id,
            platform_id     = EXCLUDED.platform_id,
            ppl_id          = EXCLUDED.ppl_id,
            thread_ids_json = EXCLUDED.thread_ids_json,
            metadata        = EXCLUDED.metadata;

    -- ── §2  MESSAGES ─────────────────────────────────────────────────────────
    -- Pattern per thread:
    --   mid x0  Reservation confirmation   (booking_confirmation)
    --   mid x1  Door-code message          (unclassified)
    --   mid x6  Arrival check-in prompt    (unclassified)
    --   mid x7  Guest trigger message      (medical/job on threads 1 and 2)
    --   mid x8  Checkout reminder          (checkout)  — thread 4 only
    -- -------------------------------------------------------------------------

    -- Thread 95000001 — Booking 54000001 ──────────────────────────────────────
    INSERT INTO messages (platform_id, thread_id, mid, content, message_timestamp, metadata)
    VALUES
        (pms_id, 95000001, 97000010,
            'Reservation Confirmation'                                         || E'\n\n' ||
            'Dates & Details:'                                                 || E'\n'   ||
            'Check-in:  ' || arr1 || ' at 4:00 PM'                            || E'\n'   ||
            'Check-out: ' || dep1 || ' at 10:00 AM'                           || E'\n'   ||
            'Nights: 3'                                                        || E'\n'   ||
            'Guests: 2'                                                        || E'\n\n' ||
            'If anything is incorrect, please let me know ASAP so I can update it before arrival.' || E'\n\n' ||
            'Address:'                                                         || E'\n'   ||
            '370 Sunshine Dr Apt L4, Coconut Creek, FL 33066'                 || E'\n'   ||
            'https://www.google.com/maps/place/26.235574,-80.176134'          || E'\n\n' ||
            'Parking:'                                                         || E'\n'   ||
            'Street parking is available on a first-come basis. Visitor spots are unmarked.' || E'\n\n' ||
            'WiFi:'                                                            || E'\n'   ||
            'Network name: CoconutCreekGuest'                                  || E'\n'   ||
            'Password: PalmWaves2026'                                          || E'\n\n' ||
            'House Rules:'                                                     || E'\n'   ||
            'No smoking or parties/events'                                     || E'\n'   ||
            'Quiet hours: 11:00 PM – 8:00 AM',
            NOW() - INTERVAL '3 hours',
            '{}'::jsonb),

        (pms_id, 95000001, 97000011,
            'Hi,' || E'\n\n' ||
            'Thanks for booking with us! Your door code is 5001. ' ||
            'The code activates at 4 PM on check-in day. ' ||
            'Please use the smart lock at the main entrance and message us if you have any trouble.',
            NOW() - INTERVAL '170 minutes',
            '{}'::jsonb),

        (pms_id, 95000001, 97000016,
            'Please send a quick message after you arrive so we can make sure everything is perfect for your stay.',
            NOW() - INTERVAL '160 minutes',
            '{}'::jsonb),

        (pms_id, 95000001, 97000017,
            'Hi, we booked this stay because my mother has an early procedure at Broward Health and needs to recover nearby for a few days. ' ||
            'Please let us know if the building has an elevator because she will be arriving with medical equipment and limited mobility.',
            NOW() - INTERVAL '150 minutes',
            '{}'::jsonb)

    ON CONFLICT (platform_id, thread_id, mid) DO NOTHING;

    -- Thread 95000002 — Booking 54000002 ──────────────────────────────────────
    INSERT INTO messages (platform_id, thread_id, mid, content, message_timestamp, metadata)
    VALUES
        (pms_id, 95000002, 97000020,
            'Reservation Confirmation'                                         || E'\n\n' ||
            'Dates & Details:'                                                 || E'\n'   ||
            'Check-in:  ' || arr2 || ' at 4:00 PM'                            || E'\n'   ||
            'Check-out: ' || dep2 || ' at 10:00 AM'                           || E'\n'   ||
            'Nights: 3'                                                        || E'\n'   ||
            'Guests: 2'                                                        || E'\n\n' ||
            'If anything is incorrect, please let me know ASAP so I can update it before arrival.' || E'\n\n' ||
            'Address:'                                                         || E'\n'   ||
            '370 Sunshine Dr Apt L4, Coconut Creek, FL 33066'                 || E'\n'   ||
            'https://www.google.com/maps/place/26.235574,-80.176134'          || E'\n\n' ||
            'Parking:'                                                         || E'\n'   ||
            'Street parking is available on a first-come basis. Visitor spots are unmarked.' || E'\n\n' ||
            'WiFi:'                                                            || E'\n'   ||
            'Network name: CoconutCreekGuest'                                  || E'\n'   ||
            'Password: PalmWaves2026'                                          || E'\n\n' ||
            'House Rules:'                                                     || E'\n'   ||
            'No smoking or parties/events'                                     || E'\n'   ||
            'Quiet hours: 11:00 PM – 8:00 AM',
            NOW() - INTERVAL '2 hours',
            '{}'::jsonb),

        (pms_id, 95000002, 97000021,
            'Hi,' || E'\n\n' ||
            'Thanks for booking with us! Your door code is 5002. ' ||
            'The code activates at 4 PM on check-in day. ' ||
            'Please use the smart lock at the main entrance and message us if you have any trouble.',
            NOW() - INTERVAL '115 minutes',
            '{}'::jsonb),

        (pms_id, 95000002, 97000026,
            'Please send a quick message after you arrive so we can make sure everything is perfect for your stay.',
            NOW() - INTERVAL '110 minutes',
            '{}'::jsonb),

        (pms_id, 95000002, 97000027,
            'We are coming in for a temporary work assignment and job relocation training that starts the next morning. ' ||
            'Could you confirm the WiFi is stable enough for video meetings while we are in town for the contract?',
            NOW() - INTERVAL '100 minutes',
            '{}'::jsonb)

    ON CONFLICT (platform_id, thread_id, mid) DO NOTHING;

    -- Thread 95000003 — Booking 54000003 ──────────────────────────────────────
    INSERT INTO messages (platform_id, thread_id, mid, content, message_timestamp, metadata)
    VALUES
        (pms_id, 95000003, 97000030,
            'Reservation Confirmation'                                         || E'\n\n' ||
            'Dates & Details:'                                                 || E'\n'   ||
            'Check-in:  ' || arr3 || ' at 4:00 PM'                            || E'\n'   ||
            'Check-out: ' || dep3 || ' at 10:00 AM'                           || E'\n'   ||
            'Nights: 3'                                                        || E'\n'   ||
            'Guests: 2'                                                        || E'\n\n' ||
            'If anything is incorrect, please let me know ASAP so I can update it before arrival.' || E'\n\n' ||
            'Address:'                                                         || E'\n'   ||
            '370 Sunshine Dr Apt L4, Coconut Creek, FL 33066'                 || E'\n'   ||
            'https://www.google.com/maps/place/26.235574,-80.176134'          || E'\n\n' ||
            'Parking:'                                                         || E'\n'   ||
            'Street parking is available on a first-come basis. Visitor spots are unmarked.' || E'\n\n' ||
            'WiFi:'                                                            || E'\n'   ||
            'Network name: CoconutCreekGuest'                                  || E'\n'   ||
            'Password: PalmWaves2026'                                          || E'\n\n' ||
            'House Rules:'                                                     || E'\n'   ||
            'No smoking or parties/events'                                     || E'\n'   ||
            'Quiet hours: 11:00 PM – 8:00 AM',
            NOW() - INTERVAL '1 hour',
            '{}'::jsonb),

        (pms_id, 95000003, 97000031,
            'Hi,' || E'\n\n' ||
            'Thanks for booking with us! Your door code is 5003. ' ||
            'The code activates at 4 PM on check-in day. ' ||
            'Please use the smart lock at the main entrance and message us if you have any trouble.',
            NOW() - INTERVAL '58 minutes',
            '{}'::jsonb),

        (pms_id, 95000003, 97000036,
            'Please send a quick message after you arrive so we can make sure everything is perfect for your stay.',
            NOW() - INTERVAL '55 minutes',
            '{}'::jsonb)

    ON CONFLICT (platform_id, thread_id, mid) DO NOTHING;

    -- Thread 95000004 — Booking 54000004 ──────────────────────────────────────
    -- This thread includes a checkout reminder (4 messages total).
    INSERT INTO messages (platform_id, thread_id, mid, content, message_timestamp, metadata)
    VALUES
        (pms_id, 95000004, 97000040,
            'Reservation Confirmation'                                         || E'\n\n' ||
            'Dates & Details:'                                                 || E'\n'   ||
            'Check-in:  ' || arr4 || ' at 4:00 PM'                            || E'\n'   ||
            'Check-out: ' || dep4 || ' at 10:00 AM'                           || E'\n'   ||
            'Nights: 3'                                                        || E'\n'   ||
            'Guests: 2'                                                        || E'\n\n' ||
            'If anything is incorrect, please let me know ASAP so I can update it before arrival.' || E'\n\n' ||
            'Address:'                                                         || E'\n'   ||
            '370 Sunshine Dr Apt L4, Coconut Creek, FL 33066'                 || E'\n'   ||
            'https://www.google.com/maps/place/26.235574,-80.176134'          || E'\n\n' ||
            'Parking:'                                                         || E'\n'   ||
            'Street parking is available on a first-come basis. Visitor spots are unmarked.' || E'\n\n' ||
            'WiFi:'                                                            || E'\n'   ||
            'Network name: CoconutCreekGuest'                                  || E'\n'   ||
            'Password: PalmWaves2026'                                          || E'\n\n' ||
            'House Rules:'                                                     || E'\n'   ||
            'No smoking or parties/events'                                     || E'\n'   ||
            'Quiet hours: 11:00 PM – 8:00 AM',
            NOW() - INTERVAL '30 minutes',
            '{}'::jsonb),

        (pms_id, 95000004, 97000041,
            'Hi,' || E'\n\n' ||
            'Thanks for booking with us! Your door code is 5004. ' ||
            'The code activates at 4 PM on check-in day. ' ||
            'Please use the smart lock at the main entrance and message us if you have any trouble.',
            NOW() - INTERVAL '28 minutes',
            '{}'::jsonb),

        (pms_id, 95000004, 97000046,
            'Please send a quick message after you arrive so we can make sure everything is perfect for your stay.',
            NOW() - INTERVAL '25 minutes',
            '{}'::jsonb),

        (pms_id, 95000004, 97000048,
            'Reminder: check-out is ' || dep4 || ' at 10:00 AM. ' ||
            'Please load the dishwasher and start it, place used towels in the tub, and lock the door on your way out.',
            NOW() - INTERVAL '20 minutes',
            '{}'::jsonb)

    ON CONFLICT (platform_id, thread_id, mid) DO NOTHING;

    -- ── §3  MESSAGE THREAD PROGRESS ──────────────────────────────────────────
    -- Mirrors the pattern in message_processing_seed_data.sql.
    -- last_seen_mid = highest mid in the thread; total = message count.

    DELETE FROM message_thread_progress
    WHERE platform_id = pms_id
      AND thread_id BETWEEN 95000001 AND 95000004;

    INSERT INTO message_thread_progress
        (platform_id, thread_id, booking_id, last_seen_mid, last_seen_date_utc, "offset", "limit", total)
    VALUES
        (pms_id, 95000001, 54000001, 97000017, NOW() - INTERVAL '150 minutes', 0, 4, 4),
        (pms_id, 95000002, 54000002, 97000027, NOW() - INTERVAL '100 minutes', 0, 4, 4),
        (pms_id, 95000003, 54000003, 97000036, NOW() - INTERVAL '55 minutes',  0, 3, 3),
        (pms_id, 95000004, 54000004, 97000048, NOW() - INTERVAL '20 minutes',  0, 4, 4)
    ON CONFLICT DO NOTHING;

END $$;

COMMIT;


-- ============================================================================
-- VERIFICATION  (run manually)
-- ============================================================================
/*

-- Booking summary
SELECT
    id,
    arrival,
    departure,
    departure - arrival   AS nights,
    arrival - LAG(departure) OVER (ORDER BY arrival) AS gap_from_prev,
    arrival - CURRENT_DATE AS days_from_today
FROM booking_registers
WHERE id BETWEEN 54000001 AND 54000004
ORDER BY arrival;
-- Expect: 4 rows · nights=3 each · gap=5 each · days_from_today ≥ 91

-- Message counts per thread
SELECT thread_id, COUNT(*) AS msg_count
FROM messages
WHERE thread_id BETWEEN 95000001 AND 95000004
GROUP BY thread_id
ORDER BY thread_id;
-- Expect: 95000001→4, 95000002→4, 95000003→3, 95000004→4

-- Thread progress
SELECT thread_id, booking_id, last_seen_mid, total
FROM message_thread_progress
WHERE thread_id BETWEEN 95000001 AND 95000004
ORDER BY thread_id;
-- Expect: 4 rows matching the above counts

-- Confirm all arrivals are beyond 90 days
SELECT id, arrival, arrival - CURRENT_DATE AS days_out
FROM booking_registers
WHERE id BETWEEN 54000001 AND 54000004
  AND arrival - CURRENT_DATE <= 90;
-- Expect: 0 rows (all are > 90 days out)

*/
