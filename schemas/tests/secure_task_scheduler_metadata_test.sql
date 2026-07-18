-- ============================================
-- METADATA MODULE TEST SUITE
-- Version: 2.2
-- ============================================
-- 
-- Run AFTER: secure_task_scheduler_metadata_improved.sql
-- 
-- Test Coverage:
-- - Deep merge functionality
-- - Worker metadata operations
-- - Task metadata operations
-- - Metadata history tracking
-- - Cleanup functions
-- - Validation functions
-- - Error handling
-- - Edge cases
-- ============================================

-- Enable extensions if needed
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================
-- TEST FRAMEWORK SETUP
-- ============================================

CREATE SCHEMA IF NOT EXISTS test_metadata;

-- Test results table
DROP TABLE IF EXISTS test_metadata.test_results CASCADE;
CREATE TABLE test_metadata.test_results (
    id SERIAL PRIMARY KEY,
    test_name TEXT NOT NULL,
    test_category TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('PASS', 'FAIL', 'ERROR')),
    message TEXT,
    expected TEXT,
    actual TEXT,
    error_detail TEXT,
    execution_time_ms NUMERIC,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Test logging function
CREATE OR REPLACE FUNCTION test_metadata.log_test(
    p_name TEXT,
    p_category TEXT,
    p_status TEXT,
    p_message TEXT DEFAULT NULL,
    p_expected TEXT DEFAULT NULL,
    p_actual TEXT DEFAULT NULL,
    p_error TEXT DEFAULT NULL,
    p_execution_time NUMERIC DEFAULT NULL
) RETURNS VOID AS $$
BEGIN
    INSERT INTO test_metadata.test_results (
        test_name, test_category, status, message, 
        expected, actual, error_detail, execution_time_ms
    ) VALUES (
        p_name, p_category, p_status, p_message,
        p_expected, p_actual, p_error, p_execution_time
    );
END;
$$ LANGUAGE plpgsql;

-- Assert equals function
CREATE OR REPLACE FUNCTION test_metadata.assert_equals(
    p_test_name TEXT,
    p_category TEXT,
    p_expected ANYELEMENT,
    p_actual ANYELEMENT
) RETURNS BOOLEAN AS $$
BEGIN
    IF p_expected = p_actual OR (p_expected IS NULL AND p_actual IS NULL) THEN
        PERFORM test_metadata.log_test(
            p_test_name, p_category, 'PASS',
            'Values match',
            p_expected::TEXT, p_actual::TEXT
        );
        RETURN TRUE;
    ELSE
        PERFORM test_metadata.log_test(
            p_test_name, p_category, 'FAIL',
            'Values do not match',
            p_expected::TEXT, p_actual::TEXT
        );
        RETURN FALSE;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Assert JSONB equals
CREATE OR REPLACE FUNCTION test_metadata.assert_jsonb_equals(
    p_test_name TEXT,
    p_category TEXT,
    p_expected JSONB,
    p_actual JSONB
) RETURNS BOOLEAN AS $$
BEGIN
    IF p_expected = p_actual OR (p_expected IS NULL AND p_actual IS NULL) THEN
        PERFORM test_metadata.log_test(
            p_test_name, p_category, 'PASS',
            'JSONB values match',
            p_expected::TEXT, p_actual::TEXT
        );
        RETURN TRUE;
    ELSE
        PERFORM test_metadata.log_test(
            p_test_name, p_category, 'FAIL',
            'JSONB values do not match',
            p_expected::TEXT, p_actual::TEXT
        );
        RETURN FALSE;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Assert true
CREATE OR REPLACE FUNCTION test_metadata.assert_true(
    p_test_name TEXT,
    p_category TEXT,
    p_condition BOOLEAN,
    p_message TEXT DEFAULT 'Condition is true'
) RETURNS BOOLEAN AS $$
BEGIN
    IF p_condition THEN
        PERFORM test_metadata.log_test(
            p_test_name, p_category, 'PASS', p_message
        );
        RETURN TRUE;
    ELSE
        PERFORM test_metadata.log_test(
            p_test_name, p_category, 'FAIL',
            'Condition is false (expected true)'
        );
        RETURN FALSE;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Assert raises exception
CREATE OR REPLACE FUNCTION test_metadata.assert_raises(
    p_test_name TEXT,
    p_category TEXT,
    p_sql TEXT,
    p_expected_error TEXT DEFAULT NULL
) RETURNS BOOLEAN AS $$
DECLARE
    v_error_message TEXT;
BEGIN
    EXECUTE p_sql;
    
    -- If we get here, no exception was raised
    PERFORM test_metadata.log_test(
        p_test_name, p_category, 'FAIL',
        'Expected exception but none was raised',
        p_expected_error, 'No exception'
    );
    RETURN FALSE;
    
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error_message = MESSAGE_TEXT;
    
    IF p_expected_error IS NULL OR v_error_message LIKE '%' || p_expected_error || '%' THEN
        PERFORM test_metadata.log_test(
            p_test_name, p_category, 'PASS',
            'Expected exception was raised',
            p_expected_error, v_error_message
        );
        RETURN TRUE;
    ELSE
        PERFORM test_metadata.log_test(
            p_test_name, p_category, 'FAIL',
            'Wrong exception was raised',
            p_expected_error, v_error_message
        );
        RETURN FALSE;
    END IF;
END;
$$ LANGUAGE plpgsql;


-- ============================================
-- TEST DATA SETUP
-- ============================================

CREATE OR REPLACE FUNCTION test_metadata.setup_test_data()
RETURNS VOID AS $$
DECLARE
    v_worker_1_key TEXT;
    v_worker_2_key TEXT;
    v_task_id_1 BIGINT;
    v_task_id_2 BIGINT;
    v_queue_exists BOOLEAN;
BEGIN
    -- Ensure a clean slate from any prior runs
    PERFORM test_metadata.cleanup_test_data();
    
    -- Create test queue if it doesn't exist
    SELECT EXISTS(SELECT 1 FROM queue_registry WHERE queue_name = 'test_metadata') 
    INTO v_queue_exists;
    
    IF NOT v_queue_exists THEN
        PERFORM create_queue('test_metadata', 'Queue for metadata tests');
    END IF;

    -- Register test workers
    SELECT api_key INTO v_worker_1_key
    FROM register_worker(
        'test_worker_metadata_1',
        'Test Worker 1',
        10,
        '30 seconds'::INTERVAL,
        '["test_metadata"]'::JSONB
    );
    
    SELECT api_key INTO v_worker_2_key
    FROM register_worker(
        'test_worker_metadata_2',
        'Test Worker 2',
        5,
        '30 seconds'::INTERVAL,
        '["test_metadata"]'::JSONB
    );
    
    -- Store API keys in a temporary table for tests
    DROP TABLE IF EXISTS test_metadata.test_workers;
    CREATE TABLE test_metadata.test_workers (
        worker_id TEXT,
        api_key TEXT,
        worker_num INTEGER
    );
    
    INSERT INTO test_metadata.test_workers VALUES
        ('test_worker_metadata_1', v_worker_1_key, 1),
        ('test_worker_metadata_2', v_worker_2_key, 2);
    
    -- Create test tasks
    PERFORM enqueue_task(
        v_worker_1_key,
        'test_task_metadata',
        '{"test": "data"}'::JSONB,
        'immediate',
        50,
        NOW(),
        3,
        NULL,
        'test_metadata'
    );
    
    -- Dequeue tasks for testing
    SELECT task_id INTO v_task_id_1
    FROM dequeue_task(v_worker_1_key, '10 minutes'::INTERVAL, ARRAY['test_metadata']);
    
    -- Create second task
    PERFORM enqueue_task(
        v_worker_1_key,
        'test_task_metadata_2',
        '{"test": "data2"}'::JSONB,
        'immediate',
        50,
        NOW(),
        3,
        NULL,
        'test_metadata'
    );
    
    SELECT task_id INTO v_task_id_2
    FROM dequeue_task(v_worker_1_key, '10 minutes'::INTERVAL, ARRAY['test_metadata']);
    
    -- Store task IDs
    DROP TABLE IF EXISTS test_metadata.test_tasks;
    CREATE TABLE test_metadata.test_tasks (
        task_id BIGINT,
        task_num INTEGER
    );
    
    INSERT INTO test_metadata.test_tasks VALUES
        (v_task_id_1, 1),
        (v_task_id_2, 2);
    
    RAISE NOTICE 'Test data setup complete';
    RAISE NOTICE 'Worker 1 ID: %, API Key: %', 'test_worker_metadata_1', substring(v_worker_1_key, 1, 15) || '...';
    RAISE NOTICE 'Worker 2 ID: %, API Key: %', 'test_worker_metadata_2', substring(v_worker_2_key, 1, 15) || '...';
    RAISE NOTICE 'Task 1 ID: %', v_task_id_1;
    RAISE NOTICE 'Task 2 ID: %', v_task_id_2;
END;
$$ LANGUAGE plpgsql;


-- ============================================
-- TEST SUITE 1: DEEP MERGE FUNCTIONALITY
-- ============================================

CREATE OR REPLACE FUNCTION test_metadata.test_deep_merge()
RETURNS VOID AS $$
DECLARE
    v_result JSONB;
BEGIN
    RAISE NOTICE '=== Testing Deep Merge Functionality ===';
    
    -- Test 1: Simple merge
    v_result := jsonb_deep_merge(
        '{"a": 1, "b": 2}'::JSONB,
        '{"b": 3, "c": 4}'::JSONB
    );
    PERFORM test_metadata.assert_jsonb_equals(
        'Deep merge: Simple merge',
        'deep_merge',
        '{"a": 1, "b": 3, "c": 4}'::JSONB,
        v_result
    );
    
    -- Test 2: Nested object merge
    v_result := jsonb_deep_merge(
        '{"config": {"x": 1, "y": 2}, "b": 3}'::JSONB,
        '{"config": {"x": 10}, "c": 4}'::JSONB
    );
    PERFORM test_metadata.assert_jsonb_equals(
        'Deep merge: Nested object preservation',
        'deep_merge',
        '{"config": {"x": 10, "y": 2}, "b": 3, "c": 4}'::JSONB,
        v_result
    );
    
    -- Test 3: Deep nested merge (3 levels)
    v_result := jsonb_deep_merge(
        '{"a": {"b": {"c": 1, "d": 2}, "e": 3}}'::JSONB,
        '{"a": {"b": {"c": 10}}}'::JSONB
    );
    PERFORM test_metadata.assert_jsonb_equals(
        'Deep merge: 3-level nested preservation',
        'deep_merge',
        '{"a": {"b": {"c": 10, "d": 2}, "e": 3}}'::JSONB,
        v_result
    );
    
    -- Test 4: Empty base
    v_result := jsonb_deep_merge(
        '{}'::JSONB,
        '{"a": 1, "b": 2}'::JSONB
    );
    PERFORM test_metadata.assert_jsonb_equals(
        'Deep merge: Empty base',
        'deep_merge',
        '{"a": 1, "b": 2}'::JSONB,
        v_result
    );
    
    -- Test 5: Empty patch
    v_result := jsonb_deep_merge(
        '{"a": 1, "b": 2}'::JSONB,
        '{}'::JSONB
    );
    PERFORM test_metadata.assert_jsonb_equals(
        'Deep merge: Empty patch',
        'deep_merge',
        '{"a": 1, "b": 2}'::JSONB,
        v_result
    );
    
    -- Test 6: Array replacement (arrays are not merged, they replace)
    v_result := jsonb_deep_merge(
        '{"arr": [1, 2, 3]}'::JSONB,
        '{"arr": [4, 5]}'::JSONB
    );
    PERFORM test_metadata.assert_jsonb_equals(
        'Deep merge: Array replacement',
        'deep_merge',
        '{"arr": [4, 5]}'::JSONB,
        v_result
    );
    
    -- Test 7: Null handling
    v_result := jsonb_deep_merge(
        '{"a": 1, "b": null}'::JSONB,
        '{"b": 2, "c": null}'::JSONB
    );
    PERFORM test_metadata.assert_jsonb_equals(
        'Deep merge: Null handling',
        'deep_merge',
        '{"a": 1, "b": 2, "c": null}'::JSONB,
        v_result
    );
END;
$$ LANGUAGE plpgsql;


-- ============================================
-- TEST SUITE 2: VALIDATION FUNCTIONS
-- ============================================

CREATE OR REPLACE FUNCTION test_metadata.test_validation()
RETURNS VOID AS $$
BEGIN
    RAISE NOTICE '=== Testing Validation Functions ===';
    
    -- Test 1: Valid keys pass
    PERFORM test_metadata.assert_true(
        'Validation: Valid keys accepted',
        'validation',
        validate_metadata_keys('{"config": 1, "data": 2}'::JSONB),
        'Valid keys should pass'
    );
    
    -- Test 2: Reserved key _system
    PERFORM test_metadata.assert_raises(
        'Validation: Reserved _system key rejected',
        'validation',
        'SELECT validate_metadata_keys(''{"_system": 1}''::JSONB)',
        'Reserved metadata key "_system"'
    );
    
    -- Test 3: Reserved key _internal
    PERFORM test_metadata.assert_raises(
        'Validation: Reserved _internal key rejected',
        'validation',
        'SELECT validate_metadata_keys(''{"_internal": 1}''::JSONB)',
        'Reserved metadata key "_internal"'
    );
    
    -- Test 4: Any underscore prefix
    PERFORM test_metadata.assert_raises(
        'Validation: Underscore prefix rejected',
        'validation',
        'SELECT validate_metadata_keys(''{"_custom": 1}''::JSONB)',
        'Metadata keys starting with underscore'
    );
    
    -- Test 5: Multiple keys with one reserved
    PERFORM test_metadata.assert_raises(
        'Validation: Mixed valid/invalid keys rejected',
        'validation',
        'SELECT validate_metadata_keys(''{"valid": 1, "_invalid": 2}''::JSONB)',
        'underscore'
    );
END;
$$ LANGUAGE plpgsql;


-- ============================================
-- TEST SUITE 3: WORKER METADATA OPERATIONS
-- ============================================

CREATE OR REPLACE FUNCTION test_metadata.test_worker_metadata()
RETURNS VOID AS $$
DECLARE
    v_api_key TEXT;
    v_result JSONB;
    v_profile JSONB;
    v_all_metadata RECORD;
BEGIN
    RAISE NOTICE '=== Testing Worker Metadata Operations ===';
    
    SELECT api_key INTO v_api_key 
    FROM test_metadata.test_workers 
    WHERE worker_num = 1;
    
    -- Test 1: Set initial worker metadata
    v_result := patch_worker_metadata(
        v_api_key,
        '{"config": {"timeout": 30, "retries": 3}, "version": 1}'::JSONB,
        TRUE
    );
    PERFORM test_metadata.assert_jsonb_equals(
        'Worker metadata: Initial set',
        'worker_metadata',
        '{"config": {"timeout": 30, "retries": 3}, "version": 1}'::JSONB,
        v_result
    );
    
    -- Test 2: Deep merge update (preserve nested fields)
    v_result := patch_worker_metadata(
        v_api_key,
        '{"config": {"timeout": 60}}'::JSONB,
        TRUE  -- Deep merge
    );
    PERFORM test_metadata.assert_jsonb_equals(
        'Worker metadata: Deep merge preserves nested',
        'worker_metadata',
        '{"config": {"timeout": 60, "retries": 3}, "version": 1}'::JSONB,
        v_result
    );
    
    -- Test 3: Shallow merge (replaces nested object)
    v_result := patch_worker_metadata(
        v_api_key,
        '{"config": {"timeout": 90}}'::JSONB,
        FALSE  -- Shallow merge
    );
    PERFORM test_metadata.assert_jsonb_equals(
        'Worker metadata: Shallow merge replaces nested',
        'worker_metadata',
        '{"config": {"timeout": 90}, "version": 1}'::JSONB,
        v_result
    );
    
    -- Test 4: Get worker metadata
    v_result := get_worker_metadata(v_api_key);
    PERFORM test_metadata.assert_jsonb_equals(
        'Worker metadata: Get metadata',
        'worker_metadata',
        '{"config": {"timeout": 90}, "version": 1}'::JSONB,
        v_result
    );

    -- Test 5: Get enriched worker profile metadata
    v_profile := get_worker_metadata_profile(v_api_key);
    PERFORM test_metadata.assert_true(
        'Worker metadata: Profile payload includes worker and config fields',
        'worker_metadata',
        v_profile->>'worker_id' = 'test_worker_metadata_1'
        AND (v_profile ? 'worker_timeout')
        AND (v_profile ? 'metadata_history_enabled'),
        'Profile should include worker identity and scheduler configuration fields'
    );
    
    -- Test 6: Version increment
    PERFORM patch_worker_metadata(
        v_api_key,
        '{"new_field": "value"}'::JSONB,
        TRUE
    );
    PERFORM test_metadata.assert_true(
        'Worker metadata: Version incremented',
        'worker_metadata',
        (SELECT version = 4 FROM worker_metadata WHERE worker_id = 'test_worker_metadata_1'),
        'Version should increment with each update'
    );
    
    -- Test 7: Get all workers metadata
    SELECT INTO v_all_metadata *
    FROM get_all_workers_metadata(TRUE)
    WHERE worker_id = 'test_worker_metadata_1';
    
    PERFORM test_metadata.assert_true(
        'Worker metadata: Bulk query returns data',
        'worker_metadata',
        v_all_metadata.worker_id IS NOT NULL,
        'Bulk query should return worker metadata'
    );
    
    -- Test 8: Reserved key rejection
    PERFORM test_metadata.assert_raises(
        'Worker metadata: Reserved key rejected',
        'worker_metadata',
        format('SELECT patch_worker_metadata(''%s'', ''{"_system": "value"}''::JSONB, TRUE)', v_api_key),
        'Reserved metadata key'
    );
    
    -- Test 9: Size limit enforcement
    PERFORM test_metadata.assert_raises(
        'Worker metadata: Size limit enforced',
        'worker_metadata',
        format('SELECT patch_worker_metadata(''%s'', ''{"large": "%s"}''::JSONB, TRUE)', 
            v_api_key, 
            repeat('x', 110000)  -- Exceeds 100KB limit
        ),
        'exceeds maximum size'
    );

    -- Test 10: Delete existing worker metadata
    PERFORM test_metadata.assert_true(
        'Worker metadata: Delete existing metadata',
        'worker_metadata',
        delete_worker_metadata(v_api_key),
        'Delete should return TRUE when metadata exists'
    );

    v_result := get_worker_metadata(v_api_key);
    PERFORM test_metadata.assert_jsonb_equals(
        'Worker metadata: Delete clears metadata to empty object',
        'worker_metadata',
        '{}'::JSONB,
        v_result
    );

    -- Test 11: Delete when already empty returns FALSE
    PERFORM test_metadata.assert_true(
        'Worker metadata: Delete absent metadata returns false',
        'worker_metadata',
        NOT delete_worker_metadata(v_api_key),
        'Delete should return FALSE when metadata does not exist'
    );
END;
$$ LANGUAGE plpgsql;


-- ============================================
-- TEST SUITE 4: TASK METADATA OPERATIONS
-- ============================================

CREATE OR REPLACE FUNCTION test_metadata.test_task_metadata()
RETURNS VOID AS $$
DECLARE
    v_api_key TEXT;
    v_task_id BIGINT;
    v_result JSONB;
    v_history_count INTEGER;
BEGIN
    RAISE NOTICE '=== Testing Task Metadata Operations ===';
    
    SELECT api_key INTO v_api_key 
    FROM test_metadata.test_workers 
    WHERE worker_num = 1;
    
    SELECT task_id INTO v_task_id
    FROM test_metadata.test_tasks
    WHERE task_num = 1;
    
    -- Test 1: Set initial task metadata
    v_result := patch_task_metadata(
        v_api_key,
        v_task_id,
        '{"progress": {"current": 0, "total": 100}, "started": "2026-02-11T10:00:00Z"}'::JSONB,
        TRUE,  -- Log history
        TRUE   -- Deep merge
    );
    PERFORM test_metadata.assert_jsonb_equals(
        'Task metadata: Initial set',
        'task_metadata',
        '{"progress": {"current": 0, "total": 100}, "started": "2026-02-11T10:00:00Z"}'::JSONB,
        v_result
    );
    
    -- Test 2: Deep merge update (preserve fields)
    v_result := patch_task_metadata(
        v_api_key,
        v_task_id,
        '{"progress": {"current": 50}}'::JSONB,
        TRUE,
        TRUE
    );
    PERFORM test_metadata.assert_jsonb_equals(
        'Task metadata: Deep merge preserves fields',
        'task_metadata',
        '{"progress": {"current": 50, "total": 100}, "started": "2026-02-11T10:00:00Z"}'::JSONB,
        v_result
    );
    
    -- Test 3: Shallow merge (replaces nested object)
    v_result := patch_task_metadata(
        v_api_key,
        v_task_id,
        '{"progress": {"current": 75}}'::JSONB,
        TRUE,
        FALSE  -- Shallow merge
    );
    PERFORM test_metadata.assert_jsonb_equals(
        'Task metadata: Shallow merge replaces nested',
        'task_metadata',
        '{"progress": {"current": 75}, "started": "2026-02-11T10:00:00Z"}'::JSONB,
        v_result
    );
    
    -- Test 4: Get task metadata
    v_result := get_task_metadata(v_api_key, v_task_id);
    PERFORM test_metadata.assert_jsonb_equals(
        'Task metadata: Get metadata',
        'task_metadata',
        '{"progress": {"current": 75}, "started": "2026-02-11T10:00:00Z"}'::JSONB,
        v_result
    );
    
    -- Test 5: History logging
    SELECT COUNT(*) INTO v_history_count
    FROM task_metadata_history
    WHERE task_id = v_task_id;
    
    PERFORM test_metadata.assert_true(
        'Task metadata: History logged',
        'task_metadata',
        v_history_count = 3,  -- 3 updates so far
        format('Expected 3 history records, got %s', v_history_count)
    );
    
    -- Test 6: Update without history logging
    v_result := patch_task_metadata(
        v_api_key,
        v_task_id,
        '{"no_history": true}'::JSONB,
        FALSE,  -- Don't log history
        TRUE
    );
    
    SELECT COUNT(*) INTO v_history_count
    FROM task_metadata_history
    WHERE task_id = v_task_id;
    
    PERFORM test_metadata.assert_true(
        'Task metadata: History not logged when disabled',
        'task_metadata',
        v_history_count = 3,  -- Still 3 (didn't increase)
        format('Expected 3 history records, got %s', v_history_count)
    );
    
    -- Test 7: Get task metadata history
    PERFORM test_metadata.assert_true(
        'Task metadata: History query works',
        'task_metadata',
        EXISTS(
            SELECT 1 FROM get_task_metadata_history(v_api_key, v_task_id, 10)
        ),
        'History query should return records'
    );
    
    -- Test 8: Delete task metadata
    PERFORM test_metadata.assert_true(
        'Task metadata: Delete existing metadata',
        'task_metadata',
        delete_task_metadata(v_api_key, v_task_id, TRUE),
        'Delete should return TRUE for owned processing task'
    );

    v_result := get_task_metadata(v_api_key, v_task_id);
    PERFORM test_metadata.assert_jsonb_equals(
        'Task metadata: Delete clears metadata to empty object',
        'task_metadata',
        '{}'::JSONB,
        v_result
    );

    SELECT COUNT(*) INTO v_history_count
    FROM task_metadata_history
    WHERE task_id = v_task_id;

    PERFORM test_metadata.assert_true(
        'Task metadata: Delete action logged to history',
        'task_metadata',
        v_history_count = 4,
        format('Expected 4 history records after delete, got %s', v_history_count)
    );

    -- Test 9: Wrong worker cannot access metadata
    DECLARE
        v_other_api_key TEXT;
    BEGIN
        SELECT api_key INTO v_other_api_key 
        FROM test_metadata.test_workers 
        WHERE worker_num = 2;
        
        PERFORM test_metadata.assert_raises(
            'Task metadata: Wrong worker rejected',
            'task_metadata',
            format('SELECT get_task_metadata(''%s'', %s)', v_other_api_key, v_task_id),
            'not owned by worker'
        );
    END;
    
    -- Test 10: Reserved key rejection
    PERFORM test_metadata.assert_raises(
        'Task metadata: Reserved key rejected',
        'task_metadata',
        format('SELECT patch_task_metadata(''%s'', %s, ''{"_system": "value"}''::JSONB, TRUE, TRUE)', 
            v_api_key, v_task_id),
        'Reserved metadata key'
    );
END;
$$ LANGUAGE plpgsql;


-- ============================================
-- TEST SUITE 5: LEASE EXPIRATION CHECKS
-- ============================================

CREATE OR REPLACE FUNCTION test_metadata.test_lease_expiration()
RETURNS VOID AS $$
DECLARE
    v_api_key TEXT;
    v_task_id BIGINT;
BEGIN
    RAISE NOTICE '=== Testing Lease Expiration Checks ===';
    
    SELECT api_key INTO v_api_key 
    FROM test_metadata.test_workers 
    WHERE worker_num = 1;
    
    SELECT task_id INTO v_task_id
    FROM test_metadata.test_tasks
    WHERE task_num = 2;
    
    -- Test 1: Valid lease allows update
    PERFORM test_metadata.assert_true(
        'Lease check: Valid lease allows update',
        'lease_expiration',
        (SELECT lease_expires_at > NOW() FROM task_queue WHERE id = v_task_id),
        'Task should have valid lease'
    );
    
    -- Test 2: Expire the lease manually
    UPDATE task_queue
    SET lease_expires_at = NOW() - INTERVAL '1 minute'
    WHERE id = v_task_id;
    
    -- Test 3: Expired lease rejects update
    PERFORM test_metadata.assert_raises(
        'Lease check: Expired lease rejected',
        'lease_expiration',
        format('SELECT patch_task_metadata(''%s'', %s, ''{"test": "value"}''::JSONB, TRUE, TRUE)', 
            v_api_key, v_task_id),
        'lease expired'
    );
    
    -- Restore lease for cleanup
    UPDATE task_queue
    SET lease_expires_at = NOW() + INTERVAL '10 minutes'
    WHERE id = v_task_id;
END;
$$ LANGUAGE plpgsql;


-- ============================================
-- TEST SUITE 6: CLEANUP FUNCTIONS
-- ============================================

CREATE OR REPLACE FUNCTION test_metadata.test_cleanup()
RETURNS VOID AS $$
DECLARE
    v_api_key TEXT;
    v_task_id BIGINT;
    v_initial_count INTEGER;
    v_after_count INTEGER;
    v_deleted_count INTEGER;
BEGIN
    RAISE NOTICE '=== Testing Cleanup Functions ===';
    
    SELECT api_key INTO v_api_key 
    FROM test_metadata.test_workers 
    WHERE worker_num = 1;
    
    SELECT task_id INTO v_task_id
    FROM test_metadata.test_tasks
    WHERE task_num = 1;
    
    -- Create some old history records
    INSERT INTO task_metadata_history (task_id, worker_id, patch, metadata_after, created_at)
    SELECT 
        v_task_id,
        'test_worker_metadata_1',
        '{"old": "data"}'::JSONB,
        '{"old": "data"}'::JSONB,
        NOW() - INTERVAL '100 days' - (n || ' days')::INTERVAL
    FROM generate_series(1, 10) n;
    
    -- Create some recent history records
    INSERT INTO task_metadata_history (task_id, worker_id, patch, metadata_after)
    SELECT 
        v_task_id,
        'test_worker_metadata_1',
        '{"new": "data"}'::JSONB,
        '{"new": "data"}'::JSONB
    FROM generate_series(1, 5);
    
    SELECT COUNT(*) INTO v_initial_count
    FROM task_metadata_history
    WHERE task_id = v_task_id;
    
    -- Test 1: Cleanup old records
    v_deleted_count := cleanup_task_metadata_history('90 days'::INTERVAL, 5);
    
    PERFORM test_metadata.assert_true(
        'Cleanup: Old records deleted',
        'cleanup',
        v_deleted_count = 10,
        format('Expected 10 deletions, got %s', v_deleted_count)
    );
    
    -- Test 2: Recent records preserved
    SELECT COUNT(*) INTO v_after_count
    FROM task_metadata_history
    WHERE task_id = v_task_id
      AND created_at > NOW() - INTERVAL '90 days';
    
    PERFORM test_metadata.assert_true(
        'Cleanup: Recent records preserved',
        'cleanup',
        v_after_count >= 5,
        format('Expected at least 5 recent records, got %s', v_after_count)
    );
    
    -- Test 3: Minimum retention enforced
    PERFORM test_metadata.assert_raises(
        'Cleanup: Minimum retention enforced',
        'cleanup',
        'SELECT cleanup_task_metadata_history(''5 days''::INTERVAL, 1000)',
        'Cannot cleanup metadata history newer than 7 days'
    );
    
    -- Test 4: Batch size limit enforced
    PERFORM test_metadata.assert_raises(
        'Cleanup: Batch size limit enforced',
        'cleanup',
        'SELECT cleanup_task_metadata_history(''90 days''::INTERVAL, 60000)',
        'Batch size cannot exceed 50000'
    );
END;
$$ LANGUAGE plpgsql;


-- ============================================
-- TEST SUITE 7: EDGE CASES AND ERROR HANDLING
-- ============================================

CREATE OR REPLACE FUNCTION test_metadata.test_edge_cases()
RETURNS VOID AS $$
DECLARE
    v_api_key TEXT;
    v_task_id BIGINT;
    v_result JSONB;
BEGIN
    RAISE NOTICE '=== Testing Edge Cases ===';
    
    SELECT api_key INTO v_api_key 
    FROM test_metadata.test_workers 
    WHERE worker_num = 1;
    
    SELECT task_id INTO v_task_id
    FROM test_metadata.test_tasks
    WHERE task_num = 1;
    
    -- Test 1: Get metadata for worker with no metadata
    DELETE FROM worker_metadata WHERE worker_id = 'test_worker_metadata_2';
    
    DECLARE
        v_api_key_2 TEXT;
    BEGIN
        SELECT api_key INTO v_api_key_2 
        FROM test_metadata.test_workers 
        WHERE worker_num = 2;
        
        v_result := get_worker_metadata(v_api_key_2);
        
        PERFORM test_metadata.assert_jsonb_equals(
            'Edge case: Get non-existent worker metadata returns empty',
            'edge_cases',
            '{}'::JSONB,
            v_result
        );
    END;
    
    -- Test 2: Invalid JSON type
    PERFORM test_metadata.assert_raises(
        'Edge case: Non-object JSON rejected',
        'edge_cases',
        format('SELECT patch_worker_metadata(''%s'', ''["array"]''::JSONB, TRUE)', v_api_key),
        'must be a JSON object'
    );
    
    -- Test 3: NULL patch rejected
    PERFORM test_metadata.assert_raises(
        'Edge case: NULL patch rejected',
        'edge_cases',
        format('SELECT patch_worker_metadata(''%s'', NULL, TRUE)', v_api_key),
        'must be a JSON object'
    );
    
    -- Test 4: Empty object is valid
    v_result := patch_worker_metadata(v_api_key, '{}'::JSONB, TRUE);
    
    PERFORM test_metadata.assert_true(
        'Edge case: Empty object patch accepted',
        'edge_cases',
        v_result IS NOT NULL,
        'Empty object should be valid'
    );
    
    -- Test 5: Deep nesting (5 levels)
    v_result := jsonb_deep_merge(
        '{"a":{"b":{"c":{"d":{"e":1}}}}}'::JSONB,
        '{"a":{"b":{"c":{"d":{"e":2}}}}}'::JSONB
    );
    
    PERFORM test_metadata.assert_jsonb_equals(
        'Edge case: Deep nesting handled',
        'edge_cases',
        '{"a":{"b":{"c":{"d":{"e":2}}}}}'::JSONB,
        v_result
    );
    
    -- Test 6: Invalid task ID
    PERFORM test_metadata.assert_raises(
        'Edge case: Invalid task ID rejected',
        'edge_cases',
        format('SELECT patch_task_metadata(''%s'', 999999, ''{"test": "value"}''::JSONB, TRUE, TRUE)', v_api_key),
        'not found'
    );
    
    -- Test 7: Task not in processing state
    -- First complete the task
    PERFORM complete_task(v_api_key, v_task_id, NULL);
    
    PERFORM test_metadata.assert_raises(
        'Edge case: Completed task metadata update rejected',
        'edge_cases',
        format('SELECT patch_task_metadata(''%s'', %s, ''{"test": "value"}''::JSONB, TRUE, TRUE)', 
            v_api_key, v_task_id),
        'not processing'
    );
END;
$$ LANGUAGE plpgsql;


-- ============================================
-- TEST SUITE 8: PERFORMANCE TESTS
-- ============================================

CREATE OR REPLACE FUNCTION test_metadata.test_performance()
RETURNS VOID AS $$
DECLARE
    v_api_key TEXT;
    v_start_time TIMESTAMPTZ;
    v_end_time TIMESTAMPTZ;
    v_duration NUMERIC;
    v_result JSONB;
    v_i INTEGER;
BEGIN
    RAISE NOTICE '=== Testing Performance ===';
    
    SELECT api_key INTO v_api_key 
    FROM test_metadata.test_workers 
    WHERE worker_num = 1;
    
    -- Test 1: 100 sequential deep merges
    v_start_time := clock_timestamp();
    
    FOR v_i IN 1..100 LOOP
        v_result := jsonb_deep_merge(
            '{"a":{"b":{"c":1,"d":2},"e":3},"f":4}'::JSONB,
            format('{"a":{"b":{"c":%s}}}', v_i)::JSONB
        );
    END LOOP;
    
    v_end_time := clock_timestamp();
    v_duration := EXTRACT(EPOCH FROM (v_end_time - v_start_time)) * 1000;
    
    PERFORM test_metadata.log_test(
        'Performance: 100 deep merges',
        'performance',
        CASE WHEN v_duration < 1000 THEN 'PASS' ELSE 'FAIL' END,
        format('Completed in %s ms (%s ms avg)', round(v_duration, 2), round(v_duration/100, 2)),
        '< 1000 ms total',
        format('%s ms', round(v_duration, 2)),
        NULL,
        v_duration
    );
    
    -- Test 2: 50 worker metadata updates
    v_start_time := clock_timestamp();
    
    FOR v_i IN 1..50 LOOP
        PERFORM patch_worker_metadata(
            v_api_key,
            format('{"iteration": %s}', v_i)::JSONB,
            TRUE
        );
    END LOOP;
    
    v_end_time := clock_timestamp();
    v_duration := EXTRACT(EPOCH FROM (v_end_time - v_start_time)) * 1000;
    
    PERFORM test_metadata.log_test(
        'Performance: 50 metadata updates',
        'performance',
        CASE WHEN v_duration < 5000 THEN 'PASS' ELSE 'FAIL' END,
        format('Completed in %s ms (%s ms avg)', round(v_duration, 2), round(v_duration/50, 2)),
        '< 5000 ms total',
        format('%s ms', round(v_duration, 2)),
        NULL,
        v_duration
    );
    
    -- Test 3: Metadata retrieval speed
    v_start_time := clock_timestamp();
    
    FOR v_i IN 1..100 LOOP
        v_result := get_worker_metadata(v_api_key);
    END LOOP;
    
    v_end_time := clock_timestamp();
    v_duration := EXTRACT(EPOCH FROM (v_end_time - v_start_time)) * 1000;
    
    PERFORM test_metadata.log_test(
        'Performance: 100 metadata retrievals',
        'performance',
        CASE WHEN v_duration < 1000 THEN 'PASS' ELSE 'FAIL' END,
        format('Completed in %s ms (%s ms avg)', round(v_duration, 2), round(v_duration/100, 2)),
        '< 1000 ms total',
        format('%s ms', round(v_duration, 2)),
        NULL,
        v_duration
    );
END;
$$ LANGUAGE plpgsql;


-- ============================================
-- TEST RUNNER
-- ============================================

CREATE OR REPLACE FUNCTION test_metadata.run_all_tests()
RETURNS TABLE(
    category TEXT,
    total_tests INTEGER,
    passed INTEGER,
    failed INTEGER,
    errors INTEGER,
    pass_rate NUMERIC
) AS $$
BEGIN
    -- Clear previous results
    DELETE FROM test_metadata.test_results;
    
    RAISE NOTICE '';
    RAISE NOTICE '╔════════════════════════════════════════════════════════╗';
    RAISE NOTICE '║       METADATA MODULE TEST SUITE v2.2                  ║';
    RAISE NOTICE '╚════════════════════════════════════════════════════════╝';
    RAISE NOTICE '';
    
    -- Setup test data
    PERFORM test_metadata.setup_test_data();
    RAISE NOTICE '';
    
    -- Run test suites
    BEGIN
        PERFORM test_metadata.test_deep_merge();
    EXCEPTION WHEN OTHERS THEN
        PERFORM test_metadata.log_test(
            'Deep merge suite',
            'deep_merge',
            'ERROR',
            'Test suite failed',
            NULL,
            NULL,
            SQLERRM
        );
    END;
    
    BEGIN
        PERFORM test_metadata.test_validation();
    EXCEPTION WHEN OTHERS THEN
        PERFORM test_metadata.log_test(
            'Validation suite',
            'validation',
            'ERROR',
            'Test suite failed',
            NULL,
            NULL,
            SQLERRM
        );
    END;
    
    BEGIN
        PERFORM test_metadata.test_worker_metadata();
    EXCEPTION WHEN OTHERS THEN
        PERFORM test_metadata.log_test(
            'Worker metadata suite',
            'worker_metadata',
            'ERROR',
            'Test suite failed',
            NULL,
            NULL,
            SQLERRM
        );
    END;
    
    BEGIN
        PERFORM test_metadata.test_task_metadata();
    EXCEPTION WHEN OTHERS THEN
        PERFORM test_metadata.log_test(
            'Task metadata suite',
            'task_metadata',
            'ERROR',
            'Test suite failed',
            NULL,
            NULL,
            SQLERRM
        );
    END;
    
    BEGIN
        PERFORM test_metadata.test_lease_expiration();
    EXCEPTION WHEN OTHERS THEN
        PERFORM test_metadata.log_test(
            'Lease expiration suite',
            'lease_expiration',
            'ERROR',
            'Test suite failed',
            NULL,
            NULL,
            SQLERRM
        );
    END;
    
    BEGIN
        PERFORM test_metadata.test_cleanup();
    EXCEPTION WHEN OTHERS THEN
        PERFORM test_metadata.log_test(
            'Cleanup suite',
            'cleanup',
            'ERROR',
            'Test suite failed',
            NULL,
            NULL,
            SQLERRM
        );
    END;
    
    BEGIN
        PERFORM test_metadata.test_edge_cases();
    EXCEPTION WHEN OTHERS THEN
        PERFORM test_metadata.log_test(
            'Edge cases suite',
            'edge_cases',
            'ERROR',
            'Test suite failed',
            NULL,
            NULL,
            SQLERRM
        );
    END;
    
    BEGIN
        PERFORM test_metadata.test_performance();
    EXCEPTION WHEN OTHERS THEN
        PERFORM test_metadata.log_test(
            'Performance suite',
            'performance',
            'ERROR',
            'Test suite failed',
            NULL,
            NULL,
            SQLERRM
        );
    END;
    
    RAISE NOTICE '';
    RAISE NOTICE '╔════════════════════════════════════════════════════════╗';
    RAISE NOTICE '║                   TEST RESULTS                         ║';
    RAISE NOTICE '╚════════════════════════════════════════════════════════╝';
    RAISE NOTICE '';
    
    -- Always cleanup after execution (even when successful)
    PERFORM test_metadata.cleanup_test_data();
    
    -- Return summary
    RETURN QUERY
    SELECT 
        test_category,
        COUNT(*)::INTEGER AS total,
        COUNT(*) FILTER (WHERE status = 'PASS')::INTEGER AS passed,
        COUNT(*) FILTER (WHERE status = 'FAIL')::INTEGER AS failed,
        COUNT(*) FILTER (WHERE status = 'ERROR')::INTEGER AS errors,
        ROUND(
            COUNT(*) FILTER (WHERE status = 'PASS')::NUMERIC / 
            NULLIF(COUNT(*), 0) * 100, 
            2
        ) AS pass_rate
    FROM test_metadata.test_results
    GROUP BY test_category
    ORDER BY test_category;
EXCEPTION WHEN OTHERS THEN
    PERFORM test_metadata.cleanup_test_data();
    RAISE;
END;
$$ LANGUAGE plpgsql;


-- ============================================
-- TEST CLEANUP
-- ============================================

CREATE OR REPLACE FUNCTION test_metadata.cleanup_test_data()
RETURNS VOID AS $$
BEGIN
    -- Delete test tasks
    DELETE FROM task_queue WHERE task_name LIKE 'test_task_metadata%';
    
    -- Delete worker metadata and keys
    DELETE FROM worker_metadata WHERE worker_id LIKE 'test_worker_metadata%';
    DELETE FROM worker_api_keys WHERE worker_id LIKE 'test_worker_metadata%';
    
    -- Clear rate limits generated by test workers
    DELETE FROM rate_limits WHERE identifier LIKE 'test_worker_metadata%';
    
    -- Remove task metadata history created by test workers
    DELETE FROM task_metadata_history 
    WHERE worker_id LIKE 'test_worker_metadata%'
       OR task_id IN (
            SELECT id FROM task_queue WHERE task_name LIKE 'test_task_metadata%'
       );
    
    -- Delete test workers
    DELETE FROM worker_registry WHERE worker_id LIKE 'test_worker_metadata%';
    
    -- Delete test queue
    DELETE FROM queue_registry WHERE queue_name = 'test_metadata';
    
    -- Drop temp tables
    DROP TABLE IF EXISTS test_metadata.test_workers;
    DROP TABLE IF EXISTS test_metadata.test_tasks;
    
    RAISE NOTICE 'Test data cleanup complete';
END;
$$ LANGUAGE plpgsql;


-- ============================================
-- QUICK TEST REPORT
-- ============================================

CREATE OR REPLACE FUNCTION test_metadata.print_test_report()
RETURNS VOID AS $$
DECLARE
    v_rec RECORD;
    v_total INTEGER;
    v_passed INTEGER;
    v_failed INTEGER;
    v_errors INTEGER;
    v_overall_rate NUMERIC;
BEGIN
    SELECT 
        COUNT(*)::INTEGER,
        COUNT(*) FILTER (WHERE status = 'PASS')::INTEGER,
        COUNT(*) FILTER (WHERE status = 'FAIL')::INTEGER,
        COUNT(*) FILTER (WHERE status = 'ERROR')::INTEGER,
        ROUND(COUNT(*) FILTER (WHERE status = 'PASS')::NUMERIC / NULLIF(COUNT(*), 0) * 100, 2)
    INTO v_total, v_passed, v_failed, v_errors, v_overall_rate
    FROM test_metadata.test_results;
    
    RAISE NOTICE '';
    RAISE NOTICE 'OVERALL SUMMARY:';
    RAISE NOTICE '  Total Tests: %', v_total;
    RAISE NOTICE '  Passed:      % (%.2f%%)', v_passed, v_overall_rate;
    RAISE NOTICE '  Failed:      %', v_failed;
    RAISE NOTICE '  Errors:      %', v_errors;
    RAISE NOTICE '';
    
    IF v_failed > 0 OR v_errors > 0 THEN
        RAISE NOTICE 'FAILED/ERROR TESTS:';
        FOR v_rec IN 
            SELECT test_name, test_category, status, message, error_detail
            FROM test_metadata.test_results
            WHERE status IN ('FAIL', 'ERROR')
            ORDER BY test_category, test_name
        LOOP
            RAISE NOTICE '  [%] % - %', v_rec.status, v_rec.test_name, 
                COALESCE(v_rec.message, v_rec.error_detail);
        END LOOP;
        RAISE NOTICE '';
    END IF;
    
    RAISE NOTICE '═══════════════════════════════════════════════════════════';
    IF v_failed = 0 AND v_errors = 0 THEN
        RAISE NOTICE '✓ ALL TESTS PASSED!';
    ELSE
        RAISE NOTICE '✗ SOME TESTS FAILED';
    END IF;
    RAISE NOTICE '═══════════════════════════════════════════════════════════';
    RAISE NOTICE '';
END;
$$ LANGUAGE plpgsql;


-- ============================================
-- USAGE INSTRUCTIONS
-- ============================================

/*

To run the complete test suite:

1. Run all tests and get summary:
   SELECT * FROM test_metadata.run_all_tests();

2. Print detailed report:
   SELECT test_metadata.print_test_report();

3. View all test results:
   SELECT * FROM test_metadata.test_results ORDER BY test_category, test_name;

4. View only failures:
   SELECT * FROM test_metadata.test_results 
   WHERE status IN ('FAIL', 'ERROR')
   ORDER BY test_category, test_name;

5. Clean up test data when done:
   SELECT test_metadata.cleanup_test_data();


To run individual test suites:
   SELECT test_metadata.test_deep_merge();
   SELECT test_metadata.test_validation();
   SELECT test_metadata.test_worker_metadata();
   SELECT test_metadata.test_task_metadata();
   SELECT test_metadata.test_lease_expiration();
   SELECT test_metadata.test_cleanup();
   SELECT test_metadata.test_edge_cases();
   SELECT test_metadata.test_performance();


Example output:

     category      | total_tests | passed | failed | errors | pass_rate
-------------------+-------------+--------+--------+--------+-----------
 cleanup           |           4 |      4 |      0 |      0 |    100.00
 deep_merge        |           7 |      7 |      0 |      0 |    100.00
 edge_cases        |           7 |      7 |      0 |      0 |    100.00
 lease_expiration  |           3 |      3 |      0 |      0 |    100.00
 performance       |           3 |      3 |      0 |      0 |    100.00
 task_metadata     |           9 |      9 |      0 |      0 |    100.00
 validation        |           5 |      5 |      0 |      0 |    100.00
 worker_metadata   |           8 |      8 |      0 |      0 |    100.00

*/
