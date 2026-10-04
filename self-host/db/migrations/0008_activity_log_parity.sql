-- ============================================================
-- 0008 activity_log: error_details, status check
-- Upstream: 20260803000000_add_activity_log_error_details.sql
--           20260526000004_enum_check_constraints_retention_and_index.sql (status check)
-- ============================================================
-- The server writes error_details on schema-validation errors. Without the
-- column those rows fail to insert, and because the per-key rate limits count
-- activity_log rows, failed calls would stop counting towards them.
--
-- The hosted table is range-partitioned with a 90-day retention job; self-host
-- keeps the plain table (see README, "Backups and housekeeping").
-- ============================================================

ALTER TABLE public.activity_log
  ADD COLUMN IF NOT EXISTS error_details jsonb;

ALTER TABLE public.activity_log DROP CONSTRAINT IF EXISTS activity_log_status_check;
ALTER TABLE public.activity_log ADD CONSTRAINT activity_log_status_check
  CHECK (status IN ('success', 'error', 'rate_limited'));
