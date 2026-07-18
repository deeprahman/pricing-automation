-- ============================================
-- SECURE TASK SCHEDULER DEPENDENCIES MODULE
-- Version: 1.0
-- Run AFTER: secure_task_scheduler.sql
-- ============================================

-- ============================================
-- 1. DEPENDENCY VALIDATION
-- ============================================

DO $$
BEGIN
    IF to_regclass('public.task_queue') IS NULL THEN
        RAISE EXCEPTION 'Missing table: task_queue. Run secure_task_scheduler.sql first.';
    END IF;
    IF to_regtype('task_status') IS NULL THEN
        RAISE EXCEPTION 'Missing type: task_status. Run secure_task_scheduler.sql first.';
    END IF;
    IF to_regprocedure('validate_worker_auth(text)') IS NULL THEN
        RAISE EXCEPTION 'Missing function: validate_worker_auth(text). Run secure_task_scheduler.sql first.';
    END IF;
    IF to_regprocedure('check_rate_limit(character varying,character varying,integer,integer)') IS NULL THEN
        RAISE EXCEPTION 'Missing function: check_rate_limit(...). Run secure_task_scheduler.sql first.';
    END IF;
    IF to_regprocedure('log_audit(audit_operation,character varying,bigint,character varying,jsonb,jsonb,boolean,text)') IS NULL THEN
        RAISE EXCEPTION 'Missing function: log_audit(...). Run secure_task_scheduler.sql first.';
    END IF;
    IF to_regprocedure('dequeue_task(text,interval,character varying[])') IS NULL THEN
        RAISE EXCEPTION 'Missing function: dequeue_task(text, interval, varchar[]). Run secure_task_scheduler.sql first.';
    END IF;
END $$;


-- ============================================
-- 2. DEPENDENCY TABLE
-- ============================================

CREATE TABLE IF NOT EXISTS task_dependencies (
    task_id BIGINT NOT NULL REFERENCES task_queue(id) ON DELETE CASCADE,
    prerequisite_task_id BIGINT NOT NULL REFERENCES task_queue(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (task_id, prerequisite_task_id),
    CONSTRAINT chk_task_dependencies_no_self_ref CHECK (task_id <> prerequisite_task_id)
);

CREATE INDEX IF NOT EXISTS idx_task_dependencies_prerequisite
ON task_dependencies (prerequisite_task_id);

DO $$
BEGIN
    -- Remove orphan rows if parent table was recreated and FKs were dropped by CASCADE.
    DELETE FROM task_dependencies td
    WHERE NOT EXISTS (
            SELECT 1
            FROM task_queue t
            WHERE t.id = td.task_id
        )
       OR NOT EXISTS (
            SELECT 1
            FROM task_queue t
            WHERE t.id = td.prerequisite_task_id
        );

    -- Remove duplicate rows before (re)creating PK in legacy installs.
    DELETE FROM task_dependencies a
    USING task_dependencies b
    WHERE a.ctid < b.ctid
      AND a.task_id = b.task_id
      AND a.prerequisite_task_id = b.prerequisite_task_id;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'task_dependencies_pkey'
          AND conrelid = 'task_dependencies'::regclass
    ) THEN
        ALTER TABLE task_dependencies
            ADD CONSTRAINT task_dependencies_pkey
            PRIMARY KEY (task_id, prerequisite_task_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'chk_task_dependencies_no_self_ref'
          AND conrelid = 'task_dependencies'::regclass
    ) THEN
        ALTER TABLE task_dependencies
            ADD CONSTRAINT chk_task_dependencies_no_self_ref
            CHECK (task_id <> prerequisite_task_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'task_dependencies_task_id_fkey'
          AND conrelid = 'task_dependencies'::regclass
    ) THEN
        ALTER TABLE task_dependencies
            ADD CONSTRAINT task_dependencies_task_id_fkey
            FOREIGN KEY (task_id)
            REFERENCES task_queue(id)
            ON DELETE CASCADE;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'task_dependencies_prerequisite_task_id_fkey'
          AND conrelid = 'task_dependencies'::regclass
    ) THEN
        ALTER TABLE task_dependencies
            ADD CONSTRAINT task_dependencies_prerequisite_task_id_fkey
            FOREIGN KEY (prerequisite_task_id)
            REFERENCES task_queue(id)
            ON DELETE CASCADE;
    END IF;
END $$;


-- ============================================
-- 3. INTERNAL HELPERS
-- ============================================

CREATE OR REPLACE FUNCTION task_dependency_creates_cycle(
    p_task_id BIGINT,
    p_prerequisite_task_id BIGINT
) RETURNS BOOLEAN AS $$
DECLARE
    v_has_cycle BOOLEAN;
BEGIN
    IF p_task_id = p_prerequisite_task_id THEN
        RETURN TRUE;
    END IF;

    WITH RECURSIVE dependency_path AS (
        SELECT
            p_prerequisite_task_id AS task_id,
            ARRAY[p_prerequisite_task_id]::BIGINT[] AS path
        UNION ALL
        SELECT
            td.prerequisite_task_id AS task_id,
            dependency_path.path || td.prerequisite_task_id
        FROM task_dependencies td
        JOIN dependency_path
            ON td.task_id = dependency_path.task_id
        WHERE NOT td.prerequisite_task_id = ANY(dependency_path.path)
    )
    SELECT EXISTS (
        SELECT 1
        FROM dependency_path
        WHERE task_id = p_task_id
    )
    INTO v_has_cycle;

    RETURN COALESCE(v_has_cycle, FALSE);
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION auto_fail_dependent_tasks(
    p_prerequisite_task_id BIGINT,
    p_reason TEXT DEFAULT NULL
) RETURNS INTEGER AS $$
DECLARE
    v_failed_count INTEGER;
    v_prerequisite_uuid UUID;
    v_reason TEXT;
BEGIN
    SELECT task_uuid
    INTO v_prerequisite_uuid
    FROM task_queue
    WHERE id = p_prerequisite_task_id;

    IF v_prerequisite_uuid IS NULL THEN
        RETURN 0;
    END IF;

    v_reason := COALESCE(
        p_reason,
        format(
            'Dependency failure: prerequisite task %s failed',
            v_prerequisite_uuid::TEXT
        )
    );

    UPDATE task_queue dependent
    SET
        status = 'failed',
        last_error = v_reason,
        error_count = dependent.error_count + 1,
        lease_expires_at = NULL,
        updated_at = NOW()
    FROM task_dependencies td
    WHERE td.prerequisite_task_id = p_prerequisite_task_id
      AND dependent.id = td.task_id
      AND dependent.status IN ('pending', 'retrying', 'scheduled');

    GET DIAGNOSTICS v_failed_count = ROW_COUNT;
    RETURN v_failed_count;
END;
$$ LANGUAGE plpgsql;


-- ============================================
-- 4. DEPENDENCY API FUNCTIONS
-- ============================================

CREATE OR REPLACE FUNCTION add_task_dependency(
    p_api_key TEXT,
    p_task_uuid UUID,
    p_prerequisite_task_uuid UUID
) RETURNS BOOLEAN AS $$
DECLARE
    v_worker_id VARCHAR;
    v_task_id BIGINT;
    v_prerequisite_task_id BIGINT;
    v_prerequisite_status task_status;
    v_inserted_count INTEGER;
BEGIN
    v_worker_id := validate_worker_auth(p_api_key);
    PERFORM check_rate_limit(v_worker_id, 'dependency_add', 10000, 60);

    SELECT id
    INTO v_task_id
    FROM task_queue
    WHERE task_uuid = p_task_uuid;

    IF v_task_id IS NULL THEN
        RAISE EXCEPTION 'Task not found for task_uuid: %', p_task_uuid;
    END IF;

    SELECT id, status
    INTO v_prerequisite_task_id, v_prerequisite_status
    FROM task_queue
    WHERE task_uuid = p_prerequisite_task_uuid;

    IF v_prerequisite_task_id IS NULL THEN
        RAISE EXCEPTION 'Prerequisite task not found for task_uuid: %', p_prerequisite_task_uuid;
    END IF;

    IF v_task_id = v_prerequisite_task_id THEN
        RAISE EXCEPTION 'Task cannot depend on itself (%).', p_task_uuid;
    END IF;

    IF task_dependency_creates_cycle(v_task_id, v_prerequisite_task_id) THEN
        RAISE EXCEPTION
            'Dependency cycle detected: task % cannot depend on task %.',
            p_task_uuid, p_prerequisite_task_uuid;
    END IF;

    INSERT INTO task_dependencies (task_id, prerequisite_task_id)
    VALUES (v_task_id, v_prerequisite_task_id)
    ON CONFLICT (task_id, prerequisite_task_id) DO NOTHING;

    GET DIAGNOSTICS v_inserted_count = ROW_COUNT;

    IF v_prerequisite_status = 'failed' THEN
        PERFORM auto_fail_dependent_tasks(
            v_prerequisite_task_id,
            format(
                'Dependency failure: prerequisite task %s already failed',
                p_prerequisite_task_uuid::TEXT
            )
        );
    END IF;

    RETURN (v_inserted_count > 0);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


CREATE OR REPLACE FUNCTION add_task_dependencies(
    p_api_key TEXT,
    p_task_uuid UUID,
    p_prerequisite_task_uuids UUID[]
) RETURNS INTEGER AS $$
DECLARE
    v_worker_id VARCHAR;
    v_task_id BIGINT;
    v_unique_prerequisites UUID[];
    v_prerequisite_uuid UUID;
    v_prerequisite_task_id BIGINT;
    v_prerequisite_status task_status;
    v_missing_prerequisites TEXT;
    v_inserted_count INTEGER;
    v_failed_prerequisite_ids BIGINT[] := ARRAY[]::BIGINT[];
BEGIN
    v_worker_id := validate_worker_auth(p_api_key);
    PERFORM check_rate_limit(v_worker_id, 'dependency_add_batch', 10000, 60);

    SELECT id
    INTO v_task_id
    FROM task_queue
    WHERE task_uuid = p_task_uuid;

    IF v_task_id IS NULL THEN
        RAISE EXCEPTION 'Task not found for task_uuid: %', p_task_uuid;
    END IF;

    IF p_prerequisite_task_uuids IS NULL OR array_length(p_prerequisite_task_uuids, 1) IS NULL THEN
        RETURN 0;
    END IF;

    SELECT ARRAY(
        SELECT DISTINCT dep_uuid
        FROM unnest(p_prerequisite_task_uuids) dep_uuid
        WHERE dep_uuid IS NOT NULL
    )
    INTO v_unique_prerequisites;

    IF array_length(v_unique_prerequisites, 1) IS NULL THEN
        RETURN 0;
    END IF;

    IF p_task_uuid = ANY(v_unique_prerequisites) THEN
        RAISE EXCEPTION 'Task cannot depend on itself (%).', p_task_uuid;
    END IF;

    WITH input_uuids AS (
        SELECT unnest(v_unique_prerequisites) AS dep_uuid
    )
    SELECT string_agg(input_uuids.dep_uuid::TEXT, ', ')
    INTO v_missing_prerequisites
    FROM input_uuids
    LEFT JOIN task_queue tq
        ON tq.task_uuid = input_uuids.dep_uuid
    WHERE tq.id IS NULL;

    IF v_missing_prerequisites IS NOT NULL THEN
        RAISE EXCEPTION 'Prerequisite task(s) not found: %', v_missing_prerequisites;
    END IF;

    FOREACH v_prerequisite_uuid IN ARRAY v_unique_prerequisites
    LOOP
        SELECT id, status
        INTO v_prerequisite_task_id, v_prerequisite_status
        FROM task_queue
        WHERE task_uuid = v_prerequisite_uuid;

        IF task_dependency_creates_cycle(v_task_id, v_prerequisite_task_id) THEN
            RAISE EXCEPTION
                'Dependency cycle detected: task % cannot depend on task %.',
                p_task_uuid, v_prerequisite_uuid;
        END IF;

        IF v_prerequisite_status = 'failed' THEN
            v_failed_prerequisite_ids := array_append(v_failed_prerequisite_ids, v_prerequisite_task_id);
        END IF;
    END LOOP;

    INSERT INTO task_dependencies (task_id, prerequisite_task_id)
    SELECT
        v_task_id,
        tq.id
    FROM (
        SELECT unnest(v_unique_prerequisites) AS dep_uuid
    ) input_uuids
    JOIN task_queue tq
        ON tq.task_uuid = input_uuids.dep_uuid
    ON CONFLICT (task_id, prerequisite_task_id) DO NOTHING;

    GET DIAGNOSTICS v_inserted_count = ROW_COUNT;

    IF array_length(v_failed_prerequisite_ids, 1) IS NOT NULL THEN
        FOREACH v_prerequisite_task_id IN ARRAY v_failed_prerequisite_ids
        LOOP
            SELECT task_uuid
            INTO v_prerequisite_uuid
            FROM task_queue
            WHERE id = v_prerequisite_task_id;

            PERFORM auto_fail_dependent_tasks(
                v_prerequisite_task_id,
                format(
                    'Dependency failure: prerequisite task %s already failed',
                    v_prerequisite_uuid::TEXT
                )
            );
        END LOOP;
    END IF;

    RETURN v_inserted_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


CREATE OR REPLACE FUNCTION remove_task_dependency(
    p_api_key TEXT,
    p_task_uuid UUID,
    p_prerequisite_task_uuid UUID
) RETURNS BOOLEAN AS $$
DECLARE
    v_worker_id VARCHAR;
    v_task_id BIGINT;
    v_prerequisite_task_id BIGINT;
BEGIN
    v_worker_id := validate_worker_auth(p_api_key);
    PERFORM check_rate_limit(v_worker_id, 'dependency_remove', 10000, 60);

    SELECT id
    INTO v_task_id
    FROM task_queue
    WHERE task_uuid = p_task_uuid;

    IF v_task_id IS NULL THEN
        RAISE EXCEPTION 'Task not found for task_uuid: %', p_task_uuid;
    END IF;

    SELECT id
    INTO v_prerequisite_task_id
    FROM task_queue
    WHERE task_uuid = p_prerequisite_task_uuid;

    IF v_prerequisite_task_id IS NULL THEN
        RAISE EXCEPTION 'Prerequisite task not found for task_uuid: %', p_prerequisite_task_uuid;
    END IF;

    DELETE FROM task_dependencies
    WHERE task_id = v_task_id
      AND prerequisite_task_id = v_prerequisite_task_id;

    RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


CREATE OR REPLACE FUNCTION get_task_dependencies(
    p_api_key TEXT,
    p_task_uuid UUID
) RETURNS TABLE (
    prerequisite_task_uuid UUID,
    prerequisite_status task_status,
    created_at TIMESTAMPTZ
) AS $$
DECLARE
    v_worker_id VARCHAR;
    v_task_id BIGINT;
BEGIN
    v_worker_id := validate_worker_auth(p_api_key);
    PERFORM check_rate_limit(v_worker_id, 'dependency_get', 10000, 60);

    SELECT id
    INTO v_task_id
    FROM task_queue
    WHERE task_uuid = p_task_uuid;

    IF v_task_id IS NULL THEN
        RAISE EXCEPTION 'Task not found for task_uuid: %', p_task_uuid;
    END IF;

    RETURN QUERY
    SELECT
        prereq.task_uuid AS prerequisite_task_uuid,
        prereq.status AS prerequisite_status,
        td.created_at
    FROM task_dependencies td
    JOIN task_queue prereq
        ON prereq.id = td.prerequisite_task_id
    WHERE td.task_id = v_task_id
    ORDER BY td.created_at ASC, prereq.task_uuid ASC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ============================================
-- 5. AUTO-FAIL TRIGGER
-- ============================================

CREATE OR REPLACE FUNCTION propagate_failed_task_dependencies()
RETURNS TRIGGER AS $$
DECLARE
    v_failed_count INTEGER;
    v_reason TEXT;
BEGIN
    v_reason := format(
        'Dependency failure: prerequisite task %s failed (%s)',
        NEW.task_uuid::TEXT,
        COALESCE(NULLIF(NEW.last_error, ''), 'no error details')
    );

    v_failed_count := auto_fail_dependent_tasks(NEW.id, v_reason);

    IF v_failed_count > 0 THEN
        PERFORM log_audit(
            'fail',
            'task',
            NEW.id,
            'system_dependency',
            NULL,
            jsonb_build_object(
                'auto_failed_dependents', v_failed_count,
                'prerequisite_task_uuid', NEW.task_uuid,
                'reason', v_reason
            ),
            TRUE,
            NULL
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_task_dependencies_auto_fail ON task_queue;
CREATE TRIGGER trg_task_dependencies_auto_fail
AFTER UPDATE OF status ON task_queue
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status AND NEW.status = 'failed')
EXECUTE FUNCTION propagate_failed_task_dependencies();


-- ============================================
-- 6. DEQUEUE OVERRIDE WITH DEPENDENCY GATE
-- ============================================

CREATE OR REPLACE FUNCTION dequeue_task(
    p_api_key TEXT,
    p_lease_duration INTERVAL DEFAULT '5 minutes',
    p_queue_names VARCHAR[] DEFAULT ARRAY['default']
) RETURNS TABLE (
    task_id BIGINT,
    task_uuid UUID,
    task_name VARCHAR,
    task_data JSONB,
    attempts INTEGER,
    max_attempts INTEGER,
    queue_name VARCHAR
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
        AND t.queue_name = ANY(v_allowed_queues)
        AND (t.worker_id IS NULL OR t.lease_expires_at < NOW())
        AND NOT EXISTS (
            SELECT 1
            FROM task_dependencies td
            JOIN task_queue prereq
                ON prereq.id = td.prerequisite_task_id
            WHERE td.task_id = t.id
              AND prereq.status <> 'completed'
        )
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
                t.queue_name
            FROM task_queue t
            WHERE t.id = v_task_id;
        END IF;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
