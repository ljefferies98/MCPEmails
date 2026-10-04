-- ============================================================
-- 0009 send_approvals
-- Upstream: 20260802200000_add_send_approvals.sql
--           20260802210000_expand_send_approval_operations.sql
--           20260805200000_mcp_app_approval_review.sql (send_approvals half)
-- ============================================================
-- Holds encrypted outbound messages for inboxes with send_approval_required.
-- The hosted RLS policies (auth.uid()) are not ported: on self-host only the
-- service_role reads this table, and it bypasses RLS.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.send_approvals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE CASCADE,
  inbox_id uuid NOT NULL REFERENCES public.inboxes(id) ON DELETE CASCADE,
  api_key_id uuid REFERENCES public.api_keys(id) ON DELETE SET NULL,
  operation text NOT NULL,
  payload jsonb NOT NULL,
  payload_encrypted boolean NOT NULL DEFAULT true,
  summary jsonb NOT NULL DEFAULT '{}'::jsonb,
  send_at timestamptz,
  status text NOT NULL DEFAULT 'pending',
  created_at timestamptz NOT NULL DEFAULT now(),
  decided_at timestamptz,
  decided_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  decision_note text
);

ALTER TABLE public.send_approvals
  ADD COLUMN IF NOT EXISTS decided_via text,
  ADD COLUMN IF NOT EXISTS decided_by_api_key_id uuid REFERENCES public.api_keys(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS expires_at timestamptz;

ALTER TABLE public.send_approvals DROP CONSTRAINT IF EXISTS send_approvals_operation_check;
ALTER TABLE public.send_approvals ADD CONSTRAINT send_approvals_operation_check
  CHECK (operation IN ('email_send', 'email_reply', 'email_forward', 'draft_send', 'schedule_create'));
ALTER TABLE public.send_approvals DROP CONSTRAINT IF EXISTS send_approvals_status_check;
ALTER TABLE public.send_approvals ADD CONSTRAINT send_approvals_status_check
  CHECK (status IN ('pending', 'approved', 'rejected', 'cancelled', 'expired'));
ALTER TABLE public.send_approvals DROP CONSTRAINT IF EXISTS send_approvals_decided_via_check;
ALTER TABLE public.send_approvals ADD CONSTRAINT send_approvals_decided_via_check
  CHECK (decided_via IS NULL OR decided_via IN ('dashboard', 'review_page', 'mcp_app'));

UPDATE public.send_approvals
  SET expires_at = created_at + interval '24 hours'
  WHERE expires_at IS NULL;

CREATE INDEX IF NOT EXISTS send_approvals_workspace_pending_idx
  ON public.send_approvals (workspace_id, created_at DESC) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS send_approvals_pending_expiry_idx
  ON public.send_approvals (expires_at) WHERE status = 'pending';
