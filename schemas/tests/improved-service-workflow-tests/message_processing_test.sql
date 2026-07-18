-- ============================================
-- MESSAGE PROCESSING SCHEMA - QUICK VALIDATION
-- ============================================
-- Assumes the schema in `schemas/message_processing.sql` is already installed.
--
-- Run (example):
--   psql -U n8n -d n8n -f schemas/tests/improved-service-workflow-tests/message_processing_test.sql
--
-- This script uses a transaction and rolls back to avoid leaving test data.

\echo '================================================'
\echo 'MESSAGE PROCESSING SCHEMA TESTS'
\echo '================================================'
\echo ''

BEGIN;

-- Preflight: ensure required tables from message_processing.sql are present
DO $$
BEGIN
  IF to_regclass('public.messages') IS NULL THEN
    RAISE EXCEPTION 'Missing table: messages (install message_processing.sql first)';
  END IF;
  IF to_regclass('public.message_classes') IS NULL THEN
    RAISE EXCEPTION 'Missing table: message_classes (install message_processing.sql first)';
  END IF;
  IF to_regclass('public.message_class_lookup') IS NULL THEN
    RAISE EXCEPTION 'Missing table: message_class_lookup (install message_processing.sql first)';
  END IF;
  IF to_regclass('public.message_processing_status') IS NULL THEN
    RAISE EXCEPTION 'Missing table: message_processing_status (install message_processing.sql first)';
  END IF;
END $$;

-- Per-run test context to avoid collisions in populated databases
CREATE TEMP TABLE msg_test_ctx AS
SELECT
  (100000 + (txid_current() % 900000))::INT AS platform_id,
  (txid_current()::BIGINT + 1000) AS thread_id,
  1::BIGINT AS mid1,
  2::BIGINT AS mid2;

DO $$
DECLARE
  v_platform_id INT;
BEGIN
  IF to_regclass('public.platforms') IS NULL THEN
    RETURN;
  END IF;

  SELECT platform_id INTO v_platform_id
  FROM msg_test_ctx;

  INSERT INTO platforms (id, name, type, is_active)
  VALUES (v_platform_id, 'message_processing_test_platform', 'pms', TRUE)
  ON CONFLICT (id) DO NOTHING;
END $$;

-- 1) Uniqueness: (platform_id, thread_id, mid)
\echo '-> Test 1: Unique (platform_id, thread_id, mid)...'

INSERT INTO messages (platform_id, thread_id, mid, content, message_timestamp)
SELECT platform_id, thread_id, mid1, 'hello', NOW()
FROM msg_test_ctx;

DO $$
BEGIN
  INSERT INTO messages (platform_id, thread_id, mid, content, message_timestamp)
  SELECT platform_id, thread_id, mid1, 'duplicate', NOW()
  FROM msg_test_ctx;
  RAISE EXCEPTION 'Expected unique_violation, but insert succeeded';
EXCEPTION WHEN unique_violation THEN
  RAISE NOTICE '  OK: unique_violation raised as expected';
END $$;

\echo ''

-- 2) Primary class rule: at most one primary per message
\echo '-> Test 2: At most one primary class per message...'

INSERT INTO message_classes (name, description)
VALUES ('booking_confirmation', 'Booking confirmation messages')
ON CONFLICT (name) DO NOTHING;

INSERT INTO message_classes (name, description)
VALUES ('medical', 'Medical-related messages')
ON CONFLICT (name) DO NOTHING;

INSERT INTO message_class_lookup (message_id, class_id, is_primary, source, confidence)
SELECT m.id, mc.id, TRUE, 'auto', 0.9
FROM messages m
JOIN message_classes mc ON mc.name = 'booking_confirmation'
JOIN msg_test_ctx c ON m.platform_id = c.platform_id AND m.thread_id = c.thread_id AND m.mid = c.mid1;

DO $$
DECLARE
  v_message_id BIGINT;
  v_class_id BIGINT;
BEGIN
  SELECT id INTO v_message_id
  FROM messages m
  JOIN msg_test_ctx c ON m.platform_id = c.platform_id AND m.thread_id = c.thread_id AND m.mid = c.mid1;

  SELECT id INTO v_class_id
  FROM message_classes
  WHERE name = 'medical';

  INSERT INTO message_class_lookup (message_id, class_id, is_primary, source, confidence)
  VALUES (v_message_id, v_class_id, TRUE, 'human', 0.8);

  RAISE EXCEPTION 'Expected unique_violation (primary class), but insert succeeded';
EXCEPTION WHEN unique_violation THEN
  RAISE NOTICE '  OK: unique_violation raised as expected (primary constraint)';
END $$;

\echo ''

-- 3) Search correctness: "thread contains class" (any message match)
\echo '-> Test 3: Thread contains class query...'

-- Another message in same thread, tagged differently (secondary tag)
INSERT INTO messages (platform_id, thread_id, mid, content, message_timestamp)
SELECT platform_id, thread_id, mid2, 'follow up', NOW()
FROM msg_test_ctx;

INSERT INTO message_class_lookup (message_id, class_id, is_primary, source)
SELECT m.id, mc.id, FALSE, 'auto'
FROM messages m
JOIN message_classes mc ON mc.name = 'medical'
JOIN msg_test_ctx c ON m.platform_id = c.platform_id AND m.thread_id = c.thread_id AND m.mid = c.mid2;

WITH thread_list AS (
  SELECT unnest(ARRAY[
    (SELECT thread_id FROM msg_test_ctx),
    (SELECT thread_id FROM msg_test_ctx) + 1
  ]::bigint[]) AS thread_id
)
SELECT DISTINCT m.thread_id
FROM thread_list tl
JOIN messages m
  ON m.platform_id = (SELECT platform_id FROM msg_test_ctx)
 AND m.thread_id = tl.thread_id
 AND m.deleted_at IS NULL
JOIN message_class_lookup mcl
  ON mcl.message_id = m.id
JOIN message_classes mc
  ON mc.id = mcl.class_id
WHERE mc.name = ANY (ARRAY['medical']::text[]);

\echo '  (Expect one row matching the test thread_id)'
\echo ''

-- 4) Status tracking: status row created by trigger
\echo '-> Test 4: Status row created on message insert...'

SELECT
  m.id AS message_id,
  mps.status,
  CASE WHEN mps.message_id IS NOT NULL THEN 'OK: status exists' ELSE 'MISSING: status row' END AS status_check
FROM messages m
LEFT JOIN message_processing_status mps ON mps.message_id = m.id
JOIN msg_test_ctx c ON m.platform_id = c.platform_id AND m.thread_id = c.thread_id AND m.mid = c.mid1;

\echo ''
\echo '-> Test 5: Status reset to pending when message content changes...'

UPDATE message_processing_status
SET status = 'completed',
    last_error = 'stale result'
WHERE message_id = (
  SELECT m.id
  FROM messages m
  JOIN msg_test_ctx c ON m.platform_id = c.platform_id AND m.thread_id = c.thread_id AND m.mid = c.mid1
);

UPDATE messages
SET content = 'hello updated'
WHERE id = (
  SELECT m.id
  FROM messages m
  JOIN msg_test_ctx c ON m.platform_id = c.platform_id AND m.thread_id = c.thread_id AND m.mid = c.mid1
);

SELECT
  m.id AS message_id,
  mps.status,
  mps.last_error,
  CASE
    WHEN mps.status = 'pending' AND mps.last_error IS NULL THEN 'OK: status reset'
    ELSE 'MISSING: status not reset'
  END AS status_reset_check
FROM messages m
JOIN message_processing_status mps ON mps.message_id = m.id
JOIN msg_test_ctx c ON m.platform_id = c.platform_id AND m.thread_id = c.thread_id AND m.mid = c.mid1;

\echo ''
\echo '-> Test 6: fetch_unclassified_messages claims pending rows in PK order...'

INSERT INTO messages (platform_id, thread_id, mid, content, message_timestamp)
SELECT platform_id, thread_id, 3, 'claim batch third', NOW()
FROM msg_test_ctx;

INSERT INTO messages (platform_id, thread_id, mid, content, message_timestamp)
SELECT platform_id, thread_id, 4, 'claim batch fourth', NOW()
FROM msg_test_ctx;

INSERT INTO messages (platform_id, thread_id, mid, content, message_timestamp)
SELECT platform_id, thread_id, 5, 'deleted candidate', NOW()
FROM msg_test_ctx;

UPDATE messages
SET deleted_at = NOW(),
    deleted_reason = 'test deleted'
WHERE id = (
  SELECT m.id
  FROM messages m
  JOIN msg_test_ctx c ON m.platform_id = c.platform_id AND m.thread_id = c.thread_id
  WHERE m.mid = 5
);

CREATE TEMP TABLE claim_batch_one AS
SELECT *
FROM fetch_unclassified_messages(2);

DO $$
DECLARE
  v_expected BIGINT[];
  v_actual BIGINT[];
BEGIN
  SELECT array_agg(id ORDER BY id)
  INTO v_expected
  FROM (
    SELECT m.id
    FROM messages m
    JOIN msg_test_ctx c ON m.platform_id = c.platform_id AND m.thread_id = c.thread_id
    WHERE m.deleted_at IS NULL
      AND m.mid IN (1, 2, 3, 4)
    ORDER BY m.id ASC
    LIMIT 2
  ) expected_rows;

  SELECT array_agg(message_id ORDER BY message_id)
  INTO v_actual
  FROM claim_batch_one;

  IF v_actual IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'Unexpected first claim batch. Expected %, got %', v_expected, v_actual;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM message_processing_status
    WHERE message_id = ANY(v_actual)
      AND status <> 'processing'
  ) THEN
    RAISE EXCEPTION 'Claimed rows were not moved to processing';
  END IF;
END $$;

SELECT *
FROM claim_batch_one
ORDER BY message_id;

\echo ''
\echo '-> Test 7: second claim skips processing rows and deleted rows...'

CREATE TEMP TABLE claim_batch_two AS
SELECT *
FROM fetch_unclassified_messages(10);

DO $$
DECLARE
  v_expected BIGINT[];
  v_actual BIGINT[];
BEGIN
  SELECT array_agg(id ORDER BY id)
  INTO v_expected
  FROM (
    SELECT m.id
    FROM messages m
    JOIN msg_test_ctx c ON m.platform_id = c.platform_id AND m.thread_id = c.thread_id
    WHERE m.deleted_at IS NULL
      AND m.mid IN (3, 4)
    ORDER BY m.id ASC
  ) expected_rows;

  SELECT array_agg(message_id ORDER BY message_id)
  INTO v_actual
  FROM claim_batch_two;

  IF v_actual IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'Unexpected second claim batch. Expected %, got %', v_expected, v_actual;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM claim_batch_two cb
    JOIN messages m ON m.id = cb.message_id
    WHERE m.deleted_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Deleted rows must not be claimed';
  END IF;
END $$;

SELECT *
FROM claim_batch_two
ORDER BY message_id;

\echo ''
\echo '-> Test 8: stale processing rows can be requeued...'

CREATE TEMP TABLE requeue_none AS
SELECT *
FROM requeue_stale_processing_messages('1 hour');

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM requeue_none) THEN
    RAISE EXCEPTION 'Fresh processing rows should not be requeued by a long threshold';
  END IF;
END $$;

SELECT pg_sleep(1.1);

CREATE TEMP TABLE requeue_batch AS
SELECT *
FROM requeue_stale_processing_messages('0.5 seconds');

DO $$
DECLARE
  v_expected BIGINT[];
  v_actual BIGINT[];
BEGIN
  SELECT array_agg(message_id ORDER BY message_id)
  INTO v_expected
  FROM (
    SELECT message_id FROM claim_batch_one
    UNION ALL
    SELECT message_id FROM claim_batch_two
  ) expected_rows;

  SELECT array_agg(message_id ORDER BY message_id)
  INTO v_actual
  FROM requeue_batch;

  IF v_actual IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'Unexpected requeue batch. Expected %, got %', v_expected, v_actual;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM message_processing_status
    WHERE message_id = ANY(v_actual)
      AND (status <> 'pending' OR last_error <> 'processing timeout')
  ) THEN
    RAISE EXCEPTION 'Requeued rows must be pending with processing timeout';
  END IF;
END $$;

SELECT *
FROM requeue_batch
ORDER BY message_id;

\echo ''
\echo '-> Test 9: requeued rows are claimable again...'

CREATE TEMP TABLE claim_batch_three AS
SELECT *
FROM fetch_unclassified_messages(10);

DO $$
DECLARE
  v_expected BIGINT[];
  v_actual BIGINT[];
BEGIN
  SELECT array_agg(message_id ORDER BY message_id)
  INTO v_expected
  FROM requeue_batch;

  SELECT array_agg(message_id ORDER BY message_id)
  INTO v_actual
  FROM claim_batch_three;

  IF v_actual IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'Unexpected third claim batch. Expected %, got %', v_expected, v_actual;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM message_processing_status
    WHERE message_id = ANY(v_actual)
      AND status <> 'processing'
  ) THEN
    RAISE EXCEPTION 'Reclaimed rows were not moved back to processing';
  END IF;
END $$;

SELECT *
FROM claim_batch_three
ORDER BY message_id;

\echo ''
\echo '-> Test 10: get_thread_primary_classes returns deduplicated sorted primary classes...'

CREATE TEMP TABLE class_test_ctx AS
SELECT ('deleted_only_' || txid_current())::TEXT AS deleted_class_name;

INSERT INTO message_classes (name, description)
SELECT deleted_class_name, 'Deleted-only primary test class'
FROM class_test_ctx;

INSERT INTO messages (platform_id, thread_id, mid, content, message_timestamp)
SELECT platform_id, thread_id, 6, 'primary medical', NOW()
FROM msg_test_ctx;

INSERT INTO messages (platform_id, thread_id, mid, content, message_timestamp)
SELECT platform_id, thread_id, 7, 'deleted class message', NOW()
FROM msg_test_ctx;

INSERT INTO messages (platform_id, thread_id, mid, content, message_timestamp)
SELECT platform_id, thread_id, 8, 'duplicate primary medical', NOW()
FROM msg_test_ctx;

UPDATE messages
SET deleted_at = NOW(),
    deleted_reason = 'deleted class test'
WHERE id = (
  SELECT m.id
  FROM messages m
  JOIN msg_test_ctx c ON m.platform_id = c.platform_id AND m.thread_id = c.thread_id
  WHERE m.mid = 7
);

INSERT INTO message_class_lookup (message_id, class_id, is_primary, source)
SELECT m.id, mc.id, TRUE, 'auto'
FROM messages m
JOIN message_classes mc ON mc.name = 'medical'
JOIN msg_test_ctx c ON m.platform_id = c.platform_id AND m.thread_id = c.thread_id
WHERE m.mid = 6;

INSERT INTO message_class_lookup (message_id, class_id, is_primary, source)
SELECT m.id, mc.id, TRUE, 'auto'
FROM messages m
JOIN message_classes mc ON mc.name = 'medical'
JOIN msg_test_ctx c ON m.platform_id = c.platform_id AND m.thread_id = c.thread_id
WHERE m.mid = 8;

INSERT INTO message_class_lookup (message_id, class_id, is_primary, source)
SELECT m.id, mc.id, TRUE, 'auto'
FROM messages m
JOIN msg_test_ctx c ON m.platform_id = c.platform_id AND m.thread_id = c.thread_id
JOIN class_test_ctx ct ON TRUE
JOIN message_classes mc ON mc.name = ct.deleted_class_name
WHERE m.mid = 7;

CREATE TEMP TABLE thread_primary_classes_result AS
SELECT *
FROM get_thread_primary_classes(
  (SELECT platform_id FROM msg_test_ctx),
  (SELECT thread_id FROM msg_test_ctx)
);

DO $$
DECLARE
  v_classes TEXT[];
BEGIN
  SELECT classes INTO v_classes
  FROM thread_primary_classes_result;

  IF v_classes IS DISTINCT FROM ARRAY['booking_confirmation', 'medical']::TEXT[] THEN
    RAISE EXCEPTION 'Unexpected classes for thread primary lookup. Expected %, got %',
      ARRAY['booking_confirmation', 'medical']::TEXT[],
      v_classes;
  END IF;
END $$;

SELECT *
FROM thread_primary_classes_result;

\echo ''
\echo '-> Test 11: get_thread_primary_classes ignores deleted-only thread rows...'

CREATE TEMP TABLE deleted_thread_ctx AS
SELECT
  (SELECT platform_id FROM msg_test_ctx) AS platform_id,
  (SELECT thread_id FROM msg_test_ctx) + 99999 AS thread_id;

INSERT INTO messages (platform_id, thread_id, mid, content, message_timestamp)
SELECT platform_id, thread_id, 1, 'deleted-only thread message', NOW()
FROM deleted_thread_ctx;

UPDATE messages
SET deleted_at = NOW(),
    deleted_reason = 'deleted-only-thread'
WHERE id = (
  SELECT m.id
  FROM messages m
  JOIN deleted_thread_ctx d ON m.platform_id = d.platform_id AND m.thread_id = d.thread_id
  WHERE m.mid = 1
);

INSERT INTO message_class_lookup (message_id, class_id, is_primary, source)
SELECT m.id, mc.id, TRUE, 'auto'
FROM messages m
JOIN deleted_thread_ctx d ON m.platform_id = d.platform_id AND m.thread_id = d.thread_id
JOIN message_classes mc ON mc.name = 'medical'
WHERE m.mid = 1;

CREATE TEMP TABLE deleted_thread_classes_result AS
SELECT *
FROM get_thread_primary_classes(
  (SELECT platform_id FROM deleted_thread_ctx),
  (SELECT thread_id FROM deleted_thread_ctx)
);

DO $$
DECLARE
  v_classes TEXT[];
BEGIN
  SELECT classes INTO v_classes
  FROM deleted_thread_classes_result;

  IF v_classes IS DISTINCT FROM ARRAY[]::TEXT[] THEN
    RAISE EXCEPTION 'Deleted-only thread should return empty classes, got %', v_classes;
  END IF;
END $$;

SELECT *
FROM deleted_thread_classes_result;

\echo ''
\echo '-> Test 12: fetch_unclassified_messages supports optional role filtering...'

UPDATE message_processing_status
SET status = 'completed',
    last_error = NULL
WHERE status IN ('pending', 'processing');

CREATE TEMP TABLE role_filter_ctx AS
SELECT
  (SELECT platform_id FROM msg_test_ctx) AS platform_id,
  (SELECT thread_id FROM msg_test_ctx) + 123456 AS thread_id;

INSERT INTO messages (platform_id, thread_id, mid, content, message_timestamp, metadata)
SELECT platform_id, thread_id, 1, 'guest role filter message', NOW(), '{"from_role":"guest"}'::JSONB
FROM role_filter_ctx;

INSERT INTO messages (platform_id, thread_id, mid, content, message_timestamp, metadata)
SELECT platform_id, thread_id, 2, 'owner role filter message', NOW(), '{"from_role":"owner"}'::JSONB
FROM role_filter_ctx;

INSERT INTO messages (platform_id, thread_id, mid, content, message_timestamp, metadata)
SELECT platform_id, thread_id, 3, 'co-host role filter message', NOW(), '{"from_role":"co_host"}'::JSONB
FROM role_filter_ctx;

CREATE TEMP TABLE role_filtered_batch AS
SELECT *
FROM fetch_unclassified_messages(10, 'guest');

DO $$
DECLARE
  v_guest_id BIGINT;
  v_actual BIGINT[];
BEGIN
  SELECT m.id
  INTO v_guest_id
  FROM messages m
  JOIN role_filter_ctx c ON m.platform_id = c.platform_id AND m.thread_id = c.thread_id
  WHERE m.mid = 1;

  SELECT array_agg(message_id ORDER BY message_id)
  INTO v_actual
  FROM role_filtered_batch;

  IF v_actual IS DISTINCT FROM ARRAY[v_guest_id]::BIGINT[] THEN
    RAISE EXCEPTION 'Role-filtered claim should only include guest message. Expected %, got %',
      ARRAY[v_guest_id]::BIGINT[],
      v_actual;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM messages m
    JOIN role_filter_ctx c ON m.platform_id = c.platform_id AND m.thread_id = c.thread_id
    JOIN message_processing_status mps ON mps.message_id = m.id
    WHERE m.mid IN (2, 3)
      AND mps.status <> 'pending'
  ) THEN
    RAISE EXCEPTION 'Non-guest role rows must remain pending after guest-filtered claim';
  END IF;
END $$;

CREATE TEMP TABLE role_unfiltered_batch AS
SELECT *
FROM fetch_unclassified_messages(10);

DO $$
DECLARE
  v_expected BIGINT[];
  v_actual BIGINT[];
BEGIN
  SELECT array_agg(m.id ORDER BY m.id)
  INTO v_expected
  FROM messages m
  JOIN role_filter_ctx c ON m.platform_id = c.platform_id AND m.thread_id = c.thread_id
  WHERE m.mid IN (2, 3);

  SELECT array_agg(message_id ORDER BY message_id)
  INTO v_actual
  FROM role_unfiltered_batch;

  IF v_actual IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'One-argument claim should remain unfiltered. Expected %, got %',
      v_expected,
      v_actual;
  END IF;
END $$;

SELECT *
FROM role_filtered_batch
ORDER BY message_id;

SELECT *
FROM role_unfiltered_batch
ORDER BY message_id;

\echo ''
\echo 'All tests executed (transaction will be rolled back).'
\echo ''

ROLLBACK;
