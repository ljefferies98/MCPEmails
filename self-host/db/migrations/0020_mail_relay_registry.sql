-- ============================================================
-- 0020 mail relay registry
-- Upstream:
--   20261015180000_mail_relay_registry.sql (tables, record/learn functions)
--   20261015200000_mail_relay_learning_gate.sql
--   20261016100000_mail_relay_learning_rescued_calls.sql
--   20261026140000_mail_relay_learning_automation_runs.sql
-- ============================================================
-- The server records relayed connections and learns hosts that need the relay
-- whenever SMTP_RELAY_URL is set (optional on self-host, see docs/smtp-relay.md).
-- Without a relay these tables stay empty. The functions are the final hosted
-- versions after the three learning-gate migrations. The growth_mail_relay_*
-- reporting functions are hosted-only.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.mail_relay_hosts (
    host text NOT NULL,
    protocol text NOT NULL,
    source text DEFAULT 'auto'::text NOT NULL,
    reason text,
    learned_by text,
    first_learned_at timestamp with time zone DEFAULT now() NOT NULL,
    last_learned_at timestamp with time zone DEFAULT now() NOT NULL,
    times_learned integer DEFAULT 1 NOT NULL,
    CONSTRAINT mail_relay_hosts_host_shape CHECK ((host ~ '^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$'::text)),
    CONSTRAINT mail_relay_hosts_learned_by_check CHECK (((learned_by IS NULL) OR (learned_by = ANY (ARRAY['web'::text, 'edge'::text])))),
    CONSTRAINT mail_relay_hosts_protocol_check CHECK ((protocol = ANY (ARRAY['imap'::text, 'smtp'::text]))),
    CONSTRAINT mail_relay_hosts_source_check CHECK ((source = ANY (ARRAY['auto'::text, 'manual'::text])))
);

COMMENT ON TABLE public.mail_relay_hosts IS 'Mail hosts reached through the non-AWS relay because a direct connection failed and a relayed one worked. auto rows expire 30 days after last_learned_at (readers apply it) and are re-learned if still needed. Service-role only.';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.mail_relay_hosts'::regclass AND conname = 'mail_relay_hosts_pkey') THEN
    ALTER TABLE public.mail_relay_hosts ADD CONSTRAINT mail_relay_hosts_pkey PRIMARY KEY (host, protocol);
  END IF;
END $$;

ALTER TABLE public.mail_relay_hosts ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.mail_relay_stats (
    hour timestamp with time zone NOT NULL,
    runtime text NOT NULL,
    protocol text NOT NULL,
    host text NOT NULL,
    route text NOT NULL,
    outcome text NOT NULL,
    count integer DEFAULT 0 NOT NULL,
    total_ms bigint DEFAULT 0 NOT NULL,
    last_detail text,
    last_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT mail_relay_stats_outcome_check CHECK ((outcome = ANY (ARRAY['ok'::text, 'relay_down'::text, 'host_refused'::text]))),
    CONSTRAINT mail_relay_stats_protocol_check CHECK ((protocol = ANY (ARRAY['imap'::text, 'smtp'::text]))),
    CONSTRAINT mail_relay_stats_route_check CHECK ((route = ANY (ARRAY['listed'::text, 'learned'::text, 'fallback'::text]))),
    CONSTRAINT mail_relay_stats_runtime_check CHECK ((runtime = ANY (ARRAY['web'::text, 'edge'::text])))
);

COMMENT ON TABLE public.mail_relay_stats IS 'Hourly counters of connections carried by the mail relay: listed (hand-kept list), learned (mail_relay_hosts) or fallback (one retry after a direct failure); ok, relay_down or host_refused. Service-role only.';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.mail_relay_stats'::regclass AND conname = 'mail_relay_stats_pkey') THEN
    ALTER TABLE public.mail_relay_stats ADD CONSTRAINT mail_relay_stats_pkey PRIMARY KEY (hour, runtime, protocol, host, route, outcome);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS mail_relay_stats_last_at_idx ON public.mail_relay_stats USING btree (last_at);

ALTER TABLE public.mail_relay_stats ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.mail_relay_candidates (
    host text NOT NULL,
    protocol text NOT NULL,
    rescues integer DEFAULT 1 NOT NULL,
    first_rescue_at timestamp with time zone DEFAULT now() NOT NULL,
    last_rescue_at timestamp with time zone DEFAULT now() NOT NULL,
    last_reason text,
    last_runtime text,
    direct_successes integer DEFAULT 0 NOT NULL,
    refused boolean DEFAULT false NOT NULL,
    CONSTRAINT mail_relay_candidates_last_runtime_check CHECK (((last_runtime IS NULL) OR (last_runtime = ANY (ARRAY['web'::text, 'edge'::text])))),
    CONSTRAINT mail_relay_candidates_protocol_check CHECK ((protocol = ANY (ARRAY['imap'::text, 'smtp'::text])))
);

COMMENT ON TABLE public.mail_relay_candidates IS 'Hosts the relay rescued once (or that rule 1 refused): learned into mail_relay_hosts only at a second rescue 5+ minutes after the first, and never with 5+ direct successes in 7 days. Service-role only.';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.mail_relay_candidates'::regclass AND conname = 'mail_relay_candidates_pkey') THEN
    ALTER TABLE public.mail_relay_candidates ADD CONSTRAINT mail_relay_candidates_pkey PRIMARY KEY (host, protocol);
  END IF;
END $$;

ALTER TABLE public.mail_relay_candidates ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.record_mail_relay_use(p_runtime text, p_protocol text, p_host text, p_route text, p_outcome text, p_ms integer, p_detail text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $$
BEGIN
  INSERT INTO public.mail_relay_stats AS s
    (hour, runtime, protocol, host, route, outcome, count, total_ms, last_detail, last_at)
  VALUES (
    date_trunc('hour', now()), p_runtime, p_protocol, lower(p_host), p_route, p_outcome,
    1, GREATEST(COALESCE(p_ms, 0), 0), left(p_detail, 300), now()
  )
  ON CONFLICT (hour, runtime, protocol, host, route, outcome) DO UPDATE SET
    count = s.count + 1,
    total_ms = s.total_ms + GREATEST(COALESCE(p_ms, 0), 0),
    last_detail = COALESCE(left(EXCLUDED.last_detail, 300), s.last_detail),
    last_at = now();

  -- Self-trimming, about once in two hundred writes. Cheap: the table holds a
  -- handful of rows per relayed host per hour.
  IF random() < 0.005 THEN
    DELETE FROM public.mail_relay_stats WHERE last_at < now() - interval '120 days';
  END IF;
END;
$$
;

REVOKE ALL ON FUNCTION public.record_mail_relay_use(text,text,text,text,text,integer,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_mail_relay_use(text,text,text,text,text,integer,text) TO service_role;

CREATE OR REPLACE FUNCTION public.learn_mail_relay_host(p_host text, p_protocol text, p_reason text, p_runtime text)
 RETURNS boolean
 LANGUAGE plpgsql
 SET search_path TO ''
AS $$
DECLARE
  c_max_direct_successes constant integer := 5;
  c_rescues_needed constant integer := 2;
  c_min_spread constant interval := interval '5 minutes';
  c_window constant interval := interval '7 days';
  c_learned_for constant interval := interval '30 days';
  c_send_tools constant text[] := ARRAY['email_send', 'email_reply', 'email_forward', 'draft_send', 'email_compose'];

  v_host text := lower(trim(p_host));
  v_known public.mail_relay_hosts%ROWTYPE;
  v_since timestamptz := now() - c_window;
  v_calls bigint;
  v_rescued bigint;
  v_ok bigint;
  v_candidate public.mail_relay_candidates%ROWTYPE;
BEGIN
  SELECT * INTO v_known FROM public.mail_relay_hosts WHERE host = v_host AND protocol = p_protocol;

  -- Still relayed (manual, or learned and not expired): nothing to decide.
  IF FOUND AND (v_known.source = 'manual' OR v_known.last_learned_at > now() - c_learned_for) THEN
    RETURN true;
  END IF;

  -- Calls made while an earlier learning was in force went through the relay.
  IF FOUND THEN
    v_since := GREATEST(v_since, v_known.last_learned_at + c_learned_for);
  END IF;

  SELECT count(*)
    INTO v_calls
    FROM public.activity_log a
    JOIN public.inboxes i ON i.id = a.inbox_id
   WHERE a.created_at > v_since
     AND a.status = 'success'
     AND CASE
           WHEN p_protocol = 'smtp' THEN
             lower(i.smtp_host) = v_host
             AND a.tool_name = ANY (c_send_tools)
           ELSE
             lower(i.imap_host) = v_host
             AND NOT (a.tool_name = ANY (c_send_tools))
             AND a.tool_name NOT LIKE 'signature\_%'
             AND a.tool_name NOT LIKE 'schedule\_%'
             AND a.tool_name NOT LIKE 'automation\_%'
             AND a.tool_name <> 'contact_search'
         END;

  -- Unattended IMAP work: automation runs that got past the provider search.
  IF p_protocol = 'imap' THEN
    SELECT v_calls + count(*)
      INTO v_calls
      FROM public.triage_runs r
      JOIN public.triage_rules t ON t.id = r.rule_id
      JOIN public.inboxes i ON i.id = t.inbox_id
     WHERE r.started_at > v_since
       AND r.status IN ('completed', 'completed_with_errors', 'skipped')
       AND lower(i.imap_host) = v_host;
  END IF;

  -- Successes the relay carried are not evidence that the host works directly.
  SELECT COALESCE(sum(s.count), 0)
    INTO v_rescued
    FROM public.mail_relay_stats s
   WHERE s.host = v_host
     AND s.protocol = p_protocol
     AND s.route IN ('fallback', 'learned')
     AND s.outcome = 'ok'
     AND s.hour >= date_trunc('hour', v_since);

  v_ok := GREATEST(v_calls - v_rescued, 0);

  -- Rule 1: a host that works directly is never learned.
  IF v_ok >= c_max_direct_successes THEN
    INSERT INTO public.mail_relay_candidates AS c
      (host, protocol, rescues, last_reason, last_runtime, direct_successes, refused)
    VALUES (v_host, p_protocol, 1, left(p_reason, 300), p_runtime, v_ok, true)
    ON CONFLICT (host, protocol) DO UPDATE SET
      rescues = CASE WHEN c.first_rescue_at < now() - c_window THEN 1 ELSE c.rescues + 1 END,
      first_rescue_at = CASE WHEN c.first_rescue_at < now() - c_window THEN now() ELSE c.first_rescue_at END,
      last_rescue_at = now(),
      last_reason = EXCLUDED.last_reason,
      last_runtime = EXCLUDED.last_runtime,
      direct_successes = EXCLUDED.direct_successes,
      refused = true;
    RETURN false;
  END IF;

  -- Rule 2: count this rescue. Evidence older than the window starts over.
  INSERT INTO public.mail_relay_candidates AS c
    (host, protocol, rescues, last_reason, last_runtime, direct_successes, refused)
  VALUES (v_host, p_protocol, 1, left(p_reason, 300), p_runtime, v_ok, false)
  ON CONFLICT (host, protocol) DO UPDATE SET
    rescues = CASE WHEN c.first_rescue_at < now() - c_window THEN 1 ELSE c.rescues + 1 END,
    first_rescue_at = CASE WHEN c.first_rescue_at < now() - c_window THEN now() ELSE c.first_rescue_at END,
    last_rescue_at = now(),
    last_reason = EXCLUDED.last_reason,
    last_runtime = EXCLUDED.last_runtime,
    direct_successes = EXCLUDED.direct_successes,
    refused = false
  RETURNING * INTO v_candidate;

  IF v_candidate.rescues < c_rescues_needed OR v_candidate.last_rescue_at - v_candidate.first_rescue_at < c_min_spread THEN
    RETURN false;
  END IF;

  INSERT INTO public.mail_relay_hosts (host, protocol, source, reason, learned_by)
  VALUES (v_host, p_protocol, 'auto', left(p_reason, 300), p_runtime)
  ON CONFLICT (host, protocol) DO UPDATE SET
    last_learned_at = now(),
    times_learned = public.mail_relay_hosts.times_learned + 1,
    reason = EXCLUDED.reason,
    learned_by = EXCLUDED.learned_by;
  DELETE FROM public.mail_relay_candidates WHERE host = v_host AND protocol = p_protocol;
  RETURN true;
END;
$$
;

REVOKE ALL ON FUNCTION public.learn_mail_relay_host(text,text,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.learn_mail_relay_host(text,text,text,text) TO service_role;
