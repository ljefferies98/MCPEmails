-- ============================================================
-- 0015 product_funnel_events
-- Upstream: 20260802000000_add_truthful_product_funnel_events.sql (table)
--           20260805010000_add_persistent_onboarding_state.sql (stage/category checks)
--           20260805160000_connection_security_and_diagnostics.sql (phase, connection_type, outcome)
--           20260813100000_add_billing_funnel_events.sql, 20260827100000_add_personal_plan.sql,
--           20260829220000_funnel_consent_required_category.sql, 20260909080000_funnel_auth_reason.sql,
--           20260914120000_funnel_plan_change_stages.sql, 20261002180000_checkout_cancel_feedback.sql
--           (check widenings, auth_reason)
-- ============================================================
-- The server appends first_tool_call / technical_activation /
-- value_activation milestones here once per workspace. On self-host this is a
-- local record only; nothing is sent anywhere. The checks mirror hosted so a
-- value the server writes is accepted in both places.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.product_funnel_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  workspace_id uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE CASCADE,
  stage text NOT NULL,
  outcome text NOT NULL,
  category text NOT NULL,
  error_category text,
  occurred_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.product_funnel_events
  ADD COLUMN IF NOT EXISTS phase text,
  ADD COLUMN IF NOT EXISTS connection_type text,
  ADD COLUMN IF NOT EXISTS auth_reason text;

ALTER TABLE public.product_funnel_events DROP CONSTRAINT IF EXISTS product_funnel_events_stage_check;
ALTER TABLE public.product_funnel_events ADD CONSTRAINT product_funnel_events_stage_check
  CHECK (stage IN (
    'onboarding_started', 'client_selected', 'provider_selected', 'inbox_connection',
    'connection_verified', 'credential_created', 'technical_activation',
    'value_activation', 'first_tool_call', 'paywall_reached', 'pricing_viewed',
    'checkout_started', 'checkout_completed', 'billing_portal_opened',
    'plan_upgraded', 'plan_downgraded', 'multi_inbox_prompt'
  ));
ALTER TABLE public.product_funnel_events DROP CONSTRAINT IF EXISTS product_funnel_events_outcome_check;
ALTER TABLE public.product_funnel_events ADD CONSTRAINT product_funnel_events_outcome_check
  CHECK (outcome IN ('started', 'success', 'failure'));
ALTER TABLE public.product_funnel_events DROP CONSTRAINT IF EXISTS product_funnel_events_category_check;
ALTER TABLE public.product_funnel_events ADD CONSTRAINT product_funnel_events_category_check
  CHECK (category IN (
    'gmail', 'outlook', 'fastmail', 'icloud', 'yahoo', 'zoho', 'yandex',
    'generic_imap', 'api_key', 'oauth', 'claude', 'chatgpt', 'cursor',
    'vscode', 'cline', 'windsurf', 'gemini', 'zed', 'jetbrains', 'raycast',
    'warp', 'curl', 'unknown', 'personal_month', 'personal_year', 'solo_month',
    'solo_year', 'pro_month', 'pro_year', 'free', 'personal', 'solo', 'pro',
    'pricing_page', 'dashboard_billing'
  ));
ALTER TABLE public.product_funnel_events DROP CONSTRAINT IF EXISTS product_funnel_events_error_category_check;
ALTER TABLE public.product_funnel_events ADD CONSTRAINT product_funnel_events_error_category_check
  CHECK (error_category IS NULL OR error_category IN (
    'auth_failed', 'validation_failed', 'provider_denied', 'token_exchange_failed',
    'plan_limit', 'conflict', 'persistence_failed', 'unknown', 'consent_required',
    'price_not_configured', 'subscription_exists', 'stripe_error', 'no_customer'
  ));
ALTER TABLE public.product_funnel_events DROP CONSTRAINT IF EXISTS product_funnel_events_phase_check;
ALTER TABLE public.product_funnel_events ADD CONSTRAINT product_funnel_events_phase_check
  CHECK (phase IS NULL OR phase IN (
    'tcp', 'tls', 'greeting', 'authentication',
    'smtp_tcp', 'smtp_tls', 'smtp_greeting', 'smtp_authentication',
    'authorization', 'token_exchange', 'persistence', 'complete'
  ));
ALTER TABLE public.product_funnel_events DROP CONSTRAINT IF EXISTS product_funnel_events_connection_type_check;
ALTER TABLE public.product_funnel_events ADD CONSTRAINT product_funnel_events_connection_type_check
  CHECK (connection_type IS NULL OR connection_type IN ('first_connect', 'reconnect'));
ALTER TABLE public.product_funnel_events DROP CONSTRAINT IF EXISTS product_funnel_events_terminal_error_check;
ALTER TABLE public.product_funnel_events ADD CONSTRAINT product_funnel_events_terminal_error_check
  CHECK ((outcome IN ('started', 'success') AND error_category IS NULL) OR outcome = 'failure');

CREATE INDEX IF NOT EXISTS product_funnel_events_workspace_stage_occurred_idx
  ON public.product_funnel_events (workspace_id, stage, occurred_at DESC);
CREATE INDEX IF NOT EXISTS product_funnel_events_stage_outcome_occurred_idx
  ON public.product_funnel_events (stage, outcome, occurred_at DESC);
