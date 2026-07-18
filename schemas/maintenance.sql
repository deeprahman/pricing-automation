-- ============================================================
--  maintenance.sql — Data Lifecycle Management
--  Compatible with: PostgreSQL 13+
--
--  Run AFTER all schema files:
--    1) property_platform_sql.sql
--    2) booking_registers.sql
--    3) secure_task_scheduler.sql
--    4) secure_task_scheduler_metadata.sql
--    5) message_processing.sql
--    6) pricing-engine.sql
--    7) special_operation_assigner_tables.sql
--    8) app_log.sql
--    9) secrets.sql
--
--  Safe to re-run: all CREATE OR REPLACE and IF NOT EXISTS guards.
-- ============================================================


-- ============================================================
-- 0. DEPENDENCY VALIDATION
-- ============================================================

DO $$
DECLARE
    v_missing TEXT := '';
BEGIN
    IF to_regclass('public.app_logs')                IS NULL THEN v_missing := v_missing || ' app_logs'; END IF;
    IF to_regclass('public.messages')                IS NULL THEN v_missing := v_missing || ' messages'; END IF;
    IF to_regclass('public.message_class_lookup')    IS NULL THEN v_missing := v_missing || ' message_class_lookup'; END IF;
    IF to_regclass('public.message_thread_progress') IS NULL THEN v_missing := v_missing || ' message_thread_progress'; END IF;
    IF to_regclass('public.booking_registers')       IS NULL THEN v_missing := v_missing || ' booking_registers'; END IF;
    IF to_regclass('public.booking_applied_rules')   IS NULL THEN v_missing := v_missing || ' booking_applied_rules'; END IF;
    IF to_regclass('public.task_queue')              IS NULL THEN v_missing := v_missing || ' task_queue'; END IF;
    IF to_regclass('public.audit_log')               IS NULL THEN v_missing := v_missing || ' audit_log'; END IF;
    IF to_regclass('public.rate_limits')             IS NULL THEN v_missing := v_missing || ' rate_limits'; END IF;
    IF to_regclass('public.worker_registry')         IS NULL THEN v_missing := v_missing || ' worker_registry'; END IF;
    IF to_regclass('public.worker_api_keys')         IS NULL THEN v_missing := v_missing || ' worker_api_keys'; END IF;

    IF v_missing <> '' THEN
        RAISE EXCEPTION 'maintenance.sql: missing required tables: [%]. Run prerequisite schema files first.', BTRIM(v_missing);
    END IF;
END $$;


-- ============================================================
-- 1. BOOKING REGISTERS ARCHIVE TABLE
--    Created once; used by archive_old_bookings().
--    No FK constraints — intentional, this is cold storage.
-- ============================================================

CREATE TABLE IF NOT EXISTS booking_registers_archive (
    LIKE booking_registers INCLUDING ALL
);

-- Mark archive rows with when they were archived
ALTER TABLE booking_registers_archive
    ADD COLUMN IF NOT EXISTS archived_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- Lightweight index for compliance lookups by departure year
CREATE INDEX IF NOT EXISTS idx_booking_registers_archive_departure
    ON booking_registers_archive (departure DESC);

CREATE INDEX IF NOT EXISTS idx_booking_registers_archive_platform
    ON booking_registers_archive (platform_id, departure DESC);


-- ============================================================
-- 1A. WORKER MANAGER STATE
--    Single-row heartbeat table used by the PWS Admin UI.
--    The worker manager is a supervisor, not a task worker, so it
--    should not be counted inside worker_registry active workers.
-- ============================================================

CREATE TABLE IF NOT EXISTS worker_manager_state (
    manager_id                         VARCHAR(100) PRIMARY KEY DEFAULT 'default',
    supervisor_status                  TEXT NOT NULL DEFAULT 'unknown',
    supervisor_pid                     INTEGER,
    supervisor_started_at              TIMESTAMPTZ,
    supervisor_last_seen_at            TIMESTAMPTZ,
    database_available                 BOOLEAN,
    database_error                     TEXT,
    managed_workers_expected           INTEGER NOT NULL DEFAULT 0,
    managed_workers_running            INTEGER NOT NULL DEFAULT 0,
    managed_worker_names               JSONB NOT NULL DEFAULT '[]'::JSONB,
    started_workers                    JSONB NOT NULL DEFAULT '[]'::JSONB,
    stopped_workers                    JSONB NOT NULL DEFAULT '[]'::JSONB,
    seed_check_interval_seconds        INTEGER,
    last_seed_check_at                 TIMESTAMPTZ,
    last_seed_success                  BOOLEAN,
    last_seed_error                    TEXT,
    maintenance_enabled                BOOLEAN,
    maintenance_status                 TEXT NOT NULL DEFAULT 'unknown',
    maintenance_pid                    INTEGER,
    maintenance_started_at             TIMESTAMPTZ,
    maintenance_last_seen_at           TIMESTAMPTZ,
    maintenance_interval_seconds       INTEGER,
    maintenance_action_count           INTEGER NOT NULL DEFAULT 0,
    maintenance_actions                JSONB NOT NULL DEFAULT '[]'::JSONB,
    last_promote_count                 INTEGER,
    last_reset_count                   INTEGER,
    last_maintenance_action_at         TIMESTAMPTZ,
    last_maintenance_action_name       TEXT,
    last_maintenance_action_success    BOOLEAN,
    last_maintenance_action_rows       BIGINT,
    last_maintenance_action_duration_seconds NUMERIC,
    last_maintenance_action_error      TEXT,
    last_maintenance_loop_error        TEXT,
    manifest_path                      TEXT,
    db_name                            TEXT,
    log_dir                            TEXT,
    created_at                         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_worker_manager_state_supervisor_seen
    ON worker_manager_state (supervisor_last_seen_at DESC);

CREATE INDEX IF NOT EXISTS idx_worker_manager_state_maintenance_seen
    ON worker_manager_state (maintenance_last_seen_at DESC);

COMMENT ON TABLE worker_manager_state IS
'Latest worker-manager supervisor and maintenance heartbeat for the admin UI. '
'This table intentionally records the manager outside worker_registry.';


-- ============================================================
-- 2. MONITORING VIEW
--    Tracks live / dead row counts and total table size for
--    every high-churn table. Query this to detect bloat early.
-- ============================================================

CREATE OR REPLACE VIEW table_growth_monitor AS
SELECT
    s.schemaname,
    s.relname                                                          AS tablename,
    pg_size_pretty(pg_total_relation_size(format('%I.%I', s.schemaname, s.relname)::REGCLASS)) AS total_size,
    pg_total_relation_size(format('%I.%I', s.schemaname, s.relname)::REGCLASS) AS total_size_bytes,
    s.n_live_tup                                                       AS live_rows,
    s.n_dead_tup                                                       AS dead_rows,
    CASE
        WHEN s.n_live_tup > 0
        THEN ROUND(100.0 * s.n_dead_tup / (s.n_live_tup + s.n_dead_tup), 1)
        ELSE 0
    END                                                                AS dead_row_pct,
    s.last_autovacuum,
    s.last_autoanalyze
FROM pg_stat_user_tables s
WHERE s.relname IN (
    'app_logs',
    'messages',
    'message_class_lookup',
    'message_thread_progress',
    'task_queue',
    'task_metadata_history',
    'audit_log',
    'rate_limits',
    'booking_registers',
    'booking_registers_archive',
    'booking_applied_rules',
    'calculated_prices',
    'llm_model_usage',
    'worker_registry',
    'worker_api_keys',
    'worker_metadata',
    'worker_manager_state'
)
ORDER BY pg_total_relation_size(format('%I.%I', s.schemaname, s.relname)::REGCLASS) DESC;

COMMENT ON VIEW table_growth_monitor IS
'Live row / dead row / size snapshot for all high-churn tables. '
'Dead row pct > 20% with no recent autovacuum = bloat risk.';


-- ============================================================
-- 3. CLEANUP: APP LOGS
--    app_log.sql ships with a commented-out pg_cron schedule.
--    This function is the proper implementation.
--
--    Default retention: 90 days.
--    Batch-deletes to avoid long-running transactions.
-- ============================================================

CREATE OR REPLACE FUNCTION cleanup_app_logs(
    p_older_than  INTERVAL DEFAULT '90 days',
    p_batch_size  INT      DEFAULT 5000
) RETURNS BIGINT AS $$
DECLARE
    v_deleted      BIGINT := 0;
    v_batch        BIGINT;
    v_cutoff       TIMESTAMPTZ;
BEGIN
    IF p_older_than < INTERVAL '1 day' THEN
        RAISE EXCEPTION 'cleanup_app_logs: retention must be at least 1 day';
    END IF;

    IF p_batch_size < 1 OR p_batch_size > 50000 THEN
        RAISE EXCEPTION 'cleanup_app_logs: batch_size must be between 1 and 50000';
    END IF;

    v_cutoff := NOW() - p_older_than;

    LOOP
        WITH del AS (
            DELETE FROM app_logs
            WHERE id IN (
                SELECT id FROM app_logs
                WHERE created_at < v_cutoff
                ORDER BY created_at ASC
                LIMIT p_batch_size
            )
            RETURNING 1
        )
        SELECT COUNT(*) INTO v_batch FROM del;

        v_deleted := v_deleted + v_batch;
        EXIT WHEN v_batch < p_batch_size;
        PERFORM pg_sleep(0.05);
    END LOOP;

    RETURN v_deleted;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION cleanup_app_logs(INTERVAL, INT) IS
'Hard-deletes app_logs rows older than p_older_than. '
'Runs in batches to avoid locking pressure. Default: 90 days.';


-- ============================================================
-- 4. CLEANUP: MESSAGES
--    Two-phase cleanup:
--      Phase 1 — Hard-delete soft-deleted messages past grace period.
--      Phase 2 — Hard-delete very old active messages (archive phase).
--      Phase 3 — Orphaned thread progress rows (no remaining messages
--                 in the thread on that platform).
--
--    message_class_lookup rows cascade via FK when a message is deleted.
-- ============================================================

CREATE OR REPLACE FUNCTION cleanup_old_messages(
    p_soft_deleted_grace  INTERVAL DEFAULT '30 days',
    p_active_retention    INTERVAL DEFAULT '2 years',
    p_batch_size          INT      DEFAULT 2000
) RETURNS TABLE (
    deleted_soft_messages   BIGINT,
    deleted_active_messages BIGINT,
    deleted_thread_progress BIGINT
) AS $$
DECLARE
    v_soft_cutoff    TIMESTAMPTZ;
    v_active_cutoff  TIMESTAMPTZ;
    v_soft_deleted   BIGINT := 0;
    v_active_deleted BIGINT := 0;
    v_progress_del   BIGINT := 0;
    v_batch          BIGINT;
BEGIN
    IF p_soft_deleted_grace < INTERVAL '1 day' THEN
        RAISE EXCEPTION 'cleanup_old_messages: soft_deleted_grace must be at least 1 day';
    END IF;

    IF p_active_retention < INTERVAL '90 days' THEN
        RAISE EXCEPTION 'cleanup_old_messages: active_retention must be at least 90 days';
    END IF;

    IF p_batch_size < 1 OR p_batch_size > 50000 THEN
        RAISE EXCEPTION 'cleanup_old_messages: batch_size must be between 1 and 50000';
    END IF;

    v_soft_cutoff   := NOW() - p_soft_deleted_grace;
    v_active_cutoff := NOW() - p_active_retention;

    -- Phase 1: soft-deleted messages past grace period
    -- message_class_lookup cascades on DELETE via FK
    LOOP
        WITH del AS (
            DELETE FROM messages
            WHERE id IN (
                SELECT id FROM messages
                WHERE deleted_at IS NOT NULL
                  AND deleted_at < v_soft_cutoff
                ORDER BY deleted_at ASC
                LIMIT p_batch_size
            )
            RETURNING 1
        )
        SELECT COUNT(*) INTO v_batch FROM del;

        v_soft_deleted := v_soft_deleted + v_batch;
        EXIT WHEN v_batch < p_batch_size;
        PERFORM pg_sleep(0.05);
    END LOOP;

    -- Phase 2: very old active messages (configurable, default 2 years)
    LOOP
        WITH del AS (
            DELETE FROM messages
            WHERE id IN (
                SELECT id FROM messages
                WHERE deleted_at IS NULL
                  AND created_at < v_active_cutoff
                ORDER BY created_at ASC
                LIMIT p_batch_size
            )
            RETURNING 1
        )
        SELECT COUNT(*) INTO v_batch FROM del;

        v_active_deleted := v_active_deleted + v_batch;
        EXIT WHEN v_batch < p_batch_size;
        PERFORM pg_sleep(0.05);
    END LOOP;

    -- Phase 3: orphaned thread progress rows where no messages remain
    WITH del AS (
        DELETE FROM message_thread_progress mtp
        WHERE NOT EXISTS (
            SELECT 1 FROM messages m
            WHERE m.platform_id = mtp.platform_id
              AND m.thread_id   = mtp.thread_id
        )
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_progress_del FROM del;

    RETURN QUERY SELECT v_soft_deleted, v_active_deleted, v_progress_del;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION cleanup_old_messages(INTERVAL, INTERVAL, INT) IS
'Phase 1: hard-deletes soft-deleted messages past grace period (default 30 d). '
'Phase 2: hard-deletes active messages older than active_retention (default 2 yr). '
'Phase 3: removes orphaned message_thread_progress rows. '
'message_class_lookup FK cascades automatically.';


-- ============================================================
-- 5. ARCHIVE: BOOKING REGISTERS
--    Bookings must NOT be hard-deleted — they carry tax and
--    regulatory value (typically 7 years in most jurisdictions).
--
--    This function moves old bookings into booking_registers_archive
--    and removes them from the hot table.
--    Safe to re-run: ON CONFLICT DO NOTHING prevents double-archiving.
-- ============================================================

CREATE OR REPLACE FUNCTION archive_old_bookings(
    p_older_than  INTERVAL DEFAULT '7 years',
    p_batch_size  INT      DEFAULT 500
) RETURNS BIGINT AS $$
DECLARE
    v_archived   BIGINT := 0;
    v_batch      BIGINT;
    v_cutoff     DATE;
BEGIN
    IF p_older_than < INTERVAL '1 year' THEN
        RAISE EXCEPTION 'archive_old_bookings: retention must be at least 1 year';
    END IF;

    IF p_batch_size < 1 OR p_batch_size > 50000 THEN
        RAISE EXCEPTION 'archive_old_bookings: batch_size must be between 1 and 50000';
    END IF;

    v_cutoff := (CURRENT_DATE - p_older_than)::DATE;

    LOOP
        WITH candidates AS (
            SELECT id FROM booking_registers
            WHERE departure < v_cutoff
            ORDER BY departure ASC, id ASC
            LIMIT p_batch_size
        ),
        archived AS (
            INSERT INTO booking_registers_archive
            SELECT br.*, NOW() AS archived_at
            FROM booking_registers br
            JOIN candidates c ON c.id = br.id
            ON CONFLICT DO NOTHING
            RETURNING id
        ),
        deleted AS (
            DELETE FROM booking_registers
            WHERE id IN (SELECT id FROM archived)
            RETURNING 1
        )
        SELECT COUNT(*) INTO v_batch FROM deleted;

        v_archived := v_archived + v_batch;
        EXIT WHEN v_batch < p_batch_size;
        PERFORM pg_sleep(0.1);
    END LOOP;

    RETURN v_archived;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION archive_old_bookings(INTERVAL, INT) IS
'Moves booking_registers rows older than p_older_than into booking_registers_archive. '
'Does NOT hard-delete — regulatory / tax retention requires archival. '
'Default cutoff: 7 years before current date.';


-- ============================================================
-- 6. CLEANUP: BOOKING APPLIED RULES
--    booking_applied_rules accumulates every pricing instruction
--    ever sent. Once status = ''removed'' and removed_at is old,
--    there is no operational need to keep the row.
-- ============================================================

CREATE OR REPLACE FUNCTION cleanup_removed_applied_rules(
    p_older_than  INTERVAL DEFAULT '1 year',
    p_batch_size  INT      DEFAULT 2000
) RETURNS BIGINT AS $$
DECLARE
    v_deleted  BIGINT := 0;
    v_batch    BIGINT;
    v_cutoff   TIMESTAMPTZ;
BEGIN
    IF p_older_than < INTERVAL '30 days' THEN
        RAISE EXCEPTION 'cleanup_removed_applied_rules: retention must be at least 30 days';
    END IF;

    IF p_batch_size < 1 OR p_batch_size > 50000 THEN
        RAISE EXCEPTION 'cleanup_removed_applied_rules: batch_size must be between 1 and 50000';
    END IF;

    v_cutoff := NOW() - p_older_than;

    LOOP
        WITH del AS (
            DELETE FROM booking_applied_rules
            WHERE id IN (
                SELECT id FROM booking_applied_rules
                WHERE status = 'removed'
                  AND removed_at IS NOT NULL
                  AND removed_at < v_cutoff
                ORDER BY removed_at ASC
                LIMIT p_batch_size
            )
            RETURNING 1
        )
        SELECT COUNT(*) INTO v_batch FROM del;

        v_deleted := v_deleted + v_batch;
        EXIT WHEN v_batch < p_batch_size;
        PERFORM pg_sleep(0.05);
    END LOOP;

    RETURN v_deleted;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION cleanup_removed_applied_rules(INTERVAL, INT) IS
'Hard-deletes booking_applied_rules where status = ''removed'' '
'and removed_at is older than p_older_than. Default: 1 year.';


-- ============================================================
-- 7. CLEANUP: STALE FAILED APPLIED RULES
--    ''failed'' applied rules that are very old serve no
--    purpose and should be purged separately from ''removed''.
-- ============================================================

CREATE OR REPLACE FUNCTION cleanup_failed_applied_rules(
    p_older_than  INTERVAL DEFAULT '90 days',
    p_batch_size  INT      DEFAULT 2000
) RETURNS BIGINT AS $$
DECLARE
    v_deleted  BIGINT := 0;
    v_batch    BIGINT;
    v_cutoff   TIMESTAMPTZ;
BEGIN
    IF p_older_than < INTERVAL '7 days' THEN
        RAISE EXCEPTION 'cleanup_failed_applied_rules: retention must be at least 7 days';
    END IF;

    IF p_batch_size < 1 OR p_batch_size > 50000 THEN
        RAISE EXCEPTION 'cleanup_failed_applied_rules: batch_size must be between 1 and 50000';
    END IF;

    v_cutoff := NOW() - p_older_than;

    LOOP
        WITH del AS (
            DELETE FROM booking_applied_rules
            WHERE id IN (
                SELECT id FROM booking_applied_rules
                WHERE status = 'failed'
                  AND updated_at < v_cutoff
                ORDER BY updated_at ASC
                LIMIT p_batch_size
            )
            RETURNING 1
        )
        SELECT COUNT(*) INTO v_batch FROM del;

        v_deleted := v_deleted + v_batch;
        EXIT WHEN v_batch < p_batch_size;
        PERFORM pg_sleep(0.05);
    END LOOP;

    RETURN v_deleted;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION cleanup_failed_applied_rules(INTERVAL, INT) IS
'Hard-deletes booking_applied_rules where status = ''failed'' '
'and updated_at is older than p_older_than. Default: 90 days.';


-- ============================================================
-- 8. CLEANUP: AUDIT LOG
--    audit_log is append-only and grows quickly during high
--    worker activity. 180-day default is conservative for most
--    ops use-cases; increase for compliance requirements.
-- ============================================================

CREATE OR REPLACE FUNCTION cleanup_audit_log(
    p_older_than  INTERVAL DEFAULT '180 days',
    p_batch_size  INT      DEFAULT 5000
) RETURNS BIGINT AS $$
DECLARE
    v_deleted  BIGINT := 0;
    v_batch    BIGINT;
    v_cutoff   TIMESTAMPTZ;
BEGIN
    IF p_older_than < INTERVAL '7 days' THEN
        RAISE EXCEPTION 'cleanup_audit_log: retention must be at least 7 days';
    END IF;

    IF p_batch_size < 1 OR p_batch_size > 50000 THEN
        RAISE EXCEPTION 'cleanup_audit_log: batch_size must be between 1 and 50000';
    END IF;

    v_cutoff := NOW() - p_older_than;

    LOOP
        WITH del AS (
            DELETE FROM audit_log
            WHERE id IN (
                SELECT id FROM audit_log
                WHERE created_at < v_cutoff
                ORDER BY created_at ASC
                LIMIT p_batch_size
            )
            RETURNING 1
        )
        SELECT COUNT(*) INTO v_batch FROM del;

        v_deleted := v_deleted + v_batch;
        EXIT WHEN v_batch < p_batch_size;
        PERFORM pg_sleep(0.05);
    END LOOP;

    RETURN v_deleted;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION cleanup_audit_log(INTERVAL, INT) IS
'Hard-deletes audit_log rows older than p_older_than. Default: 180 days. '
'Increase retention for SOC 2 / compliance environments.';


-- ============================================================
-- 9. CLEANUP: RATE LIMITS
--    rate_limits is a rolling-window table. Rows outside the
--    largest rate-limit window (typically 60 min) are useless.
--    The inline DELETE in check_rate_limit() already prunes per
--    request but a dedicated daily pass catches stragglers.
-- ============================================================

CREATE OR REPLACE FUNCTION cleanup_rate_limits(
    p_older_than  INTERVAL DEFAULT '2 hours'
) RETURNS BIGINT AS $$
DECLARE
    v_deleted  BIGINT;
BEGIN
    IF p_older_than < INTERVAL '30 minutes' THEN
        RAISE EXCEPTION 'cleanup_rate_limits: retention must be at least 30 minutes';
    END IF;

    DELETE FROM rate_limits
    WHERE window_start < NOW() - p_older_than;

    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    RETURN v_deleted;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION cleanup_rate_limits(INTERVAL) IS
'Hard-deletes rate_limits rows with window_start older than p_older_than. '
'Default: 2 hours. Any row older than the max rate-limit window is dead data.';


-- ============================================================
-- 10. CLEANUP: INACTIVE WORKERS
--    Stale workers and their orphaned API keys are a security
--    hygiene risk. Workers that have not been seen in
--    p_inactive_since and are marked inactive are safe to purge.
--    Active workers are never touched, regardless of last_seen_at.
-- ============================================================

CREATE OR REPLACE FUNCTION cleanup_inactive_workers(
    p_inactive_since  INTERVAL DEFAULT '180 days'
) RETURNS TABLE (
    deleted_workers   BIGINT,
    deleted_api_keys  BIGINT,
    deleted_metadata  BIGINT
) AS $$
DECLARE
    v_workers   BIGINT;
    v_keys      BIGINT;
    v_meta      BIGINT;
    v_cutoff    TIMESTAMPTZ;
    v_ids       BIGINT[];
BEGIN
    IF p_inactive_since < INTERVAL '7 days' THEN
        RAISE EXCEPTION 'cleanup_inactive_workers: inactive_since must be at least 7 days';
    END IF;

    v_cutoff := NOW() - p_inactive_since;

    -- Collect IDs of workers eligible for deletion
    SELECT ARRAY_AGG(id)
    INTO v_ids
    FROM worker_registry
    WHERE is_active = FALSE
      AND last_seen_at < v_cutoff;

    IF v_ids IS NULL OR ARRAY_LENGTH(v_ids, 1) = 0 THEN
        RETURN QUERY SELECT 0::BIGINT, 0::BIGINT, 0::BIGINT;
        RETURN;
    END IF;

    -- Delete worker_metadata (if the extension table exists)
    IF to_regclass('public.worker_metadata') IS NOT NULL THEN
        DELETE FROM worker_metadata
        WHERE worker_id IN (
            SELECT worker_id FROM worker_registry WHERE id = ANY(v_ids)
        );
        GET DIAGNOSTICS v_meta = ROW_COUNT;
    ELSE
        v_meta := 0;
    END IF;

    -- Delete worker_api_keys
    DELETE FROM worker_api_keys
    WHERE worker_id IN (
        SELECT worker_id FROM worker_registry WHERE id = ANY(v_ids)
    );
    GET DIAGNOSTICS v_keys = ROW_COUNT;

    -- Delete worker_registry rows
    DELETE FROM worker_registry WHERE id = ANY(v_ids);
    GET DIAGNOSTICS v_workers = ROW_COUNT;

    RETURN QUERY SELECT v_workers, v_keys, v_meta;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION cleanup_inactive_workers(INTERVAL) IS
'Deletes worker_registry, worker_api_keys and worker_metadata rows '
'for workers where is_active = FALSE and last_seen_at is older than '
'p_inactive_since. Active workers are never deleted. Default: 180 days.';


-- ============================================================
-- 11. CLEANUP: LLM MODEL USAGE
--    llm_model_usage can grow very quickly for high-traffic
--    deployments. Keep recent history for cost monitoring;
--    purge old rows when no longer needed for reporting.
-- ============================================================

CREATE OR REPLACE FUNCTION cleanup_llm_model_usage(
    p_older_than  INTERVAL DEFAULT '90 days',
    p_batch_size  INT      DEFAULT 5000
) RETURNS BIGINT AS $$
DECLARE
    v_deleted  BIGINT := 0;
    v_batch    BIGINT;
    v_cutoff   TIMESTAMPTZ;
BEGIN
    IF to_regclass('public.llm_model_usage') IS NULL THEN
        RETURN 0;
    END IF;

    IF p_older_than < INTERVAL '7 days' THEN
        RAISE EXCEPTION 'cleanup_llm_model_usage: retention must be at least 7 days';
    END IF;

    IF p_batch_size < 1 OR p_batch_size > 50000 THEN
        RAISE EXCEPTION 'cleanup_llm_model_usage: batch_size must be between 1 and 50000';
    END IF;

    v_cutoff := NOW() - p_older_than;

    LOOP
        WITH del AS (
            DELETE FROM llm_model_usage
            WHERE id IN (
                SELECT id FROM llm_model_usage
                WHERE created_at < v_cutoff
                ORDER BY created_at ASC
                LIMIT p_batch_size
            )
            RETURNING 1
        )
        SELECT COUNT(*) INTO v_batch FROM del;

        v_deleted := v_deleted + v_batch;
        EXIT WHEN v_batch < p_batch_size;
        PERFORM pg_sleep(0.05);
    END LOOP;

    RETURN v_deleted;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION cleanup_llm_model_usage(INTERVAL, INT) IS
'Hard-deletes llm_model_usage rows older than p_older_than. '
'Skips gracefully if the table does not exist. Default: 90 days.';


-- ============================================================
-- 12. SMALL SERVER DISK MAINTENANCE
--    Scalar wrapper for worker_manager maintenance.actions.
--    It keeps high-churn tables bounded on small 40 GB servers
--    and returns a single row count for simple logging.
-- ============================================================

CREATE OR REPLACE FUNCTION small_server_disk_maintenance_run()
RETURNS BIGINT AS $$
DECLARE
    v_total BIGINT := 0;
    v_rows  BIGINT := 0;
BEGIN
    v_rows := cleanup_audit_log('7 days'::INTERVAL, 10000);
    v_total := v_total + COALESCE(v_rows, 0);

    v_rows := cleanup_rate_limits('2 hours'::INTERVAL);
    v_total := v_total + COALESCE(v_rows, 0);

    v_rows := cleanup_app_logs('30 days'::INTERVAL, 5000);
    v_total := v_total + COALESCE(v_rows, 0);

    IF to_regclass('public.task_metadata_history') IS NOT NULL THEN
        v_rows := cleanup_task_metadata_history('30 days'::INTERVAL, 5000);
        v_total := v_total + COALESCE(v_rows, 0);
    END IF;

    v_rows := cleanup_old_tasks('14 days'::INTERVAL, 5000);
    v_total := v_total + COALESCE(v_rows, 0);

    SELECT (r.deleted_soft_messages + r.deleted_active_messages + r.deleted_thread_progress)
    INTO v_rows
    FROM cleanup_old_messages('30 days'::INTERVAL, '2 years'::INTERVAL, 2000) r;
    v_total := v_total + COALESCE(v_rows, 0);

    SELECT (r.deleted_workers + r.deleted_api_keys + r.deleted_metadata)
    INTO v_rows
    FROM cleanup_inactive_workers('7 days'::INTERVAL) r;
    v_total := v_total + COALESCE(v_rows, 0);

    v_rows := cleanup_failed_applied_rules('90 days'::INTERVAL, 5000);
    v_total := v_total + COALESCE(v_rows, 0);

    v_rows := cleanup_removed_applied_rules('1 year'::INTERVAL, 5000);
    v_total := v_total + COALESCE(v_rows, 0);

    v_rows := cleanup_llm_model_usage('90 days'::INTERVAL, 5000);
    v_total := v_total + COALESCE(v_rows, 0);

    RETURN v_total;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION small_server_disk_maintenance_run() IS
'Small-server disk guard for worker_manager. Keeps audit_log at 7 days, '
'app_logs and task metadata at 30 days, completed tasks at 14 days, and '
'returns the total number of rows affected.';


-- ============================================================
-- 13. DAILY MAINTENANCE ORCHESTRATOR
--    Single function to call from pg_cron or the task_queue
--    ''maintenance'' queue. Returns one row per job with rows
--    affected so results can be logged to app_logs.
--
--    Calls existing cleanup functions from the core schemas
--    (cleanup_old_tasks, cleanup_task_metadata_history,
--     maintain_price_partitions, cleanup_expired_data,
--     cleanup_expired_nightlyrates_listing) as well as all
--    new functions defined in this file.
-- ============================================================

CREATE OR REPLACE FUNCTION daily_maintenance_run()
RETURNS TABLE (
    job_name       TEXT,
    rows_affected  BIGINT,
    duration_ms    INT,
    error_message  TEXT
) AS $$
DECLARE
    v_start  TIMESTAMPTZ;
    v_rows   BIGINT;
    v_err    TEXT;
BEGIN
    -- ── 1. App logs (90 days) ─────────────────────────────
    v_start := clock_timestamp();
    v_rows  := 0; v_err := NULL;
    BEGIN
        v_rows := cleanup_app_logs('90 days');
    EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
    RETURN QUERY SELECT
        'app_logs'::TEXT,
        v_rows,
        (EXTRACT(EPOCH FROM clock_timestamp() - v_start) * 1000)::INT,
        v_err;

    -- ── 2. Task queue (completed/failed, 30 days) ─────────
    v_start := clock_timestamp();
    v_rows  := 0; v_err := NULL;
    BEGIN
        v_rows := cleanup_old_tasks('30 days', 5000)::BIGINT;
    EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
    RETURN QUERY SELECT
        'task_queue'::TEXT,
        v_rows,
        (EXTRACT(EPOCH FROM clock_timestamp() - v_start) * 1000)::INT,
        v_err;

    -- ── 3. Task metadata history (90 days) ────────────────
    v_start := clock_timestamp();
    v_rows  := 0; v_err := NULL;
    BEGIN
        IF to_regclass('public.task_metadata_history') IS NOT NULL THEN
            v_rows := cleanup_task_metadata_history('90 days', 5000)::BIGINT;
        END IF;
    EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
    RETURN QUERY SELECT
        'task_metadata_history'::TEXT,
        v_rows,
        (EXTRACT(EPOCH FROM clock_timestamp() - v_start) * 1000)::INT,
        v_err;

    -- ── 4. Audit log (180 days) ───────────────────────────
    v_start := clock_timestamp();
    v_rows  := 0; v_err := NULL;
    BEGIN
        v_rows := cleanup_audit_log('180 days');
    EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
    RETURN QUERY SELECT
        'audit_log'::TEXT,
        v_rows,
        (EXTRACT(EPOCH FROM clock_timestamp() - v_start) * 1000)::INT,
        v_err;

    -- ── 5. Rate limits (2 hours) ──────────────────────────
    v_start := clock_timestamp();
    v_rows  := 0; v_err := NULL;
    BEGIN
        v_rows := cleanup_rate_limits('2 hours');
    EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
    RETURN QUERY SELECT
        'rate_limits'::TEXT,
        v_rows,
        (EXTRACT(EPOCH FROM clock_timestamp() - v_start) * 1000)::INT,
        v_err;

    -- ── 6. Messages (soft-deleted grace 30d, active 2yr) ──
    v_start := clock_timestamp();
    v_rows  := 0; v_err := NULL;
    BEGIN
        SELECT (r.deleted_soft_messages + r.deleted_active_messages + r.deleted_thread_progress)
        INTO v_rows
        FROM cleanup_old_messages('30 days', '2 years') r;
    EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
    RETURN QUERY SELECT
        'messages'::TEXT,
        v_rows,
        (EXTRACT(EPOCH FROM clock_timestamp() - v_start) * 1000)::INT,
        v_err;

    -- ── 7. Booking applied rules — removed (1 year) ───────
    v_start := clock_timestamp();
    v_rows  := 0; v_err := NULL;
    BEGIN
        v_rows := cleanup_removed_applied_rules('1 year');
    EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
    RETURN QUERY SELECT
        'applied_rules_removed'::TEXT,
        v_rows,
        (EXTRACT(EPOCH FROM clock_timestamp() - v_start) * 1000)::INT,
        v_err;

    -- ── 8. Booking applied rules — failed (90 days) ───────
    v_start := clock_timestamp();
    v_rows  := 0; v_err := NULL;
    BEGIN
        v_rows := cleanup_failed_applied_rules('90 days');
    EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
    RETURN QUERY SELECT
        'applied_rules_failed'::TEXT,
        v_rows,
        (EXTRACT(EPOCH FROM clock_timestamp() - v_start) * 1000)::INT,
        v_err;

    -- ── 9. LLM model usage (90 days) ──────────────────────
    v_start := clock_timestamp();
    v_rows  := 0; v_err := NULL;
    BEGIN
        v_rows := cleanup_llm_model_usage('90 days');
    EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
    RETURN QUERY SELECT
        'llm_model_usage'::TEXT,
        v_rows,
        (EXTRACT(EPOCH FROM clock_timestamp() - v_start) * 1000)::INT,
        v_err;

    -- ── 10. Inactive workers (180 days) ───────────────────
    v_start := clock_timestamp();
    v_rows  := 0; v_err := NULL;
    BEGIN
        SELECT (r.deleted_workers + r.deleted_api_keys + r.deleted_metadata)
        INTO v_rows
        FROM cleanup_inactive_workers('180 days') r;
    EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
    RETURN QUERY SELECT
        'inactive_workers'::TEXT,
        v_rows,
        (EXTRACT(EPOCH FROM clock_timestamp() - v_start) * 1000)::INT,
        v_err;

    -- ── 11. Nightly rates (90 days) ───────────────────────
    v_start := clock_timestamp();
    v_rows  := 0; v_err := NULL;
    BEGIN
        IF to_regclass('public.nightlyrates_listing') IS NOT NULL THEN
            v_rows := cleanup_expired_nightlyrates_listing(90);
        END IF;
    EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
    RETURN QUERY SELECT
        'nightlyrates_listing'::TEXT,
        v_rows,
        (EXTRACT(EPOCH FROM clock_timestamp() - v_start) * 1000)::INT,
        v_err;

    -- ── 12. Calculated prices — partition maintenance ──────
    v_start := clock_timestamp();
    v_rows  := 0; v_err := NULL;
    BEGIN
        IF to_regclass('public.calculated_prices') IS NOT NULL THEN
            PERFORM maintain_price_partitions();
        END IF;
    EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
    RETURN QUERY SELECT
        'calculated_prices_partitions'::TEXT,
        0::BIGINT,
        (EXTRACT(EPOCH FROM clock_timestamp() - v_start) * 1000)::INT,
        v_err;

    -- ── 13. Expired pricing overrides / iCal events ───────
    v_start := clock_timestamp();
    v_rows  := 0; v_err := NULL;
    BEGIN
        IF to_regclass('public.price_overrides') IS NOT NULL
           AND to_regclass('public.ical_events') IS NOT NULL THEN
            PERFORM cleanup_expired_data();
        END IF;
    EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
    RETURN QUERY SELECT
        'expired_pricing_data'::TEXT,
        0::BIGINT,
        (EXTRACT(EPOCH FROM clock_timestamp() - v_start) * 1000)::INT,
        v_err;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION daily_maintenance_run() IS
'Orchestrates all daily cleanup and archival jobs. '
'Returns one result row per job with rows_affected, duration_ms, and any error_message. '
'Each job runs in an independent exception block so one failure cannot abort the rest. '
'Call via pg_cron or enqueue a recurring task in the maintenance queue.';


-- ============================================================
-- 14. MONTHLY MAINTENANCE ORCHESTRATOR
--    Runs heavier, less frequent operations:
--      - Booking archive (7-year cutoff)
--    Separate from daily_maintenance_run to avoid unexpected
--    long-running transactions in the nightly window.
-- ============================================================

CREATE OR REPLACE FUNCTION monthly_maintenance_run()
RETURNS TABLE (
    job_name       TEXT,
    rows_affected  BIGINT,
    duration_ms    INT,
    error_message  TEXT
) AS $$
DECLARE
    v_start  TIMESTAMPTZ;
    v_rows   BIGINT;
    v_err    TEXT;
BEGIN
    -- ── 1. Archive old bookings (7 years) ─────────────────
    v_start := clock_timestamp();
    v_rows  := 0; v_err := NULL;
    BEGIN
        v_rows := archive_old_bookings('7 years', 200);
    EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
    RETURN QUERY SELECT
        'booking_registers_archive'::TEXT,
        v_rows,
        (EXTRACT(EPOCH FROM clock_timestamp() - v_start) * 1000)::INT,
        v_err;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION monthly_maintenance_run() IS
'Heavy monthly maintenance: archives booking_registers rows older than 7 years. '
'Kept separate from daily_maintenance_run to avoid long-running nightly jobs.';


-- ============================================================
-- 15. SCHEDULE SETUP VIA pg_cron (OPTIONAL)
--    Mirrors the pattern used by ensure_nightlyrates_listing_cleanup_schedule().
--    Call once after deployment. Safe to call again (re-registers the job).
--    Has no effect if pg_cron is not installed — logs a NOTICE instead.
-- ============================================================

CREATE OR REPLACE FUNCTION ensure_daily_maintenance_schedule(
    p_job_name  TEXT    DEFAULT 'daily-maintenance-run',
    p_cron      TEXT    DEFAULT '0 3 * * *'
) RETURNS TEXT AS $$
DECLARE
    v_job_id  BIGINT;
BEGIN
    IF to_regclass('cron.job') IS NULL THEN
        RETURN 'pg_cron extension is not installed; daily maintenance schedule not created. '
               'Call daily_maintenance_run() manually or via your task scheduler.';
    END IF;

    -- Remove previous registration if it exists
    EXECUTE 'SELECT jobid FROM cron.job WHERE jobname = $1 LIMIT 1'
    INTO v_job_id
    USING p_job_name;

    IF v_job_id IS NOT NULL THEN
        EXECUTE 'SELECT cron.unschedule($1::bigint)' USING v_job_id;
    END IF;

    EXECUTE format(
        'SELECT cron.schedule($1, $2, %L)',
        'SELECT daily_maintenance_run()'
    )
    INTO v_job_id
    USING p_job_name, p_cron;

    RETURN format('scheduled %s at "%s" (job id %s)', p_job_name, p_cron, v_job_id);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION ensure_monthly_maintenance_schedule(
    p_job_name  TEXT    DEFAULT 'monthly-maintenance-run',
    p_cron      TEXT    DEFAULT '0 4 1 * *'
) RETURNS TEXT AS $$
DECLARE
    v_job_id  BIGINT;
BEGIN
    IF to_regclass('cron.job') IS NULL THEN
        RETURN 'pg_cron extension is not installed; monthly maintenance schedule not created.';
    END IF;

    EXECUTE 'SELECT jobid FROM cron.job WHERE jobname = $1 LIMIT 1'
    INTO v_job_id
    USING p_job_name;

    IF v_job_id IS NOT NULL THEN
        EXECUTE 'SELECT cron.unschedule($1::bigint)' USING v_job_id;
    END IF;

    EXECUTE format(
        'SELECT cron.schedule($1, $2, %L)',
        'SELECT monthly_maintenance_run()'
    )
    INTO v_job_id
    USING p_job_name, p_cron;

    RETURN format('scheduled %s at "%s" (job id %s)', p_job_name, p_cron, v_job_id);
END;
$$ LANGUAGE plpgsql;

-- Attempt to register schedules on install; silently skip if pg_cron is absent
DO $$
BEGIN
    PERFORM ensure_daily_maintenance_schedule();
    PERFORM ensure_monthly_maintenance_schedule();
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'maintenance.sql: schedule registration skipped: %', SQLERRM;
END $$;


-- ============================================================
-- 15. ALTERNATIVE: TASK QUEUE INTEGRATION
--    If you prefer to drive maintenance via the existing task
--    scheduler rather than pg_cron, enqueue a recurring task
--    in the ''maintenance'' queue using the API key of a
--    maintenance worker.
--
--    Example (run manually after registering a maintenance worker):
--
--    SELECT enqueue_task(
--        'sk_<your_maintenance_worker_api_key>',
--        'daily_maintenance_run',
--        '{}'::JSONB,
--        'recurring',
--        50,
--        NOW(),
--        1,
--        'daily',
--        'maintenance',
--        '03:00:00'::TIME,
--        'UTC'
--    );
-- ============================================================


-- ============================================================
-- 16. VERIFICATION
-- ============================================================

DO $$
DECLARE
    v_missing_fn TEXT := '';
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'cleanup_app_logs')               THEN v_missing_fn := v_missing_fn || ' cleanup_app_logs'; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'cleanup_old_messages')            THEN v_missing_fn := v_missing_fn || ' cleanup_old_messages'; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'archive_old_bookings')            THEN v_missing_fn := v_missing_fn || ' archive_old_bookings'; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'cleanup_removed_applied_rules')   THEN v_missing_fn := v_missing_fn || ' cleanup_removed_applied_rules'; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'cleanup_failed_applied_rules')    THEN v_missing_fn := v_missing_fn || ' cleanup_failed_applied_rules'; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'cleanup_audit_log')               THEN v_missing_fn := v_missing_fn || ' cleanup_audit_log'; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'cleanup_rate_limits')             THEN v_missing_fn := v_missing_fn || ' cleanup_rate_limits'; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'cleanup_inactive_workers')        THEN v_missing_fn := v_missing_fn || ' cleanup_inactive_workers'; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'cleanup_llm_model_usage')         THEN v_missing_fn := v_missing_fn || ' cleanup_llm_model_usage'; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'small_server_disk_maintenance_run') THEN v_missing_fn := v_missing_fn || ' small_server_disk_maintenance_run'; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'daily_maintenance_run')           THEN v_missing_fn := v_missing_fn || ' daily_maintenance_run'; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'monthly_maintenance_run')         THEN v_missing_fn := v_missing_fn || ' monthly_maintenance_run'; END IF;

    IF to_regclass('public.booking_registers_archive') IS NULL THEN
        v_missing_fn := v_missing_fn || ' booking_registers_archive(table)';
    END IF;

    IF to_regclass('public.table_growth_monitor') IS NULL THEN
        v_missing_fn := v_missing_fn || ' table_growth_monitor(view)';
    END IF;

    IF v_missing_fn <> '' THEN
        RAISE EXCEPTION 'maintenance.sql verification FAILED — missing: [%]', BTRIM(v_missing_fn);
    END IF;

    RAISE NOTICE 'maintenance.sql installed successfully ✓';
END $$;
