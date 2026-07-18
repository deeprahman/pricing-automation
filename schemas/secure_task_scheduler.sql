-- ============================================
-- SECURE TASK SCHEDULER FOR POSTGRESQL
-- Version: 2.1 (Hybrid Queue System)
-- ============================================

-- Enable necessary extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================
-- 1. ENUMERATIONS
-- ============================================

DROP TYPE IF EXISTS task_status CASCADE;
CREATE TYPE task_status AS ENUM (
    'pending',
    'processing',
    'completed',
    'failed',
    'scheduled',
    'retrying'
);

DROP TYPE IF EXISTS task_type CASCADE;
CREATE TYPE task_type AS ENUM (
    'immediate',
    'delayed',
    'recurring',
    'periodic'
);

DROP TYPE IF EXISTS audit_operation CASCADE;
CREATE TYPE audit_operation AS ENUM (
    'enqueue',
    'dequeue',
    'complete',
    'fail',
    'heartbeat',
    'reset',
    'cleanup',
    'worker_register',
    'worker_heartbeat',
    'worker_meta_patch',
    'task_meta_patch',
    'meta_cleanup',
    'worker_meta_delete',
    'task_meta_delete'
);

-- ============================================
-- 2. SECURITY TABLES
-- ============================================

DROP TABLE IF EXISTS worker_api_keys CASCADE;
CREATE TABLE worker_api_keys (
    id BIGSERIAL PRIMARY KEY,
    worker_id VARCHAR(100) UNIQUE NOT NULL,
    api_key_hash TEXT NOT NULL,
    api_key_prefix VARCHAR(10) NOT NULL,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    last_used_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ,
    permissions JSONB DEFAULT '{"can_dequeue": true, "can_complete": true}'::JSONB
);

DROP TABLE IF EXISTS rate_limits CASCADE;
CREATE TABLE rate_limits (
    id BIGSERIAL PRIMARY KEY,
    identifier VARCHAR(100) NOT NULL,
    operation VARCHAR(50) NOT NULL,
    window_start TIMESTAMPTZ NOT NULL,
    request_count INTEGER DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(identifier, operation, window_start)
);

DROP TABLE IF EXISTS audit_log CASCADE;
CREATE TABLE audit_log (
    id BIGSERIAL PRIMARY KEY,
    operation audit_operation NOT NULL,
    entity_type VARCHAR(50),
    entity_id BIGINT,
    actor_id VARCHAR(100),
    old_values JSONB,
    new_values JSONB,
    ip_address INET,
    user_agent TEXT,
    success BOOLEAN DEFAULT TRUE,
    error_message TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_audit_log_created ON audit_log(created_at DESC);
CREATE INDEX idx_audit_log_actor ON audit_log(actor_id, created_at DESC);
CREATE INDEX idx_audit_log_entity ON audit_log(entity_type, entity_id);

-- ============================================
-- 3. QUEUE REGISTRY TABLE (NEW)
-- ============================================

DROP TABLE IF EXISTS queue_registry CASCADE;
CREATE TABLE queue_registry (
    id BIGSERIAL PRIMARY KEY,
    queue_name VARCHAR(100) UNIQUE NOT NULL,
    description TEXT,
    is_active BOOLEAN DEFAULT TRUE,
    max_priority INTEGER DEFAULT 100,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT valid_queue_name CHECK (queue_name ~ '^[a-z0-9_-]+$')
);

-- Insert default queues
INSERT INTO queue_registry (queue_name, description) VALUES
('default', 'Default shared queue for general tasks'),
('email', 'Email and notification tasks'),
('payment', 'Payment processing tasks'),
('reports', 'Report generation tasks'),
('maintenance', 'System maintenance tasks')
ON CONFLICT (queue_name) DO NOTHING;

-- ============================================
-- 4. MAIN TABLES
-- ============================================

DROP TABLE IF EXISTS task_queue CASCADE;
CREATE TABLE task_queue (
    id BIGSERIAL PRIMARY KEY,
    task_uuid UUID DEFAULT uuid_generate_v4(),
    
    -- Task metadata
    task_name VARCHAR(255) NOT NULL,
    task_type task_type DEFAULT 'immediate',
    queue_name VARCHAR(100) DEFAULT 'default',  -- NEW: Queue assignment
    
    -- Task payload
    task_data JSONB NOT NULL DEFAULT '{}',
    task_metadata JSONB DEFAULT '{}',
    
    -- Scheduling
    status task_status DEFAULT 'pending',
    priority INTEGER DEFAULT 0,
    scheduled_at TIMESTAMPTZ DEFAULT NOW(),
    
    -- Worker assignment
    worker_id VARCHAR(100),
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    
    -- Retry mechanism
    attempts INTEGER DEFAULT 0,
    max_attempts INTEGER DEFAULT 3,
    last_error TEXT,
    error_count INTEGER DEFAULT 0,
    
    -- Lease management
    lease_expires_at TIMESTAMPTZ,
    last_heartbeat_at TIMESTAMPTZ,
    
    -- Recurring tasks
    recurrence_pattern VARCHAR(100),
    recurrence_time TIME,
    recurrence_timezone TEXT,
    next_run_at TIMESTAMPTZ,
    
    -- Audit trail
    created_by VARCHAR(100),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    -- Constraints
    CONSTRAINT valid_priority CHECK (priority >= 0 AND priority <= 100),
    CONSTRAINT valid_attempts CHECK (attempts >= 0 AND max_attempts > 0 AND max_attempts <= 10),
    CONSTRAINT valid_scheduling CHECK (
        scheduled_at IS NULL OR 
        scheduled_at <= NOW() + INTERVAL '1 year'
    ),
    CONSTRAINT valid_task_name_length CHECK (length(task_name) <= 255),
    CONSTRAINT valid_recurrence_pattern CHECK (
        recurrence_pattern IS NULL OR
        recurrence_pattern IN ('hourly', 'daily', 'weekly', 'monthly')
    ),
    CONSTRAINT valid_recurrence_schedule_pair CHECK (
        (recurrence_time IS NULL AND recurrence_timezone IS NULL)
        OR
        (recurrence_time IS NOT NULL AND recurrence_timezone IS NOT NULL)
    ),
    CONSTRAINT valid_recurrence_timezone_not_blank CHECK (
        recurrence_timezone IS NULL OR length(trim(recurrence_timezone)) > 0
    ),
    CONSTRAINT valid_recurrence_time_pattern CHECK (
        recurrence_time IS NULL OR recurrence_pattern IN ('daily', 'weekly', 'monthly')
    ),
    -- NEW: Foreign key to queue registry
    CONSTRAINT fk_queue_name FOREIGN KEY (queue_name) 
        REFERENCES queue_registry(queue_name) ON UPDATE CASCADE
);

DROP TABLE IF EXISTS worker_registry CASCADE;
CREATE TABLE worker_registry (
    id BIGSERIAL PRIMARY KEY,
    worker_id VARCHAR(100) UNIQUE NOT NULL,
    worker_name VARCHAR(255),
    worker_type VARCHAR(50),
    
    -- NEW: Queue subscriptions
    subscribed_queues JSONB DEFAULT '["default"]'::JSONB,
    
    -- Capacity and load
    max_concurrent_tasks INTEGER DEFAULT 5,
    current_load INTEGER DEFAULT 0,
    
    -- Resource constraints
    cpu_weight FLOAT DEFAULT 1.0,
    memory_weight FLOAT DEFAULT 1.0,
    specializations JSONB DEFAULT '[]',
    
    -- Health tracking
    last_seen_at TIMESTAMPTZ DEFAULT NOW(),
    is_active BOOLEAN DEFAULT TRUE,
    
    -- Heartbeat tracking
    heartbeat_interval INTERVAL DEFAULT '30 seconds',
    expected_next_heartbeat TIMESTAMPTZ,
    
    -- Statistics
    tasks_completed BIGINT DEFAULT 0,
    tasks_failed BIGINT DEFAULT 0,
    total_processing_time INTERVAL DEFAULT '0 seconds',
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    CONSTRAINT valid_max_tasks CHECK (max_concurrent_tasks > 0 AND max_concurrent_tasks <= 50),
    CONSTRAINT valid_current_load CHECK (current_load >= 0)
);

DROP TABLE IF EXISTS scheduler_config CASCADE;
CREATE TABLE scheduler_config (
    config_key VARCHAR(100) PRIMARY KEY,
    config_value TEXT NOT NULL,
    config_type VARCHAR(50),
    description TEXT,
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    updated_by VARCHAR(100),
    CONSTRAINT valid_config_key CHECK (config_key ~ '^[a-z_]+$')
);

-- ============================================
-- 5. PERFORMANCE INDEXES
-- ============================================

CREATE INDEX idx_task_queue_status_scheduled 
ON task_queue(status, scheduled_at) 
WHERE status IN ('pending', 'scheduled');

-- NEW: Index on queue_name for filtering
CREATE INDEX idx_task_queue_queue_name 
ON task_queue(queue_name, status, priority DESC, scheduled_at ASC)
WHERE status IN ('pending', 'retrying');

CREATE INDEX idx_task_queue_priority 
ON task_queue(priority DESC, scheduled_at ASC) 
WHERE status = 'pending';

CREATE INDEX idx_task_queue_worker_lease 
ON task_queue(worker_id, lease_expires_at) 
WHERE status = 'processing';

CREATE INDEX idx_task_queue_retry 
ON task_queue(status, next_run_at) 
WHERE status = 'retrying';

CREATE INDEX idx_task_queue_parent_task_uuid_text
ON task_queue ((task_data #>> '{meta,parent_task_uuid}'));

CREATE INDEX idx_worker_registry_active 
ON worker_registry(last_seen_at) 
WHERE is_active = TRUE;

CREATE INDEX idx_rate_limits_lookup 
ON rate_limits(identifier, operation, window_start);

-- ============================================
-- 6. SECURITY HELPER FUNCTIONS
-- ============================================

CREATE OR REPLACE FUNCTION validate_worker_auth(
    p_api_key TEXT
) RETURNS VARCHAR AS $$
DECLARE
    v_worker_id VARCHAR;
    v_key_hash TEXT;
BEGIN
    v_key_hash := encode(digest(p_api_key, 'sha256'), 'hex');
    
    SELECT worker_id INTO v_worker_id
    FROM worker_api_keys
    WHERE api_key_hash = v_key_hash
    AND is_active = TRUE
    AND (expires_at IS NULL OR expires_at > NOW());
    
    IF v_worker_id IS NULL THEN
        RAISE EXCEPTION 'Authentication failed: Invalid or expired API key';
    END IF;
    
    UPDATE worker_api_keys 
    SET last_used_at = NOW()
    WHERE worker_id = v_worker_id;
    
    RETURN v_worker_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION check_rate_limit(
    p_identifier VARCHAR,
    p_operation VARCHAR,
    p_max_requests INTEGER DEFAULT 100,
    p_window_minutes INTEGER DEFAULT 60
) RETURNS BOOLEAN AS $$
DECLARE
    v_window_start TIMESTAMPTZ;
    v_current_count INTEGER;
BEGIN
    v_window_start := DATE_TRUNC('minute', NOW() - (NOW()::TIME)::INTERVAL);
    
    INSERT INTO rate_limits (identifier, operation, window_start, request_count)
    VALUES (p_identifier, p_operation, v_window_start, 1)
    ON CONFLICT (identifier, operation, window_start)
    DO UPDATE SET 
        request_count = rate_limits.request_count + 1,
        created_at = NOW()
    RETURNING request_count INTO v_current_count;
    
    IF v_current_count > p_max_requests THEN
        RAISE EXCEPTION 'Rate limit exceeded: % requests per % minutes', 
            p_max_requests, p_window_minutes;
    END IF;
    
    DELETE FROM rate_limits 
    WHERE window_start < NOW() - (p_window_minutes || ' minutes')::INTERVAL;
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION validate_task_data_size(
    p_task_data JSONB,
    p_max_size_kb INTEGER DEFAULT 100
) RETURNS BOOLEAN AS $$
DECLARE
    v_size_bytes INTEGER;
BEGIN
    v_size_bytes := octet_length(p_task_data::TEXT);
    
    IF v_size_bytes > (p_max_size_kb * 1024) THEN
        RAISE EXCEPTION 'Task data exceeds maximum size of % KB (current: % KB)', 
            p_max_size_kb, 
            ROUND(v_size_bytes / 1024.0);
    END IF;
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION log_audit(
    p_operation audit_operation,
    p_entity_type VARCHAR,
    p_entity_id BIGINT,
    p_actor_id VARCHAR,
    p_old_values JSONB DEFAULT NULL,
    p_new_values JSONB DEFAULT NULL,
    p_success BOOLEAN DEFAULT TRUE,
    p_error_message TEXT DEFAULT NULL
) RETURNS VOID AS $$
BEGIN
    INSERT INTO audit_log (
        operation,
        entity_type,
        entity_id,
        actor_id,
        old_values,
        new_values,
        success,
        error_message
    ) VALUES (
        p_operation,
        p_entity_type,
        p_entity_id,
        p_actor_id,
        p_old_values,
        p_new_values,
        p_success,
        p_error_message
    );
END;
$$ LANGUAGE plpgsql;

DROP FUNCTION IF EXISTS calculate_next_run(VARCHAR, TIMESTAMPTZ);
DROP FUNCTION IF EXISTS calculate_next_run(VARCHAR, TIMESTAMPTZ, TIME, TEXT);
CREATE OR REPLACE FUNCTION calculate_next_run(
    p_pattern VARCHAR,
    p_base_time TIMESTAMPTZ DEFAULT NOW(),
    p_recurrence_time TIME DEFAULT NULL,
    p_recurrence_timezone TEXT DEFAULT NULL
) RETURNS TIMESTAMPTZ AS $$
DECLARE
    v_next_run TIMESTAMPTZ;
    v_local_base TIMESTAMP;
    v_local_candidate TIMESTAMP;
BEGIN
    IF (p_recurrence_time IS NULL) <> (p_recurrence_timezone IS NULL) THEN
        RAISE EXCEPTION 'recurrence_time and recurrence_timezone must both be provided or both be null';
    END IF;

    IF p_recurrence_timezone IS NOT NULL THEN
        IF length(trim(p_recurrence_timezone)) = 0 THEN
            RAISE EXCEPTION 'recurrence_timezone cannot be empty';
        END IF;

        BEGIN
            v_local_base := p_base_time AT TIME ZONE p_recurrence_timezone;
        EXCEPTION
            WHEN invalid_parameter_value THEN
                RAISE EXCEPTION 'Invalid recurrence timezone: %', p_recurrence_timezone;
        END;

        IF p_pattern = 'hourly' THEN
            RAISE EXCEPTION 'recurrence_time/timezone is not supported for hourly recurrence';
        END IF;

        CASE p_pattern
            WHEN 'daily' THEN
                v_local_candidate := DATE_TRUNC('day', v_local_base) + p_recurrence_time;
                IF v_local_candidate <= v_local_base THEN
                    v_local_candidate := v_local_candidate + INTERVAL '1 day';
                END IF;
            WHEN 'weekly' THEN
                v_local_candidate := DATE_TRUNC('week', v_local_base) + p_recurrence_time;
                IF v_local_candidate <= v_local_base THEN
                    v_local_candidate := v_local_candidate + INTERVAL '1 week';
                END IF;
            WHEN 'monthly' THEN
                v_local_candidate := DATE_TRUNC('month', v_local_base) + p_recurrence_time;
                IF v_local_candidate <= v_local_base THEN
                    v_local_candidate := v_local_candidate + INTERVAL '1 month';
                END IF;
            ELSE
                RAISE EXCEPTION 'Invalid recurrence pattern: %. Allowed: hourly, daily, weekly, monthly', p_pattern;
        END CASE;

        RETURN v_local_candidate AT TIME ZONE p_recurrence_timezone;
    END IF;

    CASE p_pattern
        WHEN 'hourly' THEN
            v_next_run := DATE_TRUNC('hour', p_base_time) + INTERVAL '1 hour';
        WHEN 'daily' THEN
            v_next_run := DATE_TRUNC('day', p_base_time) + INTERVAL '1 day';
        WHEN 'weekly' THEN
            v_next_run := DATE_TRUNC('week', p_base_time) + INTERVAL '1 week';
        WHEN 'monthly' THEN
            v_next_run := DATE_TRUNC('month', p_base_time) + INTERVAL '1 month';
        ELSE
            RAISE EXCEPTION 'Invalid recurrence pattern: %. Allowed: hourly, daily, weekly, monthly', p_pattern;
    END CASE;
    
    RETURN v_next_run;
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================
-- 7. QUEUE MANAGEMENT FUNCTIONS (NEW)
-- ============================================

-- Create a new queue
CREATE OR REPLACE FUNCTION create_queue(
    p_queue_name VARCHAR,
    p_description TEXT DEFAULT NULL
) RETURNS BOOLEAN AS $$
BEGIN
    -- Validate queue name format
    IF p_queue_name !~ '^[a-z0-9_-]+$' THEN
        RAISE EXCEPTION 'Invalid queue name. Use only lowercase letters, numbers, underscore, and hyphen';
    END IF;
    
    INSERT INTO queue_registry (queue_name, description)
    VALUES (p_queue_name, p_description)
    ON CONFLICT (queue_name) DO NOTHING;
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

-- Get queue statistics
CREATE OR REPLACE FUNCTION get_queue_stats_by_queue()
RETURNS TABLE (
    queue_name VARCHAR,
    total_tasks BIGINT,
    pending_tasks BIGINT,
    processing_tasks BIGINT,
    completed_tasks_24h BIGINT,
    failed_tasks_24h BIGINT,
    avg_completion_time INTERVAL
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        tq.queue_name,
        COUNT(*) as total_tasks,
        COUNT(*) FILTER (WHERE tq.status = 'pending') as pending_tasks,
        COUNT(*) FILTER (WHERE tq.status = 'processing') as processing_tasks,
        COUNT(*) FILTER (WHERE tq.status = 'completed' 
                         AND tq.completed_at > NOW() - INTERVAL '24 hours') as completed_tasks_24h,
        COUNT(*) FILTER (WHERE tq.status = 'failed' 
                         AND tq.updated_at > NOW() - INTERVAL '24 hours') as failed_tasks_24h,
        AVG(tq.completed_at - tq.started_at) FILTER (WHERE tq.status = 'completed') as avg_completion_time
    FROM task_queue tq
    GROUP BY tq.queue_name
    ORDER BY tq.queue_name;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- 8. CORE TASK MANAGEMENT FUNCTIONS (UPDATED)
-- ============================================

-- Enqueue a new task (WITH QUEUE SUPPORT)
CREATE OR REPLACE FUNCTION enqueue_task(
    p_api_key TEXT,
    p_task_name VARCHAR,
    p_task_data JSONB,
    p_task_type task_type DEFAULT 'immediate',
    p_priority INTEGER DEFAULT 0,
    p_scheduled_at TIMESTAMPTZ DEFAULT NULL,
    p_max_attempts INTEGER DEFAULT 3,
    p_recurrence_pattern VARCHAR DEFAULT NULL,
    p_queue_name VARCHAR DEFAULT 'default',  -- NEW: Queue parameter
    p_recurrence_time TIME DEFAULT NULL,
    p_recurrence_timezone TEXT DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    v_task_uuid UUID;
    v_next_run TIMESTAMPTZ;
    v_worker_id VARCHAR;
    v_queue_exists BOOLEAN;
BEGIN
    -- Authenticate worker
    v_worker_id := validate_worker_auth(p_api_key);
    
    -- Rate limiting
    PERFORM check_rate_limit(v_worker_id, 'enqueue', 1000, 60);
    
    -- Validate queue exists
    SELECT EXISTS(SELECT 1 FROM queue_registry WHERE queue_name = p_queue_name AND is_active = TRUE)
    INTO v_queue_exists;
    
    IF NOT v_queue_exists THEN
        RAISE EXCEPTION 'Queue "%" does not exist or is inactive', p_queue_name;
    END IF;
    
    -- Validate input
    IF p_task_name IS NULL OR length(trim(p_task_name)) = 0 THEN
        RAISE EXCEPTION 'Task name cannot be empty';
    END IF;
    
    IF length(p_task_name) > 255 THEN
        RAISE EXCEPTION 'Task name too long (max 255 characters)';
    END IF;
    
    PERFORM validate_task_data_size(p_task_data, 100);
    
    IF p_priority < 0 OR p_priority > 100 THEN
        RAISE EXCEPTION 'Priority must be between 0 and 100';
    END IF;
    
    IF p_max_attempts < 1 OR p_max_attempts > 10 THEN
        RAISE EXCEPTION 'Max attempts must be between 1 and 10';
    END IF;
    
    IF p_scheduled_at IS NOT NULL AND p_scheduled_at > NOW() + INTERVAL '1 year' THEN
        RAISE EXCEPTION 'Cannot schedule tasks more than 1 year in advance';
    END IF;

    IF (p_recurrence_time IS NULL) <> (p_recurrence_timezone IS NULL) THEN
        RAISE EXCEPTION 'recurrence_time and recurrence_timezone must both be provided or both be null';
    END IF;

    IF p_recurrence_timezone IS NOT NULL THEN
        IF length(trim(p_recurrence_timezone)) = 0 THEN
            RAISE EXCEPTION 'recurrence_timezone cannot be empty';
        END IF;
        BEGIN
            PERFORM NOW() AT TIME ZONE p_recurrence_timezone;
        EXCEPTION
            WHEN invalid_parameter_value THEN
                RAISE EXCEPTION 'Invalid recurrence timezone: %', p_recurrence_timezone;
        END;
    END IF;
    
    IF p_recurrence_pattern IS NOT NULL THEN
        IF p_recurrence_pattern NOT IN ('hourly', 'daily', 'weekly', 'monthly') THEN
            RAISE EXCEPTION 'Invalid recurrence pattern. Allowed: hourly, daily, weekly, monthly';
        END IF;
        IF p_recurrence_time IS NOT NULL AND p_recurrence_pattern = 'hourly' THEN
            RAISE EXCEPTION 'recurrence_time/timezone is not supported for hourly recurrence';
        END IF;
        v_next_run := calculate_next_run(
            p_recurrence_pattern,
            COALESCE(p_scheduled_at, NOW()),
            p_recurrence_time,
            p_recurrence_timezone
        );
    ELSE
        IF p_recurrence_time IS NOT NULL OR p_recurrence_timezone IS NOT NULL THEN
            RAISE EXCEPTION 'recurrence_time/timezone requires recurrence_pattern';
        END IF;
        v_next_run := COALESCE(p_scheduled_at, NOW());
    END IF;
    
    v_task_uuid := uuid_generate_v4();
    
    -- Insert task
    INSERT INTO task_queue (
        task_uuid,
        task_name,
        task_type,
        task_data,
        priority,
        scheduled_at,
        max_attempts,
        recurrence_pattern,
        recurrence_time,
        recurrence_timezone,
        next_run_at,
        status,
        created_by,
        queue_name  -- NEW: Set queue
    ) VALUES (
        v_task_uuid,
        p_task_name,
        p_task_type,
        p_task_data,
        p_priority,
        v_next_run,
        p_max_attempts,
        p_recurrence_pattern,
        p_recurrence_time,
        p_recurrence_timezone,
        v_next_run,
        CASE 
            WHEN v_next_run > NOW() THEN 'scheduled'::task_status
            ELSE 'pending'::task_status
        END,
        v_worker_id,
        p_queue_name  -- NEW: Set queue
    );
    
    -- Audit log
    PERFORM log_audit(
        'enqueue',
        'task',
        (SELECT id FROM task_queue WHERE task_uuid = v_task_uuid),
        v_worker_id,
        NULL,
        jsonb_build_object('task_uuid', v_task_uuid, 'task_name', p_task_name, 'queue_name', p_queue_name)
    );
    
    RETURN v_task_uuid;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Dequeue next available task (WITH QUEUE FILTERING)
CREATE OR REPLACE FUNCTION dequeue_task(
    p_api_key TEXT,
    p_lease_duration INTERVAL DEFAULT '5 minutes',
    p_queue_names VARCHAR[] DEFAULT ARRAY['default']  -- NEW: Queue filter
) RETURNS TABLE (
    task_id BIGINT,
    task_uuid UUID,
    task_name VARCHAR,
    task_data JSONB,
    attempts INTEGER,
    max_attempts INTEGER,
    queue_name VARCHAR  -- NEW: Return queue name
) AS $$
DECLARE
    v_task_id BIGINT;
    v_worker_capacity INTEGER;
    v_worker_id VARCHAR;
    v_worker_queues JSONB;
    v_allowed_queues VARCHAR[];
BEGIN
    -- Authenticate worker
    v_worker_id := validate_worker_auth(p_api_key);
    
    -- Rate limiting
    PERFORM check_rate_limit(v_worker_id, 'dequeue', 1000, 60);
    
    -- Validate lease duration
    IF p_lease_duration > INTERVAL '1 hour' THEN
        RAISE EXCEPTION 'Lease duration cannot exceed 1 hour';
    END IF;
    
    -- Get worker's subscribed queues
    SELECT subscribed_queues INTO v_worker_queues
    FROM worker_registry
    WHERE worker_id = v_worker_id;
    
    -- Determine allowed queues (intersection of worker subscriptions and requested queues)
    SELECT ARRAY(
        SELECT jsonb_array_elements_text(v_worker_queues)
        INTERSECT
        SELECT unnest(p_queue_names)
    ) INTO v_allowed_queues;
    
    IF array_length(v_allowed_queues, 1) IS NULL THEN
        RAISE EXCEPTION 'Worker is not subscribed to any of the requested queues';
    END IF;
    
    -- Check worker capacity
    SELECT max_concurrent_tasks - current_load 
    INTO v_worker_capacity
    FROM worker_registry
    WHERE worker_id = v_worker_id
    AND is_active = TRUE;
    
    IF v_worker_capacity IS NULL THEN
        RAISE EXCEPTION 'Worker not registered or inactive';
    END IF;
    
    IF v_worker_capacity > 0 THEN
        -- Find and lock next available task from allowed queues
        SELECT id INTO v_task_id
        FROM task_queue t
        WHERE t.status IN ('pending', 'retrying')
        AND t.scheduled_at <= NOW()
        AND t.queue_name = ANY(v_allowed_queues)  -- NEW: Queue filtering
        AND (t.worker_id IS NULL OR t.lease_expires_at < NOW())
        ORDER BY 
            t.priority DESC,
            t.scheduled_at ASC,
            t.attempts ASC
        LIMIT 1
        FOR UPDATE SKIP LOCKED;
        
        IF v_task_id IS NOT NULL THEN
            -- Update task
            UPDATE task_queue
            SET 
                status = 'processing',
                worker_id = v_worker_id,
                started_at = NOW(),
                lease_expires_at = NOW() + p_lease_duration,
                attempts = task_queue.attempts + 1,
                updated_at = NOW()
            WHERE id = v_task_id;
            
            -- Update worker load
            UPDATE worker_registry
            SET 
                current_load = current_load + 1,
                updated_at = NOW()
            WHERE worker_id = v_worker_id;
            
            -- Audit log
            PERFORM log_audit(
                'dequeue',
                'task',
                v_task_id,
                v_worker_id,
                NULL,
                jsonb_build_object('worker_id', v_worker_id)
            );
            
            -- Return task details
            RETURN QUERY
            SELECT 
                t.id,
                t.task_uuid,
                t.task_name,
                t.task_data,
                t.attempts,
                t.max_attempts,
                t.queue_name  -- NEW: Return queue name
            FROM task_queue t
            WHERE t.id = v_task_id;
        END IF;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Heartbeat (unchanged but included for completeness)
CREATE OR REPLACE FUNCTION heartbeat_task(
    p_api_key TEXT,
    p_task_id BIGINT,
    p_extend_by INTERVAL DEFAULT '5 minutes'
) RETURNS BOOLEAN AS $$
DECLARE
    v_worker_id VARCHAR;
    v_task_worker_id VARCHAR;
BEGIN
    v_worker_id := validate_worker_auth(p_api_key);
    PERFORM check_rate_limit(v_worker_id, 'heartbeat', 10000, 60);
    
    IF p_extend_by > INTERVAL '1 hour' THEN
        RAISE EXCEPTION 'Cannot extend lease by more than 1 hour';
    END IF;
    
    SELECT worker_id INTO v_task_worker_id
    FROM task_queue
    WHERE id = p_task_id
    AND status = 'processing';
    
    IF v_task_worker_id IS NULL THEN
        RAISE EXCEPTION 'Task not found or not in processing state';
    END IF;
    
    IF v_task_worker_id != v_worker_id THEN
        PERFORM log_audit('heartbeat', 'task', p_task_id, v_worker_id, NULL, NULL, FALSE, 'Worker does not own this task');
        RAISE EXCEPTION 'Unauthorized: Worker does not own this task';
    END IF;
    
    UPDATE task_queue
    SET 
        last_heartbeat_at = NOW(),
        lease_expires_at = NOW() + p_extend_by,
        updated_at = NOW()
    WHERE id = p_task_id
    AND status = 'processing'
    AND worker_id = v_worker_id
    AND lease_expires_at > NOW();
    
    RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Complete task (FIXED - with queue support)
CREATE OR REPLACE FUNCTION complete_task(
    p_api_key TEXT,
    p_task_id BIGINT,
    p_result_data JSONB DEFAULT NULL
) RETURNS BOOLEAN AS $$
DECLARE
    v_recurrence_pattern VARCHAR;
    v_recurrence_time TIME;
    v_recurrence_timezone TEXT;
    v_next_run TIMESTAMPTZ;
    v_worker_id VARCHAR;
    v_task_worker_id VARCHAR;
    v_started_at TIMESTAMPTZ;
    v_task_name VARCHAR;
    v_task_type task_type;
    v_task_data JSONB;
    v_priority INTEGER;
    v_max_attempts INTEGER;
    v_queue_name VARCHAR;  -- NEW: Queue name
BEGIN
    v_worker_id := validate_worker_auth(p_api_key);
    PERFORM check_rate_limit(v_worker_id, 'complete', 10000, 60);
    
    IF p_result_data IS NOT NULL THEN
        PERFORM validate_task_data_size(p_result_data, 100);
    END IF;
    
    SELECT 
        worker_id,
        recurrence_pattern,
        recurrence_time,
        recurrence_timezone,
        started_at,
        task_name,
        task_type,
        task_data,
        priority,
        max_attempts,
        queue_name  -- NEW: Get queue name
    INTO 
        v_task_worker_id,
        v_recurrence_pattern,
        v_recurrence_time,
        v_recurrence_timezone,
        v_started_at,
        v_task_name,
        v_task_type,
        v_task_data,
        v_priority,
        v_max_attempts,
        v_queue_name
    FROM task_queue
    WHERE id = p_task_id
    AND status = 'processing';
    
    IF v_task_worker_id IS NULL THEN
        RAISE EXCEPTION 'Task not found or not in processing state';
    END IF;
    
    IF v_task_worker_id != v_worker_id THEN
        PERFORM log_audit('complete', 'task', p_task_id, v_worker_id, NULL, NULL, FALSE, 'Worker does not own this task');
        RAISE EXCEPTION 'Unauthorized: Worker does not own this task';
    END IF;
    
    -- Handle recurring tasks
    IF v_recurrence_pattern IS NOT NULL THEN
        v_next_run := calculate_next_run(
            v_recurrence_pattern,
            NOW(),
            v_recurrence_time,
            v_recurrence_timezone
        );
        
        INSERT INTO task_queue (
            task_uuid,
            task_name,
            task_type,
            task_data,
            priority,
            scheduled_at,
            max_attempts,
            recurrence_pattern,
            recurrence_time,
            recurrence_timezone,
            next_run_at,
            status,
            created_by,
            queue_name  -- NEW: Preserve queue for recurring task
        ) VALUES (
            uuid_generate_v4(),
            v_task_name,
            v_task_type,
            v_task_data,
            v_priority,
            v_next_run,
            v_max_attempts,
            v_recurrence_pattern,
            v_recurrence_time,
            v_recurrence_timezone,
            v_next_run,
            'scheduled',
            v_worker_id,
            v_queue_name  -- NEW: Same queue
        );
    END IF;
    
    UPDATE task_queue
    SET 
        status = 'completed',
        completed_at = NOW(),
        lease_expires_at = NULL,
        task_metadata = COALESCE(p_result_data, '{}'::JSONB),
        updated_at = NOW()
    WHERE id = p_task_id;
    
    UPDATE worker_registry
    SET 
        current_load = GREATEST(0, current_load - 1),
        tasks_completed = tasks_completed + 1,
        total_processing_time = total_processing_time + 
            COALESCE(NOW() - v_started_at, INTERVAL '0'),
        updated_at = NOW()
    WHERE worker_id = v_worker_id;
    
    PERFORM log_audit(
        'complete',
        'task',
        p_task_id,
        v_worker_id,
        jsonb_build_object('status', 'processing'),
        jsonb_build_object('status', 'completed')
    );
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fail task (supports interval delay and boolean retry flag)
CREATE OR REPLACE FUNCTION fail_task_core(
    p_api_key TEXT,
    p_task_id BIGINT,
    p_error_message TEXT,
    p_retry_delay INTERVAL,
    p_force_fail BOOLEAN DEFAULT FALSE
) RETURNS BOOLEAN AS $$
DECLARE
    v_attempts INTEGER;
    v_max_attempts INTEGER;
    v_worker_id VARCHAR;
    v_task_worker_id VARCHAR;
BEGIN
    v_worker_id := validate_worker_auth(p_api_key);
    PERFORM check_rate_limit(v_worker_id, 'fail', 10000, 60);
    
    IF length(p_error_message) > 10000 THEN
        p_error_message := substring(p_error_message, 1, 10000) || '... (truncated)';
    END IF;
    
    SELECT worker_id, attempts, max_attempts 
    INTO v_task_worker_id, v_attempts, v_max_attempts
    FROM task_queue
    WHERE id = p_task_id
    AND status = 'processing';
    
    IF v_task_worker_id IS NULL THEN
        RAISE EXCEPTION 'Task not found or not in processing state';
    END IF;
    
    IF v_task_worker_id != v_worker_id THEN
        PERFORM log_audit('fail', 'task', p_task_id, v_worker_id, NULL, NULL, FALSE, 'Worker does not own this task');
        RAISE EXCEPTION 'Unauthorized: Worker does not own this task';
    END IF;

    -- When retry is explicitly disabled, force the failure path.
    IF p_force_fail THEN
        v_attempts := v_max_attempts;
    END IF;
    
    IF v_attempts >= v_max_attempts THEN
        UPDATE task_queue
        SET 
            status = 'failed',
            attempts = GREATEST(attempts, v_attempts),
            last_error = p_error_message,
            error_count = error_count + 1,
            lease_expires_at = NULL,
            updated_at = NOW()
        WHERE id = p_task_id;
        
        UPDATE worker_registry
        SET 
            current_load = GREATEST(0, current_load - 1),
            tasks_failed = tasks_failed + 1,
            updated_at = NOW()
        WHERE worker_id = v_worker_id;
    ELSE
        UPDATE task_queue
        SET 
            status = 'retrying',
            last_error = p_error_message,
            error_count = error_count + 1,
            scheduled_at = NOW() + p_retry_delay,
            worker_id = NULL,
            lease_expires_at = NULL,
            updated_at = NOW()
        WHERE id = p_task_id;
        
        UPDATE worker_registry
        SET 
            current_load = GREATEST(0, current_load - 1),
            updated_at = NOW()
        WHERE worker_id = v_worker_id;
    END IF;
    
    PERFORM log_audit(
        'fail',
        'task',
        p_task_id,
        v_worker_id,
        NULL,
        jsonb_build_object('error', p_error_message, 'attempts', v_attempts)
    );
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Original interval-based signature (backward compatible)
CREATE OR REPLACE FUNCTION fail_task(
    p_api_key TEXT,
    p_task_id BIGINT,
    p_error_message TEXT,
    p_retry_delay INTERVAL DEFAULT '5 minutes'
) RETURNS BOOLEAN AS $$
BEGIN
    RETURN fail_task_core(p_api_key, p_task_id, p_error_message, p_retry_delay, FALSE);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Overload to support boolean retry flag used by n8n interface
CREATE OR REPLACE FUNCTION fail_task(
    p_api_key TEXT,
    p_task_id BIGINT,
    p_error_message TEXT,
    p_retry BOOLEAN,
    p_retry_delay INTERVAL DEFAULT '5 minutes'
) RETURNS BOOLEAN AS $$
BEGIN
    RETURN fail_task_core(p_api_key, p_task_id, p_error_message, p_retry_delay, NOT p_retry);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- 9. MAINTENANCE FUNCTIONS
-- ============================================

CREATE OR REPLACE FUNCTION promote_scheduled_tasks()
RETURNS INTEGER AS $$
DECLARE
    v_promoted_count INTEGER;
BEGIN
    WITH promoted_tasks AS (
        UPDATE task_queue
        SET
            status = 'pending',
            worker_id = NULL,
            lease_expires_at = NULL,
            updated_at = NOW()
        WHERE status = 'scheduled'
        AND scheduled_at <= NOW()
        RETURNING id
    )
    SELECT COUNT(*) INTO v_promoted_count FROM promoted_tasks;

    IF v_promoted_count > 0 THEN
        PERFORM log_audit(
            'reset',
            'task',
            NULL,
            'system',
            NULL,
            jsonb_build_object('promoted_count', v_promoted_count)
        );
    END IF;

    RETURN v_promoted_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION reset_stuck_tasks() 
RETURNS INTEGER AS $$
DECLARE
    v_reset_count INTEGER;
    v_inactive_worker_count INTEGER;
BEGIN
    WITH stuck_tasks AS (
        UPDATE task_queue
        SET 
            status = 'pending',
            worker_id = NULL,
            lease_expires_at = NULL,
            last_error = COALESCE(last_error, '') || '; Task reset due to lease expiration at ' || NOW()::TEXT,
            updated_at = NOW()
        WHERE status = 'processing'
        AND lease_expires_at < NOW()
        RETURNING id, worker_id
    )
    SELECT COUNT(*) INTO v_reset_count FROM stuck_tasks;
    
    UPDATE worker_registry
    SET 
        is_active = FALSE,
        current_load = 0,
        updated_at = NOW()
    WHERE is_active = TRUE
    AND expected_next_heartbeat < NOW();
    GET DIAGNOSTICS v_inactive_worker_count = ROW_COUNT;

    IF v_reset_count > 0 OR v_inactive_worker_count > 0 THEN
        PERFORM log_audit(
            'reset',
            'task',
            NULL,
            'system',
            NULL,
            jsonb_build_object(
                'reset_count', v_reset_count,
                'inactive_worker_count', v_inactive_worker_count
            )
        );
    END IF;
    
    RETURN v_reset_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION cleanup_old_tasks(
    p_older_than INTERVAL DEFAULT '30 days',
    p_batch_size INTEGER DEFAULT 1000
) RETURNS INTEGER AS $$
DECLARE
    v_deleted_count INTEGER DEFAULT 0;
    v_batch_deleted INTEGER;
BEGIN
    IF p_older_than < INTERVAL '7 days' THEN
        RAISE EXCEPTION 'Cannot cleanup tasks newer than 7 days';
    END IF;
    
    IF p_batch_size > 10000 THEN
        RAISE EXCEPTION 'Batch size cannot exceed 10000';
    END IF;
    
    LOOP
        WITH deleted AS (
            DELETE FROM task_queue
            WHERE status IN ('completed', 'failed')
            AND updated_at < NOW() - p_older_than
            AND id IN (
                SELECT id 
                FROM task_queue 
                WHERE status IN ('completed', 'failed')
                AND updated_at < NOW() - p_older_than
                ORDER BY updated_at ASC
                LIMIT p_batch_size
            )
            RETURNING 1
        )
        SELECT COUNT(*) INTO v_batch_deleted FROM deleted;
        
        v_deleted_count := v_deleted_count + v_batch_deleted;
        
        EXIT WHEN v_batch_deleted < p_batch_size;
        
        PERFORM pg_sleep(0.1);
    END LOOP;
    
    IF v_deleted_count > 0 THEN
        PERFORM log_audit('cleanup', 'task', NULL, 'system', NULL, jsonb_build_object('deleted_count', v_deleted_count));
    END IF;
    
    RETURN v_deleted_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- 10. WORKER MANAGEMENT (WITH QUEUE SUBSCRIPTIONS)
-- ============================================

-- Register worker with queue subscriptions
CREATE OR REPLACE FUNCTION register_worker(
    p_worker_id VARCHAR,
    p_worker_name VARCHAR DEFAULT NULL,
    p_max_concurrent_tasks INTEGER DEFAULT 5,
    p_heartbeat_interval INTERVAL DEFAULT '30 seconds',
    p_subscribed_queues JSONB DEFAULT '["default"]'::JSONB  -- NEW: Queue subscriptions
) RETURNS TABLE (
    worker_id VARCHAR,
    api_key TEXT,
    success BOOLEAN
) AS $$
DECLARE
    v_api_key TEXT;
    v_api_key_hash TEXT;
    v_api_key_prefix VARCHAR;
    v_queue_name TEXT;
    v_existing_worker_name VARCHAR;
    v_existing_max_concurrent_tasks INTEGER;
    v_existing_heartbeat_interval INTERVAL;
    v_existing_subscribed_queues JSONB;
    v_existing_is_active BOOLEAN;
    v_audit_reason TEXT;
BEGIN
    IF p_worker_id IS NULL OR length(trim(p_worker_id)) = 0 THEN
        RAISE EXCEPTION 'Worker ID cannot be empty';
    END IF;
    
    IF p_max_concurrent_tasks < 1 OR p_max_concurrent_tasks > 50 THEN
        RAISE EXCEPTION 'Max concurrent tasks must be between 1 and 50';
    END IF;
    
    -- Validate all queues exist
    FOR v_queue_name IN SELECT jsonb_array_elements_text(p_subscribed_queues)
    LOOP
        IF NOT EXISTS(SELECT 1 FROM queue_registry WHERE queue_name = v_queue_name AND is_active = TRUE) THEN
            RAISE EXCEPTION 'Queue "%" does not exist or is inactive', v_queue_name;
        END IF;
    END LOOP;
    
    v_api_key := 'sk_' || encode(gen_random_bytes(32), 'hex');
    v_api_key_hash := encode(digest(v_api_key, 'sha256'), 'hex');
    v_api_key_prefix := substring(v_api_key, 1, 10);

    SELECT
        worker_name,
        max_concurrent_tasks,
        heartbeat_interval,
        subscribed_queues,
        is_active
    INTO
        v_existing_worker_name,
        v_existing_max_concurrent_tasks,
        v_existing_heartbeat_interval,
        v_existing_subscribed_queues,
        v_existing_is_active
    FROM worker_registry
    WHERE worker_registry.worker_id = p_worker_id;

    IF NOT FOUND THEN
        v_audit_reason := 'created';
    ELSIF v_existing_worker_name IS DISTINCT FROM COALESCE(p_worker_name, p_worker_id)
       OR v_existing_max_concurrent_tasks IS DISTINCT FROM p_max_concurrent_tasks
       OR v_existing_heartbeat_interval IS DISTINCT FROM p_heartbeat_interval
       OR v_existing_subscribed_queues IS DISTINCT FROM p_subscribed_queues
       OR v_existing_is_active IS DISTINCT FROM TRUE THEN
        v_audit_reason := 'configuration_changed';
    END IF;
    
    INSERT INTO worker_registry (
        worker_id,
        worker_name,
        max_concurrent_tasks,
        heartbeat_interval,
        expected_next_heartbeat,
        is_active,
        subscribed_queues  -- NEW: Store subscriptions
    ) VALUES (
        p_worker_id,
        COALESCE(p_worker_name, p_worker_id),
        p_max_concurrent_tasks,
        p_heartbeat_interval,
        NOW() + p_heartbeat_interval,
        TRUE,
        p_subscribed_queues
    )
    ON CONFLICT ON CONSTRAINT worker_registry_worker_id_key
    DO UPDATE SET
        is_active = TRUE,
        last_seen_at = NOW(),
        expected_next_heartbeat = NOW() + p_heartbeat_interval,
        subscribed_queues = p_subscribed_queues,  -- NEW: Update subscriptions
        updated_at = NOW();
    
    INSERT INTO worker_api_keys (
        worker_id,
        api_key_hash,
        api_key_prefix,
        is_active
    ) VALUES (
        p_worker_id,
        v_api_key_hash,
        v_api_key_prefix,
        TRUE
    )
    ON CONFLICT ON CONSTRAINT worker_api_keys_worker_id_key
    DO UPDATE SET
        api_key_hash = v_api_key_hash,
        api_key_prefix = v_api_key_prefix,
        is_active = TRUE,
        created_at = NOW();
    
    IF v_audit_reason IS NOT NULL THEN
        PERFORM log_audit('worker_register', 'worker', NULL, p_worker_id, NULL,
            jsonb_build_object(
                'worker_id', p_worker_id,
                'queues', p_subscribed_queues,
                'reason', v_audit_reason
            ));
    END IF;
    
    RETURN QUERY SELECT p_worker_id, v_api_key, TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Update worker queue subscriptions
CREATE OR REPLACE FUNCTION update_worker_subscriptions(
    p_api_key TEXT,
    p_subscribed_queues JSONB
) RETURNS BOOLEAN AS $$
DECLARE
    v_worker_id VARCHAR;
    v_queue_name TEXT;
BEGIN
    v_worker_id := validate_worker_auth(p_api_key);
    
    -- Validate all queues exist
    FOR v_queue_name IN SELECT jsonb_array_elements_text(p_subscribed_queues)
    LOOP
        IF NOT EXISTS(SELECT 1 FROM queue_registry WHERE queue_name = v_queue_name AND is_active = TRUE) THEN
            RAISE EXCEPTION 'Queue "%" does not exist or is inactive', v_queue_name;
        END IF;
    END LOOP;
    
    UPDATE worker_registry
    SET 
        subscribed_queues = p_subscribed_queues,
        updated_at = NOW()
    WHERE worker_id = v_worker_id;
    
    RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION worker_heartbeat(
    p_api_key TEXT,
    p_current_load INTEGER DEFAULT NULL,
    p_heartbeat_interval INTERVAL DEFAULT '30 seconds'
) RETURNS BOOLEAN AS $$
DECLARE
    v_worker_id VARCHAR;
BEGIN
    v_worker_id := validate_worker_auth(p_api_key);
    
    UPDATE worker_registry
    SET 
        last_seen_at = NOW(),
        expected_next_heartbeat = NOW() + p_heartbeat_interval,
        current_load = COALESCE(p_current_load, current_load),
        updated_at = NOW()
    WHERE worker_id = v_worker_id;
    
    RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION get_worker_stats(
    p_worker_id VARCHAR DEFAULT NULL
) RETURNS TABLE (
    worker_id VARCHAR,
    worker_name VARCHAR,
    is_active BOOLEAN,
    current_load INTEGER,
    max_capacity INTEGER,
    subscribed_queues JSONB,  -- NEW: Show subscriptions
    tasks_completed BIGINT,
    tasks_failed BIGINT,
    availability_ratio FLOAT,
    last_seen_seconds INTEGER
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        wr.worker_id,
        wr.worker_name,
        wr.is_active,
        wr.current_load,
        wr.max_concurrent_tasks,
        wr.subscribed_queues,  -- NEW: Include subscriptions
        wr.tasks_completed,
        wr.tasks_failed,
        CASE 
            WHEN wr.tasks_completed + wr.tasks_failed > 0 
            THEN wr.tasks_completed::FLOAT / (wr.tasks_completed + wr.tasks_failed)
            ELSE 1.0
        END as availability_ratio,
        EXTRACT(EPOCH FROM (NOW() - wr.last_seen_at))::INTEGER as last_seen_seconds
    FROM worker_registry wr
    WHERE (p_worker_id IS NULL OR wr.worker_id = p_worker_id)
    ORDER BY wr.is_active DESC, wr.current_load ASC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- 11. MONITORING FUNCTIONS
-- ============================================

-- Get detailed status for a single task (used by n8n interface)
CREATE OR REPLACE FUNCTION get_task_status(
    p_api_key TEXT,
    p_task_id BIGINT
) RETURNS TABLE (
    id BIGINT,
    task_uuid UUID,
    task_name VARCHAR,
    status task_status,
    worker_id VARCHAR,
    attempts INTEGER,
    max_attempts INTEGER,
    queue_name VARCHAR,
    scheduled_at TIMESTAMPTZ,
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    lease_expires_at TIMESTAMPTZ,
    last_error TEXT,
    task_type task_type,
    priority INTEGER,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
) AS $$
DECLARE
    v_worker_id VARCHAR;
BEGIN
    v_worker_id := validate_worker_auth(p_api_key);
    PERFORM check_rate_limit(v_worker_id, 'status', 10000, 60);

    RETURN QUERY
    SELECT 
        t.id,
        t.task_uuid,
        t.task_name,
        t.status,
        t.worker_id,
        t.attempts,
        t.max_attempts,
        t.queue_name,
        t.scheduled_at,
        t.started_at,
        t.completed_at,
        t.lease_expires_at,
        t.last_error,
        t.task_type,
        t.priority,
        t.created_at,
        t.updated_at
    FROM task_queue t
    WHERE t.id = p_task_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Task not found';
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION get_task_ancestors_descendants(
    p_task_uuid UUID
) RETURNS TABLE (
    relation_type TEXT,
    depth INTEGER,
    id BIGINT,
    task_uuid UUID,
    task_name VARCHAR,
    status task_status,
    queue_name VARCHAR,
    task_type task_type,
    priority INTEGER,
    task_data JSONB,
    task_metadata JSONB,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    parent_task_uuid UUID
) AS $$
DECLARE
    v_uuid_pattern CONSTANT TEXT := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM task_queue t
        WHERE t.task_uuid = p_task_uuid
    ) THEN
        RAISE EXCEPTION 'Task not found for task_uuid: %', p_task_uuid;
    END IF;

    RETURN QUERY
    WITH RECURSIVE
    ancestor_chain AS (
        SELECT
            parent_task.task_uuid,
            1 AS depth,
            ARRAY[p_task_uuid, parent_task.task_uuid]::UUID[] AS visited
        FROM task_queue current_task
        JOIN task_queue parent_task
            ON parent_task.task_uuid::TEXT = current_task.task_data #>> '{meta,parent_task_uuid}'
        WHERE current_task.task_uuid = p_task_uuid

        UNION ALL

        SELECT
            parent_task.task_uuid,
            ac.depth + 1,
            ac.visited || parent_task.task_uuid
        FROM ancestor_chain ac
        JOIN task_queue current_task
            ON current_task.task_uuid = ac.task_uuid
        JOIN task_queue parent_task
            ON parent_task.task_uuid::TEXT = current_task.task_data #>> '{meta,parent_task_uuid}'
        WHERE NOT parent_task.task_uuid = ANY(ac.visited)
    ),
    descendant_chain AS (
        SELECT
            child_task.task_uuid,
            1 AS depth,
            ARRAY[p_task_uuid, child_task.task_uuid]::UUID[] AS visited
        FROM task_queue child_task
        WHERE child_task.task_data #>> '{meta,parent_task_uuid}' = p_task_uuid::TEXT

        UNION ALL

        SELECT
            child_task.task_uuid,
            dc.depth + 1,
            dc.visited || child_task.task_uuid
        FROM descendant_chain dc
        JOIN task_queue child_task
            ON child_task.task_data #>> '{meta,parent_task_uuid}' = dc.task_uuid::TEXT
        WHERE NOT child_task.task_uuid = ANY(dc.visited)
    ),
    combined AS (
        SELECT
            'ancestor'::TEXT AS relation_type,
            ac.depth,
            ac.task_uuid
        FROM ancestor_chain ac
        UNION ALL
        SELECT
            'descendant'::TEXT AS relation_type,
            dc.depth,
            dc.task_uuid
        FROM descendant_chain dc
    ),
    deduped AS (
        SELECT
            c.relation_type,
            c.task_uuid,
            MIN(c.depth) AS depth
        FROM combined c
        GROUP BY c.relation_type, c.task_uuid
    )
    SELECT
        d.relation_type,
        d.depth,
        t.id,
        t.task_uuid,
        t.task_name,
        t.status,
        t.queue_name,
        t.task_type,
        t.priority,
        t.task_data,
        t.task_metadata,
        t.created_at,
        t.updated_at,
        CASE
            WHEN (t.task_data #>> '{meta,parent_task_uuid}') ~* v_uuid_pattern
            THEN (t.task_data #>> '{meta,parent_task_uuid}')::UUID
            ELSE NULL
        END AS parent_task_uuid
    FROM deduped d
    JOIN task_queue t
        ON t.task_uuid = d.task_uuid
    ORDER BY
        CASE WHEN d.relation_type = 'ancestor' THEN 0 ELSE 1 END,
        CASE WHEN d.relation_type = 'ancestor' THEN d.depth ELSE NULL END DESC,
        CASE WHEN d.relation_type = 'descendant' THEN d.depth ELSE NULL END ASC,
        t.id ASC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION get_queue_stats() 
RETURNS TABLE (
    total_tasks BIGINT,
    pending_tasks BIGINT,
    processing_tasks BIGINT,
    scheduled_tasks BIGINT,
    retrying_tasks BIGINT,
    completed_tasks_24h BIGINT,
    failed_tasks_24h BIGINT,
    avg_completion_time INTERVAL,
    oldest_pending_task TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        COUNT(*) as total_tasks,
        COUNT(*) FILTER (WHERE status = 'pending') as pending_tasks,
        COUNT(*) FILTER (WHERE status = 'processing') as processing_tasks,
        COUNT(*) FILTER (WHERE status = 'scheduled') as scheduled_tasks,
        COUNT(*) FILTER (WHERE status = 'retrying') as retrying_tasks,
        COUNT(*) FILTER (WHERE status = 'completed' 
                         AND completed_at > NOW() - INTERVAL '24 hours') as completed_tasks_24h,
        COUNT(*) FILTER (WHERE status = 'failed' 
                         AND updated_at > NOW() - INTERVAL '24 hours') as failed_tasks_24h,
        AVG(completed_at - started_at) FILTER (WHERE status = 'completed') as avg_completion_time,
        MIN(scheduled_at) FILTER (WHERE status IN ('pending', 'retrying')) as oldest_pending_task
    FROM task_queue;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- 12. TRIGGERS
-- ============================================

CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_task_queue_updated_at
BEFORE UPDATE ON task_queue
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_worker_registry_updated_at
BEFORE UPDATE ON worker_registry
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_queue_registry_updated_at
BEFORE UPDATE ON queue_registry
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

-- ============================================
-- 13. VIEWS FOR MONITORING
-- ============================================

CREATE OR REPLACE VIEW ready_queue AS
SELECT 
    id,
    task_uuid,
    task_name,
    queue_name,  -- NEW: Show queue
    priority,
    scheduled_at,
    attempts,
    max_attempts,
    created_at
FROM task_queue
WHERE status IN ('pending', 'retrying')
AND scheduled_at <= NOW()
AND (worker_id IS NULL OR lease_expires_at < NOW())
ORDER BY priority DESC, scheduled_at ASC;

CREATE OR REPLACE VIEW processing_tasks AS
SELECT 
    t.id,
    t.task_uuid,
    t.task_name,
    t.queue_name,  -- NEW: Show queue
    t.worker_id,
    t.started_at,
    t.lease_expires_at,
    t.last_heartbeat_at,
    t.attempts,
    (t.lease_expires_at - NOW()) as lease_time_remaining,
    (NOW() - t.last_heartbeat_at) as time_since_last_heartbeat
FROM task_queue t
WHERE t.status = 'processing'
ORDER BY t.lease_expires_at ASC;

-- NEW: View for queue-worker mapping
CREATE OR REPLACE VIEW queue_worker_subscriptions AS
SELECT 
    w.worker_id,
    w.worker_name,
    w.is_active,
    jsonb_array_elements_text(w.subscribed_queues) as queue_name,
    w.current_load,
    w.max_concurrent_tasks
FROM worker_registry w
ORDER BY queue_name, w.worker_id;

-- ============================================
-- 14. DEFAULT CONFIGURATION
-- ============================================

INSERT INTO scheduler_config (config_key, config_value, config_type, description) VALUES
('default_lease_duration', '5 minutes', 'interval', 'Default task lease duration'),
('max_retry_delay', '1 hour', 'interval', 'Maximum delay between retries'),
('cleanup_retention', '30 days', 'interval', 'How long to keep completed/failed tasks'),
('worker_timeout', '10 minutes', 'interval', 'Worker heartbeat timeout'),
('max_concurrent_tasks_per_worker', '10', 'integer', 'Maximum tasks per worker'),
('rate_limit_enqueue', '1000', 'integer', 'Max enqueue requests per hour'),
('rate_limit_dequeue', '1000', 'integer', 'Max dequeue requests per hour'),
('max_task_data_size_kb', '100', 'integer', 'Maximum task data size in KB'),
('enable_queue_isolation', 'true', 'boolean', 'Enable queue-based task isolation')
ON CONFLICT (config_key) DO NOTHING;

-- ============================================
-- 15. EXAMPLE USAGE WITH QUEUES
-- ============================================

/*
-- ===== SETUP PHASE =====

-- Step 1: Create custom queues
SELECT create_queue('high_priority', 'Critical tasks requiring immediate attention');
SELECT create_queue('low_priority', 'Background tasks that can wait');

-- Step 2: Register workers with queue subscriptions

-- Worker 1: Handles default and high priority queues
SELECT * FROM register_worker(
    'worker-001', 
    'Critical Task Worker', 
    10,
    '30 seconds'::INTERVAL,
    '["default", "high_priority", "email"]'::JSONB
);
-- Save API key: sk_abc123...

-- Worker 2: Handles only payment queue (specialized)
SELECT * FROM register_worker(
    'worker-002',
    'Payment Processor',
    5,
    '30 seconds'::INTERVAL,
    '["payment"]'::JSONB
);
-- Save API key: sk_def456...

-- Worker 3: Handles low priority and reports
SELECT * FROM register_worker(
    'worker-003',
    'Background Worker',
    20,
    '30 seconds'::INTERVAL,
    '["low_priority", "reports", "maintenance"]'::JSONB
);
-- Save API key: sk_ghi789...

-- ===== ENQUEUE TASKS TO DIFFERENT QUEUES =====

-- High priority task (only worker-001 can process)
SELECT enqueue_task(
    'sk_abc123...',
    'urgent_notification',
    '{"user_id": 123, "message": "System alert"}'::JSONB,
    'immediate',
    95,
    NOW(),
    3,
    NULL,
    'high_priority'  -- Goes to high_priority queue
);

-- Payment task (only worker-002 can process)
SELECT enqueue_task(
    'sk_def456...',
    'process_payment',
    '{"amount": 100, "currency": "USD"}'::JSONB,
    'immediate',
    80,
    NOW(),
    3,
    NULL,
    'payment'  -- Goes to payment queue
);

-- Email task (worker-001 can process - subscribed to email)
SELECT enqueue_task(
    'sk_abc123...',
    'send_welcome_email',
    '{"to": "user@example.com"}'::JSONB,
    'immediate',
    50,
    NOW(),
    3,
    NULL,
    'email'  -- Goes to email queue
);

-- Background report (only worker-003 can process)
SELECT enqueue_task(
    'sk_ghi789...',
    'monthly_analytics',
    '{"month": "2024-01"}'::JSONB,
    'immediate',
    10,
    NOW(),
    3,
    NULL,
    'reports'  -- Goes to reports queue
);

-- ===== DEQUEUE FROM SPECIFIC QUEUES =====

-- Worker 1 dequeues from high_priority and default queues
SELECT * FROM dequeue_task(
    'sk_abc123...',
    '10 minutes'::INTERVAL,
    ARRAY['high_priority', 'default', 'email']  -- Specify queues
);
-- Will get: urgent_notification (highest priority in subscribed queues)

-- Worker 2 dequeues from payment queue only
SELECT * FROM dequeue_task(
    'sk_def456...',
    '10 minutes'::INTERVAL,
    ARRAY['payment']  -- Only payment queue
);
-- Will get: process_payment

-- Worker 3 dequeues from all its subscribed queues
SELECT * FROM dequeue_task(
    'sk_ghi789...',
    '10 minutes'::INTERVAL,
    ARRAY['reports', 'low_priority', 'maintenance']
);
-- Will get: monthly_analytics

-- ===== MONITORING BY QUEUE =====

-- See stats per queue
SELECT * FROM get_queue_stats_by_queue();

-- See which workers are subscribed to which queues
SELECT * FROM queue_worker_subscriptions;

-- See all workers and their subscriptions
SELECT 
    worker_id,
    worker_name,
    subscribed_queues,
    current_load,
    max_capacity
FROM get_worker_stats();

-- See tasks in a specific queue
SELECT 
    id,
    task_name,
    status,
    priority,
    queue_name
FROM task_queue
WHERE queue_name = 'payment'
ORDER BY priority DESC;

-- ===== UPDATE WORKER SUBSCRIPTIONS =====

-- Worker 1 wants to also handle reports now
SELECT update_worker_subscriptions(
    'sk_abc123...',
    '["default", "high_priority", "email", "reports"]'::JSONB
);

-- ===== SHARED QUEUE BEHAVIOR =====

-- Multiple workers can subscribe to same queue
-- Tasks are distributed using priority and SKIP LOCKED

-- Create 3 tasks in default queue
SELECT enqueue_task('sk_abc123...', 'task_1', '{}'::JSONB, 'immediate', 50, NOW(), 3, NULL, 'default');
SELECT enqueue_task('sk_abc123...', 'task_2', '{}'::JSONB, 'immediate', 60, NOW(), 3, NULL, 'default');
SELECT enqueue_task('sk_abc123...', 'task_3', '{}'::JSONB, 'immediate', 40, NOW(), 3, NULL, 'default');

-- If worker-001 and worker-003 both subscribe to 'default':
-- Worker 1 dequeues: Gets task_2 (priority 60)
-- Worker 3 dequeues: Gets task_1 (priority 50)
-- Next dequeue: Gets task_3 (priority 40)

*/
