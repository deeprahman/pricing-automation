-- ============================================
-- SECURE TASK SCHEDULER DEPENDENCIES TEST SUITE
-- Run AFTER:
--   1) schemas/secure_task_scheduler.sql
--   2) schemas/secure_task_scheduler_dependencies.sql
-- ============================================

BEGIN;

-- --------------------------------------------
-- 0) SANITY CHECKS
-- --------------------------------------------
DO $$
BEGIN
    IF to_regclass('public.task_dependencies') IS NULL THEN
        RAISE EXCEPTION 'Missing table: task_dependencies';
    END IF;
    IF to_regprocedure('add_task_dependency(text,uuid,uuid)') IS NULL THEN
        RAISE EXCEPTION 'Missing function: add_task_dependency';
    END IF;
    IF to_regprocedure('add_task_dependencies(text,uuid,uuid[])') IS NULL THEN
        RAISE EXCEPTION 'Missing function: add_task_dependencies';
    END IF;
    IF to_regprocedure('remove_task_dependency(text,uuid,uuid)') IS NULL THEN
        RAISE EXCEPTION 'Missing function: remove_task_dependency';
    END IF;
    IF to_regprocedure('get_task_dependencies(text,uuid)') IS NULL THEN
        RAISE EXCEPTION 'Missing function: get_task_dependencies';
    END IF;
    IF to_regprocedure('dequeue_task(text,interval,character varying[])') IS NULL THEN
        RAISE EXCEPTION 'Missing function: dequeue_task';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM pg_trigger
        WHERE tgname = 'trg_task_dependencies_auto_fail'
          AND tgrelid = 'task_queue'::regclass
          AND NOT tgisinternal
    ) THEN
        RAISE EXCEPTION 'Missing trigger: trg_task_dependencies_auto_fail';
    END IF;
END $$;

-- --------------------------------------------
-- 1) TEST CONTEXT
-- --------------------------------------------
CREATE TEMP TABLE test_dep_context (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

SELECT create_queue('test_dep_gate', 'Dependency gate tests');
SELECT create_queue('test_dep_multi', 'Multi prerequisite tests');
SELECT create_queue('test_dep_fail', 'Auto-fail propagation tests');
SELECT create_queue('test_dep_misc', 'Helper API and cycle tests');

DO $$
DECLARE
    v_worker_id TEXT;
    v_api_key TEXT;
BEGIN
    v_worker_id := 'test-dependency-worker-' || txid_current();

    SELECT worker_id, api_key
    INTO v_worker_id, v_api_key
    FROM register_worker(
        v_worker_id,
        'Task Dependency Test Worker',
        5,
        '30 seconds'::INTERVAL,
        '["test_dep_gate", "test_dep_multi", "test_dep_fail", "test_dep_misc"]'::JSONB
    );

    INSERT INTO test_dep_context (key, value) VALUES
        ('worker_id', v_worker_id),
        ('api_key', v_api_key);
END $$;

-- --------------------------------------------
-- 2) DEPENDENCY GATING + UNBLOCK AFTER COMPLETE
-- --------------------------------------------
DO $$
DECLARE
    v_api_key TEXT;
    v_prereq_uuid UUID;
    v_target_uuid UUID;
    v_dequeued_task_id BIGINT;
    v_dequeued_task_name TEXT;
BEGIN
    SELECT value INTO v_api_key FROM test_dep_context WHERE key = 'api_key';

    SELECT enqueue_task(
        v_api_key,
        'dep_gate_prereq',
        '{}'::JSONB,
        'immediate',
        20,
        NOW() - INTERVAL '1 minute',
        3,
        NULL,
        'test_dep_gate'
    ) INTO v_prereq_uuid;

    SELECT enqueue_task(
        v_api_key,
        'dep_gate_target',
        '{}'::JSONB,
        'immediate',
        95,
        NOW() - INTERVAL '1 minute',
        3,
        NULL,
        'test_dep_gate'
    ) INTO v_target_uuid;

    IF NOT add_task_dependency(v_api_key, v_target_uuid, v_prereq_uuid) THEN
        RAISE EXCEPTION 'Expected dependency insertion to return TRUE';
    END IF;

    SELECT task_id, task_name
    INTO v_dequeued_task_id, v_dequeued_task_name
    FROM dequeue_task(v_api_key, '5 minutes'::INTERVAL, ARRAY['test_dep_gate'])
    LIMIT 1;

    IF v_dequeued_task_name <> 'dep_gate_prereq' THEN
        RAISE EXCEPTION 'Expected dep_gate_prereq to dequeue first, got %', v_dequeued_task_name;
    END IF;

    PERFORM complete_task(v_api_key, v_dequeued_task_id, '{"ok":true}'::JSONB);

    SELECT task_id, task_name
    INTO v_dequeued_task_id, v_dequeued_task_name
    FROM dequeue_task(v_api_key, '5 minutes'::INTERVAL, ARRAY['test_dep_gate'])
    LIMIT 1;

    IF v_dequeued_task_name <> 'dep_gate_target' THEN
        RAISE EXCEPTION 'Expected dep_gate_target after prerequisite completion, got %', v_dequeued_task_name;
    END IF;

    PERFORM complete_task(v_api_key, v_dequeued_task_id, '{"ok":true}'::JSONB);
END $$;

-- --------------------------------------------
-- 3) MULTI-PREREQUISITE GATING
-- --------------------------------------------
DO $$
DECLARE
    v_api_key TEXT;
    v_prereq_a UUID;
    v_prereq_b UUID;
    v_target UUID;
    v_inserted INTEGER;
    v_dequeued_task_id BIGINT;
    v_dequeued_task_name TEXT;
BEGIN
    SELECT value INTO v_api_key FROM test_dep_context WHERE key = 'api_key';

    SELECT enqueue_task(
        v_api_key,
        'dep_multi_prereq_a',
        '{}'::JSONB,
        'immediate',
        70,
        NOW() - INTERVAL '1 minute',
        3,
        NULL,
        'test_dep_multi'
    ) INTO v_prereq_a;

    SELECT enqueue_task(
        v_api_key,
        'dep_multi_prereq_b',
        '{}'::JSONB,
        'immediate',
        60,
        NOW() - INTERVAL '1 minute',
        3,
        NULL,
        'test_dep_multi'
    ) INTO v_prereq_b;

    SELECT enqueue_task(
        v_api_key,
        'dep_multi_target',
        '{}'::JSONB,
        'immediate',
        95,
        NOW() - INTERVAL '1 minute',
        3,
        NULL,
        'test_dep_multi'
    ) INTO v_target;

    SELECT add_task_dependencies(
        v_api_key,
        v_target,
        ARRAY[v_prereq_a, v_prereq_b]
    ) INTO v_inserted;

    IF v_inserted <> 2 THEN
        RAISE EXCEPTION 'Expected 2 dependencies inserted, got %', v_inserted;
    END IF;

    SELECT task_id, task_name
    INTO v_dequeued_task_id, v_dequeued_task_name
    FROM dequeue_task(v_api_key, '5 minutes'::INTERVAL, ARRAY['test_dep_multi'])
    LIMIT 1;

    IF v_dequeued_task_name <> 'dep_multi_prereq_a' THEN
        RAISE EXCEPTION 'Expected dep_multi_prereq_a first, got %', v_dequeued_task_name;
    END IF;
    PERFORM complete_task(v_api_key, v_dequeued_task_id, '{"ok":true}'::JSONB);

    SELECT task_id, task_name
    INTO v_dequeued_task_id, v_dequeued_task_name
    FROM dequeue_task(v_api_key, '5 minutes'::INTERVAL, ARRAY['test_dep_multi'])
    LIMIT 1;

    IF v_dequeued_task_name <> 'dep_multi_prereq_b' THEN
        RAISE EXCEPTION 'Expected dep_multi_prereq_b second, got %', v_dequeued_task_name;
    END IF;
    PERFORM complete_task(v_api_key, v_dequeued_task_id, '{"ok":true}'::JSONB);

    SELECT task_id, task_name
    INTO v_dequeued_task_id, v_dequeued_task_name
    FROM dequeue_task(v_api_key, '5 minutes'::INTERVAL, ARRAY['test_dep_multi'])
    LIMIT 1;

    IF v_dequeued_task_name <> 'dep_multi_target' THEN
        RAISE EXCEPTION 'Expected dep_multi_target after both prerequisites, got %', v_dequeued_task_name;
    END IF;
    PERFORM complete_task(v_api_key, v_dequeued_task_id, '{"ok":true}'::JSONB);
END $$;

-- --------------------------------------------
-- 4) AUTO-FAIL PROPAGATION FROM FAILED PREREQUISITE
-- --------------------------------------------
DO $$
DECLARE
    v_api_key TEXT;
    v_prereq_uuid UUID;
    v_target_uuid UUID;
    v_dequeued_task_id BIGINT;
    v_dequeued_task_name TEXT;
    v_target_status task_status;
    v_target_error TEXT;
    v_remaining INTEGER;
BEGIN
    SELECT value INTO v_api_key FROM test_dep_context WHERE key = 'api_key';

    SELECT enqueue_task(
        v_api_key,
        'dep_fail_prereq',
        '{}'::JSONB,
        'immediate',
        30,
        NOW() - INTERVAL '1 minute',
        1,
        NULL,
        'test_dep_fail'
    ) INTO v_prereq_uuid;

    SELECT enqueue_task(
        v_api_key,
        'dep_fail_target',
        '{}'::JSONB,
        'immediate',
        90,
        NOW() - INTERVAL '1 minute',
        3,
        NULL,
        'test_dep_fail'
    ) INTO v_target_uuid;

    PERFORM add_task_dependency(v_api_key, v_target_uuid, v_prereq_uuid);

    SELECT task_id, task_name
    INTO v_dequeued_task_id, v_dequeued_task_name
    FROM dequeue_task(v_api_key, '5 minutes'::INTERVAL, ARRAY['test_dep_fail'])
    LIMIT 1;

    IF v_dequeued_task_name <> 'dep_fail_prereq' THEN
        RAISE EXCEPTION 'Expected dep_fail_prereq to dequeue first, got %', v_dequeued_task_name;
    END IF;

    PERFORM fail_task(
        v_api_key,
        v_dequeued_task_id,
        'forced prerequisite failure',
        '1 minute'::INTERVAL
    );

    SELECT status, last_error
    INTO v_target_status, v_target_error
    FROM task_queue
    WHERE task_uuid = v_target_uuid;

    IF v_target_status <> 'failed' THEN
        RAISE EXCEPTION 'Expected dependent task to auto-fail, got %', v_target_status;
    END IF;

    IF position(v_prereq_uuid::TEXT IN COALESCE(v_target_error, '')) = 0 THEN
        RAISE EXCEPTION 'Expected dependent error to contain prerequisite uuid. Error: %', v_target_error;
    END IF;

    SELECT COUNT(*) INTO v_remaining
    FROM dequeue_task(v_api_key, '5 minutes'::INTERVAL, ARRAY['test_dep_fail']);

    IF v_remaining <> 0 THEN
        RAISE EXCEPTION 'Expected no dequeueable tasks remaining in test_dep_fail queue';
    END IF;
END $$;

-- --------------------------------------------
-- 5) HELPER API: BATCH DEDUPE, GET, REMOVE
-- --------------------------------------------
DO $$
DECLARE
    v_api_key TEXT;
    v_target_uuid UUID;
    v_prereq_1 UUID;
    v_prereq_2 UUID;
    v_inserted_first INTEGER;
    v_inserted_second INTEGER;
    v_dep_count INTEGER;
    v_removed BOOLEAN;
BEGIN
    SELECT value INTO v_api_key FROM test_dep_context WHERE key = 'api_key';

    SELECT enqueue_task(
        v_api_key,
        'dep_helper_target',
        '{}'::JSONB,
        'immediate',
        50,
        NOW() - INTERVAL '1 minute',
        3,
        NULL,
        'test_dep_misc'
    ) INTO v_target_uuid;

    SELECT enqueue_task(
        v_api_key,
        'dep_helper_prereq_1',
        '{}'::JSONB,
        'immediate',
        20,
        NOW() - INTERVAL '1 minute',
        3,
        NULL,
        'test_dep_misc'
    ) INTO v_prereq_1;

    SELECT enqueue_task(
        v_api_key,
        'dep_helper_prereq_2',
        '{}'::JSONB,
        'immediate',
        20,
        NOW() - INTERVAL '1 minute',
        3,
        NULL,
        'test_dep_misc'
    ) INTO v_prereq_2;

    SELECT add_task_dependencies(
        v_api_key,
        v_target_uuid,
        ARRAY[v_prereq_1, v_prereq_2, v_prereq_1]
    ) INTO v_inserted_first;

    IF v_inserted_first <> 2 THEN
        RAISE EXCEPTION 'Expected first batch insert count = 2, got %', v_inserted_first;
    END IF;

    SELECT add_task_dependencies(
        v_api_key,
        v_target_uuid,
        ARRAY[v_prereq_1, v_prereq_2, v_prereq_1]
    ) INTO v_inserted_second;

    IF v_inserted_second <> 0 THEN
        RAISE EXCEPTION 'Expected second batch insert count = 0, got %', v_inserted_second;
    END IF;

    SELECT COUNT(*) INTO v_dep_count
    FROM get_task_dependencies(v_api_key, v_target_uuid);

    IF v_dep_count <> 2 THEN
        RAISE EXCEPTION 'Expected 2 dependencies from get_task_dependencies, got %', v_dep_count;
    END IF;

    SELECT remove_task_dependency(v_api_key, v_target_uuid, v_prereq_1)
    INTO v_removed;
    IF v_removed IS DISTINCT FROM TRUE THEN
        RAISE EXCEPTION 'Expected remove_task_dependency to return TRUE on first delete';
    END IF;

    SELECT remove_task_dependency(v_api_key, v_target_uuid, v_prereq_1)
    INTO v_removed;
    IF v_removed IS DISTINCT FROM FALSE THEN
        RAISE EXCEPTION 'Expected remove_task_dependency to return FALSE on second delete';
    END IF;

    SELECT COUNT(*) INTO v_dep_count
    FROM get_task_dependencies(v_api_key, v_target_uuid);

    IF v_dep_count <> 1 THEN
        RAISE EXCEPTION 'Expected dependency count = 1 after removal, got %', v_dep_count;
    END IF;
END $$;

-- --------------------------------------------
-- 6) CYCLE PREVENTION
-- --------------------------------------------
DO $$
DECLARE
    v_api_key TEXT;
    v_cycle_a UUID;
    v_cycle_b UUID;
BEGIN
    SELECT value INTO v_api_key FROM test_dep_context WHERE key = 'api_key';

    SELECT enqueue_task(
        v_api_key,
        'dep_cycle_a',
        '{}'::JSONB,
        'immediate',
        10,
        NOW() - INTERVAL '1 minute',
        3,
        NULL,
        'test_dep_misc'
    ) INTO v_cycle_a;

    SELECT enqueue_task(
        v_api_key,
        'dep_cycle_b',
        '{}'::JSONB,
        'immediate',
        10,
        NOW() - INTERVAL '1 minute',
        3,
        NULL,
        'test_dep_misc'
    ) INTO v_cycle_b;

    PERFORM add_task_dependency(v_api_key, v_cycle_a, v_cycle_b);

    BEGIN
        PERFORM add_task_dependency(v_api_key, v_cycle_b, v_cycle_a);
        RAISE EXCEPTION 'Expected cycle detection exception was not raised';
    EXCEPTION WHEN OTHERS THEN
        IF position('cycle' IN lower(SQLERRM)) = 0 THEN
            RAISE EXCEPTION 'Unexpected error while testing cycle prevention: %', SQLERRM;
        END IF;
    END;
END $$;

-- --------------------------------------------
-- 7) INVALID AUTH HANDLING
-- --------------------------------------------
DO $$
BEGIN
    BEGIN
        PERFORM add_task_dependency(
            'invalid_api_key',
            uuid_generate_v4(),
            uuid_generate_v4()
        );
        RAISE EXCEPTION 'Expected authentication failure was not raised';
    EXCEPTION WHEN OTHERS THEN
        IF position('Authentication failed' IN SQLERRM) = 0 THEN
            RAISE EXCEPTION 'Unexpected auth error: %', SQLERRM;
        END IF;
    END;
END $$;

ROLLBACK;
