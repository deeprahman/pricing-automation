-- ============================================
-- SERVICE WORKER TESTING SETUP SCRIPT
-- Version: 2.1
-- ============================================
-- This script sets up a complete testing environment
-- for the service worker workflow.
--
-- Usage:
--   psql -U your_user -d your_database -f test_setup.sql
--
-- Then save the API key from the output!
-- ============================================

\echo '================================================'
\echo 'SERVICE WORKER TEST ENVIRONMENT SETUP'
\echo '================================================'
\echo ''

-- ============================================
-- 1. VERIFY SCHEMA VERSION
-- ============================================

\echo '→ Step 1: Verifying schema...'

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_tables WHERE tablename = 'queue_registry') THEN
        RAISE EXCEPTION 'queue_registry table not found. Please install secure_task_scheduler v2.1 schema first.';
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_tables WHERE tablename = 'worker_registry') THEN
        RAISE EXCEPTION 'worker_registry table not found. Please install secure_task_scheduler v2.1 schema first.';
    END IF;
    
    RAISE NOTICE '✓ Schema verification passed';
END $$;

\echo ''

-- ============================================
-- 2. CREATE TEST QUEUES
-- ============================================

\echo '→ Step 2: Creating test queues...'

-- Create test queues
SELECT create_queue('test_short', 'Queue for short test tasks (< 1 second)');
SELECT create_queue('test_medium', 'Queue for medium test tasks (5-30 seconds)');
SELECT create_queue('test_long', 'Queue for long-running batch tasks (minutes)');

-- Verify creation
SELECT 
    '  ✓ Queue created: ' || queue_name || ' (active: ' || is_active || ')' as status
FROM queue_registry
WHERE queue_name LIKE 'test_%'
ORDER BY queue_name;

\echo ''

-- ============================================
-- 3. REGISTER TEST WORKER
-- ============================================

\echo '→ Step 3: Registering test worker...'
\echo ''
\echo '⚠️  IMPORTANT: SAVE THE API KEY FROM THE OUTPUT BELOW!'
\echo ''

-- Register worker and display API key
SELECT 
    worker_id,
    api_key,
    '✓ Worker registered successfully!' as status
FROM register_worker(
    'test-worker-001',                                                    -- worker_id
    'Test Worker for Tutorial',                                           -- worker_name
    10,                                                                    -- max_concurrent_tasks
    '30 seconds'::INTERVAL,                                               -- heartbeat_interval
    '["default", "test_short", "test_medium", "test_long"]'::JSONB       -- subscribed_queues
);

\echo ''
\echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
\echo 'COPY THE API KEY ABOVE AND SET IT IN n8n:'
\echo 'export SERVICE_WORKER_API_KEY="sk_..."'
\echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
\echo ''

-- ============================================
-- 4. VERIFY WORKER SETUP
-- ============================================

\echo '→ Step 4: Verifying worker setup...'

SELECT 
    worker_id,
    worker_name,
    is_active,
    subscribed_queues,
    max_concurrent_tasks,
    '✓ Active and ready' as status
FROM worker_registry
WHERE worker_id = 'test-worker-001';

\echo ''

-- ============================================
-- 5. CREATE SAMPLE TEST TASKS
-- ============================================

\echo '→ Step 5: Creating sample test tasks...'

-- Short tasks
DO $$
DECLARE
    v_api_key TEXT;
BEGIN
    SELECT api_key_hash INTO v_api_key
    FROM worker_api_keys
    WHERE worker_id = 'test-worker-001'
    LIMIT 1;
    
    -- Create 3 short tasks
    PERFORM enqueue_task(
        v_api_key,
        'test_short_task',
        json_build_object('value', 'sample-' || i, 'description', 'Sample short task ' || i)::JSONB,
        'immediate',
        50 + (i * 10),
        NOW(),
        3,
        NULL,
        'test_short'
    ) FROM generate_series(1, 3) i;
    
    RAISE NOTICE '  ✓ Created 3 short test tasks';
    
    -- Create 1 medium task
    PERFORM enqueue_task(
        v_api_key,
        'test_medium_task',
        '{"iterations": 5, "description": "Sample medium task"}'::JSONB,
        'immediate',
        60,
        NOW(),
        3,
        NULL,
        'test_medium'
    );
    
    RAISE NOTICE '  ✓ Created 1 medium test task';
    
    -- Create 1 long batch task
    PERFORM enqueue_task(
        v_api_key,
        'test_long_batch_task',
        json_build_object(
            'totalUnits', 20,
            'batchSize', 5,
            'description', 'Sample batch task'
        )::JSONB,
        'immediate',
        70,
        NOW(),
        3,
        NULL,
        'test_long'
    );
    
    RAISE NOTICE '  ✓ Created 1 long batch test task';
END $$;

\echo ''

-- ============================================
-- 6. DISPLAY CREATED TASKS
-- ============================================

\echo '→ Step 6: Summary of created tasks...'
\echo ''

SELECT 
    task_name,
    queue_name,
    priority,
    status,
    'Ready for processing' as note
FROM task_queue
WHERE task_name LIKE 'test_%'
ORDER BY priority DESC, id;

\echo ''

-- ============================================
-- 7. FINAL INSTRUCTIONS
-- ============================================

\echo '================================================'
\echo 'SETUP COMPLETE!'
\echo '================================================'
\echo ''
\echo 'Next steps:'
\echo '1. Copy the API key from Step 3 above'
\echo '2. Set in n8n: export SERVICE_WORKER_API_KEY="sk_..."'
\echo '3. Import improved_service_worker_v2.json to n8n'
\echo '4. Add the test task handlers (see TESTING_TUTORIAL.md Part 3)'
\echo '5. Start the workflow in n8n'
\echo '6. Watch the tasks process!'
\echo ''
\echo 'Monitoring commands:'
\echo '  - Watch tasks: SELECT * FROM task_queue WHERE task_name LIKE '\''test_%'\'';'
\echo '  - Worker stats: SELECT * FROM get_worker_stats('\''test-worker-001'\'');'
\echo '  - Queue stats: SELECT * FROM get_queue_stats_by_queue();'
\echo ''
\echo 'For detailed testing instructions, see TESTING_TUTORIAL.md'
\echo '================================================'

-- ============================================
-- HELPER VIEWS FOR TESTING
-- ============================================

-- Drop existing views if they exist
DROP VIEW IF EXISTS v_test_tasks CASCADE;
DROP VIEW IF EXISTS v_test_worker_status CASCADE;

-- View for easy task monitoring
CREATE VIEW v_test_tasks AS
SELECT 
    id,
    task_uuid,
    task_name,
    queue_name,
    status,
    priority,
    attempts,
    max_attempts,
    CASE 
        WHEN status = 'processing' THEN 
            EXTRACT(EPOCH FROM (NOW() - started_at))::INTEGER || 's running'
        WHEN status = 'completed' THEN
            EXTRACT(EPOCH FROM (completed_at - started_at))::INTEGER || 's total'
        WHEN status = 'pending' THEN
            'Waiting'
        WHEN status = 'scheduled' THEN
            'Scheduled for ' || TO_CHAR(scheduled_at, 'HH24:MI:SS')
        WHEN status = 'retrying' THEN
            'Retry in ' || EXTRACT(EPOCH FROM (scheduled_at - NOW()))::INTEGER || 's'
        ELSE status::TEXT
    END as duration_info,
    worker_id,
    created_at,
    started_at,
    completed_at
FROM task_queue
WHERE task_name LIKE 'test_%'
ORDER BY id DESC;

-- View for worker status
CREATE VIEW v_test_worker_status AS
SELECT 
    w.worker_id,
    w.worker_name,
    w.is_active,
    w.current_load,
    w.max_concurrent_tasks,
    w.subscribed_queues,
    w.tasks_completed,
    w.tasks_failed,
    ROUND(
        CASE 
            WHEN w.tasks_completed + w.tasks_failed > 0 
            THEN w.tasks_completed::NUMERIC / (w.tasks_completed + w.tasks_failed) * 100
            ELSE 0
        END, 2
    ) as success_rate_pct,
    EXTRACT(EPOCH FROM (NOW() - w.last_seen_at))::INTEGER as last_seen_seconds_ago,
    COUNT(t.id) FILTER (WHERE t.status = 'processing') as currently_processing
FROM worker_registry w
LEFT JOIN task_queue t ON t.worker_id = w.worker_id AND t.status = 'processing'
WHERE w.worker_id = 'test-worker-001'
GROUP BY w.worker_id, w.worker_name, w.is_active, w.current_load, 
         w.max_concurrent_tasks, w.subscribed_queues, w.tasks_completed, 
         w.tasks_failed, w.last_seen_at;

\echo ''
\echo 'Helper views created:'
\echo '  - v_test_tasks: Quick view of all test tasks'
\echo '  - v_test_worker_status: Worker health and statistics'
\echo ''
\echo 'Usage:'
\echo '  SELECT * FROM v_test_tasks;'
\echo '  SELECT * FROM v_test_worker_status;'
\echo ''

-- ============================================
-- TESTING HELPER FUNCTIONS
-- ============================================

-- Function to quickly reset test environment
CREATE OR REPLACE FUNCTION reset_test_environment()
RETURNS TEXT AS $$
DECLARE
    v_deleted_tasks INTEGER;
BEGIN
    -- Delete all test tasks
    DELETE FROM task_queue 
    WHERE task_name LIKE 'test_%' OR queue_name LIKE 'test_%';
    
    GET DIAGNOSTICS v_deleted_tasks = ROW_COUNT;
    
    -- Reset worker stats
    UPDATE worker_registry
    SET 
        current_load = 0,
        tasks_completed = 0,
        tasks_failed = 0,
        total_processing_time = '0 seconds'::INTERVAL
    WHERE worker_id = 'test-worker-001';
    
    RETURN '✓ Test environment reset: ' || v_deleted_tasks || ' tasks deleted, worker stats reset';
END;
$$ LANGUAGE plpgsql;

-- Function to create a batch of test tasks
CREATE OR REPLACE FUNCTION create_test_tasks(
    p_short_count INTEGER DEFAULT 3,
    p_medium_count INTEGER DEFAULT 1,
    p_long_count INTEGER DEFAULT 1
)
RETURNS TEXT AS $$
DECLARE
    v_api_key TEXT;
    v_total INTEGER;
BEGIN
    SELECT api_key_hash INTO v_api_key
    FROM worker_api_keys
    WHERE worker_id = 'test-worker-001'
    LIMIT 1;
    
    IF v_api_key IS NULL THEN
        RAISE EXCEPTION 'Test worker not found. Run setup script first.';
    END IF;
    
    -- Create short tasks
    PERFORM enqueue_task(
        v_api_key,
        'test_short_task',
        json_build_object('value', 'auto-' || i)::JSONB,
        'immediate',
        50,
        NOW(),
        3,
        NULL,
        'test_short'
    ) FROM generate_series(1, p_short_count) i;
    
    -- Create medium tasks
    PERFORM enqueue_task(
        v_api_key,
        'test_medium_task',
        json_build_object('iterations', 5)::JSONB,
        'immediate',
        60,
        NOW(),
        3,
        NULL,
        'test_medium'
    ) FROM generate_series(1, p_medium_count) i;
    
    -- Create long tasks
    PERFORM enqueue_task(
        v_api_key,
        'test_long_batch_task',
        json_build_object('totalUnits', 20, 'batchSize', 5)::JSONB,
        'immediate',
        70,
        NOW(),
        3,
        NULL,
        'test_long'
    ) FROM generate_series(1, p_long_count) i;
    
    v_total := p_short_count + p_medium_count + p_long_count;
    
    RETURN '✓ Created ' || v_total || ' test tasks (' || 
           p_short_count || ' short, ' || 
           p_medium_count || ' medium, ' || 
           p_long_count || ' long)';
END;
$$ LANGUAGE plpgsql;

\echo ''
\echo 'Helper functions created:'
\echo '  - reset_test_environment(): Clean up all test data'
\echo '  - create_test_tasks(short, medium, long): Create test tasks quickly'
\echo ''
\echo 'Usage:'
\echo '  SELECT reset_test_environment();'
\echo '  SELECT create_test_tasks(5, 2, 1);'
\echo ''
\echo '================================================'
\echo 'Setup script completed successfully!'
\echo '================================================'