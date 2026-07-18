-- ============================================
-- SECURE TASK SCHEDULER TEST SUITE (POSTGRESQL)
-- Run AFTER schemas/secure_task_scheduler.sql
-- ============================================

BEGIN;
SET LOCAL TIME ZONE 'UTC';

-- --------------------------------------------
-- 0) BASIC SANITY CHECKS
-- --------------------------------------------
DO $$
BEGIN
    IF to_regtype('task_status') IS NULL THEN
        RAISE EXCEPTION 'Missing type: task_status';
    END IF;
    IF to_regtype('task_type') IS NULL THEN
        RAISE EXCEPTION 'Missing type: task_type';
    END IF;
    IF to_regtype('audit_operation') IS NULL THEN
        RAISE EXCEPTION 'Missing type: audit_operation';
    END IF;

    IF to_regclass('public.worker_api_keys') IS NULL THEN
        RAISE EXCEPTION 'Missing table: worker_api_keys';
    END IF;
    IF to_regclass('public.rate_limits') IS NULL THEN
        RAISE EXCEPTION 'Missing table: rate_limits';
    END IF;
    IF to_regclass('public.audit_log') IS NULL THEN
        RAISE EXCEPTION 'Missing table: audit_log';
    END IF;
    IF to_regclass('public.queue_registry') IS NULL THEN
        RAISE EXCEPTION 'Missing table: queue_registry';
    END IF;
    IF to_regclass('public.task_queue') IS NULL THEN
        RAISE EXCEPTION 'Missing table: task_queue';
    END IF;
    IF to_regclass('public.worker_registry') IS NULL THEN
        RAISE EXCEPTION 'Missing table: worker_registry';
    END IF;
    IF to_regclass('public.scheduler_config') IS NULL THEN
        RAISE EXCEPTION 'Missing table: scheduler_config';
    END IF;
    IF to_regprocedure('get_task_ancestors_descendants(uuid)') IS NULL THEN
        RAISE EXCEPTION 'Missing function: get_task_ancestors_descendants(uuid)';
    END IF;
    IF to_regprocedure('promote_scheduled_tasks()') IS NULL THEN
        RAISE EXCEPTION 'Missing function: promote_scheduled_tasks()';
    END IF;
    IF to_regclass('public.idx_task_queue_parent_task_uuid_text') IS NULL THEN
        RAISE EXCEPTION 'Missing index: idx_task_queue_parent_task_uuid_text';
    END IF;
END $$;

-- Ensure default config exists
DO $$
DECLARE
    v_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_count FROM scheduler_config;
    IF v_count = 0 THEN
        RAISE EXCEPTION 'scheduler_config is empty';
    END IF;
END $$;

-- --------------------------------------------
-- 1) SETUP TEST QUEUES
-- --------------------------------------------
SELECT create_queue('test_queue_a', 'Test queue A');
SELECT create_queue('test_queue_b', 'Test queue B');

-- --------------------------------------------
-- 2) TEST CONTEXT
-- --------------------------------------------
CREATE TEMP TABLE test_context (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TEMP TABLE test_tasks (
    name TEXT PRIMARY KEY,
    task_uuid UUID,
    task_id BIGINT
);

-- Register a worker and store api key
DO $$
DECLARE
    v_worker_id TEXT;
    v_api_key TEXT;
    v_worker2_id TEXT;
    v_api_key2 TEXT;
BEGIN
    v_worker_id := 'test-worker-' || txid_current();

    SELECT worker_id, api_key
    INTO v_worker_id, v_api_key
    FROM register_worker(
        v_worker_id,
        'Test Worker',
        5,
        '30 seconds'::INTERVAL,
        '["default", "test_queue_a"]'::JSONB
    );

    INSERT INTO test_context(key, value) VALUES
        ('worker_id', v_worker_id),
        ('api_key', v_api_key);

    -- Secondary worker for ordering/concurrency tests
    v_worker2_id := v_worker_id || '-2';
    SELECT worker_id, api_key
    INTO v_worker2_id, v_api_key2
    FROM register_worker(
        v_worker2_id,
        'Test Worker 2',
        5,
        '30 seconds'::INTERVAL,
        '["default", "test_queue_a"]'::JSONB
    );

    INSERT INTO test_context(key, value) VALUES
        ('worker2_id', v_worker2_id),
        ('worker2_api_key', v_api_key2);
END $$;

-- --------------------------------------------
-- 3) WORKER AUTH + SUBSCRIPTIONS
-- --------------------------------------------
DO $$
DECLARE
    v_worker_id TEXT;
    v_api_key TEXT;
    v_returned TEXT;
    v_subscribed JSONB;
BEGIN
    SELECT value INTO v_worker_id FROM test_context WHERE key = 'worker_id';
    SELECT value INTO v_api_key FROM test_context WHERE key = 'api_key';

    v_returned := validate_worker_auth(v_api_key);
    IF v_returned <> v_worker_id THEN
        RAISE EXCEPTION 'validate_worker_auth returned % expected %', v_returned, v_worker_id;
    END IF;

    -- Invalid key should fail
    BEGIN
        PERFORM validate_worker_auth('invalid_key');
        RAISE EXCEPTION 'Expected invalid key error not raised';
    EXCEPTION WHEN OTHERS THEN
        -- expected
    END;

    -- Update subscriptions
    PERFORM update_worker_subscriptions(v_api_key, '["default", "test_queue_a", "test_queue_b"]'::JSONB);

    SELECT subscribed_queues INTO v_subscribed
    FROM worker_registry
    WHERE worker_id = v_worker_id;

    IF v_subscribed ? 'test_queue_b' IS NOT TRUE THEN
        RAISE EXCEPTION 'update_worker_subscriptions did not apply test_queue_b';
    END IF;

    -- Lease duration too long should raise
    BEGIN
        PERFORM dequeue_task(v_api_key, '2 hours'::INTERVAL, ARRAY['test_queue_a']);
        RAISE EXCEPTION 'Expected lease duration exception not raised';
    EXCEPTION WHEN OTHERS THEN
        -- expected
    END;

    -- Queue overlap empty should raise
    BEGIN
        PERFORM dequeue_task(v_api_key, '5 minutes'::INTERVAL, ARRAY['payment']);
        RAISE EXCEPTION 'Expected queue overlap exception not raised';
    EXCEPTION WHEN OTHERS THEN
        -- expected
    END;
END $$;

-- Worker heartbeat
DO $$
DECLARE
    v_worker_id TEXT;
    v_api_key TEXT;
    v_before_load INTEGER;
    v_after_load INTEGER;
BEGIN
    SELECT value INTO v_worker_id FROM test_context WHERE key = 'worker_id';
    SELECT value INTO v_api_key FROM test_context WHERE key = 'api_key';

    SELECT current_load INTO v_before_load FROM worker_registry WHERE worker_id = v_worker_id;
    PERFORM worker_heartbeat(v_api_key, 2, '30 seconds'::INTERVAL);
    SELECT current_load INTO v_after_load FROM worker_registry WHERE worker_id = v_worker_id;

    IF v_after_load <> 2 OR v_after_load = v_before_load THEN
        RAISE EXCEPTION 'worker_heartbeat did not update current_load';
    END IF;
END $$;

-- --------------------------------------------
-- 4) RATE LIMIT + DATA SIZE VALIDATION
-- --------------------------------------------
DO $$
BEGIN
    PERFORM check_rate_limit('test_rl', 'op', 2, 60);
    PERFORM check_rate_limit('test_rl', 'op', 2, 60);
    BEGIN
        PERFORM check_rate_limit('test_rl', 'op', 2, 60);
        RAISE EXCEPTION 'Expected rate limit exception not raised';
    EXCEPTION WHEN OTHERS THEN
        -- expected
    END;
END $$;

DO $$
BEGIN
    PERFORM validate_task_data_size('{"ok":true}'::JSONB, 1);
    -- Below limit (~80 KB) should pass
    PERFORM validate_task_data_size(jsonb_build_object('blob', repeat('b', 80 * 1024)), 100);
    BEGIN
        PERFORM validate_task_data_size(jsonb_build_object('blob', repeat('a', 110 * 1024)), 100);
        RAISE EXCEPTION 'Expected data size exception not raised';
    EXCEPTION WHEN OTHERS THEN
        -- expected
    END;
END $$;

-- --------------------------------------------
-- 5) AUDIT LOG + CALCULATE NEXT RUN
-- --------------------------------------------
DO $$
DECLARE
    v_before INTEGER;
    v_after INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_before FROM audit_log;
    PERFORM log_audit('enqueue', 'test', NULL, 'tester', NULL, NULL, TRUE, NULL);
    SELECT COUNT(*) INTO v_after FROM audit_log;

    IF v_after <> v_before + 1 THEN
        RAISE EXCEPTION 'audit_log count did not increment';
    END IF;
END $$;

DO $$
DECLARE
    v_base TIMESTAMPTZ := '2024-01-01 10:15:00+00';
BEGIN
    IF calculate_next_run('hourly', v_base) <> '2024-01-01 11:00:00+00'::TIMESTAMPTZ THEN
        RAISE EXCEPTION 'calculate_next_run hourly failed';
    END IF;
    IF calculate_next_run('daily', v_base) <> '2024-01-02 00:00:00+00'::TIMESTAMPTZ THEN
        RAISE EXCEPTION 'calculate_next_run daily failed';
    END IF;
    IF calculate_next_run('weekly', v_base) <> '2024-01-08 00:00:00+00'::TIMESTAMPTZ THEN
        RAISE EXCEPTION 'calculate_next_run weekly failed';
    END IF;
    IF calculate_next_run('monthly', v_base) <> '2024-02-01 00:00:00+00'::TIMESTAMPTZ THEN
        RAISE EXCEPTION 'calculate_next_run monthly failed';
    END IF;
    IF calculate_next_run('daily', '2024-03-08 16:00:00+00'::TIMESTAMPTZ, '10:00:00'::TIME, 'America/New_York')
        <> '2024-03-09 15:00:00+00'::TIMESTAMPTZ THEN
        RAISE EXCEPTION 'calculate_next_run daily local pre-DST failed';
    END IF;
    IF calculate_next_run('daily', '2024-03-09 16:00:00+00'::TIMESTAMPTZ, '10:00:00'::TIME, 'America/New_York')
        <> '2024-03-10 14:00:00+00'::TIMESTAMPTZ THEN
        RAISE EXCEPTION 'calculate_next_run daily local DST shift failed';
    END IF;
    IF calculate_next_run('daily', '2024-11-03 16:30:00+00'::TIMESTAMPTZ, '10:00:00'::TIME, 'America/New_York')
        <> '2024-11-04 15:00:00+00'::TIMESTAMPTZ THEN
        RAISE EXCEPTION 'calculate_next_run daily local post-DST failed';
    END IF;

    BEGIN
        PERFORM calculate_next_run('yearly', v_base);
        RAISE EXCEPTION 'Expected invalid recurrence exception not raised';
    EXCEPTION WHEN OTHERS THEN
        -- expected
    END;

    BEGIN
        PERFORM calculate_next_run('daily', v_base, '10:00:00'::TIME, NULL);
        RAISE EXCEPTION 'Expected recurrence pair validation exception not raised';
    EXCEPTION WHEN OTHERS THEN
        -- expected
    END;
END $$;

-- --------------------------------------------
-- 6) ENQUEUE TEST TASKS
-- --------------------------------------------
DO $$
DECLARE
    v_api_key TEXT;
    v_status task_status;
BEGIN
    SELECT value INTO v_api_key FROM test_context WHERE key = 'api_key';

    -- Scheduled task should be scheduled
    INSERT INTO test_tasks(name, task_uuid)
    SELECT 'scheduled_task', enqueue_task(
        v_api_key,
        'task_scheduled',
        '{"a": 2}'::JSONB,
        'delayed',
        5,
        NOW() + INTERVAL '1 hour',
        3,
        NULL,
        'test_queue_a'
    );

    SELECT status INTO v_status
    FROM task_queue
    WHERE task_uuid = (SELECT task_uuid FROM test_tasks WHERE name = 'scheduled_task');

    IF v_status <> 'scheduled' THEN
        RAISE EXCEPTION 'scheduled_task status expected scheduled, got %', v_status;
    END IF;

    -- Queue A tasks (priority order: retry > fail_final > stuck_reset > pending)
    INSERT INTO test_tasks(name, task_uuid)
    SELECT 'retry_task', enqueue_task(
        v_api_key,
        'task_for_retry',
        '{}'::JSONB,
        'immediate',
        90,
        NOW() - INTERVAL '1 minute',
        3,
        NULL,
        'test_queue_a'
    );

    INSERT INTO test_tasks(name, task_uuid)
    SELECT 'fail_final_task', enqueue_task(
        v_api_key,
        'task_fail_final',
        '{}'::JSONB,
        'immediate',
        80,
        NOW() - INTERVAL '1 minute',
        1,
        NULL,
        'test_queue_a'
    );

    INSERT INTO test_tasks(name, task_uuid)
    SELECT 'stuck_task', enqueue_task(
        v_api_key,
        'task_stuck_reset',
        '{}'::JSONB,
        'immediate',
        70,
        NOW() - INTERVAL '1 minute',
        3,
        NULL,
        'test_queue_a'
    );

    INSERT INTO test_tasks(name, task_uuid)
    SELECT 'pending_task', enqueue_task(
        v_api_key,
        'task_pending',
        '{}'::JSONB,
        'immediate',
        10,
        NOW() - INTERVAL '1 minute',
        3,
        NULL,
        'test_queue_a'
    );

    -- Queue B recurring task
    INSERT INTO test_tasks(name, task_uuid)
    SELECT 'recurring_task', enqueue_task(
        v_api_key,
        'task_recurring',
        '{"k": 1}'::JSONB,
        'recurring',
        99,
        NOW() - INTERVAL '1 minute',
        3,
        'daily',
        'test_queue_b'
    );

    INSERT INTO test_tasks(name, task_uuid)
    SELECT 'recurring_local_time_task', enqueue_task(
        v_api_key,
        'task_recurring_local_time',
        '{"k": 2}'::JSONB,
        'recurring',
        98,
        NOW() - INTERVAL '1 minute',
        3,
        'daily',
        'test_queue_b',
        '10:00:00'::TIME,
        'America/New_York'
    );

    -- Max attempts upper bound should fail
    BEGIN
        PERFORM enqueue_task(
            v_api_key,
            'too_many_attempts',
            '{}'::JSONB,
            'immediate',
            0,
            NOW(),
            11,
            NULL,
            'test_queue_a'
        );
        RAISE EXCEPTION 'Expected max_attempts upper bound exception not raised';
    EXCEPTION WHEN OTHERS THEN
        -- expected
    END;

    -- Priority upper bound should fail
    BEGIN
        PERFORM enqueue_task(
            v_api_key,
            'bad_priority',
            '{}'::JSONB,
            'immediate',
            101,
            NOW(),
            3,
            NULL,
            'test_queue_a'
        );
        RAISE EXCEPTION 'Expected priority upper bound exception not raised';
    EXCEPTION WHEN OTHERS THEN
        -- expected
    END;

    -- Invalid queue should fail
    BEGIN
        PERFORM enqueue_task(
            v_api_key,
            'bad_queue',
            '{}'::JSONB,
            'immediate',
            0,
            NOW(),
            3,
            NULL,
            'no_such_queue'
        );
        RAISE EXCEPTION 'Expected invalid queue error not raised';
    EXCEPTION WHEN OTHERS THEN
        -- expected
    END;

    BEGIN
        PERFORM enqueue_task(
            v_api_key,
            'bad_recurrence_timezone_pair',
            '{}'::JSONB,
            'recurring',
            0,
            NOW(),
            3,
            'daily',
            'test_queue_a',
            '10:00:00'::TIME,
            NULL
        );
        RAISE EXCEPTION 'Expected recurrence pair error not raised';
    EXCEPTION WHEN OTHERS THEN
        -- expected
    END;

    BEGIN
        PERFORM enqueue_task(
            v_api_key,
            'bad_recurrence_timezone',
            '{}'::JSONB,
            'recurring',
            0,
            NOW(),
            3,
            'daily',
            'test_queue_a',
            '10:00:00'::TIME,
            'No/Such_Timezone'
        );
        RAISE EXCEPTION 'Expected invalid recurrence timezone error not raised';
    EXCEPTION WHEN OTHERS THEN
        -- expected
    END;
END $$;

-- --------------------------------------------
-- 6B) PROMOTE SCHEDULED TASKS
-- --------------------------------------------
DO $$
DECLARE
    v_api_key TEXT;
    v_promoted_task_uuid UUID;
    v_promoted_count INTEGER;
    v_status task_status;
    v_dequeued_task_id BIGINT;
    v_dequeued_task_name TEXT;
BEGIN
    SELECT value INTO v_api_key FROM test_context WHERE key = 'api_key';

    v_promoted_task_uuid := enqueue_task(
        v_api_key,
        'task_due_promotion',
        '{"source":"scheduled-promotion-test"}'::JSONB,
        'delayed',
        100,
        NOW() + INTERVAL '5 minutes',
        3,
        NULL,
        'test_queue_a'
    );

    -- Keep status scheduled, but force due for promotion.
    UPDATE task_queue
    SET scheduled_at = NOW() - INTERVAL '1 minute',
        status = 'scheduled'
    WHERE task_uuid = v_promoted_task_uuid;

    SELECT promote_scheduled_tasks() INTO v_promoted_count;
    IF v_promoted_count < 1 THEN
        RAISE EXCEPTION 'promote_scheduled_tasks expected to promote at least one task';
    END IF;

    SELECT status INTO v_status
    FROM task_queue
    WHERE task_uuid = v_promoted_task_uuid;

    IF v_status <> 'pending' THEN
        RAISE EXCEPTION 'promote_scheduled_tasks expected pending status, got %', v_status;
    END IF;

    SELECT task_id, task_name INTO v_dequeued_task_id, v_dequeued_task_name
    FROM dequeue_task(v_api_key, '5 minutes'::INTERVAL, ARRAY['test_queue_a'])
    LIMIT 1;

    IF v_dequeued_task_name <> 'task_due_promotion' THEN
        RAISE EXCEPTION 'Expected promoted task_due_promotion, got %', v_dequeued_task_name;
    END IF;

    PERFORM complete_task(v_api_key, v_dequeued_task_id, '{"result":"promoted"}'::JSONB);
END $$;

-- Populate task IDs
UPDATE test_tasks t
SET task_id = q.id
FROM task_queue q
WHERE q.task_uuid = t.task_uuid;

-- --------------------------------------------
-- 7) DEQUEUE + PROCESSING VIEW + HEARTBEAT
-- --------------------------------------------
CREATE TEMP TABLE test_dequeue_retry AS
SELECT * FROM dequeue_task(
    (SELECT value FROM test_context WHERE key = 'api_key'),
    '5 minutes'::INTERVAL,
    ARRAY['test_queue_a']
);

DO $$
DECLARE
    v_task_name TEXT;
    v_task_id BIGINT;
    v_view_count INTEGER;
BEGIN
    SELECT task_name, task_id INTO v_task_name, v_task_id FROM test_dequeue_retry;

    IF v_task_name <> 'task_for_retry' THEN
        RAISE EXCEPTION 'Expected task_for_retry, got %', v_task_name;
    END IF;

    -- processing_tasks view should include the task
    SELECT COUNT(*) INTO v_view_count FROM processing_tasks WHERE id = v_task_id;
    IF v_view_count <> 1 THEN
        RAISE EXCEPTION 'processing_tasks view missing task %', v_task_id;
    END IF;
END $$;

-- Make local-time recurring task eligible for dequeue and verify reschedule keeps 10:00 local wall-clock
UPDATE task_queue
SET status = 'pending',
    scheduled_at = NOW() - INTERVAL '1 minute',
    worker_id = NULL,
    lease_expires_at = NULL,
    started_at = NULL
WHERE task_uuid = (SELECT task_uuid FROM test_tasks WHERE name = 'recurring_local_time_task');

CREATE TEMP TABLE test_dequeue_recurring_local_time AS
SELECT * FROM dequeue_task(
    (SELECT value FROM test_context WHERE key = 'api_key'),
    '5 minutes'::INTERVAL,
    ARRAY['test_queue_b']
);

DO $$
DECLARE
    v_api_key TEXT;
    v_task_name TEXT;
    v_task_id BIGINT;
    v_status task_status;
    v_next_scheduled TIMESTAMPTZ;
    v_next_local_time TIME;
    v_recurrence_time TIME;
    v_recurrence_timezone TEXT;
BEGIN
    SELECT value INTO v_api_key FROM test_context WHERE key = 'api_key';
    SELECT task_name, task_id INTO v_task_name, v_task_id FROM test_dequeue_recurring_local_time;

    IF v_task_name <> 'task_recurring_local_time' THEN
        RAISE EXCEPTION 'Expected task_recurring_local_time, got %', v_task_name;
    END IF;

    PERFORM complete_task(v_api_key, v_task_id, '{"result": "local_time"}'::JSONB);

    SELECT status INTO v_status FROM task_queue WHERE id = v_task_id;
    IF v_status <> 'completed' THEN
        RAISE EXCEPTION 'complete_task expected completed for local-time recurrence, got %', v_status;
    END IF;

    SELECT scheduled_at, recurrence_time, recurrence_timezone
    INTO v_next_scheduled, v_recurrence_time, v_recurrence_timezone
    FROM task_queue
    WHERE task_name = 'task_recurring_local_time'
      AND recurrence_pattern = 'daily'
      AND status = 'scheduled'
    ORDER BY created_at DESC
    LIMIT 1;

    IF v_next_scheduled IS NULL THEN
        RAISE EXCEPTION 'local-time recurring task did not create next scheduled task';
    END IF;
    IF v_recurrence_time <> '10:00:00'::TIME THEN
        RAISE EXCEPTION 'local-time recurring task lost recurrence_time metadata';
    END IF;
    IF v_recurrence_timezone <> 'America/New_York' THEN
        RAISE EXCEPTION 'local-time recurring task lost recurrence_timezone metadata';
    END IF;

    v_next_local_time := (v_next_scheduled AT TIME ZONE 'America/New_York')::TIME;
    IF v_next_local_time <> '10:00:00'::TIME THEN
        RAISE EXCEPTION 'local-time recurring task next run is not 10:00 America/New_York; got %', v_next_local_time;
    END IF;
END $$;

DO $$
DECLARE
    v_api_key TEXT;
    v_task_id BIGINT;
    v_old TIMESTAMPTZ;
    v_new TIMESTAMPTZ;
BEGIN
    SELECT value INTO v_api_key FROM test_context WHERE key = 'api_key';
    SELECT task_id INTO v_task_id FROM test_dequeue_retry;

    SELECT lease_expires_at INTO v_old FROM task_queue WHERE id = v_task_id;
    PERFORM heartbeat_task(v_api_key, v_task_id, '10 minutes'::INTERVAL);
    SELECT lease_expires_at INTO v_new FROM task_queue WHERE id = v_task_id;

    IF v_new <= v_old THEN
        RAISE EXCEPTION 'heartbeat_task did not extend lease';
    END IF;
END $$;

-- --------------------------------------------
-- 8) FAIL TASK (RETRYING)
-- --------------------------------------------
DO $$
DECLARE
    v_api_key TEXT;
    v_task_id BIGINT;
    v_status task_status;
    v_scheduled TIMESTAMPTZ;
BEGIN
    SELECT value INTO v_api_key FROM test_context WHERE key = 'api_key';
    SELECT task_id INTO v_task_id FROM test_dequeue_retry;

    PERFORM fail_task(v_api_key, v_task_id, 'expected failure', '1 minute'::INTERVAL);

    SELECT status, scheduled_at INTO v_status, v_scheduled
    FROM task_queue
    WHERE id = v_task_id;

    IF v_status <> 'retrying' THEN
        RAISE EXCEPTION 'fail_task expected retrying, got %', v_status;
    END IF;

    IF v_scheduled <= NOW() THEN
        RAISE EXCEPTION 'retrying task scheduled_at not in future';
    END IF;
END $$;

-- --------------------------------------------
-- 9) FAIL TASK (FINAL FAIL)
-- --------------------------------------------
CREATE TEMP TABLE test_dequeue_fail_final AS
SELECT * FROM dequeue_task(
    (SELECT value FROM test_context WHERE key = 'api_key'),
    '5 minutes'::INTERVAL,
    ARRAY['test_queue_a']
);

DO $$
DECLARE
    v_api_key TEXT;
    v_task_name TEXT;
    v_task_id BIGINT;
    v_status task_status;
BEGIN
    SELECT value INTO v_api_key FROM test_context WHERE key = 'api_key';
    SELECT task_name, task_id INTO v_task_name, v_task_id FROM test_dequeue_fail_final;

    IF v_task_name <> 'task_fail_final' THEN
        RAISE EXCEPTION 'Expected task_fail_final, got %', v_task_name;
    END IF;

    PERFORM fail_task(v_api_key, v_task_id, 'final failure', '1 minute'::INTERVAL);

    SELECT status INTO v_status FROM task_queue WHERE id = v_task_id;
    IF v_status <> 'failed' THEN
        RAISE EXCEPTION 'final fail expected failed, got %', v_status;
    END IF;
END $$;

-- --------------------------------------------
-- 10) COMPLETE TASK (RECURRING)
-- --------------------------------------------
-- Make recurring task eligible for dequeue (enqueue_task schedules next run in the future)
UPDATE task_queue
SET status = 'pending',
    scheduled_at = NOW() - INTERVAL '1 minute',
    worker_id = NULL,
    lease_expires_at = NULL,
    started_at = NULL
WHERE task_uuid = (SELECT task_uuid FROM test_tasks WHERE name = 'recurring_task');

CREATE TEMP TABLE test_dequeue_recurring AS
SELECT * FROM dequeue_task(
    (SELECT value FROM test_context WHERE key = 'api_key'),
    '5 minutes'::INTERVAL,
    ARRAY['test_queue_b']
);

DO $$
DECLARE
    v_api_key TEXT;
    v_task_name TEXT;
    v_task_id BIGINT;
    v_status task_status;
    v_next_count INTEGER;
BEGIN
    SELECT value INTO v_api_key FROM test_context WHERE key = 'api_key';
    SELECT task_name, task_id INTO v_task_name, v_task_id FROM test_dequeue_recurring;

    IF v_task_name <> 'task_recurring' THEN
        RAISE EXCEPTION 'Expected task_recurring, got %', v_task_name;
    END IF;

    PERFORM complete_task(v_api_key, v_task_id, '{"result": true}'::JSONB);

    SELECT status INTO v_status FROM task_queue WHERE id = v_task_id;
    IF v_status <> 'completed' THEN
        RAISE EXCEPTION 'complete_task expected completed, got %', v_status;
    END IF;

    SELECT COUNT(*) INTO v_next_count
    FROM task_queue
    WHERE task_name = 'task_recurring'
      AND recurrence_pattern = 'daily'
      AND status = 'scheduled'
      AND queue_name = 'test_queue_b';

    IF v_next_count < 1 THEN
        RAISE EXCEPTION 'recurring task did not create next scheduled task';
    END IF;
END $$;

-- --------------------------------------------
-- 11) RESET STUCK TASKS
-- --------------------------------------------
CREATE TEMP TABLE test_dequeue_stuck AS
SELECT * FROM dequeue_task(
    (SELECT value FROM test_context WHERE key = 'api_key'),
    '5 minutes'::INTERVAL,
    ARRAY['test_queue_a']
);

DO $$
DECLARE
    v_task_id BIGINT;
    v_worker_id TEXT;
    v_reset_count INTEGER;
    v_status task_status;
    v_active BOOLEAN;
BEGIN
    SELECT task_id INTO v_task_id FROM test_dequeue_stuck;
    SELECT value INTO v_worker_id FROM test_context WHERE key = 'worker_id';

    -- Force lease expiration and worker timeout
    UPDATE task_queue
    SET lease_expires_at = NOW() - INTERVAL '1 minute'
    WHERE id = v_task_id;

    UPDATE worker_registry
    SET expected_next_heartbeat = NOW() - INTERVAL '1 minute'
    WHERE worker_id = v_worker_id;

    SELECT reset_stuck_tasks() INTO v_reset_count;
    IF v_reset_count < 1 THEN
        RAISE EXCEPTION 'reset_stuck_tasks did not reset any tasks';
    END IF;

    SELECT status INTO v_status FROM task_queue WHERE id = v_task_id;
    IF v_status <> 'pending' THEN
        RAISE EXCEPTION 'reset_stuck_tasks expected pending, got %', v_status;
    END IF;

    SELECT is_active INTO v_active FROM worker_registry WHERE worker_id = v_worker_id;
    IF v_active IS DISTINCT FROM FALSE THEN
        RAISE EXCEPTION 'reset_stuck_tasks expected worker inactive';
    END IF;
END $$;

-- --------------------------------------------
-- 12) PERMISSIONS / KEY STATE
-- --------------------------------------------
DO $$
DECLARE
    v_worker_id TEXT;
    v_api_key TEXT;
BEGIN
    SELECT value INTO v_worker_id FROM test_context WHERE key = 'worker_id';
    SELECT value INTO v_api_key FROM test_context WHERE key = 'api_key';

    -- Deactivate key should block auth
    UPDATE worker_api_keys SET is_active = FALSE WHERE worker_id = v_worker_id;
    BEGIN
        PERFORM validate_worker_auth(v_api_key);
        RAISE EXCEPTION 'Expected auth failure for inactive key';
    EXCEPTION WHEN OTHERS THEN
        -- expected
    END;

    -- Reactivate
    UPDATE worker_api_keys SET is_active = TRUE WHERE worker_id = v_worker_id;

    -- Expired key should block auth
    UPDATE worker_api_keys SET expires_at = NOW() - INTERVAL '1 minute' WHERE worker_id = v_worker_id;
    BEGIN
        PERFORM validate_worker_auth(v_api_key);
        RAISE EXCEPTION 'Expected auth failure for expired key';
    EXCEPTION WHEN OTHERS THEN
        -- expected
    END;

    UPDATE worker_api_keys SET expires_at = NULL WHERE worker_id = v_worker_id;

    -- Permissions field not enforced yet; placeholder to ensure JSON exists
    IF NOT (SELECT permissions ? 'can_dequeue' FROM worker_api_keys WHERE worker_id = v_worker_id) THEN
        RAISE EXCEPTION 'permissions JSON missing can_dequeue';
    END IF;
END $$;

-- --------------------------------------------
-- 12) READY_QUEUE VIEW
-- --------------------------------------------
DO $$
DECLARE
    v_task_id BIGINT;
    v_count INTEGER;
BEGIN
    SELECT task_id INTO v_task_id FROM test_tasks WHERE name = 'pending_task';
    SELECT COUNT(*) INTO v_count FROM ready_queue WHERE id = v_task_id;

    IF v_count <> 1 THEN
        RAISE EXCEPTION 'ready_queue view missing pending_task %', v_task_id;
    END IF;
END $$;

-- --------------------------------------------
-- 13) UPDATED_AT TRIGGER (TASK QUEUE)
-- --------------------------------------------
DO $$
DECLARE
    v_task_id BIGINT;
    v_after TIMESTAMPTZ;
BEGIN
    SELECT task_id INTO v_task_id FROM test_tasks WHERE name = 'pending_task';
    UPDATE task_queue
    SET updated_at = '2000-01-01 00:00:00+00'::TIMESTAMPTZ
    WHERE id = v_task_id;

    SELECT updated_at INTO v_after FROM task_queue WHERE id = v_task_id;

    IF v_after <= '2010-01-01 00:00:00+00'::TIMESTAMPTZ THEN
        RAISE EXCEPTION 'update_updated_at_column trigger did not update updated_at';
    END IF;
END $$;

-- --------------------------------------------
-- 14) QUEUE/WORKER STATS + SUBSCRIPTION VIEW
-- --------------------------------------------
DO $$
DECLARE
    v_worker_id TEXT;
    v_count INTEGER;
BEGIN
    SELECT value INTO v_worker_id FROM test_context WHERE key = 'worker_id';

    SELECT COUNT(*) INTO v_count FROM get_worker_stats(v_worker_id);
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'get_worker_stats did not return worker';
    END IF;

    SELECT COUNT(*) INTO v_count FROM get_queue_stats_by_queue() WHERE queue_name IN ('test_queue_a', 'test_queue_b');
    IF v_count < 2 THEN
        RAISE EXCEPTION 'get_queue_stats_by_queue missing test queues';
    END IF;

    SELECT COUNT(*) INTO v_count FROM get_queue_stats();
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'get_queue_stats did not return a single row';
    END IF;

    SELECT COUNT(*) INTO v_count
    FROM queue_worker_subscriptions
    WHERE worker_id = v_worker_id AND queue_name IN ('test_queue_a', 'test_queue_b');

    IF v_count < 2 THEN
        RAISE EXCEPTION 'queue_worker_subscriptions missing worker queues';
    END IF;
END $$;

-- --------------------------------------------
-- 15) CLEANUP OLD TASKS
-- --------------------------------------------
DO $$
DECLARE
    v_worker_id TEXT;
    v_deleted INTEGER;
BEGIN
    SELECT value INTO v_worker_id FROM test_context WHERE key = 'worker_id';

    -- Insert old completed/failed tasks directly (updated_at in the past)
    INSERT INTO task_queue (
        task_uuid,
        task_name,
        task_type,
        queue_name,
        task_data,
        status,
        priority,
        scheduled_at,
        created_by,
        updated_at,
        completed_at
    ) VALUES (
        uuid_generate_v4(),
        'old_completed_task',
        'immediate',
        'test_queue_a',
        '{}'::JSONB,
        'completed',
        0,
        NOW() - INTERVAL '40 days',
        v_worker_id,
        NOW() - INTERVAL '40 days',
        NOW() - INTERVAL '40 days'
    );

    INSERT INTO task_queue (
        task_uuid,
        task_name,
        task_type,
        queue_name,
        task_data,
        status,
        priority,
        scheduled_at,
        created_by,
        updated_at,
        last_error
    ) VALUES (
        uuid_generate_v4(),
        'old_failed_task',
        'immediate',
        'test_queue_a',
        '{}'::JSONB,
        'failed',
        0,
        NOW() - INTERVAL '40 days',
        v_worker_id,
        NOW() - INTERVAL '40 days',
        'old error'
    );

    SELECT cleanup_old_tasks('30 days'::INTERVAL, 1000) INTO v_deleted;

    IF v_deleted < 2 THEN
        RAISE EXCEPTION 'cleanup_old_tasks expected to delete >= 2 rows, got %', v_deleted;
    END IF;
END $$;

-- --------------------------------------------
-- 16) CLEANUP GUARDRAIL (SHOULD ERROR)
-- --------------------------------------------
DO $$
BEGIN
    BEGIN
        PERFORM cleanup_old_tasks('3 days'::INTERVAL, 1000);
        RAISE EXCEPTION 'Expected cleanup guard (<7 days) exception not raised';
    EXCEPTION WHEN OTHERS THEN
        -- expected
    END;
END $$;

-- --------------------------------------------
-- 17) PRIORITY ORDERING ACROSS WORKERS (SKIP LOCKED)
-- --------------------------------------------
DO $$
DECLARE
    v_api_key1 TEXT;
    v_api_key2 TEXT;
    v_worker1 TEXT;
    v_worker2 TEXT;
    v_t1 BIGINT;
    v_t2 BIGINT;
    v_name1 TEXT;
    v_name2 TEXT;
BEGIN
    SELECT value INTO v_api_key1 FROM test_context WHERE key = 'api_key';
    SELECT value INTO v_api_key2 FROM test_context WHERE key = 'worker2_api_key';
    SELECT value INTO v_worker1 FROM test_context WHERE key = 'worker_id';
    SELECT value INTO v_worker2 FROM test_context WHERE key = 'worker2_id';

    -- Reactivate workers if prior tests marked them inactive
    UPDATE worker_registry
    SET is_active = TRUE,
        current_load = 0,
        expected_next_heartbeat = NOW() + INTERVAL '30 seconds',
        last_seen_at = NOW()
    WHERE worker_id IN (v_worker1, v_worker2);

    -- Insert two default-queue tasks with different priorities
    INSERT INTO task_queue (task_uuid, task_name, task_type, queue_name, task_data, status, priority, scheduled_at, created_by)
    VALUES
        (uuid_generate_v4(), 'prio_high', 'immediate', 'default', '{}'::JSONB, 'pending', 90, NOW() - INTERVAL '1 minute', 'system'),
        (uuid_generate_v4(), 'prio_low',  'immediate', 'default', '{}'::JSONB, 'pending', 40, NOW() - INTERVAL '1 minute', 'system');

    -- Worker1 takes highest priority
    SELECT task_id, task_name INTO v_t1, v_name1
    FROM dequeue_task(v_api_key1, '5 minutes'::INTERVAL, ARRAY['default'])
    LIMIT 1;

    IF v_name1 <> 'prio_high' THEN
        RAISE EXCEPTION 'Expected prio_high first, got %', v_name1;
    END IF;

    -- Worker2 takes the next
    SELECT task_id, task_name INTO v_t2, v_name2
    FROM dequeue_task(v_api_key2, '5 minutes'::INTERVAL, ARRAY['default'])
    LIMIT 1;

    IF v_name2 <> 'prio_low' THEN
        RAISE EXCEPTION 'Expected prio_low second, got %', v_name2;
    END IF;
END $$;

-- --------------------------------------------
-- 18) UNKNOWN WORKER HEARTBEAT SHOULD FAIL
-- --------------------------------------------
DO $$
BEGIN
    BEGIN
        PERFORM worker_heartbeat('sk_nonexistent', 0, '30 seconds'::INTERVAL);
        RAISE EXCEPTION 'Expected worker_heartbeat failure for unknown key';
    EXCEPTION WHEN OTHERS THEN
        -- expected
    END;
END $$;

-- --------------------------------------------
-- 19) TASK LINEAGE (ANCESTORS + DESCENDANTS)
-- --------------------------------------------
DO $$
DECLARE
    v_worker_id TEXT;
    v_uuid_a UUID := uuid_generate_v4();
    v_uuid_b UUID := uuid_generate_v4();
    v_uuid_c UUID := uuid_generate_v4();
    v_uuid_d UUID := uuid_generate_v4();
    v_uuid_e UUID := uuid_generate_v4();
    v_names TEXT[];
    v_count INTEGER;
    v_ancestor_count INTEGER;
    v_descendant_count INTEGER;
    v_uuid_f UUID := uuid_generate_v4();
    v_uuid_g UUID := uuid_generate_v4();
    v_uuid_x UUID := uuid_generate_v4();
    v_uuid_y UUID := uuid_generate_v4();
    v_uuid_z UUID := uuid_generate_v4();
    v_cycle_count INTEGER;
    v_cycle_distinct INTEGER;
BEGIN
    SELECT value INTO v_worker_id FROM test_context WHERE key = 'worker_id';

    INSERT INTO task_queue (
        task_uuid, task_name, task_type, queue_name, task_data, status, priority, scheduled_at, created_by
    ) VALUES
        (v_uuid_a, 'lineage_a', 'immediate', 'test_queue_a', '{"meta": {}}'::JSONB, 'pending', 0, NOW() - INTERVAL '1 minute', v_worker_id),
        (v_uuid_b, 'lineage_b', 'immediate', 'test_queue_a', jsonb_build_object('meta', jsonb_build_object('parent_task_uuid', v_uuid_a::TEXT)), 'pending', 0, NOW() - INTERVAL '1 minute', v_worker_id),
        (v_uuid_c, 'lineage_c', 'immediate', 'test_queue_a', jsonb_build_object('meta', jsonb_build_object('parent_task_uuid', v_uuid_b::TEXT)), 'pending', 0, NOW() - INTERVAL '1 minute', v_worker_id),
        (v_uuid_d, 'lineage_d', 'immediate', 'test_queue_a', jsonb_build_object('meta', jsonb_build_object('parent_task_uuid', v_uuid_c::TEXT)), 'pending', 0, NOW() - INTERVAL '1 minute', v_worker_id),
        (v_uuid_e, 'lineage_e', 'immediate', 'test_queue_a', jsonb_build_object('meta', jsonb_build_object('parent_task_uuid', v_uuid_d::TEXT)), 'pending', 0, NOW() - INTERVAL '1 minute', v_worker_id);

    SELECT array_agg(task_name ORDER BY row_no)
    INTO v_names
    FROM (
        SELECT task_name, row_number() OVER () AS row_no
        FROM get_task_ancestors_descendants(v_uuid_c)
    ) ranked;

    IF v_names IS DISTINCT FROM ARRAY['lineage_a', 'lineage_b', 'lineage_d', 'lineage_e']::TEXT[] THEN
        RAISE EXCEPTION 'Expected lineage order [lineage_a,lineage_b,lineage_d,lineage_e], got %', v_names;
    END IF;

    SELECT COUNT(*),
           COUNT(*) FILTER (WHERE relation_type = 'ancestor'),
           COUNT(*) FILTER (WHERE relation_type = 'descendant')
    INTO v_count, v_ancestor_count, v_descendant_count
    FROM get_task_ancestors_descendants(v_uuid_c);

    IF v_count <> 4 OR v_ancestor_count <> 2 OR v_descendant_count <> 2 THEN
        RAISE EXCEPTION 'Expected 4 related tasks (2 ancestors, 2 descendants), got total %, ancestors %, descendants %',
            v_count, v_ancestor_count, v_descendant_count;
    END IF;

    SELECT array_agg(task_name ORDER BY row_no)
    INTO v_names
    FROM (
        SELECT task_name, row_number() OVER () AS row_no
        FROM get_task_ancestors_descendants(v_uuid_a)
    ) ranked;

    IF v_names IS DISTINCT FROM ARRAY['lineage_b', 'lineage_c', 'lineage_d', 'lineage_e']::TEXT[] THEN
        RAISE EXCEPTION 'Expected root descendants [lineage_b,lineage_c,lineage_d,lineage_e], got %', v_names;
    END IF;

    SELECT COUNT(*) INTO v_ancestor_count
    FROM get_task_ancestors_descendants(v_uuid_a)
    WHERE relation_type = 'ancestor';

    IF v_ancestor_count <> 0 THEN
        RAISE EXCEPTION 'Expected zero ancestors for root task, got %', v_ancestor_count;
    END IF;

    SELECT array_agg(task_name ORDER BY row_no)
    INTO v_names
    FROM (
        SELECT task_name, row_number() OVER () AS row_no
        FROM get_task_ancestors_descendants(v_uuid_e)
    ) ranked;

    IF v_names IS DISTINCT FROM ARRAY['lineage_a', 'lineage_b', 'lineage_c', 'lineage_d']::TEXT[] THEN
        RAISE EXCEPTION 'Expected leaf ancestors [lineage_a,lineage_b,lineage_c,lineage_d], got %', v_names;
    END IF;

    SELECT COUNT(*) INTO v_descendant_count
    FROM get_task_ancestors_descendants(v_uuid_e)
    WHERE relation_type = 'descendant';

    IF v_descendant_count <> 0 THEN
        RAISE EXCEPTION 'Expected zero descendants for leaf task, got %', v_descendant_count;
    END IF;

    INSERT INTO task_queue (
        task_uuid, task_name, task_type, queue_name, task_data, status, priority, scheduled_at, created_by
    ) VALUES
        (v_uuid_f, 'malformed_parent', 'immediate', 'test_queue_a', '{"meta":{"parent_task_uuid":"not-a-uuid"}}'::JSONB, 'pending', 0, NOW() - INTERVAL '1 minute', v_worker_id),
        (v_uuid_g, 'malformed_child', 'immediate', 'test_queue_a', jsonb_build_object('meta', jsonb_build_object('parent_task_uuid', v_uuid_f::TEXT)), 'pending', 0, NOW() - INTERVAL '1 minute', v_worker_id);

    SELECT array_agg(task_name ORDER BY row_no)
    INTO v_names
    FROM (
        SELECT task_name, row_number() OVER () AS row_no
        FROM get_task_ancestors_descendants(v_uuid_f)
    ) ranked;

    IF v_names IS DISTINCT FROM ARRAY['malformed_child']::TEXT[] THEN
        RAISE EXCEPTION 'Expected malformed parent test to return only descendant malformed_child, got %', v_names;
    END IF;

    INSERT INTO task_queue (
        task_uuid, task_name, task_type, queue_name, task_data, status, priority, scheduled_at, created_by
    ) VALUES
        (v_uuid_x, 'cycle_x', 'immediate', 'test_queue_a', jsonb_build_object('meta', jsonb_build_object('parent_task_uuid', v_uuid_z::TEXT)), 'pending', 0, NOW() - INTERVAL '1 minute', v_worker_id),
        (v_uuid_y, 'cycle_y', 'immediate', 'test_queue_a', jsonb_build_object('meta', jsonb_build_object('parent_task_uuid', v_uuid_x::TEXT)), 'pending', 0, NOW() - INTERVAL '1 minute', v_worker_id),
        (v_uuid_z, 'cycle_z', 'immediate', 'test_queue_a', jsonb_build_object('meta', jsonb_build_object('parent_task_uuid', v_uuid_y::TEXT)), 'pending', 0, NOW() - INTERVAL '1 minute', v_worker_id);

    SELECT COUNT(*),
           COUNT(DISTINCT relation_type || ':' || task_uuid::TEXT)
    INTO v_cycle_count, v_cycle_distinct
    FROM get_task_ancestors_descendants(v_uuid_y);

    IF v_cycle_count <> 4 THEN
        RAISE EXCEPTION 'Expected cycle traversal to terminate with 4 rows, got %', v_cycle_count;
    END IF;

    IF v_cycle_distinct <> v_cycle_count THEN
        RAISE EXCEPTION 'Cycle traversal returned duplicate rows (count %, distinct %)', v_cycle_count, v_cycle_distinct;
    END IF;
END $$;

ROLLBACK;
