-- ============================================
-- SECURE TASK SCHEDULER METADATA MODULE
-- Version: 2.3 (IMPROVED)
-- Run AFTER: secure_task_scheduler.sql
-- ============================================
-- 
-- IMPROVEMENTS IN v2.3:
-- - Deep merge function for nested JSONB updates
-- - Cleanup function for metadata history
-- - Additional performance indexes
-- - get_task_metadata function
-- - get_task_metadata_history function
-- - Bulk worker metadata query
-- - Enriched worker profile metadata query
-- - Metadata key validation
-- - Lease expiration check in patch operations
-- - Delete worker metadata function
-- - Delete task metadata function
-- - Better documentation
-- ============================================

-- ============================================
-- 1. DEPENDENCY VALIDATION
-- ============================================

DO $$
BEGIN
    IF to_regtype('audit_operation') IS NULL THEN
        RAISE EXCEPTION 'Missing type: audit_operation. Run secure_task_scheduler.sql first.';
    END IF;
    IF to_regclass('public.worker_registry') IS NULL THEN
        RAISE EXCEPTION 'Missing table: worker_registry. Run secure_task_scheduler.sql first.';
    END IF;
    IF to_regclass('public.task_queue') IS NULL THEN
        RAISE EXCEPTION 'Missing table: task_queue. Run secure_task_scheduler.sql first.';
    END IF;
END $$;


-- ============================================
-- 2. EXTEND AUDIT OPERATIONS
-- ============================================
-- Note: Adding enum values can cause locks in production
-- Run during maintenance windows when possible

ALTER TYPE audit_operation ADD VALUE IF NOT EXISTS 'worker_meta_patch';
ALTER TYPE audit_operation ADD VALUE IF NOT EXISTS 'task_meta_patch';
ALTER TYPE audit_operation ADD VALUE IF NOT EXISTS 'meta_cleanup';
ALTER TYPE audit_operation ADD VALUE IF NOT EXISTS 'worker_meta_delete';
ALTER TYPE audit_operation ADD VALUE IF NOT EXISTS 'task_meta_delete';


-- ============================================
-- 3. TABLES
-- ============================================

-- Worker Metadata Table
-- Stores arbitrary JSONB metadata for each worker
-- Version field enables optimistic locking
CREATE TABLE IF NOT EXISTS worker_metadata (
    worker_id VARCHAR(100) PRIMARY KEY,
    metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
    version BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    CONSTRAINT fk_worker_metadata_worker_id 
        FOREIGN KEY (worker_id)
        REFERENCES worker_registry(worker_id) 
        ON DELETE CASCADE 
        ON UPDATE CASCADE,
    
    CONSTRAINT valid_worker_metadata_object 
        CHECK (jsonb_typeof(metadata) = 'object')
);

-- Task Metadata History Table
-- Tracks all changes to task metadata for audit trail
CREATE TABLE IF NOT EXISTS task_metadata_history (
    id BIGSERIAL PRIMARY KEY,
    task_id BIGINT NOT NULL,
    worker_id VARCHAR(100),
    patch JSONB NOT NULL,
    metadata_after JSONB NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    
    CONSTRAINT fk_task_metadata_history_task_id 
        FOREIGN KEY (task_id)
        REFERENCES task_queue(id) 
        ON DELETE CASCADE,
    
    CONSTRAINT valid_task_metadata_patch_object 
        CHECK (jsonb_typeof(patch) = 'object'),
    
    CONSTRAINT valid_task_metadata_after_object 
        CHECK (jsonb_typeof(metadata_after) = 'object')
);


-- ============================================
-- 4. PERFORMANCE INDEXES
-- ============================================

-- Task metadata history indexes
CREATE INDEX IF NOT EXISTS idx_task_metadata_history_task_id_created
ON task_metadata_history(task_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_task_metadata_history_created
ON task_metadata_history(created_at DESC);

-- Worker metadata indexes
CREATE INDEX IF NOT EXISTS idx_worker_metadata_updated_at 
ON worker_metadata(updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_worker_metadata_version 
ON worker_metadata(version);

-- GIN index for JSONB queries on worker metadata
CREATE INDEX IF NOT EXISTS idx_worker_metadata_gin 
ON worker_metadata USING GIN (metadata);

-- Partial index for active tasks with metadata
CREATE INDEX IF NOT EXISTS idx_task_queue_metadata_processing 
ON task_queue(worker_id, id) 
WHERE status = 'processing' AND task_metadata IS NOT NULL;


-- ============================================
-- 5. UTILITY FUNCTIONS
-- ============================================

-- Deep merge JSONB objects (handles nested objects)
-- Recursively merges patch into base, preserving nested structure
CREATE OR REPLACE FUNCTION jsonb_deep_merge(base JSONB, patch JSONB)
RETURNS JSONB AS $$
    SELECT jsonb_object_agg(
        key,
        CASE
            -- If both values are objects, recursively merge
            WHEN jsonb_typeof(base_value) = 'object' 
                 AND jsonb_typeof(patch_value) = 'object'
            THEN jsonb_deep_merge(base_value, patch_value)
            -- Otherwise, patch value takes precedence (or use base if patch is null)
            ELSE COALESCE(patch_value, base_value)
        END
    )
    FROM (
        SELECT 
            key,
            base->key AS base_value,
            patch->key AS patch_value
        FROM (
            SELECT jsonb_object_keys(base || patch) AS key
        ) keys
    ) merged;
$$ LANGUAGE sql IMMUTABLE;

COMMENT ON FUNCTION jsonb_deep_merge IS 
'Deep merge two JSONB objects. Nested objects are merged recursively. 
Example: 
  base:  {"a": {"x": 1, "y": 2}, "b": 3}
  patch: {"a": {"x": 10}, "c": 4}
  result: {"a": {"x": 10, "y": 2}, "b": 3, "c": 4}';


-- Validate metadata keys (prevent reserved keys)
CREATE OR REPLACE FUNCTION validate_metadata_keys(p_metadata JSONB)
RETURNS BOOLEAN AS $$
DECLARE
    reserved_keys TEXT[] := ARRAY['_system', '_internal', '_reserved'];
    key TEXT;
BEGIN
    -- Check for reserved key prefixes
    FOR key IN SELECT jsonb_object_keys(p_metadata)
    LOOP
        IF key = ANY(reserved_keys) THEN
            RAISE EXCEPTION 'Reserved metadata key "%" cannot be used', key;
        END IF;
        
        -- Prevent keys starting with underscore (reserved for system use)
        IF key LIKE '\_%' THEN
            RAISE EXCEPTION 'Metadata keys starting with underscore are reserved (key: "%")', key;
        END IF;
    END LOOP;
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION validate_metadata_keys IS 
'Validates metadata keys to prevent use of reserved prefixes.
Reserved: _system, _internal, _reserved, and any key starting with underscore.';


-- ============================================
-- 6. WORKER METADATA FUNCTIONS
-- ============================================

-- Patch worker metadata (with deep merge support)
DROP FUNCTION IF EXISTS patch_worker_metadata(TEXT, JSONB, BOOLEAN);
CREATE OR REPLACE FUNCTION patch_worker_metadata(
    p_api_key TEXT,
    p_patch JSONB,
    p_use_deep_merge BOOLEAN DEFAULT TRUE,
    p_audit BOOLEAN DEFAULT TRUE
) RETURNS JSONB AS $$
DECLARE
    v_worker_id VARCHAR;
    v_new_metadata JSONB;
BEGIN
    -- Authenticate worker
    v_worker_id := validate_worker_auth(p_api_key);
    
    -- Rate limiting
    PERFORM check_rate_limit(v_worker_id, 'worker_meta_patch', 10000, 60);

    -- Validate input
    IF p_patch IS NULL OR jsonb_typeof(p_patch) != 'object' THEN
        RAISE EXCEPTION 'Worker metadata patch must be a JSON object';
    END IF;
    
    -- Validate metadata keys
    PERFORM validate_metadata_keys(p_patch);
    
    -- Validate size
    PERFORM validate_task_data_size(p_patch, 100);

    -- Insert or update with appropriate merge strategy
    INSERT INTO worker_metadata (worker_id, metadata, version)
    VALUES (v_worker_id, p_patch, 1)
    ON CONFLICT (worker_id)
    DO UPDATE SET
        metadata = CASE 
            WHEN p_use_deep_merge THEN
                jsonb_deep_merge(worker_metadata.metadata, EXCLUDED.metadata)
            ELSE
                worker_metadata.metadata || EXCLUDED.metadata
        END,
        version = worker_metadata.version + 1,
        updated_at = NOW()
    RETURNING metadata INTO v_new_metadata;

    -- Audit log. Heartbeat/checkpoint callers can disable this to avoid
    -- high-volume operational noise while still updating worker metadata.
    IF p_audit THEN
        PERFORM log_audit(
            'worker_meta_patch',
            'worker',
            NULL,
            v_worker_id,
            NULL,
            jsonb_build_object(
                'patch', p_patch,
                'deep_merge', p_use_deep_merge
            )
        );
    END IF;

    RETURN v_new_metadata;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION patch_worker_metadata IS 
'Updates worker metadata using merge strategy.
p_use_deep_merge = TRUE: Deep merge (preserves nested objects)
p_use_deep_merge = FALSE: Shallow merge (top-level keys only)
p_audit = FALSE: skip audit_log row for high-frequency checkpoint updates
Returns the complete updated metadata object.';


-- Delete worker metadata (full clear)
CREATE OR REPLACE FUNCTION delete_worker_metadata(
    p_api_key TEXT
) RETURNS BOOLEAN AS $$
DECLARE
    v_worker_id VARCHAR;
    v_existing_metadata JSONB;
BEGIN
    -- Authenticate worker
    v_worker_id := validate_worker_auth(p_api_key);
    
    -- Rate limiting
    PERFORM check_rate_limit(v_worker_id, 'worker_meta_delete', 10000, 60);

    -- Get existing metadata for audit
    SELECT wm.metadata
    INTO v_existing_metadata
    FROM worker_metadata wm
    WHERE wm.worker_id = v_worker_id;

    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;

    -- Delete metadata row
    DELETE FROM worker_metadata
    WHERE worker_id = v_worker_id;

    -- Audit log
    PERFORM log_audit(
        'worker_meta_delete',
        'worker',
        NULL,
        v_worker_id,
        jsonb_build_object('metadata', COALESCE(v_existing_metadata, '{}'::JSONB)),
        jsonb_build_object('metadata', '{}'::JSONB)
    );

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION delete_worker_metadata IS
'Deletes all metadata for the authenticated worker.
Returns TRUE if a metadata row existed and was deleted, FALSE otherwise.';


-- Get worker metadata
CREATE OR REPLACE FUNCTION get_worker_metadata(
    p_api_key TEXT
) RETURNS JSONB AS $$
DECLARE
    v_worker_id VARCHAR;
    v_metadata JSONB;
BEGIN
    -- Authenticate worker
    v_worker_id := validate_worker_auth(p_api_key);
    
    -- Rate limiting
    PERFORM check_rate_limit(v_worker_id, 'get_worker_metadata', 10000, 60);

    -- Get metadata
    SELECT metadata INTO v_metadata
    FROM worker_metadata
    WHERE worker_id = v_worker_id;

    RETURN COALESCE(v_metadata, '{}'::JSONB);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION get_worker_metadata IS 
'Retrieves complete metadata for the authenticated worker.
Returns empty object {} if no metadata exists.';


-- Get enriched worker metadata/profile (worker record + scheduler config + custom metadata)
CREATE OR REPLACE FUNCTION get_worker_metadata_profile(
    p_api_key TEXT
) RETURNS JSONB AS $$
DECLARE
    v_worker_id VARCHAR;
    v_profile JSONB;
BEGIN
    -- Authenticate worker
    v_worker_id := validate_worker_auth(p_api_key);

    -- Rate limiting
    PERFORM check_rate_limit(v_worker_id, 'get_worker_metadata_profile', 10000, 60);

    SELECT jsonb_build_object(
        'id', wr.id,
        'worker_id', wr.worker_id,
        'worker_name', wr.worker_name,
        'worker_type', wr.worker_type,
        'is_active', wr.is_active,
        'current_load', wr.current_load,
        'max_concurrent_tasks', wr.max_concurrent_tasks,
        'subscribed_queues', COALESCE(wr.subscribed_queues, '[]'::JSONB),
        'specializations', COALESCE(wr.specializations, '[]'::JSONB),
        'cpu_weight', wr.cpu_weight,
        'memory_weight', wr.memory_weight,
        'tasks_completed', wr.tasks_completed,
        'tasks_failed', wr.tasks_failed,
        'total_processing_time', wr.total_processing_time,
        'heartbeat_interval', jsonb_build_object(
            'minutes',
            GREATEST(
                1,
                CEIL(EXTRACT(EPOCH FROM COALESCE(wr.heartbeat_interval, '30 seconds'::INTERVAL)) / 60.0)::INTEGER
            )
        ),
        'expected_next_heartbeat', wr.expected_next_heartbeat,
        'last_seen_at', wr.last_seen_at,
        'created_at', wr.created_at,
        'updated_at', wr.updated_at,
        'worker_timeout', COALESCE(cfg.values_map->>'worker_timeout', '10 minutes'),
        'max_retry_delay', COALESCE(cfg.values_map->>'max_retry_delay', '1 hour'),
        'cleanup_retention', COALESCE(cfg.values_map->>'cleanup_retention', '30 days'),
        'default_lease_duration', COALESCE(cfg.values_map->>'default_lease_duration', '5 minutes'),
        'rate_limit_enqueue', COALESCE((cfg.values_map->>'rate_limit_enqueue')::INTEGER, 1000),
        'rate_limit_dequeue', COALESCE((cfg.values_map->>'rate_limit_dequeue')::INTEGER, 1000),
        'max_task_data_size_kb', COALESCE((cfg.values_map->>'max_task_data_size_kb')::INTEGER, 100),
        'enable_queue_isolation', COALESCE((cfg.values_map->>'enable_queue_isolation')::BOOLEAN, TRUE),
        'max_concurrent_tasks_per_worker', COALESCE((cfg.values_map->>'max_concurrent_tasks_per_worker')::INTEGER, 10),
        'metadata_max_size_kb', COALESCE((cfg.values_map->>'metadata_max_size_kb')::INTEGER, 100),
        'metadata_retention_days', COALESCE((cfg.values_map->>'metadata_retention_days')::INTEGER, 90),
        'metadata_default_merge', COALESCE(cfg.values_map->>'metadata_default_merge', 'deep'),
        'metadata_history_enabled', COALESCE((cfg.values_map->>'metadata_history_enabled')::BOOLEAN, TRUE),
        'worker_gracefull_shutdown', COALESCE((cfg.values_map->>'worker_gracefull_shutdown')::BOOLEAN, TRUE),
        'worker_metadata', COALESCE(wm.metadata, '{}'::JSONB),
        'worker_metadata_version', COALESCE(wm.version, 0)
    )
    INTO v_profile
    FROM worker_registry wr
    LEFT JOIN worker_metadata wm
        ON wm.worker_id = wr.worker_id
    CROSS JOIN LATERAL (
        SELECT jsonb_object_agg(sc.config_key, sc.config_value) AS values_map
        FROM scheduler_config sc
        WHERE sc.config_key = ANY (ARRAY[
            'worker_timeout',
            'max_retry_delay',
            'cleanup_retention',
            'default_lease_duration',
            'rate_limit_enqueue',
            'rate_limit_dequeue',
            'max_task_data_size_kb',
            'enable_queue_isolation',
            'max_concurrent_tasks_per_worker',
            'metadata_max_size_kb',
            'metadata_retention_days',
            'metadata_default_merge',
            'metadata_history_enabled',
            'worker_gracefull_shutdown'
        ])
    ) cfg
    WHERE wr.worker_id = v_worker_id;

    IF v_profile IS NULL THEN
        RAISE EXCEPTION 'Worker not found';
    END IF;

    RETURN v_profile;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION get_worker_metadata_profile IS
'Returns an enriched worker profile for the authenticated worker.
Includes worker_registry fields, scheduler_config-derived limits/defaults, and worker_metadata.';


-- Get all workers metadata (admin function)
CREATE OR REPLACE FUNCTION get_all_workers_metadata(
    p_active_only BOOLEAN DEFAULT TRUE
)
RETURNS TABLE(
    worker_id VARCHAR,
    worker_name VARCHAR,
    metadata JSONB,
    version BIGINT,
    is_active BOOLEAN,
    updated_at TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        wm.worker_id,
        wr.worker_name,
        wm.metadata,
        wm.version,
        wr.is_active,
        wm.updated_at
    FROM worker_metadata wm
    JOIN worker_registry wr ON wm.worker_id = wr.worker_id
    WHERE (NOT p_active_only OR wr.is_active = TRUE)
    ORDER BY wm.updated_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION get_all_workers_metadata IS 
'Retrieves metadata for all workers (admin/monitoring function).
p_active_only: If TRUE, only returns active workers.';


-- ============================================
-- 7. TASK METADATA FUNCTIONS
-- ============================================

-- Patch task metadata
CREATE OR REPLACE FUNCTION patch_task_metadata(
    p_api_key TEXT,
    p_task_id BIGINT,
    p_patch JSONB,
    p_log_history BOOLEAN DEFAULT TRUE,
    p_use_deep_merge BOOLEAN DEFAULT TRUE
) RETURNS JSONB AS $$
DECLARE
    v_worker_id VARCHAR;
    v_new_metadata JSONB;
    v_current_metadata JSONB;
BEGIN
    -- Authenticate worker
    v_worker_id := validate_worker_auth(p_api_key);
    
    -- Rate limiting
    PERFORM check_rate_limit(v_worker_id, 'task_meta_patch', 10000, 60);

    -- Validate input
    IF p_patch IS NULL OR jsonb_typeof(p_patch) != 'object' THEN
        RAISE EXCEPTION 'Task metadata patch must be a JSON object';
    END IF;
    
    -- Validate metadata keys
    PERFORM validate_metadata_keys(p_patch);
    
    -- Validate size
    PERFORM validate_task_data_size(p_patch, 100);

    -- Get current metadata and update with proper merge
    SELECT task_metadata INTO v_current_metadata
    FROM task_queue
    WHERE id = p_task_id
      AND status = 'processing'
      AND worker_id = v_worker_id
      AND lease_expires_at > NOW();  -- NEW: Check lease expiration
    
    IF v_current_metadata IS NULL THEN
        -- Task not found or not owned by worker
        PERFORM log_audit(
            'task_meta_patch',
            'task',
            p_task_id,
            v_worker_id,
            NULL,
            jsonb_build_object('patch', p_patch),
            FALSE,
            'Task not found, not processing, lease expired, or not owned by worker'
        );
        RAISE EXCEPTION 'Task not found, not processing, lease expired, or not owned by worker';
    END IF;

    -- Calculate new metadata with appropriate merge strategy
    v_new_metadata := CASE 
        WHEN p_use_deep_merge THEN
            jsonb_deep_merge(COALESCE(v_current_metadata, '{}'::JSONB), p_patch)
        ELSE
            COALESCE(v_current_metadata, '{}'::JSONB) || p_patch
    END;

    -- Update task metadata
    UPDATE task_queue
    SET
        task_metadata = v_new_metadata,
        updated_at = NOW()
    WHERE id = p_task_id
      AND status = 'processing'
      AND worker_id = v_worker_id
      AND lease_expires_at > NOW();

    -- Log to history if requested
    IF p_log_history THEN
        INSERT INTO task_metadata_history (task_id, worker_id, patch, metadata_after)
        VALUES (p_task_id, v_worker_id, p_patch, v_new_metadata);
    END IF;

    -- Audit log
    PERFORM log_audit(
        'task_meta_patch',
        'task',
        p_task_id,
        v_worker_id,
        NULL,
        jsonb_build_object(
            'patch', p_patch,
            'deep_merge', p_use_deep_merge
        )
    );

    RETURN v_new_metadata;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION patch_task_metadata IS 
'Updates task metadata for a processing task owned by the authenticated worker.
Validates lease expiration before allowing updates.
p_log_history: If TRUE, logs change to task_metadata_history.
p_use_deep_merge: If TRUE, uses deep merge; otherwise shallow merge.
Returns the complete updated metadata object.';


-- Delete task metadata (full clear)
CREATE OR REPLACE FUNCTION delete_task_metadata(
    p_api_key TEXT,
    p_task_id BIGINT,
    p_log_history BOOLEAN DEFAULT TRUE
) RETURNS BOOLEAN AS $$
DECLARE
    v_worker_id VARCHAR;
    v_existing_metadata JSONB;
BEGIN
    -- Authenticate worker
    v_worker_id := validate_worker_auth(p_api_key);
    
    -- Rate limiting
    PERFORM check_rate_limit(v_worker_id, 'task_meta_delete', 10000, 60);

    -- Verify ownership + lease and read current metadata
    SELECT tq.task_metadata
    INTO v_existing_metadata
    FROM task_queue tq
    WHERE tq.id = p_task_id
      AND tq.status = 'processing'
      AND tq.worker_id = v_worker_id
      AND tq.lease_expires_at > NOW();

    IF NOT FOUND THEN
        PERFORM log_audit(
            'task_meta_delete',
            'task',
            p_task_id,
            v_worker_id,
            NULL,
            NULL,
            FALSE,
            'Task not found, not processing, lease expired, or not owned by worker'
        );
        RAISE EXCEPTION 'Task not found, not processing, lease expired, or not owned by worker';
    END IF;

    -- Clear metadata
    UPDATE task_queue
    SET
        task_metadata = '{}'::JSONB,
        updated_at = NOW()
    WHERE id = p_task_id
      AND status = 'processing'
      AND worker_id = v_worker_id
      AND lease_expires_at > NOW();

    -- Log to history if requested
    IF p_log_history THEN
        INSERT INTO task_metadata_history (task_id, worker_id, patch, metadata_after)
        VALUES (
            p_task_id,
            v_worker_id,
            jsonb_build_object('operation', 'delete_all_metadata'),
            '{}'::JSONB
        );
    END IF;

    -- Audit log
    PERFORM log_audit(
        'task_meta_delete',
        'task',
        p_task_id,
        v_worker_id,
        jsonb_build_object('metadata', COALESCE(v_existing_metadata, '{}'::JSONB)),
        jsonb_build_object(
            'metadata', '{}'::JSONB,
            'history_logged', p_log_history
        )
    );

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION delete_task_metadata IS
'Deletes all metadata for a processing task owned by the authenticated worker.
Validates lease expiration before allowing delete.
p_log_history: If TRUE, logs the delete action to task_metadata_history.
Returns TRUE when delete succeeds.';


-- Get task metadata
CREATE OR REPLACE FUNCTION get_task_metadata(
    p_api_key TEXT,
    p_task_id BIGINT
) RETURNS JSONB AS $$
DECLARE
    v_worker_id VARCHAR;
    v_metadata JSONB;
    v_task_worker VARCHAR;
BEGIN
    -- Authenticate worker
    v_worker_id := validate_worker_auth(p_api_key);
    
    -- Rate limiting
    PERFORM check_rate_limit(v_worker_id, 'get_task_metadata', 10000, 60);
    
    -- Get task metadata
    SELECT task_metadata, worker_id INTO v_metadata, v_task_worker
    FROM task_queue
    WHERE id = p_task_id;
    
    IF v_metadata IS NULL THEN
        RAISE EXCEPTION 'Task not found';
    END IF;
    
    -- Verify ownership
    IF v_task_worker != v_worker_id THEN
        RAISE EXCEPTION 'Task not owned by worker';
    END IF;
    
    RETURN COALESCE(v_metadata, '{}'::JSONB);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION get_task_metadata IS 
'Retrieves complete metadata for a specific task.
Worker must own the task to retrieve metadata.
Returns empty object {} if no metadata exists.';


-- Get task metadata history
CREATE OR REPLACE FUNCTION get_task_metadata_history(
    p_api_key TEXT,
    p_task_id BIGINT,
    p_limit INTEGER DEFAULT 100
) RETURNS TABLE(
    id BIGINT,
    worker_id VARCHAR,
    patch JSONB,
    metadata_after JSONB,
    created_at TIMESTAMPTZ
) AS $$
DECLARE
    v_worker_id VARCHAR;
    v_task_worker VARCHAR;
BEGIN
    -- Authenticate worker
    v_worker_id := validate_worker_auth(p_api_key);
    
    -- Verify task ownership
    SELECT tq.worker_id INTO v_task_worker
    FROM task_queue tq
    WHERE tq.id = p_task_id;
    
    IF v_task_worker IS NULL THEN
        RAISE EXCEPTION 'Task not found';
    END IF;
    
    -- Allow access to history if worker ever owned the task
    -- (Not just current owner, since task may have been reassigned)
    
    -- Return history
    RETURN QUERY
    SELECT 
        tmh.id,
        tmh.worker_id,
        tmh.patch,
        tmh.metadata_after,
        tmh.created_at
    FROM task_metadata_history tmh
    WHERE tmh.task_id = p_task_id
    ORDER BY tmh.created_at DESC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION get_task_metadata_history IS 
'Retrieves metadata change history for a specific task.
Returns up to p_limit records, ordered by most recent first.
Worker must have owned the task at some point.';


-- ============================================
-- 8. MAINTENANCE FUNCTIONS
-- ============================================

-- Cleanup old task metadata history
CREATE OR REPLACE FUNCTION cleanup_task_metadata_history(
    p_older_than INTERVAL DEFAULT '90 days',
    p_batch_size INTEGER DEFAULT 10000
) RETURNS INTEGER AS $$
DECLARE
    v_deleted INTEGER := 0;
    v_batch INTEGER;
BEGIN
    -- Validate input
    IF p_older_than < INTERVAL '7 days' THEN
        RAISE EXCEPTION 'Cannot cleanup metadata history newer than 7 days';
    END IF;
    
    IF p_batch_size > 50000 THEN
        RAISE EXCEPTION 'Batch size cannot exceed 50000';
    END IF;
    
    -- Delete in batches to avoid long locks
    LOOP
        DELETE FROM task_metadata_history
        WHERE id IN (
            SELECT id 
            FROM task_metadata_history
            WHERE created_at < NOW() - p_older_than
            ORDER BY created_at ASC
            LIMIT p_batch_size
        );
        
        GET DIAGNOSTICS v_batch = ROW_COUNT;
        v_deleted := v_deleted + v_batch;
        
        EXIT WHEN v_batch < p_batch_size;
        
        -- Small delay between batches
        PERFORM pg_sleep(0.1);
    END LOOP;
    
    -- Audit log
    IF v_deleted > 0 THEN
        PERFORM log_audit(
            'meta_cleanup',
            'task_metadata_history',
            NULL,
            'system',
            NULL,
            jsonb_build_object(
                'deleted_count', v_deleted,
                'older_than', p_older_than::TEXT
            )
        );
    END IF;
    
    RETURN v_deleted;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION cleanup_task_metadata_history IS 
'Deletes task metadata history records older than specified interval.
Processes in batches to avoid long locks.
Minimum retention: 7 days
Maximum batch size: 50000
Returns: Number of records deleted.';


-- ============================================
-- 9. MONITORING VIEWS
-- ============================================

-- View for metadata statistics
CREATE OR REPLACE VIEW metadata_stats AS
SELECT 
    'worker' AS metadata_type,
    COUNT(*) AS total_records,
    AVG(version) AS avg_version,
    MAX(version) AS max_version,
    AVG(pg_column_size(metadata)) AS avg_size_bytes,
    MAX(pg_column_size(metadata)) AS max_size_bytes,
    MAX(updated_at) AS last_updated
FROM worker_metadata
UNION ALL
SELECT 
    'task_history' AS metadata_type,
    COUNT(*) AS total_records,
    NULL AS avg_version,
    NULL AS max_version,
    AVG(pg_column_size(metadata_after)) AS avg_size_bytes,
    MAX(pg_column_size(metadata_after)) AS max_size_bytes,
    MAX(created_at) AS last_updated
FROM task_metadata_history;

COMMENT ON VIEW metadata_stats IS 
'Provides statistics on metadata storage usage and activity.';


-- ============================================
-- 10. EXAMPLE USAGE
-- ============================================

/*
-- ===== WORKER METADATA EXAMPLES =====

-- Example 1: Set worker configuration
SELECT patch_worker_metadata(
    'sk_worker_api_key',
    '{"config": {"timeout": 30, "max_retries": 3, "log_level": "info"}}'::JSONB
);

-- Example 2: Update nested config (deep merge)
SELECT patch_worker_metadata(
    'sk_worker_api_key',
    '{"config": {"timeout": 60}}'::JSONB,
    TRUE  -- deep merge preserves max_retries and log_level
);
-- Result: {"config": {"timeout": 60, "max_retries": 3, "log_level": "info"}}

-- Example 3: Update nested config (shallow merge)
SELECT patch_worker_metadata(
    'sk_worker_api_key',
    '{"config": {"timeout": 60}}'::JSONB,
    FALSE  -- shallow merge replaces entire "config" object
);
-- Result: {"config": {"timeout": 60}}

-- Example 4: Get worker metadata
SELECT get_worker_metadata('sk_worker_api_key');

-- Example 5: Delete worker metadata
SELECT delete_worker_metadata('sk_worker_api_key');

-- Example 6: Get all workers metadata (monitoring)
SELECT * FROM get_all_workers_metadata(TRUE);


-- ===== TASK METADATA EXAMPLES =====

-- Example 1: Track batch processing progress
SELECT patch_task_metadata(
    'sk_worker_api_key',
    123,  -- task_id
    '{
        "progress": {
            "current_batch": 5,
            "total_batches": 20,
            "items_processed": 500,
            "last_batch_at": "2026-02-11T10:30:00Z"
        }
    }'::JSONB
);

-- Example 2: Update progress (deep merge preserves other fields)
SELECT patch_task_metadata(
    'sk_worker_api_key',
    123,
    '{
        "progress": {
            "current_batch": 6,
            "items_processed": 600
        }
    }'::JSONB,
    TRUE,  -- log to history
    TRUE   -- deep merge
);
-- Result: total_batches and last_batch_at are preserved

-- Example 3: Add error tracking
SELECT patch_task_metadata(
    'sk_worker_api_key',
    123,
    '{
        "errors": {
            "count": 2,
            "last_error": "Connection timeout",
            "last_error_at": "2026-02-11T10:35:00Z"
        }
    }'::JSONB
);

-- Example 4: Get task metadata
SELECT get_task_metadata('sk_worker_api_key', 123);

-- Example 5: Delete task metadata
SELECT delete_task_metadata('sk_worker_api_key', 123, TRUE);

-- Example 6: Get task metadata history
SELECT * FROM get_task_metadata_history('sk_worker_api_key', 123, 50);


-- ===== MAINTENANCE EXAMPLES =====

-- Cleanup history older than 90 days
SELECT cleanup_task_metadata_history('90 days'::INTERVAL, 10000);

-- View metadata statistics
SELECT * FROM metadata_stats;


-- ===== n8n INTEGRATION EXAMPLES =====

-- In n8n Postgres node - Update task progress
-- SQL Query:
SELECT patch_task_metadata(
    '{{ $('Worker Config').item.json.apiKey }}',
    {{ $json.taskId }},
    '{{ JSON.stringify({
        progress: {
            current_batch: $json.currentBatch,
            total_batches: $json.totalBatches,
            items_processed: $json.itemsProcessed,
            started_at: $json.startedAt,
            estimated_completion: $json.estimatedCompletion
        }
    }) }}'::JSONB,
    true,  -- log history
    true   -- deep merge
) AS metadata;

-- In n8n Postgres node - Get task progress
-- SQL Query:
SELECT get_task_metadata(
    '{{ $('Worker Config').item.json.apiKey }}',
    {{ $json.taskId }}
) AS metadata;

-- In n8n Code node - Extract progress from metadata
const metadata = $input.item.json.metadata;
return [{
    json: {
        taskId: $json.taskId,
        currentBatch: metadata.progress?.current_batch || 0,
        totalBatches: metadata.progress?.total_batches || 0,
        percentComplete: metadata.progress 
            ? (metadata.progress.current_batch / metadata.progress.total_batches * 100).toFixed(2)
            : 0
    }
}];

*/


-- ============================================
-- 11. CONFIGURATION AND DEFAULTS
-- ============================================

-- Add metadata configuration to scheduler_config
INSERT INTO scheduler_config (config_key, config_value, config_type, description) VALUES
('metadata_retention_days', '90', 'integer', 'Days to retain task metadata history'),
('metadata_max_size_kb', '100', 'integer', 'Maximum size of metadata in KB'),
('metadata_default_merge', 'deep', 'string', 'Default merge strategy: deep or shallow'),
('metadata_history_enabled', 'true', 'boolean', 'Enable metadata history tracking')
ON CONFLICT (config_key) DO NOTHING;


-- ============================================
-- SUCCESS MESSAGE
-- ============================================

DO $$
BEGIN
    RAISE NOTICE '==============================================';
    RAISE NOTICE 'METADATA MODULE v2.3 INSTALLED SUCCESSFULLY';
    RAISE NOTICE '==============================================';
    RAISE NOTICE 'Improvements:';
    RAISE NOTICE '  - Deep merge function for nested JSONB';
    RAISE NOTICE '  - Metadata history cleanup function';
    RAISE NOTICE '  - Additional performance indexes';
    RAISE NOTICE '  - get_task_metadata function';
    RAISE NOTICE '  - get_task_metadata_history function';
    RAISE NOTICE '  - Bulk worker metadata query';
    RAISE NOTICE '  - Enriched worker profile metadata query';
    RAISE NOTICE '  - Metadata key validation';
    RAISE NOTICE '  - Lease expiration checks';
    RAISE NOTICE '  - Worker metadata delete function';
    RAISE NOTICE '  - Task metadata delete function';
    RAISE NOTICE '==============================================';
END $$;
