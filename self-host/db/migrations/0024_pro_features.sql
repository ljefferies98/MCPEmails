-- ============================================================
-- 0024 Pro features: gate, reminders, morning brief, subscription clean-up
-- Upstream:
--   20261024235100_pro_features_gate.sql (column, gate function)
--   20261024235200_reminders.sql (table, triggers; not the pg_cron job)
--   20261024235400_morning_briefs.sql (table, trigger; not the pg_cron job)
--   20261024210000_subscription_cleanup.sql (tables, workspaces column)
--   20261111190000_inbox_owner_visibility.sql (reminders.created_by)
-- ============================================================
-- Reminders (follow-ups, snoozes), cross-inbox search, per-inbox AI
-- instructions and the morning brief are off until you enable them:
--   UPDATE workspaces SET pro_features_enabled = true;
-- The seeded workspace is on the 'pro' plan, which the gate accepts.
-- Reminders and the morning brief also need the dispatcher to call
-- /reminders-dispatch and /morning-brief-dispatch (see docker-compose.yml);
-- hosted drives them with pg_cron + Vault, which are not ported.
-- subscriptions_scan / subscriptions_cleanup appear when
-- workspaces.subscription_cleanup_enabled is true.
-- ============================================================

ALTER TABLE public.workspaces ADD COLUMN IF NOT EXISTS pro_features_enabled boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.workspace_pro_features(p_workspace_id uuid)
 RETURNS TABLE(plan text, comped_scale boolean, rollout_enabled boolean, public_launch boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $$
  -- Hosted also reads pricing_switches.pro_features_public (the public
  -- launch). Self-host has no pricing switches: the features are visible
  -- exactly when workspaces.pro_features_enabled is true.
  SELECT
    CASE WHEN e.kind = 'comped_scale'
      AND (e.expires_at IS NULL OR e.expires_at > now()) THEN 'pro'
      ELSE w.plan
    END AS plan,
    COALESCE(e.kind = 'comped_scale' AND (e.expires_at IS NULL OR e.expires_at > now()), false) AS comped_scale,
    w.pro_features_enabled AS rollout_enabled,
    false AS public_launch
  FROM public.workspaces w
  LEFT JOIN public.user_usage_entitlements e ON e.user_id = w.owner_id
  WHERE w.id = p_workspace_id
    AND w.deleted_at IS NULL;
$$
;

REVOKE ALL ON FUNCTION public.workspace_pro_features(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.workspace_pro_features(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.reminders_enforce_integrity()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.inboxes i
    WHERE  i.id = NEW.inbox_id AND i.workspace_id = NEW.workspace_id
  ) THEN
    RAISE EXCEPTION 'reminders: inbox % does not belong to workspace %', NEW.inbox_id, NEW.workspace_id
      USING ERRCODE = '23514';
  END IF;

  IF NEW.api_key_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.api_keys k
    WHERE  k.id = NEW.api_key_id AND k.workspace_id = NEW.workspace_id
  ) THEN
    RAISE EXCEPTION 'reminders: api key % does not belong to workspace %', NEW.api_key_id, NEW.workspace_id
      USING ERRCODE = '23514';
  END IF;

  -- Message identifiers and the summary are only ever stored encrypted.
  IF jsonb_typeof(NEW.message_ref) <> 'object'
     OR NEW.message_ref ->> 'v' IS DISTINCT FROM '1'
     OR coalesce(NEW.message_ref ->> 'data', '') = ''
     OR (SELECT count(*) FROM jsonb_object_keys(NEW.message_ref)) <> 2 THEN
    RAISE EXCEPTION 'reminders: message_ref must be an encrypted wrapper'
      USING ERRCODE = '23514';
  END IF;
  IF NEW.summary IS NOT NULL THEN
    IF jsonb_typeof(NEW.summary) <> 'object'
       OR NEW.summary ->> 'v' IS DISTINCT FROM '1'
       OR coalesce(NEW.summary ->> 'data', '') = ''
       OR (SELECT count(*) FROM jsonb_object_keys(NEW.summary)) <> 2 THEN
      RAISE EXCEPTION 'reminders: summary must be an encrypted wrapper'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  RETURN NEW;
END;
$$
;

REVOKE ALL ON FUNCTION public.reminders_enforce_integrity() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reminders_enforce_integrity() TO service_role;

CREATE TABLE IF NOT EXISTS public.reminders (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    inbox_id uuid NOT NULL,
    api_key_id uuid,
    kind text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    condition text DEFAULT 'always'::text NOT NULL,
    due_at timestamp with time zone NOT NULL,
    next_check_at timestamp with time zone,
    message_digest text NOT NULL,
    message_ref jsonb NOT NULL,
    summary jsonb,
    folder text,
    claimed_at timestamp with time zone,
    lease_token uuid,
    consecutive_failures integer DEFAULT 0 NOT NULL,
    last_error_code text,
    last_checked_at timestamp with time zone,
    replied_at timestamp with time zone,
    returned_at timestamp with time zone,
    completed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid,
    CONSTRAINT reminders_condition_check CHECK ((condition = ANY (ARRAY['always'::text, 'no_reply'::text]))),
    CONSTRAINT reminders_error_code_length_check CHECK (((last_error_code IS NULL) OR (char_length(last_error_code) <= 64))),
    CONSTRAINT reminders_folder_length_check CHECK (((folder IS NULL) OR (char_length(folder) <= 512))),
    CONSTRAINT reminders_follow_up_condition_check CHECK (((kind <> 'follow_up'::text) OR (condition = 'no_reply'::text))),
    CONSTRAINT reminders_kind_check CHECK ((kind = ANY (ARRAY['follow_up'::text, 'snooze'::text]))),
    CONSTRAINT reminders_lease_pair_check CHECK (((claimed_at IS NULL) = (lease_token IS NULL))),
    CONSTRAINT reminders_snooze_folder_check CHECK (((kind <> 'snooze'::text) OR (folder IS NOT NULL))),
    CONSTRAINT reminders_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'due'::text, 'replied'::text, 'returned'::text, 'done'::text, 'cancelled'::text, 'failed'::text])))
);

COMMENT ON TABLE public.reminders IS 'Pro reminders: follow-ups (reply tracking) and snoozes (move out, bring back). Written only by service-role code; driven by pg_cron -> dispatch_reminders() -> mcp-server /reminders-dispatch. No message content in clear: message_ref and summary are AES-256-GCM wrappers {v,data} under ENCRYPTION_KEY.';

COMMENT ON COLUMN public.reminders.next_check_at IS 'When the dispatcher next acts: pending follow-ups every ~20 min (and exactly at due_at), due follow-ups every 6 h for 60 days, snoozes at due_at. NULL = never.';

COMMENT ON COLUMN public.reminders.message_digest IS 'HMAC-SHA256(ENCRYPTION_KEY, kind-tagged message id). Dedupe only; cannot be turned back into an id.';

COMMENT ON COLUMN public.reminders.message_ref IS 'Encrypted {provider_message_id, thread_id, rfc_message_id, since, snoozed_message_id?, snooze_folder_id?}.';

COMMENT ON COLUMN public.reminders.summary IS 'Encrypted {subject, to[], from}. Subject and addresses only, never a body.';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.reminders'::regclass AND conname = 'reminders_pkey') THEN
    ALTER TABLE public.reminders ADD CONSTRAINT reminders_pkey PRIMARY KEY (id);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS reminders_completed_idx ON public.reminders USING btree (completed_at) WHERE (completed_at IS NOT NULL);

CREATE INDEX IF NOT EXISTS reminders_due_idx ON public.reminders USING btree (next_check_at) WHERE ((status = ANY (ARRAY['pending'::text, 'due'::text])) AND (claimed_at IS NULL) AND (next_check_at IS NOT NULL));

CREATE INDEX IF NOT EXISTS reminders_inbox_open_idx ON public.reminders USING btree (inbox_id, next_check_at) WHERE (status = ANY (ARRAY['pending'::text, 'due'::text]));

CREATE UNIQUE INDEX IF NOT EXISTS reminders_open_message_uniq ON public.reminders USING btree (inbox_id, kind, message_digest) WHERE (status = ANY (ARRAY['pending'::text, 'due'::text, 'failed'::text]));

CREATE INDEX IF NOT EXISTS reminders_workspace_status_idx ON public.reminders USING btree (workspace_id, status, due_at);

DROP TRIGGER IF EXISTS reminders_enforce_integrity ON public.reminders;
CREATE TRIGGER reminders_enforce_integrity BEFORE INSERT OR UPDATE OF workspace_id, inbox_id, api_key_id, message_ref, summary ON public.reminders FOR EACH ROW EXECUTE FUNCTION public.reminders_enforce_integrity();

DROP TRIGGER IF EXISTS reminders_updated_at ON public.reminders;
CREATE TRIGGER reminders_updated_at BEFORE UPDATE ON public.reminders FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.reminders'::regclass AND conname = 'reminders_api_key_id_fkey') THEN
    ALTER TABLE public.reminders ADD CONSTRAINT reminders_api_key_id_fkey FOREIGN KEY (api_key_id) REFERENCES public.api_keys(id) ON DELETE SET NULL;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.reminders'::regclass AND conname = 'reminders_created_by_fkey') THEN
    ALTER TABLE public.reminders ADD CONSTRAINT reminders_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE SET NULL;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.reminders'::regclass AND conname = 'reminders_inbox_id_fkey') THEN
    ALTER TABLE public.reminders ADD CONSTRAINT reminders_inbox_id_fkey FOREIGN KEY (inbox_id) REFERENCES public.inboxes(id) ON DELETE CASCADE;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.reminders'::regclass AND conname = 'reminders_workspace_id_fkey') THEN
    ALTER TABLE public.reminders ADD CONSTRAINT reminders_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;
  END IF;
END $$;

ALTER TABLE public.reminders ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.reminders_rearm_on_reconnect()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
BEGIN
  UPDATE public.reminders
     SET next_check_at = now()
   WHERE inbox_id = NEW.id
     AND status IN ('pending', 'due')
     AND consecutive_failures > 0
     AND claimed_at IS NULL
     AND next_check_at > now()
     AND (kind = 'follow_up' OR due_at <= now());
  RETURN NEW;
END;
$$
;

REVOKE ALL ON FUNCTION public.reminders_rearm_on_reconnect() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reminders_rearm_on_reconnect() TO service_role;

DROP TRIGGER IF EXISTS reminders_rearm_on_reconnect ON public.inboxes;
CREATE TRIGGER reminders_rearm_on_reconnect AFTER UPDATE OF status, imap_password, oauth_refresh_token ON public.inboxes FOR EACH ROW WHEN (((new.status = 'active'::text) AND ((old.status IS DISTINCT FROM new.status) OR (old.imap_password IS DISTINCT FROM new.imap_password) OR (old.oauth_refresh_token IS DISTINCT FROM new.oauth_refresh_token)))) EXECUTE FUNCTION public.reminders_rearm_on_reconnect();

CREATE OR REPLACE FUNCTION public.morning_briefs_enforce_integrity()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.inbox_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.inboxes i
    WHERE  i.id = NEW.inbox_id AND i.workspace_id = NEW.workspace_id
  ) THEN
    RAISE EXCEPTION 'morning_briefs: inbox % does not belong to workspace %', NEW.inbox_id, NEW.workspace_id
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$
;

REVOKE ALL ON FUNCTION public.morning_briefs_enforce_integrity() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.morning_briefs_enforce_integrity() TO service_role;

CREATE TABLE IF NOT EXISTS public.morning_briefs (
    workspace_id uuid NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    hour smallint DEFAULT 7 NOT NULL,
    timezone text DEFAULT 'UTC'::text NOT NULL,
    locale text DEFAULT 'en'::text NOT NULL,
    inbox_id uuid,
    vip_senders text[] DEFAULT '{}'::text[] NOT NULL,
    next_due_at timestamp with time zone,
    last_local_date date,
    last_sent_at timestamp with time zone,
    last_run_at timestamp with time zone,
    last_outcome text,
    last_error_code text,
    consecutive_failures integer DEFAULT 0 NOT NULL,
    paused_at timestamp with time zone,
    claimed_at timestamp with time zone,
    lease_token uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT morning_briefs_error_code_length_check CHECK (((last_error_code IS NULL) OR (char_length(last_error_code) <= 64))),
    CONSTRAINT morning_briefs_hour_check CHECK (((hour >= 0) AND (hour <= 23))),
    CONSTRAINT morning_briefs_lease_pair_check CHECK (((claimed_at IS NULL) = (lease_token IS NULL))),
    CONSTRAINT morning_briefs_locale_check CHECK ((locale = ANY (ARRAY['en'::text, 'nb'::text, 'fr'::text, 'es'::text, 'de'::text]))),
    CONSTRAINT morning_briefs_outcome_check CHECK (((last_outcome IS NULL) OR (last_outcome = ANY (ARRAY['sent'::text, 'empty'::text, 'not_allowed'::text, 'skipped'::text, 'failed'::text])))),
    CONSTRAINT morning_briefs_timezone_check CHECK (((char_length(timezone) >= 1) AND (char_length(timezone) <= 64))),
    CONSTRAINT morning_briefs_vip_count_check CHECK ((cardinality(vip_senders) <= 50))
);

COMMENT ON TABLE public.morning_briefs IS 'Pro morning brief settings and schedule, one row per workspace. Driven by pg_cron -> dispatch_morning_briefs() -> mcp-server /morning-brief-dispatch. The brief is inserted into the target inbox, never sent and never metered.';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.morning_briefs'::regclass AND conname = 'morning_briefs_pkey') THEN
    ALTER TABLE public.morning_briefs ADD CONSTRAINT morning_briefs_pkey PRIMARY KEY (workspace_id);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS morning_briefs_due_idx ON public.morning_briefs USING btree (next_due_at NULLS FIRST) WHERE (enabled AND (paused_at IS NULL) AND (claimed_at IS NULL));

DROP TRIGGER IF EXISTS morning_briefs_enforce_integrity ON public.morning_briefs;
CREATE TRIGGER morning_briefs_enforce_integrity BEFORE INSERT OR UPDATE OF workspace_id, inbox_id ON public.morning_briefs FOR EACH ROW EXECUTE FUNCTION public.morning_briefs_enforce_integrity();

DROP TRIGGER IF EXISTS morning_briefs_updated_at ON public.morning_briefs;
CREATE TRIGGER morning_briefs_updated_at BEFORE UPDATE ON public.morning_briefs FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.morning_briefs'::regclass AND conname = 'morning_briefs_inbox_id_fkey') THEN
    ALTER TABLE public.morning_briefs ADD CONSTRAINT morning_briefs_inbox_id_fkey FOREIGN KEY (inbox_id) REFERENCES public.inboxes(id) ON DELETE SET NULL;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.morning_briefs'::regclass AND conname = 'morning_briefs_workspace_id_fkey') THEN
    ALTER TABLE public.morning_briefs ADD CONSTRAINT morning_briefs_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;
  END IF;
END $$;

ALTER TABLE public.morning_briefs ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.workspaces ADD COLUMN IF NOT EXISTS subscription_cleanup_enabled boolean NOT NULL DEFAULT false;

CREATE TABLE IF NOT EXISTS public.subscription_plans (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    inbox_id uuid NOT NULL,
    api_key_id uuid,
    senders jsonb NOT NULL,
    senders_encrypted boolean DEFAULT true NOT NULL,
    sender_count integer NOT NULL,
    summary jsonb DEFAULT '{}'::jsonb NOT NULL,
    window_days integer NOT NULL,
    scanned integer DEFAULT 0 NOT NULL,
    truncated boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    used_at timestamp with time zone,
    used_by_api_key_id uuid,
    progress jsonb,
    backlog_action text,
    backlog_moved integer DEFAULT 0 NOT NULL,
    backlog_remaining integer DEFAULT 0 NOT NULL,
    backlog_leased_until timestamp with time zone,
    CONSTRAINT subscription_plans_backlog_action_check CHECK (((backlog_action IS NULL) OR (backlog_action = ANY (ARRAY['archive'::text, 'keep'::text])))),
    CONSTRAINT subscription_plans_backlog_moved_check CHECK ((backlog_moved >= 0)),
    CONSTRAINT subscription_plans_backlog_remaining_check CHECK ((backlog_remaining >= 0)),
    CONSTRAINT subscription_plans_scanned_check CHECK ((scanned >= 0)),
    CONSTRAINT subscription_plans_sender_count_check CHECK ((sender_count >= 0)),
    CONSTRAINT subscription_plans_window_days_check CHECK (((window_days >= 1) AND (window_days <= 365)))
);

COMMENT ON TABLE public.subscription_plans IS 'Short-lived (15 min), single-use snapshots of a subscriptions_scan. senders and progress are AES-256-GCM ciphertext (unsubscribe URLs and message ids). Written only by mcp-server with the service role.';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.subscription_plans'::regclass AND conname = 'subscription_plans_pkey') THEN
    ALTER TABLE public.subscription_plans ADD CONSTRAINT subscription_plans_pkey PRIMARY KEY (id);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS subscription_plans_created_idx ON public.subscription_plans USING btree (created_at);

CREATE INDEX IF NOT EXISTS subscription_plans_workspace_created_idx ON public.subscription_plans USING btree (workspace_id, created_at DESC);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.subscription_plans'::regclass AND conname = 'subscription_plans_api_key_id_fkey') THEN
    ALTER TABLE public.subscription_plans ADD CONSTRAINT subscription_plans_api_key_id_fkey FOREIGN KEY (api_key_id) REFERENCES public.api_keys(id) ON DELETE SET NULL;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.subscription_plans'::regclass AND conname = 'subscription_plans_inbox_id_fkey') THEN
    ALTER TABLE public.subscription_plans ADD CONSTRAINT subscription_plans_inbox_id_fkey FOREIGN KEY (inbox_id) REFERENCES public.inboxes(id) ON DELETE CASCADE;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.subscription_plans'::regclass AND conname = 'subscription_plans_used_by_api_key_id_fkey') THEN
    ALTER TABLE public.subscription_plans ADD CONSTRAINT subscription_plans_used_by_api_key_id_fkey FOREIGN KEY (used_by_api_key_id) REFERENCES public.api_keys(id) ON DELETE SET NULL;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.subscription_plans'::regclass AND conname = 'subscription_plans_workspace_id_fkey') THEN
    ALTER TABLE public.subscription_plans ADD CONSTRAINT subscription_plans_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;
  END IF;
END $$;

ALTER TABLE public.subscription_plans ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.unsubscribe_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    inbox_id uuid NOT NULL,
    plan_id uuid,
    api_key_id uuid,
    sender_key text NOT NULL,
    sender_domain text,
    display_name text,
    from_address text,
    method text NOT NULL,
    status text NOT NULL,
    http_status integer,
    error text,
    url_host text,
    draft_id text,
    idempotency_key text NOT NULL,
    requested_at timestamp with time zone,
    check_after timestamp with time zone,
    checked_at timestamp with time zone,
    check_leased_at timestamp with time zone,
    check_attempts integer DEFAULT 0 NOT NULL,
    claimed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT unsubscribe_requests_check_attempts_check CHECK ((check_attempts >= 0)),
    CONSTRAINT unsubscribe_requests_display_name_check CHECK (((display_name IS NULL) OR (length(display_name) <= 200))),
    CONSTRAINT unsubscribe_requests_draft_id_check CHECK (((draft_id IS NULL) OR (length(draft_id) <= 1024))),
    CONSTRAINT unsubscribe_requests_error_check CHECK (((error IS NULL) OR (length(error) <= 64))),
    CONSTRAINT unsubscribe_requests_from_address_check CHECK (((from_address IS NULL) OR (length(from_address) <= 320))),
    CONSTRAINT unsubscribe_requests_http_status_check CHECK (((http_status IS NULL) OR ((http_status >= 100) AND (http_status <= 599)))),
    CONSTRAINT unsubscribe_requests_method_check CHECK ((method = ANY (ARRAY['one_click'::text, 'mailto'::text, 'link'::text, 'none'::text]))),
    CONSTRAINT unsubscribe_requests_sender_domain_check CHECK (((sender_domain IS NULL) OR (length(sender_domain) <= 255))),
    CONSTRAINT unsubscribe_requests_sender_key_check CHECK (((length(sender_key) >= 1) AND (length(sender_key) <= 600))),
    CONSTRAINT unsubscribe_requests_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'requested'::text, 'failed'::text, 'draft_ready'::text, 'needs_user'::text, 'filtered'::text, 'skipped_unsafe'::text, 'stopped'::text, 'still_sending'::text]))),
    CONSTRAINT unsubscribe_requests_url_host_check CHECK (((url_host IS NULL) OR (length(url_host) <= 255)))
);

COMMENT ON TABLE public.unsubscribe_requests IS 'One row per unsubscribe attempt per (inbox, sender, target host or address), keyed by an HMAC idempotency key so a replay never sends a second request. Holds the URL host only, never the URL. Written only by mcp-server with the service role.';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.unsubscribe_requests'::regclass AND conname = 'unsubscribe_requests_idempotency_key_key') THEN
    ALTER TABLE public.unsubscribe_requests ADD CONSTRAINT unsubscribe_requests_idempotency_key_key UNIQUE (idempotency_key);
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.unsubscribe_requests'::regclass AND conname = 'unsubscribe_requests_pkey') THEN
    ALTER TABLE public.unsubscribe_requests ADD CONSTRAINT unsubscribe_requests_pkey PRIMARY KEY (id);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS unsubscribe_requests_follow_up_idx ON public.unsubscribe_requests USING btree (check_after) WHERE ((checked_at IS NULL) AND (check_after IS NOT NULL));

CREATE INDEX IF NOT EXISTS unsubscribe_requests_inbox_idx ON public.unsubscribe_requests USING btree (inbox_id);

CREATE INDEX IF NOT EXISTS unsubscribe_requests_plan_idx ON public.unsubscribe_requests USING btree (plan_id) WHERE (plan_id IS NOT NULL);

CREATE INDEX IF NOT EXISTS unsubscribe_requests_workspace_created_idx ON public.unsubscribe_requests USING btree (workspace_id, created_at DESC);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.unsubscribe_requests'::regclass AND conname = 'unsubscribe_requests_api_key_id_fkey') THEN
    ALTER TABLE public.unsubscribe_requests ADD CONSTRAINT unsubscribe_requests_api_key_id_fkey FOREIGN KEY (api_key_id) REFERENCES public.api_keys(id) ON DELETE SET NULL;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.unsubscribe_requests'::regclass AND conname = 'unsubscribe_requests_inbox_id_fkey') THEN
    ALTER TABLE public.unsubscribe_requests ADD CONSTRAINT unsubscribe_requests_inbox_id_fkey FOREIGN KEY (inbox_id) REFERENCES public.inboxes(id) ON DELETE CASCADE;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.unsubscribe_requests'::regclass AND conname = 'unsubscribe_requests_plan_id_fkey') THEN
    ALTER TABLE public.unsubscribe_requests ADD CONSTRAINT unsubscribe_requests_plan_id_fkey FOREIGN KEY (plan_id) REFERENCES public.subscription_plans(id) ON DELETE SET NULL;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.unsubscribe_requests'::regclass AND conname = 'unsubscribe_requests_workspace_id_fkey') THEN
    ALTER TABLE public.unsubscribe_requests ADD CONSTRAINT unsubscribe_requests_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;
  END IF;
END $$;

ALTER TABLE public.unsubscribe_requests ENABLE ROW LEVEL SECURITY;
