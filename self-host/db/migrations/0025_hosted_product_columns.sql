-- ============================================================
-- 0025 hosted product columns the server reads
-- Upstream:
--   20261027140000_api_keys_card_listed.sql
--   20261027201500_bulk_undo_card.sql
--   20261024190000_payment_issue_columns.sql (columns only)
--   20261024180000_chat_checkout_links.sql (workspaces column only)
--   20261025090000_referrals.sql (user_usage_entitlements column and checks)
--   20260929120000.. / 20261005120000_funnel_entry_point.sql and later stage/category widenings
-- ============================================================
-- Columns on tables the server reads, for hosted features that do nothing on
-- self-host. api_keys.card_listed matters most: it is in the API-key lookup
-- select, so without it every authenticated request fails. The rest default
-- to off / NULL here: bulk undo card, Stripe payment notices, chat checkout
-- links, referral rewards. The funnel checks are widened to the hosted lists
-- so the server's best-effort funnel writes are not refused.
-- ============================================================

ALTER TABLE public.api_keys ADD COLUMN IF NOT EXISTS card_listed boolean;

ALTER TABLE public.workspaces ADD COLUMN IF NOT EXISTS bulk_undo_hidden boolean NOT NULL DEFAULT false;

ALTER TABLE public.bulk_plans DROP CONSTRAINT IF EXISTS bulk_plans_scope_kind_check;
ALTER TABLE public.bulk_plans ADD CONSTRAINT bulk_plans_scope_kind_check
  CHECK ((scope_kind = ANY (ARRAY['explicit_ids'::text, 'search'::text, 'undo'::text])));

ALTER TABLE public.workspaces ADD COLUMN IF NOT EXISTS payment_issue_kind text;
ALTER TABLE public.workspaces ADD COLUMN IF NOT EXISTS payment_issue_since timestamp with time zone;
ALTER TABLE public.workspaces ADD COLUMN IF NOT EXISTS payment_notice_shown_on date;
ALTER TABLE public.workspaces ADD COLUMN IF NOT EXISTS chat_checkout_link_enabled boolean NOT NULL DEFAULT false;

ALTER TABLE public.workspaces DROP CONSTRAINT IF EXISTS workspaces_payment_issue_kind_check;
ALTER TABLE public.workspaces ADD CONSTRAINT workspaces_payment_issue_kind_check
  CHECK (((payment_issue_kind IS NULL) OR (payment_issue_kind = ANY (ARRAY['declined'::text, 'confirm'::text]))));
ALTER TABLE public.workspaces DROP CONSTRAINT IF EXISTS workspaces_onboarding_client_check;
ALTER TABLE public.workspaces ADD CONSTRAINT workspaces_onboarding_client_check
  CHECK (((onboarding_client IS NULL) OR (onboarding_client = ANY (ARRAY['claude'::text, 'chatgpt'::text, 'cursor'::text, 'vscode'::text, 'cline'::text, 'windsurf'::text, 'gemini'::text, 'zed'::text, 'jetbrains'::text, 'raycast'::text, 'warp'::text, 'curl'::text, 'unknown'::text, 'claude_code'::text]))));

ALTER TABLE public.user_usage_entitlements ADD COLUMN IF NOT EXISTS referral_personal_until timestamp with time zone;

ALTER TABLE public.user_usage_entitlements DROP CONSTRAINT IF EXISTS user_usage_entitlements_kind_check;
ALTER TABLE public.user_usage_entitlements ADD CONSTRAINT user_usage_entitlements_kind_check
  CHECK ((kind = ANY (ARRAY['standard'::text, 'comped_scale'::text, 'referral_personal'::text])));
ALTER TABLE public.user_usage_entitlements DROP CONSTRAINT IF EXISTS user_usage_entitlements_source_check;
ALTER TABLE public.user_usage_entitlements ADD CONSTRAINT user_usage_entitlements_source_check
  CHECK ((source = ANY (ARRAY['migration'::text, 'support'::text, 'promotion'::text, 'referral'::text])));

ALTER TABLE public.product_funnel_events ADD COLUMN IF NOT EXISTS entry_point text;

ALTER TABLE public.product_funnel_events DROP CONSTRAINT IF EXISTS product_funnel_events_entry_point_check;
ALTER TABLE public.product_funnel_events ADD CONSTRAINT product_funnel_events_entry_point_check
  CHECK (((entry_point IS NULL) OR (entry_point = ANY (ARRAY['account_security'::text, 'admin_consent'::text, 'app_passwords'::text, 'billing_page'::text, 'cancel_email'::text, 'chat_link'::text, 'command_palette'::text, 'first_run'::text, 'guide'::text, 'header'::text, 'imap_setting'::text, 'inboxes_page'::text, 'multi_inbox_inboxes'::text, 'multi_inbox_overview'::text, 'other'::text, 'plan_ending_email'::text, 'post_checkout'::text, 'provider_intent'::text, 'reconnect'::text, 'second_inbox'::text, 'two_step'::text]))));
ALTER TABLE public.product_funnel_events DROP CONSTRAINT IF EXISTS product_funnel_events_category_check;
ALTER TABLE public.product_funnel_events ADD CONSTRAINT product_funnel_events_category_check
  CHECK ((category = ANY (ARRAY['alert'::text, 'alert_1'::text, 'alert_2'::text, 'aol'::text, 'api_key'::text, 'auto'::text, 'cap_banner'::text, 'chat_100'::text, 'chat_80'::text, 'chatgpt'::text, 'checkout_return'::text, 'claude'::text, 'claude_code'::text, 'cline'::text, 'curl'::text, 'cursor'::text, 'dashboard_billing'::text, 'downgrade'::text, 'early'::text, 'email'::text, 'fastmail'::text, 'free'::text, 'free_reset_email'::text, 'gemini'::text, 'generic_imap'::text, 'github'::text, 'gmail'::text, 'gmx'::text, 'google'::text, 'help_no_call'::text, 'help_no_handshake'::text, 'help_reconnect'::text, 'holdout'::text, 'icloud'::text, 'jetbrains'::text, 'level_100'::text, 'level_50'::text, 'level_80'::text, 'link_add_to_ai'::text, 'link_help_steps'::text, 'microsoft'::text, 'missing_feature'::text, 'not_using_enough'::text, 'oauth'::text, 'other'::text, 'outlook'::text, 'pass'::text, 'pass_reminder'::text, 'pause'::text, 'paywall_email_3'::text, 'personal'::text, 'personal_month'::text, 'personal_pass_3m'::text, 'personal_year'::text, 'pricing_page'::text, 'pro'::text, 'pro_month'::text, 'pro_year'::text, 'prompt_draft_replies'::text, 'prompt_morning_brief'::text, 'prompt_reply_radar'::text, 'raycast'::text, 'reliability'::text, 'solo'::text, 'solo_month'::text, 'solo_year'::text, 'step_add_to_ai'::text, 'step_first_prompt'::text, 'step_inbox'::text, 'step_it_works'::text, 'step_wait'::text, 'surface_onboarding'::text, 'surface_overview'::text, 'switched_tool'::text, 'temporary_need'::text, 'too_expensive'::text, 'unknown'::text, 'vscode'::text, 'warp'::text, 'web_de'::text, 'windsurf'::text, 'yahoo'::text, 'yandex'::text, 'zed'::text, 'zoho'::text])));
ALTER TABLE public.product_funnel_events DROP CONSTRAINT IF EXISTS product_funnel_events_stage_check;
ALTER TABLE public.product_funnel_events ADD CONSTRAINT product_funnel_events_stage_check
  CHECK ((stage = ANY (ARRAY['annual_switch_clicked'::text, 'annual_switch_completed'::text, 'annual_switch_shown'::text, 'app_password_link_clicked'::text, 'authorize_inbox_connected'::text, 'authorize_inbox_step_viewed'::text, 'authorize_signup_redirect'::text, 'authorize_skipped'::text, 'billing_portal_opened'::text, 'cancel_reason_submitted'::text, 'checkout_completed'::text, 'checkout_started'::text, 'client_changed'::text, 'client_selected'::text, 'connect_fix_link_clicked'::text, 'connect_fix_shown'::text, 'connection_verified'::text, 'credential_created'::text, 'downgrade_scheduled'::text, 'downgrade_undone'::text, 'first_call_prompt_copied'::text, 'first_tool_call'::text, 'grace_end_note_shown'::text, 'heard_about_answered'::text, 'heard_about_dismissed'::text, 'inbox_alert_holdout'::text, 'inbox_alert_sent'::text, 'inbox_connection'::text, 'inbox_parked'::text, 'inbox_reconnected'::text, 'inbox_unparked'::text, 'install_link_clicked'::text, 'morning_brief_opt_in'::text, 'morning_brief_sent'::text, 'multi_inbox_prompt'::text, 'onboarding_completed'::text, 'onboarding_exited'::text, 'onboarding_handshake_seen'::text, 'onboarding_help_shown'::text, 'onboarding_link_emailed'::text, 'onboarding_open_client_clicked'::text, 'onboarding_prompt_copied'::text, 'onboarding_reset'::text, 'onboarding_started'::text, 'onboarding_step_viewed'::text, 'pass_checkout_completed'::text, 'pass_checkout_started'::text, 'pass_expired'::text, 'pass_offer_shown'::text, 'pass_refunded'::text, 'pass_reminder_sent'::text, 'pass_renewed'::text, 'pause_ended_cancelled'::text, 'pause_extended'::text, 'pause_resumed'::text, 'pause_started'::text, 'payment_fix_clicked'::text, 'paywall_clicked'::text, 'paywall_reached'::text, 'plan_downgraded'::text, 'plan_ending_reminder_holdout'::text, 'plan_ending_reminder_sent'::text, 'plan_kept'::text, 'plan_summary_clicked'::text, 'plan_summary_dismissed'::text, 'plan_summary_shown'::text, 'plan_upgraded'::text, 'pricing_viewed'::text, 'provider_selected'::text, 'referral_attach_refused'::text, 'referral_attached'::text, 'referral_capped'::text, 'referral_charged'::text, 'referral_click'::text, 'referral_held'::text, 'referral_link_copied'::text, 'referral_link_viewed'::text, 'referral_qualified'::text, 'referral_voided'::text, 'retention_option_clicked'::text, 'second_inbox_prompt_clicked'::text, 'second_inbox_prompt_shown'::text, 'signup_completed'::text, 'technical_activation'::text, 'usage_meter_shown'::text, 'value_activation'::text, 'waiting_state_shown'::text])));
