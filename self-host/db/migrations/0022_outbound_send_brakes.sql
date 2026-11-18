-- ============================================================
-- 0022 outbound send brakes
-- Upstream:
--   20261024130000_outbound_abuse_brakes.sql
--   20261103120000_fanout_brake_scope.sql
--   20261112130000_refusal_message_key.sql
-- ============================================================
-- Per-inbox safety brakes the server checks before every send
-- (outbound-brakes.ts): at most 500 messages per inbox per 24 hours, a hold
-- when one message fans out to more than workspaces.fanout_recipient_limit
-- recipients (default 25) within an hour, and a pause after repeated spam
-- refusals. workspaces.sends_frozen_at stops all sending for a workspace.
-- Raise the fan-out limit with:
--   UPDATE workspaces SET fanout_recipient_limit = 100;
-- The server fails open if these functions are missing, so before this
-- migration sends were simply unbraked. Final hosted function versions.
-- ============================================================

ALTER TABLE public.workspaces ADD COLUMN IF NOT EXISTS sends_frozen_at timestamp with time zone;
ALTER TABLE public.workspaces ADD COLUMN IF NOT EXISTS fanout_recipient_limit integer;

ALTER TABLE public.workspaces DROP CONSTRAINT IF EXISTS workspaces_fanout_recipient_limit_check;
ALTER TABLE public.workspaces ADD CONSTRAINT workspaces_fanout_recipient_limit_check
  CHECK (((fanout_recipient_limit IS NULL) OR (fanout_recipient_limit > 0)));

CREATE TABLE IF NOT EXISTS public.inbox_send_brakes (
    inbox_id uuid NOT NULL,
    workspace_id uuid NOT NULL,
    fanout_hold_until timestamp with time zone,
    refusal_pause_until timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    fanout_content_hash text,
    CONSTRAINT inbox_send_brakes_fanout_content_hash_check CHECK (((fanout_content_hash IS NULL) OR (fanout_content_hash ~ '^[0-9a-f]{64}$'::text)))
);

COMMENT ON COLUMN public.inbox_send_brakes.fanout_content_hash IS 'SHA-256 of the normalized content that tripped the fan-out brake. Only sends with this hash are held while fanout_hold_until is in the future.';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.inbox_send_brakes'::regclass AND conname = 'inbox_send_brakes_pkey') THEN
    ALTER TABLE public.inbox_send_brakes ADD CONSTRAINT inbox_send_brakes_pkey PRIMARY KEY (inbox_id);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_inbox_send_brakes_workspace_id ON public.inbox_send_brakes USING btree (workspace_id);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.inbox_send_brakes'::regclass AND conname = 'inbox_send_brakes_inbox_id_fkey') THEN
    ALTER TABLE public.inbox_send_brakes ADD CONSTRAINT inbox_send_brakes_inbox_id_fkey FOREIGN KEY (inbox_id) REFERENCES public.inboxes(id) ON DELETE CASCADE;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.inbox_send_brakes'::regclass AND conname = 'inbox_send_brakes_workspace_id_fkey') THEN
    ALTER TABLE public.inbox_send_brakes ADD CONSTRAINT inbox_send_brakes_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;
  END IF;
END $$;

ALTER TABLE public.inbox_send_brakes ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.outbound_send_events (
    id bigint NOT NULL,
    workspace_id uuid NOT NULL,
    inbox_id uuid NOT NULL,
    kind text NOT NULL,
    messages integer DEFAULT 1 NOT NULL,
    content_hash text,
    recipient_hash text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT outbound_send_events_content_hash_check CHECK (((content_hash IS NULL) OR (content_hash ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT outbound_send_events_kind_check CHECK ((kind = ANY (ARRAY['message'::text, 'recipient'::text, 'refusal'::text]))),
    CONSTRAINT outbound_send_events_messages_check CHECK ((messages >= 1)),
    CONSTRAINT outbound_send_events_recipient_hash_check CHECK (((recipient_hash IS NULL) OR (recipient_hash ~ '^[0-9a-f]{64}$'::text)))
);

DO $$
BEGIN
  IF (SELECT attidentity FROM pg_attribute WHERE attrelid = 'public.outbound_send_events'::regclass AND attname = 'id') = '' THEN
    ALTER TABLE public.outbound_send_events ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.outbound_send_events'::regclass AND conname = 'outbound_send_events_pkey') THEN
    ALTER TABLE public.outbound_send_events ADD CONSTRAINT outbound_send_events_pkey PRIMARY KEY (id);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_outbound_send_events_created_at ON public.outbound_send_events USING btree (created_at);

CREATE INDEX IF NOT EXISTS idx_outbound_send_events_inbox_content_time ON public.outbound_send_events USING btree (inbox_id, content_hash, created_at) WHERE (kind = 'recipient'::text);

CREATE INDEX IF NOT EXISTS idx_outbound_send_events_inbox_kind_time ON public.outbound_send_events USING btree (inbox_id, kind, created_at);

CREATE INDEX IF NOT EXISTS idx_outbound_send_events_workspace_id ON public.outbound_send_events USING btree (workspace_id);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.outbound_send_events'::regclass AND conname = 'outbound_send_events_inbox_id_fkey') THEN
    ALTER TABLE public.outbound_send_events ADD CONSTRAINT outbound_send_events_inbox_id_fkey FOREIGN KEY (inbox_id) REFERENCES public.inboxes(id) ON DELETE CASCADE;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.outbound_send_events'::regclass AND conname = 'outbound_send_events_workspace_id_fkey') THEN
    ALTER TABLE public.outbound_send_events ADD CONSTRAINT outbound_send_events_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;
  END IF;
END $$;

ALTER TABLE public.outbound_send_events ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.outbound_send_gate(p_workspace_id uuid, p_inbox_id uuid, p_messages integer, p_content_hash text, p_recipient_hashes text[], p_daily_limit integer, p_fanout_limit integer, p_fanout_window_ms bigint, p_human_approved boolean, p_commit boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  v_now        timestamptz := now();
  v_messages   integer := GREATEST(COALESCE(p_messages, 1), 1);
  v_frozen     timestamptz;
  v_brake      public.inbox_send_brakes%ROWTYPE;
  v_sent       bigint;
  v_oldest     timestamptz;
  v_distinct   bigint;
  v_hold_until timestamptz;
  v_limit      integer;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('outbound_send_gate:' || p_inbox_id::text, 0));

  SELECT sends_frozen_at, COALESCE(fanout_recipient_limit, p_fanout_limit)
    INTO v_frozen, v_limit
    FROM public.workspaces WHERE id = p_workspace_id;
  v_limit := COALESCE(v_limit, p_fanout_limit);
  IF v_frozen IS NOT NULL THEN
    RETURN jsonb_build_object('decision', 'frozen');
  END IF;

  SELECT * INTO v_brake FROM public.inbox_send_brakes WHERE inbox_id = p_inbox_id;
  IF v_brake.refusal_pause_until IS NOT NULL AND v_brake.refusal_pause_until > v_now THEN
    RETURN jsonb_build_object('decision', 'paused', 'retry_at', v_brake.refusal_pause_until);
  END IF;

  SELECT COALESCE(sum(messages), 0), min(created_at) INTO v_sent, v_oldest
    FROM public.outbound_send_events
   WHERE inbox_id = p_inbox_id AND kind = 'message' AND created_at > v_now - interval '24 hours';
  IF v_sent + v_messages > p_daily_limit THEN
    RETURN jsonb_build_object(
      'decision', 'daily_limit',
      'retry_at', COALESCE(v_oldest, v_now) + interval '24 hours'
    );
  END IF;

  IF NOT COALESCE(p_human_approved, false) THEN
    -- Only the message that tripped the brake is held. Other mail from the
    -- inbox goes out. A row from before fanout_content_hash existed has no
    -- hash, so it holds nothing.
    IF v_brake.fanout_hold_until IS NOT NULL AND v_brake.fanout_hold_until > v_now
       AND p_content_hash IS NOT NULL AND v_brake.fanout_content_hash = p_content_hash THEN
      RETURN jsonb_build_object('decision', 'hold', 'reason', 'fanout', 'retry_at', v_brake.fanout_hold_until, 'newly_tripped', false);
    END IF;

    IF p_content_hash IS NOT NULL AND COALESCE(cardinality(p_recipient_hashes), 0) > 0 THEN
      SELECT count(*) INTO v_distinct FROM (
        SELECT recipient_hash FROM public.outbound_send_events
         WHERE inbox_id = p_inbox_id
           AND kind = 'recipient'
           AND content_hash = p_content_hash
           AND created_at > v_now - (p_fanout_window_ms || ' milliseconds')::interval
        UNION
        SELECT unnest(p_recipient_hashes)
      ) AS recipients;
      IF v_distinct > v_limit THEN
        -- Held for one window, the same span the count looks back over.
        v_hold_until := v_now + (p_fanout_window_ms || ' milliseconds')::interval;
        INSERT INTO public.inbox_send_brakes (inbox_id, workspace_id, fanout_hold_until, fanout_content_hash, updated_at)
        VALUES (p_inbox_id, p_workspace_id, v_hold_until, p_content_hash, v_now)
        ON CONFLICT (inbox_id) DO UPDATE
          SET fanout_hold_until = EXCLUDED.fanout_hold_until,
              fanout_content_hash = EXCLUDED.fanout_content_hash,
              updated_at = v_now;
        RETURN jsonb_build_object('decision', 'hold', 'reason', 'fanout', 'retry_at', v_hold_until, 'newly_tripped', true);
      END IF;
    END IF;
  END IF;

  IF COALESCE(p_commit, true) THEN
    INSERT INTO public.outbound_send_events (workspace_id, inbox_id, kind, messages)
    VALUES (p_workspace_id, p_inbox_id, 'message', v_messages);
    IF p_content_hash IS NOT NULL AND COALESCE(cardinality(p_recipient_hashes), 0) > 0 THEN
      INSERT INTO public.outbound_send_events (workspace_id, inbox_id, kind, content_hash, recipient_hash)
      SELECT p_workspace_id, p_inbox_id, 'recipient', p_content_hash, r
        FROM (SELECT DISTINCT unnest(p_recipient_hashes) AS r) AS distinct_recipients
       WHERE r IS NOT NULL;
    END IF;
  END IF;

  RETURN jsonb_build_object('decision', 'allow');
END;
$$
;

REVOKE ALL ON FUNCTION public.outbound_send_gate(uuid,uuid,integer,text,text[],integer,integer,bigint,boolean,boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.outbound_send_gate(uuid,uuid,integer,text,text[],integer,integer,bigint,boolean,boolean) TO service_role;

CREATE OR REPLACE FUNCTION public.outbound_send_refusal(p_workspace_id uuid, p_inbox_id uuid, p_threshold integer, p_window_ms bigint, p_pause_ms bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  v_now    timestamptz := now();
  v_count  bigint;
  v_until  timestamptz;
  v_active timestamptz;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('outbound_send_gate:' || p_inbox_id::text, 0));

  INSERT INTO public.outbound_send_events (workspace_id, inbox_id, kind)
  VALUES (p_workspace_id, p_inbox_id, 'refusal');

  SELECT refusal_pause_until INTO v_active FROM public.inbox_send_brakes WHERE inbox_id = p_inbox_id;
  IF v_active IS NOT NULL AND v_active > v_now THEN
    RETURN jsonb_build_object('paused', true, 'newly_tripped', false, 'retry_at', v_active);
  END IF;

  SELECT count(*) INTO v_count FROM public.outbound_send_events
   WHERE inbox_id = p_inbox_id AND kind = 'refusal'
     AND created_at > v_now - (p_window_ms || ' milliseconds')::interval;
  IF v_count < p_threshold THEN
    RETURN jsonb_build_object('paused', false, 'newly_tripped', false);
  END IF;

  v_until := v_now + (p_pause_ms || ' milliseconds')::interval;
  INSERT INTO public.inbox_send_brakes (inbox_id, workspace_id, refusal_pause_until, updated_at)
  VALUES (p_inbox_id, p_workspace_id, v_until, v_now)
  ON CONFLICT (inbox_id) DO UPDATE
    SET refusal_pause_until = EXCLUDED.refusal_pause_until, updated_at = v_now;
  RETURN jsonb_build_object('paused', true, 'newly_tripped', true, 'retry_at', v_until);
END;
$$
;

CREATE OR REPLACE FUNCTION public.outbound_send_refusal(p_workspace_id uuid, p_inbox_id uuid, p_threshold integer, p_window_ms bigint, p_pause_ms bigint, p_message_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  v_now    timestamptz := now();
  v_window timestamptz := now() - (p_window_ms || ' milliseconds')::interval;
  v_count  bigint;
  v_until  timestamptz;
  v_active timestamptz;
  v_key    text := CASE WHEN p_message_key ~ '^[0-9a-f]{64}$' THEN p_message_key END;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('outbound_send_gate:' || p_inbox_id::text, 0));

  SELECT refusal_pause_until INTO v_active FROM public.inbox_send_brakes WHERE inbox_id = p_inbox_id;

  IF v_key IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.outbound_send_events
     WHERE inbox_id = p_inbox_id AND kind = 'refusal' AND content_hash = v_key AND created_at > v_window
  ) THEN
    IF v_active IS NOT NULL AND v_active > v_now THEN
      RETURN jsonb_build_object('paused', true, 'newly_tripped', false, 'retry_at', v_active, 'duplicate', true);
    END IF;
    RETURN jsonb_build_object('paused', false, 'newly_tripped', false, 'duplicate', true);
  END IF;

  INSERT INTO public.outbound_send_events (workspace_id, inbox_id, kind, content_hash)
  VALUES (p_workspace_id, p_inbox_id, 'refusal', v_key);

  IF v_active IS NOT NULL AND v_active > v_now THEN
    RETURN jsonb_build_object('paused', true, 'newly_tripped', false, 'retry_at', v_active);
  END IF;

  SELECT count(*) INTO v_count FROM public.outbound_send_events
   WHERE inbox_id = p_inbox_id AND kind = 'refusal' AND created_at > v_window;
  IF v_count < p_threshold THEN
    RETURN jsonb_build_object('paused', false, 'newly_tripped', false);
  END IF;

  v_until := v_now + (p_pause_ms || ' milliseconds')::interval;
  INSERT INTO public.inbox_send_brakes (inbox_id, workspace_id, refusal_pause_until, updated_at)
  VALUES (p_inbox_id, p_workspace_id, v_until, v_now)
  ON CONFLICT (inbox_id) DO UPDATE
    SET refusal_pause_until = EXCLUDED.refusal_pause_until, updated_at = v_now;
  RETURN jsonb_build_object('paused', true, 'newly_tripped', true, 'retry_at', v_until);
END;
$$
;

REVOKE ALL ON FUNCTION public.outbound_send_refusal(uuid,uuid,integer,bigint,bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.outbound_send_refusal(uuid,uuid,integer,bigint,bigint) TO service_role;
REVOKE ALL ON FUNCTION public.outbound_send_refusal(uuid,uuid,integer,bigint,bigint,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.outbound_send_refusal(uuid,uuid,integer,bigint,bigint,text) TO service_role;
