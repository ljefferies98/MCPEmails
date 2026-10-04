-- ============================================================
-- 0013 automations: triage_rules, triage_runs, triage_run_items, triage_seen_messages
-- Upstream: 20260819170000_create_triage_automations.sql
--           20260912200000_free_action_cap_150.sql (triage_rules.paused_*)
-- ============================================================
-- Backing store for the automation_* tools (scope manage:automations). Rules
-- run when something POSTs /triage-dispatch; on self-host that is the
-- `dispatcher` service (profile "scheduler"), replacing the hosted pg_cron job
-- in 20260819190000_schedule_triage_dispatch.sql, which is not ported.
--
-- triage_rules.created_by references auth.users on hosted; self-host has no
-- auth schema, so it references public.users, which plays the same role here.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.triage_rules (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id         uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE CASCADE,
  inbox_id             uuid NOT NULL REFERENCES public.inboxes(id) ON DELETE CASCADE,
  api_key_id           uuid NOT NULL REFERENCES public.api_keys(id) ON DELETE CASCADE,
  created_by           uuid REFERENCES public.users(id) ON DELETE SET NULL,
  name                 text NOT NULL,
  enabled              boolean NOT NULL DEFAULT false,
  filter               jsonb NOT NULL,
  action               jsonb NOT NULL,
  interval_minutes     integer NOT NULL,
  max_messages_per_run integer NOT NULL DEFAULT 25,
  next_run_at          timestamptz,
  last_run_at          timestamptz,
  running_since        timestamptz,
  consecutive_failures integer NOT NULL DEFAULT 0,
  disabled_reason      text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz
);

ALTER TABLE public.triage_rules
  ADD COLUMN IF NOT EXISTS paused_reason text,
  ADD COLUMN IF NOT EXISTS paused_until  timestamptz;

ALTER TABLE public.triage_rules DROP CONSTRAINT IF EXISTS triage_rules_name_length_check;
ALTER TABLE public.triage_rules ADD CONSTRAINT triage_rules_name_length_check
  CHECK (char_length(name) BETWEEN 1 AND 80);
ALTER TABLE public.triage_rules DROP CONSTRAINT IF EXISTS triage_rules_interval_minutes_check;
ALTER TABLE public.triage_rules ADD CONSTRAINT triage_rules_interval_minutes_check
  CHECK (interval_minutes IN (15, 30, 60, 180, 360, 720, 1440));
ALTER TABLE public.triage_rules DROP CONSTRAINT IF EXISTS triage_rules_max_messages_check;
ALTER TABLE public.triage_rules ADD CONSTRAINT triage_rules_max_messages_check
  CHECK (max_messages_per_run BETWEEN 1 AND 200);
ALTER TABLE public.triage_rules DROP CONSTRAINT IF EXISTS triage_rules_interval_required_check;
ALTER TABLE public.triage_rules ADD CONSTRAINT triage_rules_interval_required_check
  CHECK (interval_minutes IS NOT NULL);

CREATE INDEX IF NOT EXISTS triage_rules_due_idx
  ON public.triage_rules (next_run_at)
  WHERE enabled AND deleted_at IS NULL AND running_since IS NULL;
CREATE INDEX IF NOT EXISTS triage_rules_workspace_idx
  ON public.triage_rules (workspace_id, created_at DESC);

CREATE OR REPLACE TRIGGER triage_rules_updated_at
  BEFORE UPDATE ON public.triage_rules
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE IF NOT EXISTS public.triage_runs (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_id      uuid NOT NULL REFERENCES public.triage_rules(id) ON DELETE CASCADE,
  workspace_id uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE CASCADE,
  status       text NOT NULL,
  trigger      text NOT NULL DEFAULT 'schedule',
  started_at   timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  duration_ms  integer,
  matched      integer NOT NULL DEFAULT 0,
  processed    integer NOT NULL DEFAULT 0,
  succeeded    integer NOT NULL DEFAULT 0,
  failed       integer NOT NULL DEFAULT 0,
  skipped      integer NOT NULL DEFAULT 0,
  error_code   text,
  error_detail text
);

ALTER TABLE public.triage_runs DROP CONSTRAINT IF EXISTS triage_runs_status_check;
ALTER TABLE public.triage_runs ADD CONSTRAINT triage_runs_status_check
  CHECK (status IN ('running', 'completed', 'completed_with_errors', 'failed', 'skipped'));
ALTER TABLE public.triage_runs DROP CONSTRAINT IF EXISTS triage_runs_trigger_check;
ALTER TABLE public.triage_runs ADD CONSTRAINT triage_runs_trigger_check
  CHECK (trigger IN ('schedule', 'manual'));
ALTER TABLE public.triage_runs DROP CONSTRAINT IF EXISTS triage_runs_completed_at_check;
ALTER TABLE public.triage_runs ADD CONSTRAINT triage_runs_completed_at_check
  CHECK ((status = 'running') = (completed_at IS NULL));

CREATE INDEX IF NOT EXISTS triage_runs_rule_idx
  ON public.triage_runs (rule_id, started_at DESC);

CREATE TABLE IF NOT EXISTS public.triage_run_items (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id           uuid NOT NULL REFERENCES public.triage_runs(id) ON DELETE CASCADE,
  rule_id          uuid NOT NULL REFERENCES public.triage_rules(id) ON DELETE CASCADE,
  message_digest   text NOT NULL,
  subject_redacted text,
  sender_redacted  text,
  outcome          text NOT NULL,
  detail           jsonb NOT NULL DEFAULT '{}'::jsonb,
  undo_state       jsonb,
  undone_at        timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.triage_run_items DROP CONSTRAINT IF EXISTS triage_run_items_outcome_check;
ALTER TABLE public.triage_run_items ADD CONSTRAINT triage_run_items_outcome_check
  CHECK (outcome IN ('applied', 'queued_for_approval', 'failed', 'skipped_duplicate'));

CREATE INDEX IF NOT EXISTS triage_run_items_run_idx
  ON public.triage_run_items (run_id, created_at);

-- The server upserts with onConflict "rule_id,message_digest"; the primary key
-- is the conflict target.
CREATE TABLE IF NOT EXISTS public.triage_seen_messages (
  rule_id        uuid NOT NULL REFERENCES public.triage_rules(id) ON DELETE CASCADE,
  message_digest text NOT NULL,
  first_seen_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (rule_id, message_digest)
);
