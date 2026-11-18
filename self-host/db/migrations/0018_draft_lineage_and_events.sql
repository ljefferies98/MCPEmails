-- ============================================================
-- 0018 draft lineage, draft card activity, draft events
-- Upstream:
--   20261013120000_draft_lineage.sql
--   20261015220000_draft_card_activity.sql
--   20261026210000_draft_card_activity_deleted.sql
--   20261027120000_draft_events.sql (table only)
-- ============================================================
-- draft_lineage maps every id one draft has had (IMAP gives a draft a new id on
-- every save) to the current one, and draft_lineage_record() writes it atomically.
-- The draft tools read both; draft_delete's base_revision depends on them.
-- draft_card_activity and draft_events are written by the server around the
-- MCP Apps draft editor. The growth_* reporting functions and the activity_log
-- backfill in 20261027120000 are hosted-only and not ported.
-- All three tables are service-role only (RLS on, no policies).
-- ============================================================

CREATE TABLE IF NOT EXISTS public.draft_lineage (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    inbox_id uuid NOT NULL,
    line_id uuid NOT NULL,
    draft_id text NOT NULL,
    revision integer NOT NULL,
    written_by text NOT NULL,
    written_at timestamp with time zone DEFAULT now() NOT NULL,
    closed_at timestamp with time zone,
    closed_reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT draft_lineage_closed_reason_check CHECK (((closed_reason IS NULL) OR (closed_reason = ANY (ARRAY['sent'::text, 'sent_kept'::text, 'deleted'::text])))),
    CONSTRAINT draft_lineage_closed_together CHECK (((closed_at IS NULL) = (closed_reason IS NULL))),
    CONSTRAINT draft_lineage_draft_id_check CHECK (((char_length(draft_id) >= 1) AND (char_length(draft_id) <= 1024))),
    CONSTRAINT draft_lineage_revision_check CHECK ((revision >= 1)),
    CONSTRAINT draft_lineage_written_by_check CHECK ((written_by = ANY (ARRAY['agent'::text, 'user'::text])))
);

COMMENT ON TABLE public.draft_lineage IS 'Draft id lineage for the mcp-server draft tools: every id one draft has had (IMAP gives a draft a new id on every save), so an older id resolves to the current one. Provider ids, a revision, who wrote last and when, and how the line closed (sent / deleted). No mail content. Service-role only; no policies on purpose.';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.draft_lineage'::regclass AND conname = 'draft_lineage_inbox_draft_key') THEN
    ALTER TABLE public.draft_lineage ADD CONSTRAINT draft_lineage_inbox_draft_key UNIQUE (inbox_id, draft_id);
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.draft_lineage'::regclass AND conname = 'draft_lineage_line_revision_key') THEN
    ALTER TABLE public.draft_lineage ADD CONSTRAINT draft_lineage_line_revision_key UNIQUE (inbox_id, line_id, revision);
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.draft_lineage'::regclass AND conname = 'draft_lineage_pkey') THEN
    ALTER TABLE public.draft_lineage ADD CONSTRAINT draft_lineage_pkey PRIMARY KEY (id);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS draft_lineage_workspace_idx ON public.draft_lineage USING btree (workspace_id);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.draft_lineage'::regclass AND conname = 'draft_lineage_inbox_id_fkey') THEN
    ALTER TABLE public.draft_lineage ADD CONSTRAINT draft_lineage_inbox_id_fkey FOREIGN KEY (inbox_id) REFERENCES public.inboxes(id) ON DELETE CASCADE;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.draft_lineage'::regclass AND conname = 'draft_lineage_workspace_id_fkey') THEN
    ALTER TABLE public.draft_lineage ADD CONSTRAINT draft_lineage_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;
  END IF;
END $$;

ALTER TABLE public.draft_lineage ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.draft_lineage_record(p_workspace_id uuid, p_inbox_id uuid, p_draft_id text, p_written_by text, p_line_id uuid DEFAULT NULL::uuid, p_expected_revision integer DEFAULT NULL::integer, p_seed_draft_id text DEFAULT NULL::text, p_adopt boolean DEFAULT false, p_written_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS TABLE(recorded_line_id uuid, recorded_revision integer, contended boolean)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $$
DECLARE
  v_line        uuid;
  v_head_rev    integer;
  v_head_closed boolean;
  v_contended   boolean := false;
  v_next        integer;
  v_at          timestamptz := coalesce(p_written_at, now());
  v_rows        integer;
BEGIN
  IF p_workspace_id IS NULL OR p_inbox_id IS NULL OR p_draft_id IS NULL OR p_written_by IS NULL THEN
    RAISE EXCEPTION 'draft_lineage_record: workspace, inbox, draft id and writer are required'
      USING ERRCODE = '22004';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('public.draft_lineage:' || p_inbox_id::text, 0)
  );

  -- 1. The line the caller resolved, if it is still open.
  IF p_line_id IS NOT NULL THEN
    SELECT l.revision, l.closed_at IS NOT NULL
      INTO v_head_rev, v_head_closed
      FROM public.draft_lineage l
     WHERE l.workspace_id = p_workspace_id
       AND l.inbox_id = p_inbox_id
       AND l.line_id = p_line_id
     ORDER BY l.revision DESC
     LIMIT 1;
    IF FOUND AND NOT v_head_closed THEN
      v_line := p_line_id;
      v_contended := p_expected_revision IS DISTINCT FROM v_head_rev;
    ELSE
      v_contended := true;
    END IF;
  END IF;

  -- 2. A line somebody else started for this very id meanwhile.
  IF v_line IS NULL AND p_adopt THEN
    SELECT l.line_id, l.revision
      INTO v_line, v_head_rev
      FROM public.draft_lineage l
     WHERE l.workspace_id = p_workspace_id
       AND l.inbox_id = p_inbox_id
       AND l.draft_id = p_draft_id
       AND l.closed_at IS NULL
       AND NOT EXISTS (
         SELECT 1 FROM public.draft_lineage h
          WHERE h.inbox_id = l.inbox_id
            AND h.line_id = l.line_id
            AND h.revision > l.revision
       );
    IF v_line IS NOT NULL THEN
      v_contended := true;
    END IF;
  END IF;

  -- 3. Otherwise a new line, seeded with the older id when there is one.
  IF v_line IS NULL THEN
    v_line := gen_random_uuid();
    v_head_rev := 0;
    IF p_seed_draft_id IS NOT NULL AND p_seed_draft_id <> p_draft_id THEN
      INSERT INTO public.draft_lineage
        (workspace_id, inbox_id, line_id, draft_id, revision, written_by, written_at)
      VALUES
        (p_workspace_id, p_inbox_id, v_line, p_seed_draft_id, 1, p_written_by, v_at)
      ON CONFLICT (inbox_id, draft_id) DO UPDATE
        SET line_id = EXCLUDED.line_id,
            revision = EXCLUDED.revision,
            written_by = EXCLUDED.written_by,
            written_at = EXCLUDED.written_at,
            closed_at = NULL,
            closed_reason = NULL
        WHERE public.draft_lineage.workspace_id = EXCLUDED.workspace_id;
      GET DIAGNOSTICS v_rows = ROW_COUNT;
      IF v_rows = 0 THEN
        RAISE EXCEPTION 'draft_lineage_record: draft id belongs to another workspace'
          USING ERRCODE = '42501';
      END IF;
      v_head_rev := 1;
    END IF;
  END IF;

  v_next := v_head_rev + 1;
  INSERT INTO public.draft_lineage
    (workspace_id, inbox_id, line_id, draft_id, revision, written_by, written_at)
  VALUES
    (p_workspace_id, p_inbox_id, v_line, p_draft_id, v_next, p_written_by, v_at)
  ON CONFLICT (inbox_id, draft_id) DO UPDATE
    SET line_id = EXCLUDED.line_id,
        revision = EXCLUDED.revision,
        written_by = EXCLUDED.written_by,
        written_at = EXCLUDED.written_at,
        closed_at = NULL,
        closed_reason = NULL
    WHERE public.draft_lineage.workspace_id = EXCLUDED.workspace_id;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RAISE EXCEPTION 'draft_lineage_record: draft id belongs to another workspace'
      USING ERRCODE = '42501';
  END IF;

  recorded_line_id := v_line;
  recorded_revision := v_next;
  contended := v_contended;
  RETURN NEXT;
END;
$$
;

REVOKE ALL ON FUNCTION public.draft_lineage_record(uuid,uuid,text,text,uuid,integer,text,boolean,timestamp with time zone) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.draft_lineage_record(uuid,uuid,text,text,uuid,integer,text,boolean,timestamp with time zone) TO service_role;

CREATE TABLE IF NOT EXISTS public.draft_card_activity (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    inbox_id uuid NOT NULL,
    api_key_id uuid NOT NULL,
    draft_id text NOT NULL,
    line_id uuid,
    action text NOT NULL,
    occurred_at timestamp with time zone NOT NULL,
    revision integer,
    fields text[] DEFAULT '{}'::text[] NOT NULL,
    to_count smallint,
    cc_count smallint,
    bcc_count smallint,
    reported_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT draft_card_activity_action_check CHECK ((action = ANY (ARRAY['saved'::text, 'sent'::text, 'deleted'::text]))),
    CONSTRAINT draft_card_activity_bcc_count_check CHECK (((bcc_count IS NULL) OR (bcc_count >= 0))),
    CONSTRAINT draft_card_activity_cc_count_check CHECK (((cc_count IS NULL) OR (cc_count >= 0))),
    CONSTRAINT draft_card_activity_draft_id_check CHECK (((char_length(draft_id) >= 1) AND (char_length(draft_id) <= 1024))),
    CONSTRAINT draft_card_activity_fields_check CHECK ((fields <@ ARRAY['to'::text, 'cc'::text, 'bcc'::text, 'subject'::text, 'body'::text])),
    CONSTRAINT draft_card_activity_revision_check CHECK (((revision IS NULL) OR (revision >= 0))),
    CONSTRAINT draft_card_activity_to_count_check CHECK (((to_count IS NULL) OR (to_count >= 0)))
);

COMMENT ON TABLE public.draft_card_activity IS 'Saves and sends made through the MCP Apps draft editor, so the mcp-server can state them in the next draft result on the same API key. Draft ids, a revision, field names and recipient counts; no mail content. Service-role only; no policies on purpose.';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.draft_card_activity'::regclass AND conname = 'draft_card_activity_pkey') THEN
    ALTER TABLE public.draft_card_activity ADD CONSTRAINT draft_card_activity_pkey PRIMARY KEY (id);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS draft_card_activity_occurred_idx ON public.draft_card_activity USING btree (occurred_at);

CREATE INDEX IF NOT EXISTS draft_card_activity_unreported_idx ON public.draft_card_activity USING btree (api_key_id, inbox_id, occurred_at) WHERE (reported_at IS NULL);

CREATE INDEX IF NOT EXISTS draft_card_activity_workspace_idx ON public.draft_card_activity USING btree (workspace_id);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.draft_card_activity'::regclass AND conname = 'draft_card_activity_api_key_id_fkey') THEN
    ALTER TABLE public.draft_card_activity ADD CONSTRAINT draft_card_activity_api_key_id_fkey FOREIGN KEY (api_key_id) REFERENCES public.api_keys(id) ON DELETE CASCADE;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.draft_card_activity'::regclass AND conname = 'draft_card_activity_inbox_id_fkey') THEN
    ALTER TABLE public.draft_card_activity ADD CONSTRAINT draft_card_activity_inbox_id_fkey FOREIGN KEY (inbox_id) REFERENCES public.inboxes(id) ON DELETE CASCADE;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.draft_card_activity'::regclass AND conname = 'draft_card_activity_workspace_id_fkey') THEN
    ALTER TABLE public.draft_card_activity ADD CONSTRAINT draft_card_activity_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;
  END IF;
END $$;

ALTER TABLE public.draft_card_activity ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.draft_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    workspace_id uuid NOT NULL,
    inbox_id uuid,
    api_key_id uuid,
    line_id uuid,
    event text NOT NULL,
    via_card boolean DEFAULT false NOT NULL,
    card_offered boolean,
    source text DEFAULT 'live'::text NOT NULL,
    CONSTRAINT draft_events_event_check CHECK ((event = ANY (ARRAY['drafted'::text, 'saved'::text, 'sent'::text, 'deleted'::text, 'hidden'::text]))),
    CONSTRAINT draft_events_source_check CHECK ((source = ANY (ARRAY['live'::text, 'backfill'::text])))
);

COMMENT ON TABLE public.draft_events IS 'Draft created / saved in the card / sent / deleted / card hidden, with via_card and card_offered flags, for the growth board draft card band. Ids only, no mail content. Written by mcp-server (draft-events.ts). Service-role only.';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.draft_events'::regclass AND conname = 'draft_events_pkey') THEN
    ALTER TABLE public.draft_events ADD CONSTRAINT draft_events_pkey PRIMARY KEY (id);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS draft_events_occurred_idx ON public.draft_events USING btree (occurred_at);

CREATE INDEX IF NOT EXISTS draft_events_workspace_idx ON public.draft_events USING btree (workspace_id, occurred_at);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.draft_events'::regclass AND conname = 'draft_events_api_key_id_fkey') THEN
    ALTER TABLE public.draft_events ADD CONSTRAINT draft_events_api_key_id_fkey FOREIGN KEY (api_key_id) REFERENCES public.api_keys(id) ON DELETE SET NULL;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.draft_events'::regclass AND conname = 'draft_events_inbox_id_fkey') THEN
    ALTER TABLE public.draft_events ADD CONSTRAINT draft_events_inbox_id_fkey FOREIGN KEY (inbox_id) REFERENCES public.inboxes(id) ON DELETE SET NULL;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.draft_events'::regclass AND conname = 'draft_events_workspace_id_fkey') THEN
    ALTER TABLE public.draft_events ADD CONSTRAINT draft_events_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;
  END IF;
END $$;

ALTER TABLE public.draft_events ENABLE ROW LEVEL SECURITY;
