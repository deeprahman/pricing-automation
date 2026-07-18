-- ============================================================================
-- INTEGRATED PRICING RULE ENGINE - PRODUCTION VERSION 3.0
-- ============================================================================
-- Purpose: Dynamic pricing rule engine integrated with property/platform system
-- Improvements from v2.1:
--   + Calendar/availability sync (iCal)
--   + Gap day detection & pricing
--   + Partitioned price caching
--   + Set-based batch operations
--   + Auto cache invalidation
--   + Configuration management
--   + Performance monitoring
-- Integration Points:
--   - Uses property_platform_sql.sql: Platforms, Properties, Platform_Property_Lookup
--   - Uses secure_task_scheduler.sql: Worker auth, audit logging, task queuing
-- ============================================================================

-- Enable necessary extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "btree_gist";

-- ============================================================================
-- 1. CONFIGURATION TABLE (NEW - from Doc 4)
-- ============================================================================

DROP TABLE IF EXISTS pricing_config CASCADE;
CREATE TABLE pricing_config (
    key VARCHAR(100) PRIMARY KEY,
    value TEXT NOT NULL,
    value_type VARCHAR(20) DEFAULT 'string' CHECK (
        value_type IN ('string', 'integer', 'decimal', 'boolean', 'json')
    ),
    description TEXT,
    category VARCHAR(50) DEFAULT 'general',
    updated_by VARCHAR(100),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT valid_config_key CHECK (key ~ '^[a-z_]+$')
);

-- Default configuration
INSERT INTO pricing_config (key, value, value_type, description, category) VALUES
    ('cache_duration_minutes', '60', 'integer', 'Price cache validity duration', 'performance'),
    ('gap_threshold_days', '3', 'integer', 'Minimum gap length for long gap classification', 'gap_pricing'),
    ('last_minute_days', '7', 'integer', 'Days threshold for last-minute classification', 'gap_pricing'),
    ('max_calculation_range_days', '365', 'integer', 'Maximum date range for batch calculations', 'limits'),
    ('enable_auto_cache_invalidation', 'true', 'boolean', 'Enable automatic cache invalidation', 'performance'),
    ('batch_size_limit', '1000', 'integer', 'Maximum batch size for operations', 'limits'),
    ('partition_retention_days', '90', 'integer', 'Days to retain old partitions', 'maintenance'),
    ('default_min_price', '50', 'decimal', 'Global minimum price floor', 'pricing'),
    ('default_max_price', '9999', 'decimal', 'Global maximum price ceiling', 'pricing')
ON CONFLICT (key) DO NOTHING;

CREATE INDEX idx_pricing_config_category ON pricing_config(category);

-- ============================================================================
-- 2. ENUMERATIONS (Enhanced from Doc 3)
-- ============================================================================

DROP TYPE IF EXISTS rule_status CASCADE;
CREATE TYPE rule_status AS ENUM (
    'active',
    'inactive',
    'scheduled',
    'expired',
    'archived'
);

DROP TYPE IF EXISTS operation_category CASCADE;
CREATE TYPE operation_category AS ENUM (
    'pricing',
    'availability',
    'length_of_stay',
    'restriction',
    'gap_discount'  -- NEW
);

DROP TYPE IF EXISTS amount_type CASCADE;
CREATE TYPE amount_type AS ENUM (
    'percentage',
    'flat',
    'multiplier',
    'fixed'
);

DROP TYPE IF EXISTS rule_audit_operation CASCADE;
CREATE TYPE rule_audit_operation AS ENUM (
    'create',
    'update',
    'delete',
    'activate',
    'deactivate',
    'apply',
    'conflict_resolve',
    'cache_invalidate'  -- NEW
);

DROP TYPE IF EXISTS booking_status CASCADE;
CREATE TYPE booking_status AS ENUM (
    'BOOKED',
    'BLOCKED',
    'AVAILABLE',
    'OWNER_HOLD'
);

-- ============================================================================
-- 3. OPERATION REGISTRY (From Doc 3)
-- ============================================================================

DROP TABLE IF EXISTS pricing_operation_types CASCADE;
CREATE TABLE pricing_operation_types (
    id BIGSERIAL PRIMARY KEY,
    operation_code VARCHAR(50) UNIQUE NOT NULL,
    operation_name VARCHAR(255) NOT NULL,
    category operation_category NOT NULL,
    description TEXT,
    default_config JSONB DEFAULT '{}'::JSONB,
    validation_schema JSONB,
    execution_weight INTEGER DEFAULT 50,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT valid_operation_code CHECK (operation_code ~ '^[a-z_]+$'),
    CONSTRAINT valid_execution_weight CHECK (execution_weight >= 0 AND execution_weight <= 100)
);

-- Insert standard operations (enhanced with gap pricing)
INSERT INTO pricing_operation_types (operation_code, operation_name, category, description, execution_weight) VALUES
('increase', 'Price Increase', 'pricing', 'Increase base price', 50),
('decrease', 'Price Decrease', 'pricing', 'Decrease base price', 50),
('set', 'Price Set', 'pricing', 'Set absolute price', 90),
('remove_overrides', 'Remove Overrides', 'pricing', 'Clear all price overrides', 100),
('min_price', 'Set Minimum Price', 'pricing', 'Enforce minimum price threshold', 80),
('max_price', 'Set Maximum Price', 'pricing', 'Enforce maximum price threshold', 80),
('multiplier', 'Apply Multiplier', 'pricing', 'Apply multiplicative factor', 60),
('min_stay', 'Minimum Stay', 'length_of_stay', 'Set minimum stay requirement', 50),
('max_stay', 'Maximum Stay', 'length_of_stay', 'Set maximum stay requirement', 50),
('close_dates', 'Close Dates', 'availability', 'Block specific dates', 70),
('open_dates', 'Open Dates', 'availability', 'Unblock specific dates', 70),
('gap_discount', 'Gap Day Discount', 'gap_discount', 'Discount for orphan dates', 85),
('last_minute_discount', 'Last Minute Discount', 'gap_discount', 'Discount for imminent dates', 85)
ON CONFLICT (operation_code) DO NOTHING;

CREATE INDEX idx_pricing_operation_types_category 
ON pricing_operation_types(category, is_active) 
WHERE is_active = TRUE;

-- ============================================================================
-- 4. CALENDAR & AVAILABILITY (NEW - from Doc 4)
-- ============================================================================

-- iCal events/bookings table
DROP TABLE IF EXISTS ical_events CASCADE;
CREATE TABLE ical_events (
    id BIGSERIAL PRIMARY KEY,
    property_id BIGINT NOT NULL REFERENCES Properties(id) ON DELETE CASCADE,
    platform_id BIGINT NOT NULL REFERENCES Platforms(id) ON DELETE CASCADE,
    
    event_uid TEXT NOT NULL,
    start_date DATE NOT NULL,
    end_date DATE NOT NULL,
    status booking_status NOT NULL DEFAULT 'BLOCKED',
    
    -- iCal metadata
    ical_source TEXT,
    summary TEXT,
    description TEXT,
    ical_fetched_at TIMESTAMPTZ DEFAULT NOW(),
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    CONSTRAINT valid_date_range CHECK (end_date > start_date),
    UNIQUE(property_id, platform_id, event_uid),
    
    -- Prevent overlapping BOOKED/BLOCKED events
    EXCLUDE USING gist (
        property_id WITH =,
        platform_id WITH =,
        daterange(start_date, end_date, '[)') WITH &&
    ) WHERE (status IN ('BOOKED', 'BLOCKED', 'OWNER_HOLD'))
);

CREATE INDEX idx_ical_events_property_platform ON ical_events(property_id, platform_id);
CREATE INDEX idx_ical_events_date_range ON ical_events USING gist(daterange(start_date, end_date, '[)'));
CREATE INDEX idx_ical_events_status ON ical_events(status) WHERE status IN ('BOOKED', 'BLOCKED');
CREATE INDEX idx_ical_events_uid ON ical_events(event_uid);
CREATE INDEX idx_ical_events_property_date ON ical_events(property_id, platform_id, start_date, end_date);

-- Gap days calculation table
DROP TABLE IF EXISTS gap_days CASCADE;
CREATE TABLE gap_days (
    id BIGSERIAL PRIMARY KEY,
    property_id BIGINT NOT NULL REFERENCES Properties(id) ON DELETE CASCADE,
    platform_id BIGINT NOT NULL REFERENCES Platforms(id) ON DELETE CASCADE,
    
    gap_date DATE NOT NULL,
    preceding_booking_end DATE,
    following_booking_start DATE,
    gap_length INTEGER,
    gap_position INTEGER,  -- Position within gap (1 = first day, etc.)
    days_until_gap INTEGER,
    
    -- Classification
    is_last_minute BOOLEAN DEFAULT FALSE,
    is_long_gap BOOLEAN DEFAULT FALSE,
    is_weekend_gap BOOLEAN DEFAULT FALSE,
    
    calculated_at TIMESTAMPTZ DEFAULT NOW(),
    
    UNIQUE(property_id, platform_id, gap_date),
    CONSTRAINT valid_gap_length CHECK (gap_length > 0)
);

CREATE INDEX idx_gap_days_property_platform ON gap_days(property_id, platform_id, gap_date);
CREATE INDEX idx_gap_days_length ON gap_days(gap_length) WHERE gap_length > 0;
CREATE INDEX idx_gap_days_last_minute ON gap_days(property_id, platform_id) WHERE is_last_minute = TRUE;
CREATE INDEX idx_gap_days_long_gap ON gap_days(property_id, platform_id) WHERE is_long_gap = TRUE;

-- ============================================================================
-- 5. PRICING RULES (Enhanced from Doc 3)
-- ============================================================================

DROP TABLE IF EXISTS pricing_rules CASCADE;
CREATE TABLE pricing_rules (
    id BIGSERIAL PRIMARY KEY,
    rule_uuid UUID DEFAULT uuid_generate_v4() UNIQUE NOT NULL,
    
    -- Integration with property/platform system
    property_id BIGINT REFERENCES Properties(id) ON DELETE CASCADE,
    platform_id BIGINT REFERENCES Platforms(id) ON DELETE CASCADE,
    platform_property_lookup_id BIGINT REFERENCES platform_property_lookup(id) ON DELETE RESTRICT,
    
    -- Operation reference
    operation_id BIGINT NOT NULL REFERENCES pricing_operation_types(id) ON DELETE RESTRICT,
    
    -- Rule configuration (JSONB for flexibility)
    rule_config JSONB NOT NULL DEFAULT '{}'::JSONB,
    
    -- Date handling
    applicable_dates JSONB,
    start_date DATE,
    end_date DATE,
    day_of_week_pattern INTEGER,
    
    -- Rule metadata
    rule_name VARCHAR(255),
    rule_description TEXT,
    priority INTEGER DEFAULT 50,
    status rule_status DEFAULT 'active',
    
    -- Conflict resolution
    allow_override BOOLEAN DEFAULT TRUE,
    requires_approval BOOLEAN DEFAULT FALSE,
    approved_by VARCHAR(100),
    approved_at TIMESTAMPTZ,
    
    -- Scope hierarchy: listing -> property -> platform -> global
    scope VARCHAR(20) GENERATED ALWAYS AS (
        CASE 
            WHEN platform_property_lookup_id IS NOT NULL THEN 'listing'
            WHEN property_id IS NOT NULL THEN 'property'
            WHEN platform_id IS NOT NULL THEN 'platform'
            ELSE 'global'
        END
    ) STORED,
    
    -- Worker/API authentication
    created_by VARCHAR(100),
    created_via VARCHAR(50),
    
    -- Statistics
    applied_count INTEGER DEFAULT 0,
    last_applied_at TIMESTAMPTZ,
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    activated_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ,
    
    CONSTRAINT valid_priority CHECK (priority >= 0 AND priority <= 100),
    CONSTRAINT valid_date_scope CHECK (
        (applicable_dates IS NOT NULL) OR 
        (start_date IS NOT NULL AND end_date IS NOT NULL) OR
        (day_of_week_pattern IS NOT NULL)
    ),
    CONSTRAINT valid_date_range CHECK (
        start_date IS NULL OR end_date IS NULL OR start_date <= end_date
    ),
    CONSTRAINT valid_day_pattern CHECK (
        day_of_week_pattern IS NULL OR 
        (day_of_week_pattern >= 0 AND day_of_week_pattern <= 127)
    ),
    CONSTRAINT valid_approval CHECK (
        NOT requires_approval OR 
        (approved_by IS NOT NULL AND approved_at IS NOT NULL) OR
        status != 'active'
    ),
    CONSTRAINT valid_scope_hierarchy CHECK (
        -- Listing
        (
            platform_property_lookup_id IS NOT NULL
            AND property_id IS NULL
            AND platform_id IS NULL
        ) OR
        -- Property (can optionally narrow to a platform)
        (
            property_id IS NOT NULL
            AND platform_property_lookup_id IS NULL
        ) OR
        -- Platform
        (
            platform_id IS NOT NULL
            AND property_id IS NULL
            AND platform_property_lookup_id IS NULL
        ) OR
        -- Global
        (
            property_id IS NULL
            AND platform_id IS NULL
            AND platform_property_lookup_id IS NULL
        )
    )
);

-- Optimized indexes
CREATE INDEX idx_pricing_rules_property_platform 
ON pricing_rules(property_id, platform_id, status, priority DESC)
WHERE status = 'active';

CREATE INDEX idx_pricing_rules_scope 
ON pricing_rules(scope, priority DESC, id ASC)
WHERE status = 'active';

CREATE INDEX idx_pricing_rules_listing
ON pricing_rules(platform_property_lookup_id, status, priority DESC)
WHERE status = 'active' AND platform_property_lookup_id IS NOT NULL;

CREATE INDEX idx_pricing_rules_operation 
ON pricing_rules(operation_id, status, priority DESC)
WHERE status = 'active';

CREATE INDEX idx_pricing_rules_uuid ON pricing_rules(rule_uuid);

CREATE INDEX idx_pricing_rules_date_range 
ON pricing_rules(start_date, end_date, status)
WHERE status = 'active' AND start_date IS NOT NULL;

CREATE INDEX idx_pricing_rules_config ON pricing_rules USING GIN(rule_config);
CREATE INDEX idx_pricing_rules_dates ON pricing_rules USING GIN(applicable_dates);

CREATE INDEX idx_pricing_rules_dow_pattern 
ON pricing_rules(day_of_week_pattern)
WHERE day_of_week_pattern IS NOT NULL AND status = 'active';

-- ============================================================================
-- 6. PRICE OVERRIDES (NEW - from Doc 4)
-- ============================================================================

DROP TABLE IF EXISTS price_overrides CASCADE;
CREATE TABLE price_overrides (
    id BIGSERIAL PRIMARY KEY,
    property_id BIGINT NOT NULL REFERENCES Properties(id) ON DELETE CASCADE,
    platform_id BIGINT NOT NULL REFERENCES Platforms(id) ON DELETE CASCADE,
    
    date DATE NOT NULL,
    price NUMERIC(10,2) NOT NULL,
    
    override_type VARCHAR(20) DEFAULT 'manual' CHECK (
        override_type IN ('manual', 'automatic', 'api', 'worker')
    ),
    reason TEXT,
    applied_by VARCHAR(100),
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    expires_at TIMESTAMPTZ,
    is_active BOOLEAN DEFAULT TRUE,
    
    UNIQUE(property_id, platform_id, date),
    CONSTRAINT valid_override_price CHECK (price >= 0)
);

CREATE INDEX idx_price_overrides_property_platform_date 
ON price_overrides(property_id, platform_id, date) 
WHERE is_active = TRUE;

CREATE INDEX idx_price_overrides_expires 
ON price_overrides(expires_at) 
WHERE expires_at IS NOT NULL AND is_active = TRUE;

-- ============================================================================
-- 7. CALCULATED PRICES CACHE (NEW - Partitioned from Doc 4)
-- ============================================================================

DROP TABLE IF EXISTS calculated_prices CASCADE;
CREATE TABLE calculated_prices (
    id BIGSERIAL,
    property_id BIGINT NOT NULL REFERENCES Properties(id) ON DELETE CASCADE,
    platform_id BIGINT NOT NULL REFERENCES Platforms(id) ON DELETE CASCADE,
    platform_property_lookup_id BIGINT REFERENCES platform_property_lookup(id) ON DELETE CASCADE,
    date DATE NOT NULL,
    
    -- Price components
    base_price NUMERIC(10,2) NOT NULL,
    rule_adjustments NUMERIC(10,2) DEFAULT 0,
    override_adjustment NUMERIC(10,2) DEFAULT 0,
    final_price NUMERIC(10,2) NOT NULL,
    
    -- Applied rules (array of rule UUIDs)
    applied_rules JSONB DEFAULT '[]'::JSONB,
    applied_rule_count INTEGER DEFAULT 0,
    
    -- Gap day info
    is_gap_day BOOLEAN DEFAULT FALSE,
    gap_length INTEGER,
    gap_discount_applied NUMERIC(10,2) DEFAULT 0,
    
    -- Availability
    is_available BOOLEAN NOT NULL,
    min_stay_required INTEGER,
    max_stay_allowed INTEGER,
    
    -- Cache management
    calculated_at TIMESTAMPTZ DEFAULT NOW(),
    valid_until TIMESTAMPTZ,
    is_valid BOOLEAN DEFAULT TRUE,
    calculation_time_ms INTEGER,
    
    CONSTRAINT valid_final_price CHECK (final_price >= 0),
    PRIMARY KEY (property_id, platform_id, date, id)
) PARTITION BY RANGE (date);

-- Create partitions for next 12 months
DO $$
DECLARE
    start_date DATE;
    end_date DATE;
    partition_name TEXT;
BEGIN
    FOR i IN 0..11 LOOP
        start_date := DATE_TRUNC('month', CURRENT_DATE + (i || ' months')::INTERVAL)::DATE;
        end_date := start_date + INTERVAL '1 month';
        partition_name := 'calculated_prices_' || TO_CHAR(start_date, 'YYYY_MM');
        
        EXECUTE format('
            CREATE TABLE IF NOT EXISTS %I PARTITION OF calculated_prices
            FOR VALUES FROM (%L) TO (%L)',
            partition_name, start_date, end_date
        );
    END LOOP;
END $$;

CREATE INDEX idx_calculated_prices_property_platform_range 
ON calculated_prices(property_id, platform_id, date);

CREATE INDEX idx_calculated_prices_property_platform_listing_range
ON calculated_prices(property_id, platform_id, platform_property_lookup_id, date)
WHERE platform_property_lookup_id IS NOT NULL;

CREATE INDEX idx_calculated_prices_availability 
ON calculated_prices(property_id, platform_id, date, is_available) 
WHERE is_available = TRUE;

CREATE INDEX idx_calculated_prices_validity 
ON calculated_prices(valid_until, is_valid) 
WHERE is_valid = TRUE;

CREATE INDEX idx_calculated_prices_invalid 
ON calculated_prices(property_id, platform_id) 
WHERE is_valid = FALSE;

CREATE INDEX idx_calculated_prices_gap_days 
ON calculated_prices(property_id, platform_id, date) 
WHERE is_gap_day = TRUE;

-- ============================================================================
-- 8. AUDIT & OPERATIONS (Enhanced from both docs)
-- ============================================================================

DROP TABLE IF EXISTS pricing_rule_audit CASCADE;
CREATE TABLE pricing_rule_audit (
    id BIGSERIAL PRIMARY KEY,
    rule_id BIGINT REFERENCES pricing_rules(id) ON DELETE SET NULL,
    rule_uuid UUID,
    
    operation rule_audit_operation NOT NULL,
    
    actor_id VARCHAR(100),
    actor_type VARCHAR(50) CHECK (actor_type IN ('worker', 'admin', 'user', 'system')),
    
    old_values JSONB,
    new_values JSONB,
    
    ip_address INET,
    user_agent TEXT,
    api_key_prefix VARCHAR(10),
    
    success BOOLEAN DEFAULT TRUE,
    error_message TEXT,
    
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_pricing_rule_audit_rule ON pricing_rule_audit(rule_id, created_at DESC);
CREATE INDEX idx_pricing_rule_audit_uuid ON pricing_rule_audit(rule_uuid, created_at DESC);
CREATE INDEX idx_pricing_rule_audit_actor ON pricing_rule_audit(actor_id, created_at DESC);
CREATE INDEX idx_pricing_rule_audit_operation ON pricing_rule_audit(operation, created_at DESC);

-- Operations log (from Doc 4)
DROP TABLE IF EXISTS pricing_operations CASCADE;
CREATE TABLE pricing_operations (
    id BIGSERIAL PRIMARY KEY,
    operation_uuid UUID DEFAULT uuid_generate_v4(),
    
    property_id BIGINT REFERENCES Properties(id) ON DELETE SET NULL,
    platform_id BIGINT REFERENCES Platforms(id) ON DELETE SET NULL,
    
    operation_type VARCHAR(50) NOT NULL,
    parameters JSONB,
    result JSONB,
    
    executed_by VARCHAR(100),
    status VARCHAR(20) DEFAULT 'completed' CHECK (
        status IN ('pending', 'running', 'completed', 'failed', 'cancelled')
    ),
    
    error_message TEXT,
    execution_time_ms INTEGER,
    rows_affected INTEGER,
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    completed_at TIMESTAMPTZ
);

CREATE INDEX idx_pricing_operations_type ON pricing_operations(operation_type, created_at DESC);
CREATE INDEX idx_pricing_operations_property ON pricing_operations(property_id, created_at DESC);
CREATE INDEX idx_pricing_operations_status ON pricing_operations(status) WHERE status != 'completed';

-- Rule execution history (from Doc 3)
DROP TABLE IF EXISTS pricing_rule_executions CASCADE;
CREATE TABLE pricing_rule_executions (
    id BIGSERIAL PRIMARY KEY,
    
    rule_id BIGINT REFERENCES pricing_rules(id) ON DELETE CASCADE,
    property_id BIGINT REFERENCES Properties(id) ON DELETE CASCADE,
    platform_id BIGINT REFERENCES Platforms(id) ON DELETE CASCADE,
    
    execution_date DATE NOT NULL,
    executed_at TIMESTAMPTZ DEFAULT NOW(),
    
    input_value NUMERIC(10, 2),
    output_value NUMERIC(10, 2),
    applied_config JSONB,
    
    success BOOLEAN DEFAULT TRUE,
    error_message TEXT,
    
    worker_id VARCHAR(100),
    task_id BIGINT,
    
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_pricing_rule_executions_rule ON pricing_rule_executions(rule_id, execution_date DESC);
CREATE INDEX idx_pricing_rule_executions_property ON pricing_rule_executions(property_id, platform_id, execution_date DESC);
CREATE INDEX idx_pricing_rule_executions_date ON pricing_rule_executions(execution_date DESC);

-- ============================================================================
-- 9. HELPER FUNCTIONS (Enhanced from both docs)
-- ============================================================================

-- Get config value with type casting
CREATE OR REPLACE FUNCTION get_config(
    p_key VARCHAR,
    p_default TEXT DEFAULT NULL
) RETURNS TEXT AS $$
DECLARE
    v_value TEXT;
BEGIN
    SELECT value INTO v_value
    FROM pricing_config
    WHERE key = p_key;
    
    RETURN COALESCE(v_value, p_default);
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION get_config_int(p_key VARCHAR, p_default INTEGER DEFAULT NULL) 
RETURNS INTEGER AS $$
BEGIN
    RETURN COALESCE(get_config(p_key)::INTEGER, p_default);
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION get_config_bool(p_key VARCHAR, p_default BOOLEAN DEFAULT NULL) 
RETURNS BOOLEAN AS $$
BEGIN
    RETURN COALESCE(get_config(p_key)::BOOLEAN, p_default);
END;
$$ LANGUAGE plpgsql STABLE;

-- Audit logging (from Doc 3)
CREATE OR REPLACE FUNCTION log_pricing_rule_audit(
    p_operation rule_audit_operation,
    p_rule_id BIGINT,
    p_rule_uuid UUID,
    p_actor_id VARCHAR,
    p_actor_type VARCHAR DEFAULT 'system',
    p_old_values JSONB DEFAULT NULL,
    p_new_values JSONB DEFAULT NULL,
    p_success BOOLEAN DEFAULT TRUE,
    p_error_message TEXT DEFAULT NULL
) RETURNS VOID AS $$
BEGIN
    INSERT INTO pricing_rule_audit (
        rule_id, rule_uuid, operation, actor_id, actor_type,
        old_values, new_values, success, error_message
    ) VALUES (
        p_rule_id, p_rule_uuid, p_operation, p_actor_id, p_actor_type,
        p_old_values, p_new_values, p_success, p_error_message
    );
END;
$$ LANGUAGE plpgsql;

-- Day-of-week pattern matching (from Doc 4)
CREATE OR REPLACE FUNCTION matches_dow_pattern(
    p_date DATE,
    p_pattern INTEGER
) RETURNS BOOLEAN AS $$
DECLARE
    v_dow INTEGER;
    v_dow_bit INTEGER;
BEGIN
    IF p_pattern IS NULL THEN
        RETURN TRUE;
    END IF;
    
    v_dow := EXTRACT(DOW FROM p_date);
    
    v_dow_bit := CASE 
        WHEN v_dow = 0 THEN 64  -- Sunday
        WHEN v_dow = 1 THEN 1   -- Monday
        WHEN v_dow = 2 THEN 2   -- Tuesday
        WHEN v_dow = 3 THEN 4   -- Wednesday
        WHEN v_dow = 4 THEN 8   -- Thursday
        WHEN v_dow = 5 THEN 16  -- Friday
        WHEN v_dow = 6 THEN 32  -- Saturday
    END;
    
    RETURN (p_pattern & v_dow_bit) > 0;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ============================================================================
-- 10. ICAL & CALENDAR FUNCTIONS (NEW - from Doc 4)
-- ============================================================================

-- Process iCal data
CREATE OR REPLACE FUNCTION process_ical_events(
    p_api_key TEXT,
    p_property_id BIGINT,
    p_platform_id BIGINT,
    p_ical_data TEXT,
    p_source_name TEXT DEFAULT 'ical_sync'
) RETURNS JSONB AS $$
DECLARE
    v_worker_id VARCHAR;
    v_event RECORD;
    v_inserted_count INTEGER := 0;
    v_updated_count INTEGER := 0;
    v_ical_lines TEXT[];
    v_current_line TEXT;
    v_event_data JSONB := '{}';
    v_in_event BOOLEAN := FALSE;
    v_start_time TIMESTAMPTZ;
    v_operation_id BIGINT;
BEGIN
    v_start_time := clock_timestamp();
    
    -- Authenticate
    v_worker_id := validate_worker_auth(p_api_key);
    
    -- Rate limiting
    PERFORM check_rate_limit(v_worker_id, 'ical_sync', 1000, 60);
    
    -- Verify property exists
    IF NOT EXISTS(SELECT 1 FROM Properties WHERE id = p_property_id) THEN
        RAISE EXCEPTION 'Property % not found', p_property_id;
    END IF;
    
    -- Parse iCal data
    v_ical_lines := string_to_array(p_ical_data, E'\n');
    
    FOR i IN 1..array_length(v_ical_lines, 1) LOOP
        v_current_line := trim(v_ical_lines[i]);
        
        IF v_current_line = 'BEGIN:VEVENT' THEN
            v_in_event := TRUE;
            v_event_data := '{}';
        ELSIF v_current_line = 'END:VEVENT' AND v_in_event THEN
            IF v_event_data ? 'DTSTART' AND v_event_data ? 'DTEND' THEN
                INSERT INTO ical_events (
                    property_id,
                    platform_id,
                    event_uid,
                    start_date,
                    end_date,
                    status,
                    summary,
                    description,
                    ical_source
                ) VALUES (
                    p_property_id,
                    p_platform_id,
                    COALESCE(v_event_data->>'UID', gen_random_uuid()::TEXT),
                    (v_event_data->>'DTSTART')::DATE,
                    (v_event_data->>'DTEND')::DATE,
                    CASE 
                        WHEN v_event_data->>'STATUS' = 'CONFIRMED' THEN 'BOOKED'::booking_status
                        ELSE 'BLOCKED'::booking_status
                    END,
                    v_event_data->>'SUMMARY',
                    v_event_data->>'DESCRIPTION',
                    p_source_name
                )
                ON CONFLICT (property_id, platform_id, event_uid)
                DO UPDATE SET
                    start_date = EXCLUDED.start_date,
                    end_date = EXCLUDED.end_date,
                    status = EXCLUDED.status,
                    summary = EXCLUDED.summary,
                    description = EXCLUDED.description,
                    ical_fetched_at = NOW(),
                    updated_at = NOW()
                RETURNING (xmax = 0) INTO v_in_event;
                
                IF v_in_event THEN
                    v_inserted_count := v_inserted_count + 1;
                ELSE
                    v_updated_count := v_updated_count + 1;
                END IF;
            END IF;
            v_in_event := FALSE;
        ELSIF v_in_event THEN
            IF position(':' in v_current_line) > 0 THEN
                v_event_data := v_event_data || jsonb_build_object(
                    split_part(v_current_line, ':', 1),
                    substring(v_current_line from position(':' in v_current_line) + 1)
                );
            END IF;
        END IF;
    END LOOP;
    
    -- Log operation
    INSERT INTO pricing_operations (
        property_id,
        platform_id,
        operation_type,
        parameters,
        result,
        executed_by,
        status,
        execution_time_ms,
        rows_affected,
        completed_at
    ) VALUES (
        p_property_id,
        p_platform_id,
        'ical_sync',
        jsonb_build_object('source', p_source_name),
        jsonb_build_object(
            'inserted', v_inserted_count,
            'updated', v_updated_count
        ),
        v_worker_id,
        'completed',
        EXTRACT(MILLISECONDS FROM clock_timestamp() - v_start_time)::INTEGER,
        v_inserted_count + v_updated_count,
        NOW()
    )
    RETURNING id INTO v_operation_id;
    
    RETURN jsonb_build_object(
        'success', TRUE,
        'inserted', v_inserted_count,
        'updated', v_updated_count,
        'total_events', v_inserted_count + v_updated_count,
        'operation_id', v_operation_id,
        'execution_time_ms', EXTRACT(MILLISECONDS FROM clock_timestamp() - v_start_time)::INTEGER
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Calculate gap days (Optimized from Doc 4)
CREATE OR REPLACE FUNCTION calculate_gap_days(
    p_api_key TEXT,
    p_property_id BIGINT,
    p_platform_id BIGINT,
    p_start_date DATE DEFAULT CURRENT_DATE,
    p_end_date DATE DEFAULT CURRENT_DATE + 365
) RETURNS JSONB AS $$
DECLARE
    v_worker_id VARCHAR;
    v_gap_count INTEGER := 0;
    v_start_time TIMESTAMPTZ;
    v_gap_threshold INTEGER;
    v_last_minute INTEGER;
    v_operation_id BIGINT;
BEGIN
    v_start_time := clock_timestamp();
    
    -- Authenticate
    v_worker_id := validate_worker_auth(p_api_key);
    
    -- Get configuration
    v_gap_threshold := get_config_int('gap_threshold_days', 3);
    v_last_minute := get_config_int('last_minute_days', 7);
    
    -- Delete existing gap days in range
    DELETE FROM gap_days 
    WHERE property_id = p_property_id 
    AND platform_id = p_platform_id
    AND gap_date BETWEEN p_start_date AND p_end_date;
    
    -- Optimized gap calculation using window functions
    WITH bookings AS (
        SELECT 
            start_date,
            end_date,
            LEAD(start_date) OVER (ORDER BY start_date) as next_start
        FROM ical_events
        WHERE property_id = p_property_id
        AND platform_id = p_platform_id
        AND status IN ('BOOKED', 'BLOCKED', 'OWNER_HOLD')
        AND start_date <= p_end_date
        AND end_date >= p_start_date
        ORDER BY start_date
    ),
    gaps AS (
        SELECT 
            end_date as gap_start,
            next_start as gap_end,
            next_start - end_date as gap_length
        FROM bookings
        WHERE next_start IS NOT NULL
        AND next_start > end_date
        AND next_start - end_date > 0
    ),
    gap_dates AS (
        SELECT 
            g.gap_start,
            g.gap_end,
            g.gap_length,
            d.gap_date,
            ROW_NUMBER() OVER (PARTITION BY g.gap_start ORDER BY d.gap_date) as gap_position
        FROM gaps g
        CROSS JOIN LATERAL generate_series(g.gap_start, g.gap_end - 1, '1 day'::INTERVAL) AS d(gap_date)
        WHERE d.gap_date::DATE BETWEEN p_start_date AND p_end_date
    )
    INSERT INTO gap_days (
        property_id,
        platform_id,
        gap_date,
        preceding_booking_end,
        following_booking_start,
        gap_length,
        gap_position,
        days_until_gap,
        is_last_minute,
        is_long_gap,
        is_weekend_gap
    )
    SELECT 
        p_property_id,
        p_platform_id,
        gap_date::DATE,
        gap_start,
        gap_end,
        gap_length,
        gap_position::INTEGER,
        gap_date::DATE - CURRENT_DATE,
        (gap_date::DATE - CURRENT_DATE) <= v_last_minute,
        gap_length >= v_gap_threshold,
        EXTRACT(ISODOW FROM gap_date::DATE) IN (6, 7)  -- Saturday or Sunday
    FROM gap_dates;
    
    GET DIAGNOSTICS v_gap_count = ROW_COUNT;
    
    -- Log operation
    INSERT INTO pricing_operations (
        property_id,
        platform_id,
        operation_type,
        parameters,
        result,
        executed_by,
        status,
        execution_time_ms,
        rows_affected,
        completed_at
    ) VALUES (
        p_property_id,
        p_platform_id,
        'gap_calculation',
        jsonb_build_object(
            'start_date', p_start_date,
            'end_date', p_end_date
        ),
        jsonb_build_object(
            'gaps_found', v_gap_count,
            'gap_threshold', v_gap_threshold,
            'last_minute_days', v_last_minute
        ),
        v_worker_id,
        'completed',
        EXTRACT(MILLISECONDS FROM clock_timestamp() - v_start_time)::INTEGER,
        v_gap_count,
        NOW()
    )
    RETURNING id INTO v_operation_id;
    
    RETURN jsonb_build_object(
        'success', TRUE,
        'gaps_found', v_gap_count,
        'date_range', jsonb_build_object('start', p_start_date, 'end', p_end_date),
        'operation_id', v_operation_id,
        'execution_time_ms', EXTRACT(MILLISECONDS FROM clock_timestamp() - v_start_time)::INTEGER
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================
-- 11. RULE MANAGEMENT FUNCTIONS (Enhanced from Doc 3)
-- ============================================================================

-- Create pricing rule with validation
CREATE OR REPLACE FUNCTION create_pricing_rule(
    p_api_key TEXT,
    p_property_id BIGINT,
    p_platform_id BIGINT,
    p_operation_code VARCHAR,
    p_rule_config JSONB,
    p_dates JSONB DEFAULT NULL,
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL,
    p_dow_pattern INTEGER DEFAULT NULL,
    p_priority INTEGER DEFAULT 50,
    p_rule_name VARCHAR DEFAULT NULL,
    p_platform_property_lookup_id BIGINT DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    v_operation_id BIGINT;
    v_rule_uuid UUID;
    v_rule_id BIGINT;
    v_worker_id VARCHAR;
    v_effective_operation_code VARCHAR;
BEGIN
    -- Authenticate
    v_worker_id := validate_worker_auth(p_api_key);
    
    -- Rate limiting
    PERFORM check_rate_limit(v_worker_id, 'create_rule', 100, 60);

    v_effective_operation_code := CASE
        WHEN p_operation_code = 'override' THEN 'set'
        ELSE p_operation_code
    END;
    
    -- Validate operation exists
    SELECT id INTO v_operation_id
    FROM pricing_operation_types
    WHERE operation_code = v_effective_operation_code
    AND is_active = TRUE;
    
    IF v_operation_id IS NULL THEN
        RAISE EXCEPTION 'Invalid operation code: %', p_operation_code;
    END IF;
    
    -- Validate rule config structure
    IF NOT (p_rule_config ? 'subject' AND p_rule_config ? 'operation') THEN
        RAISE EXCEPTION 'Invalid rule_config: must contain "subject" and "operation"';
    END IF;

    IF p_rule_config->'conditions'->'stay_length' IS NOT NULL
       AND jsonb_typeof(p_rule_config->'conditions'->'stay_length') <> 'null' THEN
        IF jsonb_typeof(p_rule_config->'conditions'->'stay_length') <> 'object' THEN
            RAISE EXCEPTION 'conditions.stay_length must be an object';
        END IF;

        IF NOT (
            p_rule_config->'conditions'->'stay_length' ? 'gt' OR
            p_rule_config->'conditions'->'stay_length' ? 'gte' OR
            p_rule_config->'conditions'->'stay_length' ? 'lt' OR
            p_rule_config->'conditions'->'stay_length' ? 'lte' OR
            p_rule_config->'conditions'->'stay_length' ? 'between'
        ) THEN
            RAISE EXCEPTION
                'conditions.stay_length must contain at least one of: gt, gte, lt, lte, between';
        END IF;

        IF p_rule_config->'conditions'->'stay_length'->'between' IS NOT NULL
           AND jsonb_typeof(p_rule_config->'conditions'->'stay_length'->'between') <> 'null' THEN
            IF jsonb_typeof(p_rule_config->'conditions'->'stay_length'->'between') <> 'object'
               OR NOT (
                    p_rule_config->'conditions'->'stay_length'->'between' ? 'min'
                    AND p_rule_config->'conditions'->'stay_length'->'between' ? 'max'
               ) THEN
                RAISE EXCEPTION 'conditions.stay_length.between must contain min and max';
            END IF;
        END IF;
    END IF;

    IF p_rule_config->'conditions'->'booking_class' IS NOT NULL
       AND jsonb_typeof(p_rule_config->'conditions'->'booking_class') <> 'null' THEN
        IF jsonb_typeof(p_rule_config->'conditions'->'booking_class') <> 'object' THEN
            RAISE EXCEPTION 'conditions.booking_class must be an object';
        END IF;
        IF NOT (p_rule_config->'conditions'->'booking_class' ? 'any_of') THEN
            RAISE EXCEPTION 'conditions.booking_class must contain "any_of"';
        END IF;
        IF jsonb_typeof(p_rule_config->'conditions'->'booking_class'->'any_of') <> 'array' THEN
            RAISE EXCEPTION 'conditions.booking_class.any_of must be a non-empty array';
        END IF;
        IF jsonb_array_length(p_rule_config->'conditions'->'booking_class'->'any_of') = 0 THEN
            RAISE EXCEPTION 'conditions.booking_class.any_of must be a non-empty array';
        END IF;
    END IF;

    IF p_rule_config->'apply_window' IS NOT NULL
       AND jsonb_typeof(p_rule_config->'apply_window') <> 'null' THEN
        IF jsonb_typeof(p_rule_config->'apply_window') <> 'object' THEN
            RAISE EXCEPTION 'apply_window must be an object';
        END IF;
        IF NOT (
            p_rule_config->'apply_window' ? 'applies_from'
            AND p_rule_config->'apply_window' ? 'duration_days'
        ) THEN
            RAISE EXCEPTION 'apply_window must contain applies_from and duration_days';
        END IF;
        IF p_rule_config->'apply_window'->>'applies_from' NOT IN ('arrival', 'departure') THEN
            RAISE EXCEPTION 'apply_window.applies_from must be arrival or departure';
        END IF;
        IF (p_rule_config->'apply_window'->>'duration_days')::INT < 1 THEN
            RAISE EXCEPTION 'apply_window.duration_days must be >= 1';
        END IF;
    END IF;
    
    -- Validate date scope
    IF p_dates IS NULL AND p_start_date IS NULL AND p_dow_pattern IS NULL THEN
        RAISE EXCEPTION 'Must specify either applicable_dates, date range, or day-of-week pattern';
    END IF;
    
    -- Validate property/platform exist
    IF p_property_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM Properties WHERE id = p_property_id) THEN
        RAISE EXCEPTION 'Property % not found', p_property_id;
    END IF;
    
    IF p_platform_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM Platforms WHERE id = p_platform_id) THEN
        RAISE EXCEPTION 'Platform % not found', p_platform_id;
    END IF;

    IF p_platform_property_lookup_id IS NOT NULL THEN
        IF p_property_id IS NOT NULL OR p_platform_id IS NOT NULL THEN
            RAISE EXCEPTION
                'Listing-scoped rule requires property_id and platform_id to be NULL';
        END IF;

        IF NOT EXISTS(
            SELECT 1
            FROM platform_property_lookup
            WHERE id = p_platform_property_lookup_id
        ) THEN
            RAISE EXCEPTION 'Platform property lookup % not found', p_platform_property_lookup_id;
        END IF;
    END IF;
    
    v_rule_uuid := uuid_generate_v4();
    
    -- Insert rule
    INSERT INTO pricing_rules (
        rule_uuid,
        property_id,
        platform_id,
        platform_property_lookup_id,
        operation_id,
        rule_config,
        applicable_dates,
        start_date,
        end_date,
        day_of_week_pattern,
        priority,
        rule_name,
        created_by,
        created_via,
        status,
        activated_at
    ) VALUES (
        v_rule_uuid,
        p_property_id,
        p_platform_id,
        p_platform_property_lookup_id,
        v_operation_id,
        p_rule_config,
        p_dates,
        p_start_date,
        p_end_date,
        p_dow_pattern,
        p_priority,
        COALESCE(p_rule_name, 'Rule ' || v_rule_uuid::TEXT),
        v_worker_id,
        'api',
        'active',
        NOW()
    )
    RETURNING id INTO v_rule_id;
    
    -- Audit log
    PERFORM log_pricing_rule_audit(
        'create',
        v_rule_id,
        v_rule_uuid,
        v_worker_id,
        'worker',
        NULL,
        jsonb_build_object(
            'rule_uuid', v_rule_uuid,
            'property_id', p_property_id,
            'platform_id', p_platform_id,
            'platform_property_lookup_id', p_platform_property_lookup_id,
            'operation_code', v_effective_operation_code
        )
    );
    
    RETURN v_rule_uuid;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Bulk remove pricing rules with optional filters (deactivate/delete)
CREATE OR REPLACE FUNCTION remove_pricing_rules(
    p_api_key TEXT,
    p_property_id BIGINT DEFAULT NULL,
    p_platform_id BIGINT DEFAULT NULL,
    p_mode VARCHAR DEFAULT 'deactivate',
    p_statuses rule_status[] DEFAULT NULL,
    p_operation_codes VARCHAR[] DEFAULT NULL,
    p_priority_min INTEGER DEFAULT NULL,
    p_priority_max INTEGER DEFAULT NULL,
    p_created_by VARCHAR DEFAULT NULL,
    p_rule_name_pattern TEXT DEFAULT NULL,
    p_active_from DATE DEFAULT NULL,
    p_active_to DATE DEFAULT NULL,
    p_dry_run BOOLEAN DEFAULT FALSE,
    p_platform_property_lookup_id BIGINT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_worker_id VARCHAR;
    v_mode VARCHAR;
    v_matched_count INTEGER := 0;
    v_affected_count INTEGER := 0;
    v_cache_invalidated INTEGER := 0;
    v_operation_id BIGINT;
    v_start_time TIMESTAMPTZ;
    v_filters JSONB;
    v_lookup_property_id BIGINT;
    v_lookup_platform_id BIGINT;
    v_operation_codes_normalized VARCHAR[];
BEGIN
    v_start_time := clock_timestamp();

    -- Authenticate + throttle
    v_worker_id := validate_worker_auth(p_api_key);
    PERFORM check_rate_limit(v_worker_id, 'remove_rules', 50, 60);

    v_mode := LOWER(COALESCE(TRIM(p_mode), 'deactivate'));
    v_operation_codes_normalized := (
        SELECT CASE
            WHEN p_operation_codes IS NULL THEN NULL
            ELSE ARRAY(
                SELECT CASE
                    WHEN value = 'override' THEN 'set'
                    ELSE value
                END
                FROM unnest(p_operation_codes) AS value
            )
        END
    );

    -- Safety guard: disallow global wipe in this function
    IF p_property_id IS NULL
       AND p_platform_id IS NULL
       AND p_platform_property_lookup_id IS NULL THEN
        RAISE EXCEPTION
            'Must provide at least one of property_id, platform_id, or platform_property_lookup_id';
    END IF;

    IF v_mode NOT IN ('deactivate', 'delete') THEN
        RAISE EXCEPTION 'Invalid mode: % (allowed: deactivate, delete)', p_mode;
    END IF;

    IF p_priority_min IS NOT NULL AND p_priority_max IS NOT NULL AND p_priority_min > p_priority_max THEN
        RAISE EXCEPTION 'Invalid priority range: min (%) cannot be greater than max (%)',
            p_priority_min, p_priority_max;
    END IF;

    IF p_property_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM Properties WHERE id = p_property_id) THEN
        RAISE EXCEPTION 'Property % not found', p_property_id;
    END IF;

    IF p_platform_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM Platforms WHERE id = p_platform_id) THEN
        RAISE EXCEPTION 'Platform % not found', p_platform_id;
    END IF;

    IF p_platform_property_lookup_id IS NOT NULL THEN
        SELECT
            ppl.properties_ptr::BIGINT,
            ppl.platform_id::BIGINT
        INTO
            v_lookup_property_id,
            v_lookup_platform_id
        FROM platform_property_lookup ppl
        WHERE ppl.id = p_platform_property_lookup_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'Platform property lookup % not found', p_platform_property_lookup_id;
        END IF;

        IF p_property_id IS NOT NULL AND p_property_id <> v_lookup_property_id THEN
            RAISE EXCEPTION
                'property_id % does not match lookup % (property_id %)',
                p_property_id, p_platform_property_lookup_id, v_lookup_property_id;
        END IF;

        IF p_platform_id IS NOT NULL AND p_platform_id <> v_lookup_platform_id THEN
            RAISE EXCEPTION
                'platform_id % does not match lookup % (platform_id %)',
                p_platform_id, p_platform_property_lookup_id, v_lookup_platform_id;
        END IF;
    END IF;

    v_filters := jsonb_build_object(
        'statuses', to_jsonb(p_statuses),
        'operation_codes', to_jsonb(v_operation_codes_normalized),
        'priority_min', p_priority_min,
        'priority_max', p_priority_max,
        'created_by', p_created_by,
        'rule_name_pattern', p_rule_name_pattern,
        'active_from', p_active_from,
        'active_to', p_active_to,
        'platform_property_lookup_id', p_platform_property_lookup_id
    );

    -- Dry run: return candidate count only; no rule/cache mutations.
    IF p_dry_run THEN
        SELECT COUNT(*)
        INTO v_matched_count
        FROM pricing_rules pr
        JOIN pricing_operation_types pot ON pot.id = pr.operation_id
        LEFT JOIN platform_property_lookup ppl ON ppl.id = pr.platform_property_lookup_id
        WHERE (p_property_id IS NULL OR COALESCE(pr.property_id, ppl.properties_ptr::BIGINT) = p_property_id)
          AND (p_platform_id IS NULL OR COALESCE(pr.platform_id, ppl.platform_id::BIGINT) = p_platform_id)
          AND (p_platform_property_lookup_id IS NULL OR pr.platform_property_lookup_id = p_platform_property_lookup_id)
          AND (p_statuses IS NULL OR pr.status = ANY(p_statuses))
          AND (v_operation_codes_normalized IS NULL OR CASE WHEN pot.operation_code = 'override' THEN 'set' ELSE pot.operation_code END = ANY(v_operation_codes_normalized))
          AND (p_priority_min IS NULL OR pr.priority >= p_priority_min)
          AND (p_priority_max IS NULL OR pr.priority <= p_priority_max)
          AND (p_created_by IS NULL OR pr.created_by = p_created_by)
          AND (p_rule_name_pattern IS NULL OR pr.rule_name ILIKE p_rule_name_pattern)
          AND (
                (p_active_from IS NULL AND p_active_to IS NULL)
                OR (
                    pr.start_date IS NOT NULL
                    AND pr.end_date IS NOT NULL
                    AND pr.start_date <= COALESCE(p_active_to, 'infinity'::DATE)
                    AND pr.end_date >= COALESCE(p_active_from, '-infinity'::DATE)
                )
              );

        INSERT INTO pricing_operations (
            property_id,
            platform_id,
            operation_type,
            parameters,
            result,
            executed_by,
            status,
            execution_time_ms,
            rows_affected,
            completed_at
        ) VALUES (
            COALESCE(p_property_id, v_lookup_property_id),
            COALESCE(p_platform_id, v_lookup_platform_id),
            format('bulk_rule_%s', v_mode),
            v_filters || jsonb_build_object('dry_run', TRUE),
            jsonb_build_object(
                'matched_count', v_matched_count,
                'affected_count', 0,
                'cache_invalidated', 0
            ),
            v_worker_id,
            'completed',
            EXTRACT(MILLISECONDS FROM clock_timestamp() - v_start_time)::INTEGER,
            0,
            NOW()
        )
        RETURNING id INTO v_operation_id;

        RETURN jsonb_build_object(
            'success', TRUE,
            'dry_run', TRUE,
            'mode', v_mode,
            'property_id', p_property_id,
            'platform_id', p_platform_id,
            'platform_property_lookup_id', p_platform_property_lookup_id,
            'matched_count', v_matched_count,
            'affected_count', 0,
            'cache_invalidated', 0,
            'execution_time_ms', EXTRACT(MILLISECONDS FROM clock_timestamp() - v_start_time)::INTEGER,
            'filters', v_filters
        );
    END IF;

    IF v_mode = 'deactivate' THEN
        WITH matched_rules AS (
            SELECT
                pr.id,
                pr.rule_uuid,
                pr.property_id,
                pr.platform_id,
                pr.platform_property_lookup_id,
                pr.scope,
                pr.start_date,
                pr.end_date
            FROM pricing_rules pr
            JOIN pricing_operation_types pot ON pot.id = pr.operation_id
            LEFT JOIN platform_property_lookup ppl ON ppl.id = pr.platform_property_lookup_id
            WHERE (p_property_id IS NULL OR COALESCE(pr.property_id, ppl.properties_ptr::BIGINT) = p_property_id)
              AND (p_platform_id IS NULL OR COALESCE(pr.platform_id, ppl.platform_id::BIGINT) = p_platform_id)
              AND (p_platform_property_lookup_id IS NULL OR pr.platform_property_lookup_id = p_platform_property_lookup_id)
              AND (p_statuses IS NULL OR pr.status = ANY(p_statuses))
              AND (v_operation_codes_normalized IS NULL OR CASE WHEN pot.operation_code = 'override' THEN 'set' ELSE pot.operation_code END = ANY(v_operation_codes_normalized))
              AND (p_priority_min IS NULL OR pr.priority >= p_priority_min)
              AND (p_priority_max IS NULL OR pr.priority <= p_priority_max)
              AND (p_created_by IS NULL OR pr.created_by = p_created_by)
              AND (p_rule_name_pattern IS NULL OR pr.rule_name ILIKE p_rule_name_pattern)
              AND (
                    (p_active_from IS NULL AND p_active_to IS NULL)
                    OR (
                        pr.start_date IS NOT NULL
                        AND pr.end_date IS NOT NULL
                        AND pr.start_date <= COALESCE(p_active_to, 'infinity'::DATE)
                        AND pr.end_date >= COALESCE(p_active_from, '-infinity'::DATE)
                    )
                  )
        ),
        affected_rules AS (
            UPDATE pricing_rules pr
            SET status = 'inactive'
            FROM matched_rules mr
            WHERE pr.id = mr.id
              AND pr.status <> 'inactive'
            RETURNING
                pr.id,
                pr.rule_uuid,
                pr.property_id,
                pr.platform_id,
                pr.platform_property_lookup_id,
                pr.scope,
                pr.start_date,
                pr.end_date
        ),
        invalidated AS (
            UPDATE calculated_prices cp
            SET is_valid = FALSE
            WHERE cp.is_valid = TRUE
              AND EXISTS (
                    SELECT 1
                    FROM affected_rules ar
                    WHERE (
                            ar.scope = 'global'
                            OR (ar.scope = 'platform' AND cp.platform_id = ar.platform_id)
                            OR (ar.scope = 'property' AND cp.property_id = ar.property_id)
                            OR (
                                ar.scope = 'listing'
                                AND cp.platform_property_lookup_id = ar.platform_property_lookup_id
                            )
                          )
                      AND cp.date BETWEEN COALESCE(ar.start_date, CURRENT_DATE)
                                      AND COALESCE(ar.end_date, (CURRENT_DATE + INTERVAL '1 year')::DATE)
                )
            RETURNING 1
        )
        SELECT
            (SELECT COUNT(*) FROM matched_rules),
            (SELECT COUNT(*) FROM affected_rules),
            (SELECT COUNT(*) FROM invalidated)
        INTO
            v_matched_count,
            v_affected_count,
            v_cache_invalidated;
    ELSE
        WITH matched_rules AS (
            SELECT
                pr.id,
                pr.rule_uuid,
                pr.property_id,
                pr.platform_id,
                pr.platform_property_lookup_id,
                pr.scope,
                pr.start_date,
                pr.end_date
            FROM pricing_rules pr
            JOIN pricing_operation_types pot ON pot.id = pr.operation_id
            LEFT JOIN platform_property_lookup ppl ON ppl.id = pr.platform_property_lookup_id
            WHERE (p_property_id IS NULL OR COALESCE(pr.property_id, ppl.properties_ptr::BIGINT) = p_property_id)
              AND (p_platform_id IS NULL OR COALESCE(pr.platform_id, ppl.platform_id::BIGINT) = p_platform_id)
              AND (p_platform_property_lookup_id IS NULL OR pr.platform_property_lookup_id = p_platform_property_lookup_id)
              AND (p_statuses IS NULL OR pr.status = ANY(p_statuses))
              AND (v_operation_codes_normalized IS NULL OR CASE WHEN pot.operation_code = 'override' THEN 'set' ELSE pot.operation_code END = ANY(v_operation_codes_normalized))
              AND (p_priority_min IS NULL OR pr.priority >= p_priority_min)
              AND (p_priority_max IS NULL OR pr.priority <= p_priority_max)
              AND (p_created_by IS NULL OR pr.created_by = p_created_by)
              AND (p_rule_name_pattern IS NULL OR pr.rule_name ILIKE p_rule_name_pattern)
              AND (
                    (p_active_from IS NULL AND p_active_to IS NULL)
                    OR (
                        pr.start_date IS NOT NULL
                        AND pr.end_date IS NOT NULL
                        AND pr.start_date <= COALESCE(p_active_to, 'infinity'::DATE)
                        AND pr.end_date >= COALESCE(p_active_from, '-infinity'::DATE)
                    )
                  )
        ),
        affected_rules AS (
            DELETE FROM pricing_rules pr
            USING matched_rules mr
            WHERE pr.id = mr.id
            RETURNING
                pr.id,
                pr.rule_uuid,
                pr.property_id,
                pr.platform_id,
                pr.platform_property_lookup_id,
                pr.scope,
                pr.start_date,
                pr.end_date
        ),
        invalidated AS (
            UPDATE calculated_prices cp
            SET is_valid = FALSE
            WHERE cp.is_valid = TRUE
              AND EXISTS (
                    SELECT 1
                    FROM affected_rules ar
                    WHERE (
                            ar.scope = 'global'
                            OR (ar.scope = 'platform' AND cp.platform_id = ar.platform_id)
                            OR (ar.scope = 'property' AND cp.property_id = ar.property_id)
                            OR (
                                ar.scope = 'listing'
                                AND cp.platform_property_lookup_id = ar.platform_property_lookup_id
                            )
                          )
                      AND cp.date BETWEEN COALESCE(ar.start_date, CURRENT_DATE)
                                      AND COALESCE(ar.end_date, (CURRENT_DATE + INTERVAL '1 year')::DATE)
                )
            RETURNING 1
        )
        SELECT
            (SELECT COUNT(*) FROM matched_rules),
            (SELECT COUNT(*) FROM affected_rules),
            (SELECT COUNT(*) FROM invalidated)
        INTO
            v_matched_count,
            v_affected_count,
            v_cache_invalidated;
    END IF;

    INSERT INTO pricing_operations (
        property_id,
        platform_id,
        operation_type,
        parameters,
        result,
        executed_by,
        status,
        execution_time_ms,
        rows_affected,
        completed_at
    ) VALUES (
        COALESCE(p_property_id, v_lookup_property_id),
        COALESCE(p_platform_id, v_lookup_platform_id),
        format('bulk_rule_%s', v_mode),
        v_filters || jsonb_build_object('dry_run', FALSE),
        jsonb_build_object(
            'matched_count', v_matched_count,
            'affected_count', v_affected_count,
            'cache_invalidated', v_cache_invalidated
        ),
        v_worker_id,
        'completed',
        EXTRACT(MILLISECONDS FROM clock_timestamp() - v_start_time)::INTEGER,
        v_affected_count,
        NOW()
    )
    RETURNING id INTO v_operation_id;

    RETURN jsonb_build_object(
        'success', TRUE,
        'dry_run', FALSE,
        'mode', v_mode,
        'property_id', p_property_id,
        'platform_id', p_platform_id,
        'platform_property_lookup_id', p_platform_property_lookup_id,
        'matched_count', v_matched_count,
        'affected_count', v_affected_count,
        'cache_invalidated', v_cache_invalidated,
        'execution_time_ms', EXTRACT(MILLISECONDS FROM clock_timestamp() - v_start_time)::INTEGER,
        'filters', v_filters
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP FUNCTION IF EXISTS get_applicable_pricing_rules(BIGINT, BIGINT, DATE, VARCHAR, BOOLEAN, BIGINT);

-- Get applicable rules (Optimized - set based)
CREATE OR REPLACE FUNCTION get_applicable_pricing_rules(
    p_property_id BIGINT,
    p_platform_id BIGINT,
    p_target_date DATE DEFAULT CURRENT_DATE,
    p_operation_code VARCHAR DEFAULT NULL,
    p_check_gaps BOOLEAN DEFAULT TRUE,
    p_platform_property_lookup_id BIGINT DEFAULT NULL,
    p_stay_length INT DEFAULT NULL,
    p_booking_classes TEXT[] DEFAULT NULL
) RETURNS TABLE (
    rule_id BIGINT,
    rule_uuid UUID,
    operation_code VARCHAR,
    operation_category operation_category,
    priority INTEGER,
    scope VARCHAR,
    rule_json JSONB
) AS $$
DECLARE
    v_gap_exists BOOLEAN := FALSE;
    v_is_last_minute BOOLEAN := FALSE;
    v_is_long_gap BOOLEAN := FALSE;
    v_operation_code_normalized VARCHAR;
BEGIN
    v_operation_code_normalized := CASE
        WHEN p_operation_code = 'override' THEN 'set'
        ELSE p_operation_code
    END;
    -- Check if date is a gap day
    IF p_check_gaps THEN
        SELECT 
            TRUE,
            gd.is_last_minute,
            gd.is_long_gap
        INTO 
            v_gap_exists,
            v_is_last_minute,
            v_is_long_gap
        FROM gap_days gd
        WHERE gd.property_id = p_property_id
        AND gd.platform_id = p_platform_id
        AND gd.gap_date = p_target_date;
    END IF;
    
    RETURN QUERY
    WITH ranked_rules AS (
        SELECT 
            pr.id AS rule_id,
            pr.rule_uuid,
            CASE WHEN pot.operation_code = 'override' THEN 'set' ELSE pot.operation_code END AS operation_code,
            pot.category AS operation_category,
            pot.execution_weight,
            pr.priority,
            pr.scope,
            -- Calculate rule score (scope + priority)
            CASE 
                WHEN pr.scope = 'listing' THEN 4000 + pr.priority
                WHEN pr.scope = 'property' THEN 3000 + pr.priority
                WHEN pr.scope = 'platform' THEN 2000 + pr.priority
                ELSE 1000 + pr.priority
            END as rule_score,
            jsonb_build_object(
                'rule_id', pr.id,
                'rule_uuid', pr.rule_uuid,
                'rule_name', pr.rule_name,
                'subject', pr.rule_config->>'subject',
                'operation', pr.rule_config->'operation',
                'rule_config', pr.rule_config,
                'priority', pr.priority,
                'scope', pr.scope,
                'platform_property_lookup_id', pr.platform_property_lookup_id,
                'metadata', pr.rule_config->'metadata'
            ) AS rule_json
        FROM pricing_rules pr
        JOIN pricing_operation_types pot ON pr.operation_id = pot.id
        WHERE pr.status = 'active'
        AND (pr.expires_at IS NULL OR pr.expires_at > NOW())
        AND (v_operation_code_normalized IS NULL OR CASE WHEN pot.operation_code = 'override' THEN 'set' ELSE pot.operation_code END = v_operation_code_normalized)
        
        -- Scope matching
        AND (
            (pr.scope = 'listing'
             AND p_platform_property_lookup_id IS NOT NULL
             AND pr.platform_property_lookup_id = p_platform_property_lookup_id) OR
            pr.scope = 'global' OR
            (pr.scope = 'platform' AND pr.platform_id = p_platform_id) OR
            (pr.scope = 'property' AND pr.property_id = p_property_id)
        )
        
        -- Date matching
        AND (
            -- Discrete dates
            (pr.applicable_dates IS NOT NULL 
             AND pr.applicable_dates ? p_target_date::TEXT)
            OR
            -- Date range
            (pr.start_date IS NOT NULL 
             AND pr.end_date IS NOT NULL
             AND p_target_date BETWEEN pr.start_date AND pr.end_date)
            OR
            -- Day of week pattern
            (pr.day_of_week_pattern IS NOT NULL
             AND matches_dow_pattern(p_target_date, pr.day_of_week_pattern))
        )
        
        -- Gap day conditions
        AND (
            pr.rule_config->'conditions'->'gap_day' IS NULL
            OR
            (v_gap_exists AND (
                (pr.rule_config->'conditions'->'gap_day'->>'is_last_minute' IS NULL
                 OR (pr.rule_config->'conditions'->'gap_day'->>'is_last_minute')::BOOLEAN = v_is_last_minute)
                AND
                (pr.rule_config->'conditions'->'gap_day'->>'is_long_gap' IS NULL
                 OR (pr.rule_config->'conditions'->'gap_day'->>'is_long_gap')::BOOLEAN = v_is_long_gap)
            ))
        )

        -- Stay-length conditions
        AND (
            pr.rule_config->'conditions'->'stay_length' IS NULL
            OR (
                p_stay_length IS NOT NULL
                AND (
                    pr.rule_config->'conditions'->'stay_length'->>'gt' IS NULL
                    OR p_stay_length > (pr.rule_config->'conditions'->'stay_length'->>'gt')::INT
                )
                AND (
                    pr.rule_config->'conditions'->'stay_length'->>'gte' IS NULL
                    OR p_stay_length >= (pr.rule_config->'conditions'->'stay_length'->>'gte')::INT
                )
                AND (
                    pr.rule_config->'conditions'->'stay_length'->>'lt' IS NULL
                    OR p_stay_length < (pr.rule_config->'conditions'->'stay_length'->>'lt')::INT
                )
                AND (
                    pr.rule_config->'conditions'->'stay_length'->>'lte' IS NULL
                    OR p_stay_length <= (pr.rule_config->'conditions'->'stay_length'->>'lte')::INT
                )
                AND (
                    pr.rule_config->'conditions'->'stay_length'->'between' IS NULL
                    OR (
                        p_stay_length >= (pr.rule_config->'conditions'->'stay_length'->'between'->>'min')::INT
                        AND p_stay_length <= (pr.rule_config->'conditions'->'stay_length'->'between'->>'max')::INT
                    )
                )
            )
        )

        -- Booking-class conditions
        AND (
            pr.rule_config->'conditions'->'booking_class'->'any_of' IS NULL
            OR (
                p_booking_classes IS NOT NULL
                AND EXISTS (
                    SELECT 1
                    FROM jsonb_array_elements_text(
                        pr.rule_config->'conditions'->'booking_class'->'any_of'
                    ) required_class
                    WHERE required_class = ANY(p_booking_classes)
                )
            )
        )
    )
    SELECT 
        rr.rule_id,
        rr.rule_uuid,
        rr.operation_code,
        rr.operation_category,
        rr.priority,
        rr.scope,
        rr.rule_json
    FROM ranked_rules rr
    ORDER BY rr.rule_score DESC, rr.execution_weight DESC, rr.rule_id ASC;
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- 12. PRICE CALCULATION (OPTIMIZED - Set-Based from Doc 4)
-- ============================================================================

-- Single date price calculation with caching
CREATE OR REPLACE FUNCTION calculate_daily_price(
    p_api_key TEXT,
    p_property_id BIGINT,
    p_platform_id BIGINT,
    p_date DATE,
    p_base_price NUMERIC DEFAULT NULL,
    p_force_recalculate BOOLEAN DEFAULT FALSE,
    p_platform_property_lookup_id BIGINT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_worker_id VARCHAR;
    v_cached RECORD;
    v_base_price NUMERIC(10,2);
    v_current_price NUMERIC(10,2);
    v_rule RECORD;
    v_applied_rules JSONB := '[]'::JSONB;
    v_rule_count INTEGER := 0;
    v_is_available BOOLEAN;
    v_override_price NUMERIC(10,2);
    v_gap_info RECORD;
    v_cache_duration INTEGER;
    v_start_time TIMESTAMPTZ;
    v_min_price NUMERIC(10,2);
    v_max_price NUMERIC(10,2);
BEGIN
    v_start_time := clock_timestamp();
    
    -- Authenticate
    v_worker_id := validate_worker_auth(p_api_key);
    
    -- Check cache first (unless force recalculate)
    IF NOT p_force_recalculate THEN
        SELECT * INTO v_cached
        FROM calculated_prices
        WHERE property_id = p_property_id
        AND platform_id = p_platform_id
        AND (
            (p_platform_property_lookup_id IS NULL AND platform_property_lookup_id IS NULL)
            OR platform_property_lookup_id = p_platform_property_lookup_id
        )
        AND date = p_date
        AND is_valid = TRUE
        AND valid_until > NOW()
        ORDER BY calculated_at DESC, id DESC
        LIMIT 1;
        
        IF FOUND THEN
            RETURN jsonb_build_object(
                'success', TRUE,
                'cached', TRUE,
                'date', p_date,
                'available', v_cached.is_available,
                'final_price', v_cached.final_price,
                'base_price', v_cached.base_price,
                'applied_rules', v_cached.applied_rules,
                'is_gap_day', v_cached.is_gap_day
            );
        END IF;
    END IF;
    
    -- Check availability
    SELECT NOT EXISTS(
        SELECT 1 FROM ical_events
        WHERE property_id = p_property_id
        AND platform_id = p_platform_id
        AND status IN ('BOOKED', 'BLOCKED', 'OWNER_HOLD')
        AND p_date BETWEEN start_date AND end_date - 1
    ) INTO v_is_available;
    
    IF NOT v_is_available THEN
        RETURN jsonb_build_object(
            'success', TRUE,
            'date', p_date,
            'available', FALSE,
            'final_price', NULL
        );
    END IF;
    
    -- Get base price (use provided or lookup from property metadata)
    v_base_price := COALESCE(
        p_base_price,
        (SELECT (descrp->>'base_price')::NUMERIC FROM Properties WHERE id = p_property_id),
        100.00
    );
    
    v_current_price := v_base_price;
    
    -- Get min/max constraints
    v_min_price := get_config_int('default_min_price', 50)::NUMERIC;
    v_max_price := get_config_int('default_max_price', 9999)::NUMERIC;
    
    -- Apply rules in priority order
    FOR v_rule IN 
        SELECT * FROM get_applicable_pricing_rules(
            p_property_id,
            p_platform_id,
            p_date,
            NULL,
            TRUE,
            p_platform_property_lookup_id
        )
        ORDER BY priority DESC, rule_id ASC
    LOOP
        DECLARE
            v_operation_type TEXT;
            v_amount NUMERIC;
            v_amount_type TEXT;
            v_adjustment NUMERIC := 0;
        BEGIN
            v_operation_type := v_rule.rule_json->'operation'->>'do';
            v_amount := (v_rule.rule_json->'operation'->>'amount')::NUMERIC;
            v_amount_type := v_rule.rule_json->'operation'->>'type';
            
            -- Apply operation
            CASE v_operation_type
                WHEN '+ increase', 'increase' THEN
                    IF v_amount_type IN ('percentage', '%') THEN
                        v_adjustment := v_current_price * (v_amount / 100.0);
                        v_current_price := v_current_price + v_adjustment;
                    ELSE
                        v_adjustment := v_amount;
                        v_current_price := v_current_price + v_amount;
                    END IF;
                
                WHEN '- decrease', 'decrease' THEN
                    IF v_amount_type IN ('percentage', '%') THEN
                        v_adjustment := -(v_current_price * (v_amount / 100.0));
                        v_current_price := v_current_price - (v_current_price * (v_amount / 100.0));
                    ELSE
                        v_adjustment := -v_amount;
                        v_current_price := v_current_price - v_amount;
                    END IF;
                
                WHEN 'override', 'set' THEN
                    v_adjustment := v_amount - v_current_price;
                    v_current_price := v_amount;
                
                WHEN 'multiply' THEN
                    v_adjustment := v_current_price * (v_amount - 1);
                    v_current_price := v_current_price * v_amount;
            END CASE;
            
            -- Track applied rule
            v_applied_rules := v_applied_rules || jsonb_build_object(
                'rule_id', v_rule.rule_id,
                'rule_uuid', v_rule.rule_uuid,
                'operation', v_rule.operation_code,
                'priority', v_rule.priority,
                'adjustment', v_adjustment
            );
            
            v_rule_count := v_rule_count + 1;
            
            -- Update rule statistics
            UPDATE pricing_rules
            SET 
                applied_count = applied_count + 1,
                last_applied_at = NOW()
            WHERE id = v_rule.rule_id;
        END;
    END LOOP;
    
    -- Check for manual overrides
    SELECT price INTO v_override_price
    FROM price_overrides
    WHERE property_id = p_property_id
    AND platform_id = p_platform_id
    AND date = p_date
    AND is_active = TRUE
    AND (expires_at IS NULL OR expires_at > NOW());
    
    IF FOUND THEN
        v_current_price := v_override_price;
        v_applied_rules := v_applied_rules || jsonb_build_object(
            'type', 'manual_override',
            'price', v_override_price
        );
    END IF;
    
    -- Apply min/max constraints
    v_current_price := GREATEST(v_min_price, LEAST(v_current_price, v_max_price));
    
    -- Get gap info
    SELECT * INTO v_gap_info
    FROM gap_days
    WHERE property_id = p_property_id
    AND platform_id = p_platform_id
    AND gap_date = p_date;
    
    -- Cache the result
    v_cache_duration := get_config_int('cache_duration_minutes', 60);
    
    INSERT INTO calculated_prices (
        property_id,
        platform_id,
        platform_property_lookup_id,
        date,
        base_price,
        rule_adjustments,
        final_price,
        applied_rules,
        applied_rule_count,
        is_gap_day,
        gap_length,
        is_available,
        valid_until,
        is_valid,
        calculation_time_ms
    ) VALUES (
        p_property_id,
        p_platform_id,
        p_platform_property_lookup_id,
        p_date,
        v_base_price,
        v_current_price - v_base_price,
        v_current_price,
        v_applied_rules,
        v_rule_count,
        v_gap_info.gap_date IS NOT NULL,
        v_gap_info.gap_length,
        v_is_available,
        NOW() + (v_cache_duration || ' minutes')::INTERVAL,
        TRUE,
        EXTRACT(MILLISECONDS FROM clock_timestamp() - v_start_time)::INTEGER
    )
    ON CONFLICT (property_id, platform_id, date, id)
    DO UPDATE SET
        final_price = EXCLUDED.final_price,
        applied_rules = EXCLUDED.applied_rules,
        applied_rule_count = EXCLUDED.applied_rule_count,
        calculated_at = NOW(),
        valid_until = EXCLUDED.valid_until,
        is_valid = TRUE,
        calculation_time_ms = EXCLUDED.calculation_time_ms;
    
    RETURN jsonb_build_object(
        'success', TRUE,
        'cached', FALSE,
        'date', p_date,
        'available', v_is_available,
        'base_price', v_base_price,
        'final_price', v_current_price,
        'adjustment', v_current_price - v_base_price,
        'applied_rules', v_applied_rules,
        'rule_count', v_rule_count,
        'is_gap_day', v_gap_info.gap_date IS NOT NULL,
        'gap_length', v_gap_info.gap_length,
        'calculation_time_ms', EXTRACT(MILLISECONDS FROM clock_timestamp() - v_start_time)::INTEGER
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Batch price calculation (Optimized - fully set-based)
CREATE OR REPLACE FUNCTION calculate_price_range_batch(
    p_api_key TEXT,
    p_property_id BIGINT,
    p_platform_id BIGINT,
    p_start_date DATE,
    p_end_date DATE,
    p_base_price NUMERIC DEFAULT NULL,
    p_force_recalculate BOOLEAN DEFAULT FALSE,
    p_platform_property_lookup_id BIGINT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_worker_id VARCHAR;
    v_results JSONB;
    v_start_time TIMESTAMPTZ;
    v_date_count INTEGER;
    v_max_range INTEGER;
    v_operation_id BIGINT;
BEGIN
    v_start_time := clock_timestamp();
    
    -- Authenticate
    v_worker_id := validate_worker_auth(p_api_key);
    
    -- Validate range
    v_max_range := get_config_int('max_calculation_range_days', 365);
    v_date_count := p_end_date - p_start_date + 1;
    
    IF v_date_count > v_max_range THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'error', format('Date range exceeds maximum of %s days', v_max_range)
        );
    END IF;
    
    -- Calculate all dates in batch
    WITH date_series AS (
        SELECT generate_series(p_start_date, p_end_date, '1 day'::INTERVAL)::DATE as calc_date
    ),
    batch_calc AS (
        SELECT 
            ds.calc_date,
            calculate_daily_price(
                p_api_key,
                p_property_id,
                p_platform_id,
                ds.calc_date,
                p_base_price,
                p_force_recalculate,
                p_platform_property_lookup_id
            ) as price_data
        FROM date_series ds
    )
    SELECT jsonb_agg(
        price_data ORDER BY calc_date
    ) INTO v_results
    FROM batch_calc;
    
    -- Log operation
    INSERT INTO pricing_operations (
        property_id,
        platform_id,
        operation_type,
        parameters,
        result,
        executed_by,
        status,
        execution_time_ms,
        rows_affected,
        completed_at
    ) VALUES (
        p_property_id,
        p_platform_id,
        'batch_price_calculation',
        jsonb_build_object(
            'start_date', p_start_date,
            'end_date', p_end_date,
            'force_recalculate', p_force_recalculate,
            'platform_property_lookup_id', p_platform_property_lookup_id
        ),
        jsonb_build_object(
            'days_calculated', v_date_count
        ),
        v_worker_id,
        'completed',
        EXTRACT(MILLISECONDS FROM clock_timestamp() - v_start_time)::INTEGER,
        v_date_count,
        NOW()
    )
    RETURNING id INTO v_operation_id;
    
    RETURN jsonb_build_object(
        'success', TRUE,
        'property_id', p_property_id,
        'platform_id', p_platform_id,
        'platform_property_lookup_id', p_platform_property_lookup_id,
        'date_range', jsonb_build_object('start', p_start_date, 'end', p_end_date),
        'days_calculated', v_date_count,
        'prices', v_results,
        'operation_id', v_operation_id,
        'execution_time_ms', EXTRACT(MILLISECONDS FROM clock_timestamp() - v_start_time)::INTEGER
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================
-- 13. CACHE INVALIDATION (NEW - from Doc 4)
-- ============================================================================

CREATE OR REPLACE FUNCTION invalidate_price_cache()
RETURNS TRIGGER AS $$
DECLARE
    v_affected_rows INTEGER;
BEGIN
    -- Invalidate based on what changed
    IF TG_TABLE_NAME = 'pricing_rules' THEN
        UPDATE calculated_prices cp
        SET is_valid = FALSE
        WHERE is_valid = TRUE
        AND (
            (NEW.scope = 'global') OR
            (NEW.scope = 'platform' AND cp.platform_id = NEW.platform_id) OR
            (NEW.scope = 'property' AND cp.property_id = NEW.property_id) OR
            (
                NEW.scope = 'listing'
                AND cp.platform_property_lookup_id = NEW.platform_property_lookup_id
            )
        )
        AND cp.date BETWEEN 
            COALESCE(NEW.start_date, CURRENT_DATE) 
            AND COALESCE(NEW.end_date, CURRENT_DATE + INTERVAL '1 year');
        
        GET DIAGNOSTICS v_affected_rows = ROW_COUNT;
        
        PERFORM log_pricing_rule_audit(
            'cache_invalidate',
            NEW.id,
            NEW.rule_uuid,
            NEW.created_by,
            'system',
            NULL,
            jsonb_build_object('invalidated_prices', v_affected_rows)
        );
        
    ELSIF TG_TABLE_NAME = 'ical_events' THEN
        UPDATE calculated_prices
        SET is_valid = FALSE
        WHERE property_id = NEW.property_id
        AND platform_id = NEW.platform_id
        AND date BETWEEN NEW.start_date AND NEW.end_date - 1
        AND is_valid = TRUE;
        
    ELSIF TG_TABLE_NAME = 'price_overrides' THEN
        UPDATE calculated_prices
        SET is_valid = FALSE
        WHERE property_id = NEW.property_id
        AND platform_id = NEW.platform_id
        AND date = NEW.date
        AND is_valid = TRUE;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER invalidate_cache_on_rule_change
    AFTER INSERT OR UPDATE ON pricing_rules
    FOR EACH ROW
    WHEN (NEW.status = 'active')
    EXECUTE FUNCTION invalidate_price_cache();

CREATE TRIGGER invalidate_cache_on_booking_change
    AFTER INSERT OR UPDATE OR DELETE ON ical_events
    FOR EACH ROW
    EXECUTE FUNCTION invalidate_price_cache();

CREATE TRIGGER invalidate_cache_on_override_change
    AFTER INSERT OR UPDATE ON price_overrides
    FOR EACH ROW
    EXECUTE FUNCTION invalidate_price_cache();

-- ============================================================================
-- 14. MAINTENANCE FUNCTIONS (NEW - from Doc 4)
-- ============================================================================

-- Partition maintenance
CREATE OR REPLACE FUNCTION maintain_price_partitions()
RETURNS JSONB AS $$
DECLARE
    v_next_month DATE;
    v_partition_name TEXT;
    v_created INTEGER := 0;
    v_dropped INTEGER := 0;
    v_retention_days INTEGER;
BEGIN
    v_retention_days := get_config_int('partition_retention_days', 90);
    
    -- Create partitions for next 3 months
    FOR i IN 0..2 LOOP
        v_next_month := DATE_TRUNC('month', CURRENT_DATE + ((12 + i) || ' months')::INTERVAL)::DATE;
        v_partition_name := 'calculated_prices_' || TO_CHAR(v_next_month, 'YYYY_MM');
        
        IF NOT EXISTS (
            SELECT 1 FROM pg_class WHERE relname = v_partition_name
        ) THEN
            EXECUTE format('
                CREATE TABLE %I PARTITION OF calculated_prices
                FOR VALUES FROM (%L) TO (%L)',
                v_partition_name,
                v_next_month,
                v_next_month + INTERVAL '1 month'
            );
            v_created := v_created + 1;
        END IF;
    END LOOP;
    
    -- Drop old partitions
    FOR v_partition_name IN
        SELECT tablename 
        FROM pg_tables 
        WHERE schemaname = 'public'
        AND tablename LIKE 'calculated_prices_20%'
        AND tablename < 'calculated_prices_' || 
            TO_CHAR(CURRENT_DATE - (v_retention_days || ' days')::INTERVAL, 'YYYY_MM')
    LOOP
        EXECUTE format('DROP TABLE IF EXISTS %I', v_partition_name);
        v_dropped := v_dropped + 1;
    END LOOP;
    
    RETURN jsonb_build_object(
        'success', TRUE,
        'partitions_created', v_created,
        'partitions_dropped', v_dropped
    );
END;
$$ LANGUAGE plpgsql;

-- Cleanup expired data
CREATE OR REPLACE FUNCTION cleanup_expired_data()
RETURNS JSONB AS $$
DECLARE
    v_deleted_overrides INTEGER;
    v_deleted_events INTEGER;
    v_invalidated_cache INTEGER;
BEGIN
    -- Delete expired overrides
    DELETE FROM price_overrides
    WHERE expires_at < NOW()
    AND is_active = TRUE;
    
    GET DIAGNOSTICS v_deleted_overrides = ROW_COUNT;
    
    -- Delete old ical events (older than 1 year)
    DELETE FROM ical_events
    WHERE end_date < CURRENT_DATE - INTERVAL '1 year';
    
    GET DIAGNOSTICS v_deleted_events = ROW_COUNT;
    
    -- Invalidate expired cache
    UPDATE calculated_prices
    SET is_valid = FALSE
    WHERE valid_until < NOW()
    AND is_valid = TRUE;
    
    GET DIAGNOSTICS v_invalidated_cache = ROW_COUNT;
    
    RETURN jsonb_build_object(
        'success', TRUE,
        'deleted_overrides', v_deleted_overrides,
        'deleted_events', v_deleted_events,
        'invalidated_cache', v_invalidated_cache
    );
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 15. TRIGGERS
-- ============================================================================

CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_pricing_rules_updated_at
BEFORE UPDATE ON pricing_rules
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_ical_events_updated_at
BEFORE UPDATE ON ical_events
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

-- Auto-audit on rule changes
CREATE OR REPLACE FUNCTION auto_audit_pricing_rule_change()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        PERFORM log_pricing_rule_audit(
            'update',
            NEW.id,
            NEW.rule_uuid,
            COALESCE(NEW.created_by, 'system'),
            'system',
            to_jsonb(OLD),
            to_jsonb(NEW),
            TRUE,
            NULL
        );
    ELSIF TG_OP = 'DELETE' THEN
        PERFORM log_pricing_rule_audit(
            'delete',
            NULL,
            OLD.rule_uuid,
            COALESCE(OLD.created_by, 'system'),
            'system',
            to_jsonb(OLD),
            NULL,
            TRUE,
            NULL
        );
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER auto_audit_pricing_rule_changes
AFTER UPDATE OR DELETE ON pricing_rules
FOR EACH ROW
EXECUTE FUNCTION auto_audit_pricing_rule_change();

-- ============================================================================
-- 16. n8n WORKER INTEGRATION
-- ============================================================================

-- Enqueue pricing calculation task
CREATE OR REPLACE FUNCTION enqueue_pricing_calculation(
    p_api_key TEXT,
    p_property_id BIGINT,
    p_platform_id BIGINT,
    p_date_range_start DATE,
    p_date_range_end DATE,
    p_base_price NUMERIC DEFAULT NULL,
    p_priority INTEGER DEFAULT 50,
    p_queue_name VARCHAR DEFAULT 'pricing',
    p_platform_property_lookup_id BIGINT DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    v_task_uuid UUID;
BEGIN
    -- Use secure_task_scheduler's enqueue function
    v_task_uuid := enqueue_task(
        p_api_key,
        'calculate_pricing_batch',
        jsonb_build_object(
            'property_id', p_property_id,
            'platform_id', p_platform_id,
            'platform_property_lookup_id', p_platform_property_lookup_id,
            'date_range', jsonb_build_object(
                'start', p_date_range_start,
                'end', p_date_range_end
            ),
            'base_price', p_base_price
        ),
        'immediate',
        p_priority,
        NOW(),
        3,
        NULL,
        p_queue_name
    );
    
    RETURN v_task_uuid;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Process pricing task (called by n8n worker)
CREATE OR REPLACE FUNCTION process_pricing_task(
    p_api_key TEXT,
    p_task_id BIGINT
) RETURNS JSONB AS $$
DECLARE
    v_task RECORD;
    v_result JSONB;
BEGIN
    -- Get task data
    SELECT task_data INTO v_task 
    FROM task_queue 
    WHERE id = p_task_id;
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'error', 'Task not found'
        );
    END IF;
    
    -- Execute batch calculation
    v_result := calculate_price_range_batch(
        p_api_key,
        (v_task.task_data->>'property_id')::BIGINT,
        (v_task.task_data->>'platform_id')::BIGINT,
        (v_task.task_data->'date_range'->>'start')::DATE,
        (v_task.task_data->'date_range'->>'end')::DATE,
        (v_task.task_data->>'base_price')::NUMERIC,
        FALSE,
        (v_task.task_data->>'platform_property_lookup_id')::BIGINT
    );
    
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================
-- 17. EXAMPLE USAGE
-- ============================================================================

/*
-- ===== SETUP =====

-- 1. Register worker with pricing queue subscription
SELECT * FROM register_worker(
    'pricing-worker-001',
    'Pricing Calculation Worker',
    10,
    '30 seconds'::INTERVAL,
    '["pricing", "default"]'::JSONB
);
-- Save API key: sk_abc123...

-- ===== CALENDAR SYNC =====

-- 2. Sync iCal data
SELECT process_ical_events(
    'sk_abc123...',
    1,  -- property_id
    4,  -- platform_id (Airbnb)
    'BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
UID:booking-12345
DTSTART:20240615
DTEND:20240620
STATUS:CONFIRMED
SUMMARY:John Doe
END:VEVENT
END:VCALENDAR',
    'airbnb_ical'
);

-- 3. Calculate gap days
SELECT calculate_gap_days(
    'sk_abc123...',
    1,  -- property_id
    4,  -- platform_id
    CURRENT_DATE,
    CURRENT_DATE + 365
);

-- ===== PRICING RULES =====

-- 4. Create weekend pricing rule
SELECT create_pricing_rule(
    'sk_abc123...',
    1,  -- property_id
    4,  -- platform_id
    'increase',
    '{
        "subject": "price",
        "operation": {
            "do": "+ increase",
            "type": "percentage",
            "amount": 20
        }
    }'::JSONB,
    NULL,
    '2024-01-01',
    '2024-12-31',
    96,  -- Weekends (Sat=32 + Sun=64)
    70,
    'Weekend Premium 2024'
);

-- 5. Create gap day discount rule
SELECT create_pricing_rule(
    'sk_abc123...',
    1,
    4,
    'decrease',
    '{
        "subject": "price",
        "operation": {
            "do": "- decrease",
            "type": "percentage",
            "amount": 15
        },
        "conditions": {
            "gap_day": {
                "is_last_minute": true,
                "is_long_gap": false
            }
        }
    }'::JSONB,
    NULL,
    '2024-01-01',
    '2024-12-31',
    NULL,
    85,
    'Last Minute Gap Discount'
);

-- ===== PRICE CALCULATION =====

-- 6. Calculate single date price
SELECT calculate_daily_price(
    'sk_abc123...',
    1,  -- property_id
    4,  -- platform_id
    '2024-12-25',
    150.00,  -- base_price
    FALSE  -- use cache if available
);

-- 7. Calculate price range (batch)
SELECT calculate_price_range_batch(
    'sk_abc123...',
    1,
    4,
    '2024-12-01',
    '2024-12-31',
    150.00,
    FALSE
);

-- ===== TASK QUEUE INTEGRATION =====

-- 8. Enqueue batch pricing task
SELECT enqueue_pricing_calculation(
    'sk_abc123...',
    1,  -- property_id
    4,  -- platform_id
    CURRENT_DATE,
    CURRENT_DATE + 90,
    150.00,
    80,  -- high priority
    'pricing'
);

-- 9. Worker processes task (in n8n)
SELECT process_pricing_task(
    'sk_abc123...',
    12345  -- task_id from queue
);

-- ===== MONITORING =====

-- 10. View cache statistics
SELECT 
    property_id,
    platform_id,
    COUNT(*) as total_cached,
    COUNT(*) FILTER (WHERE is_valid = TRUE) as valid_cached,
    COUNT(*) FILTER (WHERE is_gap_day = TRUE) as gap_days,
    AVG(calculation_time_ms) as avg_calc_time_ms
FROM calculated_prices
WHERE date >= CURRENT_DATE
GROUP BY property_id, platform_id;

-- 11. View rule performance
SELECT 
    pr.rule_name,
    pr.operation_id,
    pot.operation_code,
    pr.applied_count,
    pr.last_applied_at,
    COUNT(pre.id) as execution_count
FROM pricing_rules pr
JOIN pricing_operation_types pot ON pr.operation_id = pot.id
LEFT JOIN pricing_rule_executions pre ON pr.id = pre.rule_id
WHERE pr.status = 'active'
GROUP BY pr.id, pr.rule_name, pr.operation_id, pot.operation_code
ORDER BY pr.applied_count DESC;

-- ===== MAINTENANCE =====

-- 12. Maintain partitions (run monthly)
SELECT maintain_price_partitions();

-- 13. Cleanup expired data (run daily)
SELECT cleanup_expired_data();

*/

-- ============================================================================
-- END OF PRICING ENGINE v3.0
-- ============================================================================
