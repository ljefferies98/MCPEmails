-- ============================================================
-- 0004 inboxes: send approval, review modes, draft editor preference
-- Upstream: 20260802200000_add_send_approvals.sql (inboxes column)
--           20260805200000_mcp_app_approval_review.sql (send_review_mode)
--           20260805210000_create_bulk_plans.sql (bulk_review_mode)
--           20260916170000_draft_editor_hidden.sql (inboxes column)
-- ============================================================
-- send_approval_required is part of INBOX_SELECT_COLUMNS. PostgREST rejects
-- the whole SELECT when one projected column is missing, which the server
-- reports as inbox_not_found for every mail tool.
-- ============================================================

ALTER TABLE public.inboxes
  ADD COLUMN IF NOT EXISTS send_approval_required boolean NOT NULL DEFAULT false;

ALTER TABLE public.inboxes
  ADD COLUMN IF NOT EXISTS send_review_mode text NOT NULL DEFAULT 'off';
ALTER TABLE public.inboxes DROP CONSTRAINT IF EXISTS inboxes_send_review_mode_check;
ALTER TABLE public.inboxes ADD CONSTRAINT inboxes_send_review_mode_check
  CHECK (send_review_mode IN ('off', 'inline', 'dashboard'));
UPDATE public.inboxes
  SET send_review_mode = 'dashboard'
  WHERE send_approval_required = true AND send_review_mode = 'off';

ALTER TABLE public.inboxes
  ADD COLUMN IF NOT EXISTS bulk_review_mode text NOT NULL DEFAULT 'off';
ALTER TABLE public.inboxes DROP CONSTRAINT IF EXISTS inboxes_bulk_review_mode_check;
ALTER TABLE public.inboxes ADD CONSTRAINT inboxes_bulk_review_mode_check
  CHECK (bulk_review_mode IN ('off', 'plan'));

ALTER TABLE public.inboxes
  ADD COLUMN IF NOT EXISTS draft_editor_hidden boolean NOT NULL DEFAULT false;
