-- ============================================================
-- 0011 bulk_runs, bulk_plans
-- Upstream: 20260802180000_create_bulk_runs.sql
--           20260805210000_create_bulk_plans.sql (table half)
-- ============================================================
-- bulk_runs is progress/cancellation bookkeeping for large batch operations
-- (best effort). bulk_plans holds the encrypted, 15-minute preview of a
-- destructive bulk operation when an inbox has bulk_review_mode = 'plan'.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.bulk_runs (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id          uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE CASCADE,
  api_key_id            uuid REFERENCES public.api_keys(id) ON DELETE SET NULL,
  inbox_id              uuid NOT NULL REFERENCES public.inboxes(id) ON DELETE CASCADE,
  operation             text NOT NULL,
  status                text NOT NULL DEFAULT 'running',
  total                 integer NOT NULL,
  processed             integer NOT NULL DEFAULT 0,
  succeeded             integer NOT NULL DEFAULT 0,
  failed                integer NOT NULL DEFAULT 0,
  cancel_requested_at   timestamptz,
  completed_at          timestamptz,
  error_code            text,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.bulk_runs DROP CONSTRAINT IF EXISTS bulk_runs_operation_check;
ALTER TABLE public.bulk_runs ADD CONSTRAINT bulk_runs_operation_check
  CHECK (operation IN ('move_batch', 'flag', 'search_and_move'));
ALTER TABLE public.bulk_runs DROP CONSTRAINT IF EXISTS bulk_runs_status_check;
ALTER TABLE public.bulk_runs ADD CONSTRAINT bulk_runs_status_check
  CHECK (status IN ('running', 'cancelling', 'completed', 'completed_with_errors', 'cancelled_partial', 'failed'));
ALTER TABLE public.bulk_runs DROP CONSTRAINT IF EXISTS bulk_runs_total_check;
ALTER TABLE public.bulk_runs ADD CONSTRAINT bulk_runs_total_check CHECK (total >= 0);
ALTER TABLE public.bulk_runs DROP CONSTRAINT IF EXISTS bulk_runs_processed_check;
ALTER TABLE public.bulk_runs ADD CONSTRAINT bulk_runs_processed_check CHECK (processed >= 0);
ALTER TABLE public.bulk_runs DROP CONSTRAINT IF EXISTS bulk_runs_succeeded_check;
ALTER TABLE public.bulk_runs ADD CONSTRAINT bulk_runs_succeeded_check CHECK (succeeded >= 0);
ALTER TABLE public.bulk_runs DROP CONSTRAINT IF EXISTS bulk_runs_failed_check;
ALTER TABLE public.bulk_runs ADD CONSTRAINT bulk_runs_failed_check CHECK (failed >= 0);
ALTER TABLE public.bulk_runs DROP CONSTRAINT IF EXISTS bulk_runs_counts_valid;
ALTER TABLE public.bulk_runs ADD CONSTRAINT bulk_runs_counts_valid
  CHECK (processed = succeeded + failed AND processed <= total);

CREATE INDEX IF NOT EXISTS bulk_runs_workspace_created_idx
  ON public.bulk_runs (workspace_id, created_at DESC);
CREATE INDEX IF NOT EXISTS bulk_runs_running_inbox_idx
  ON public.bulk_runs (inbox_id, created_at DESC)
  WHERE status IN ('running', 'cancelling');

CREATE OR REPLACE TRIGGER bulk_runs_updated_at
  BEFORE UPDATE ON public.bulk_runs
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE IF NOT EXISTS public.bulk_plans (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE CASCADE,
  inbox_id uuid NOT NULL REFERENCES public.inboxes(id) ON DELETE CASCADE,
  api_key_id uuid REFERENCES public.api_keys(id) ON DELETE SET NULL,
  operation text NOT NULL,
  action text NOT NULL,
  scope jsonb NOT NULL,
  scope_encrypted boolean NOT NULL DEFAULT true,
  match_count integer NOT NULL,
  scope_kind text NOT NULL,
  permanent boolean NOT NULL DEFAULT false,
  status text NOT NULL DEFAULT 'pending',
  cancelled_at timestamptz,
  cancelled_by_api_key_id uuid REFERENCES public.api_keys(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  executed_at timestamptz,
  executed_by_api_key_id uuid REFERENCES public.api_keys(id) ON DELETE SET NULL,
  affected_count integer,
  error_code text
);

ALTER TABLE public.bulk_plans DROP CONSTRAINT IF EXISTS bulk_plans_operation_check;
ALTER TABLE public.bulk_plans ADD CONSTRAINT bulk_plans_operation_check
  CHECK (operation IN ('email_delete', 'email_organize'));
ALTER TABLE public.bulk_plans DROP CONSTRAINT IF EXISTS bulk_plans_action_check;
ALTER TABLE public.bulk_plans ADD CONSTRAINT bulk_plans_action_check
  CHECK (action IN ('delete_batch', 'search_and_delete', 'move_batch', 'search_and_move'));
ALTER TABLE public.bulk_plans DROP CONSTRAINT IF EXISTS bulk_plans_match_count_check;
ALTER TABLE public.bulk_plans ADD CONSTRAINT bulk_plans_match_count_check CHECK (match_count >= 0);
ALTER TABLE public.bulk_plans DROP CONSTRAINT IF EXISTS bulk_plans_scope_kind_check;
ALTER TABLE public.bulk_plans ADD CONSTRAINT bulk_plans_scope_kind_check
  CHECK (scope_kind IN ('explicit_ids', 'search'));
ALTER TABLE public.bulk_plans DROP CONSTRAINT IF EXISTS bulk_plans_status_check;
ALTER TABLE public.bulk_plans ADD CONSTRAINT bulk_plans_status_check
  CHECK (status IN ('pending', 'executing', 'executed', 'cancelled', 'expired', 'failed'));
ALTER TABLE public.bulk_plans DROP CONSTRAINT IF EXISTS bulk_plans_affected_count_check;
ALTER TABLE public.bulk_plans ADD CONSTRAINT bulk_plans_affected_count_check
  CHECK (affected_count IS NULL OR affected_count >= 0);

CREATE INDEX IF NOT EXISTS bulk_plans_pending_expiry_idx
  ON public.bulk_plans (expires_at) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS bulk_plans_workspace_created_idx
  ON public.bulk_plans (workspace_id, created_at DESC);
