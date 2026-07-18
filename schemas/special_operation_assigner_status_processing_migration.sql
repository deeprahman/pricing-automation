-- ============================================
-- SPECIAL OPERATION ASSIGNER STATUS MIGRATION
-- Add in-flight "processing" status for booking_applied_rules
-- ============================================

DO $$
BEGIN
    IF to_regtype('public.applied_rule_status') IS NULL THEN
        RAISE EXCEPTION 'Missing type: applied_rule_status. Run schemas/special_operation_assigner_tables.sql first.';
    END IF;
END $$;

ALTER TYPE applied_rule_status ADD VALUE IF NOT EXISTS 'processing';

DO $$
BEGIN
    IF to_regclass('public.booking_applied_rules') IS NULL THEN
        RAISE EXCEPTION 'Missing table: booking_applied_rules. Run schemas/special_operation_assigner_tables.sql first.';
    END IF;
END $$;

ALTER TABLE booking_applied_rules
    ALTER COLUMN status SET DEFAULT 'processing';
