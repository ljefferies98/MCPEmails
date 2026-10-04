-- ============================================================
-- 0006 workspaces: soft delete, first-use markers, onboarding, feature flags
-- Upstream: 20260525000000_workspaces_soft_delete.sql (column + index)
--           20260526000004_enum_check_constraints_retention_and_index.sql (plan check)
--           20260728000000_add_product_analytics_first_use_marker.sql
--           20260802000000_add_truthful_product_funnel_events.sql (workspaces half)
--           20260805010000_add_persistent_onboarding_state.sql (workspaces half)
--           20260827100000_add_personal_plan.sql (plan check)
--           20260912200000_free_action_cap_150.sql (free_action_cap_exempt)
--           20260916140000_draft_editor_flag.sql
--           20260916170000_draft_editor_hidden.sql (workspaces column)
--           20260917120000_card_diagnostics_flag.sql
-- ============================================================
-- The server reads plan, grandfathered, owner_id, analytics_first_tool_used_at
-- and onboarding_value_activated_at on every request. With any of them missing
-- that query fails, the per-workspace limit silently fails open and the
-- first-use bookkeeping is retried (and fails) on every successful call.
--
-- The hosted backfills that depend on hosted-only data (internal staff emails
-- for the draft editor and card diagnostics flags) are not reproduced; the
-- flags default to false, which is the customer default.
-- ============================================================

ALTER TABLE public.workspaces ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
CREATE INDEX IF NOT EXISTS idx_workspaces_deleted_at
  ON public.workspaces (deleted_at)
  WHERE deleted_at IS NOT NULL;

ALTER TABLE public.workspaces DROP CONSTRAINT IF EXISTS workspaces_plan_check;
ALTER TABLE public.workspaces ADD CONSTRAINT workspaces_plan_check
  CHECK (plan IN ('free', 'personal', 'solo', 'pro', 'enterprise'));

ALTER TABLE public.workspaces
  ADD COLUMN IF NOT EXISTS analytics_first_tool_name text,
  ADD COLUMN IF NOT EXISTS analytics_first_tool_provider text,
  ADD COLUMN IF NOT EXISTS analytics_first_tool_client text,
  ADD COLUMN IF NOT EXISTS analytics_first_tool_path text,
  ADD COLUMN IF NOT EXISTS analytics_first_tool_reported_at timestamptz,
  ADD COLUMN IF NOT EXISTS analytics_first_inbox_connected_at timestamptz,
  ADD COLUMN IF NOT EXISTS analytics_first_inbox_provider text,
  ADD COLUMN IF NOT EXISTS analytics_first_credential_created_at timestamptz,
  ADD COLUMN IF NOT EXISTS analytics_first_credential_method text,
  ADD COLUMN IF NOT EXISTS analytics_first_tool_used_at timestamptz;

ALTER TABLE public.workspaces
  ADD COLUMN IF NOT EXISTS onboarding_stage text NOT NULL DEFAULT 'started',
  ADD COLUMN IF NOT EXISTS onboarding_client text,
  ADD COLUMN IF NOT EXISTS onboarding_provider text,
  ADD COLUMN IF NOT EXISTS onboarding_started_at timestamptz,
  ADD COLUMN IF NOT EXISTS onboarding_client_selected_at timestamptz,
  ADD COLUMN IF NOT EXISTS onboarding_inbox_connected_at timestamptz,
  ADD COLUMN IF NOT EXISTS onboarding_connection_verified_at timestamptz,
  ADD COLUMN IF NOT EXISTS onboarding_credential_issued_at timestamptz,
  ADD COLUMN IF NOT EXISTS onboarding_technical_activated_at timestamptz,
  ADD COLUMN IF NOT EXISTS onboarding_value_activated_at timestamptz;

ALTER TABLE public.workspaces DROP CONSTRAINT IF EXISTS workspaces_onboarding_stage_check;
ALTER TABLE public.workspaces ADD CONSTRAINT workspaces_onboarding_stage_check
  CHECK (onboarding_stage IN ('started', 'client_selected', 'inbox_connected', 'credential_issued', 'technical_activation', 'value_activation'));
ALTER TABLE public.workspaces DROP CONSTRAINT IF EXISTS workspaces_onboarding_client_check;
ALTER TABLE public.workspaces ADD CONSTRAINT workspaces_onboarding_client_check CHECK (
  onboarding_client IS NULL OR onboarding_client IN (
    'claude', 'chatgpt', 'cursor', 'vscode', 'cline', 'windsurf', 'gemini',
    'zed', 'jetbrains', 'raycast', 'warp', 'curl', 'unknown'
  )
);
ALTER TABLE public.workspaces DROP CONSTRAINT IF EXISTS workspaces_onboarding_provider_check;
ALTER TABLE public.workspaces ADD CONSTRAINT workspaces_onboarding_provider_check CHECK (
  onboarding_provider IS NULL OR onboarding_provider IN (
    'gmail', 'outlook', 'fastmail', 'icloud', 'yahoo', 'zoho', 'yandex',
    'generic_imap', 'unknown'
  )
);
CREATE INDEX IF NOT EXISTS workspaces_onboarding_value_activation_idx
  ON public.workspaces (onboarding_value_activated_at)
  WHERE onboarding_value_activated_at IS NOT NULL;

-- An install that has already been used must not be treated as brand new:
-- mark the first-use and value milestones from its own activity log so the
-- server does not replay first-use bookkeeping.
UPDATE public.workspaces w
SET onboarding_started_at = COALESCE(w.onboarding_started_at, w.created_at)
WHERE w.onboarding_started_at IS NULL;

UPDATE public.workspaces AS w
SET analytics_first_tool_used_at = COALESCE(w.analytics_first_tool_used_at, first_use.occurred_at),
    onboarding_technical_activated_at = COALESCE(w.onboarding_technical_activated_at, first_use.occurred_at)
FROM (
  SELECT workspace_id, min(created_at) AS occurred_at
  FROM public.activity_log
  WHERE status = 'success'
  GROUP BY workspace_id
) AS first_use
WHERE w.id = first_use.workspace_id
  AND w.analytics_first_tool_used_at IS NULL;

UPDATE public.workspaces AS w
SET onboarding_value_activated_at = first_value.occurred_at
FROM (
  SELECT workspace_id, min(created_at) AS occurred_at
  FROM public.activity_log
  WHERE status = 'success'
    AND inbox_id IS NOT NULL
    AND tool_name <> 'inbox_list'
  GROUP BY workspace_id
) AS first_value
WHERE w.id = first_value.workspace_id
  AND w.onboarding_value_activated_at IS NULL;

UPDATE public.workspaces
SET onboarding_stage = CASE
  WHEN onboarding_value_activated_at IS NOT NULL THEN 'value_activation'
  WHEN onboarding_technical_activated_at IS NOT NULL THEN 'technical_activation'
  ELSE onboarding_stage
END
WHERE onboarding_stage = 'started';

ALTER TABLE public.workspaces
  ADD COLUMN IF NOT EXISTS free_action_cap_exempt boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS draft_editor_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS draft_editor_hidden boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS card_diagnostics boolean NOT NULL DEFAULT false;
