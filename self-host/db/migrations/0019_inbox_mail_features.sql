-- ============================================================
-- 0019 inbox mail features: signature images, folder overrides, AI instructions, Send As, confirm in chat
-- Upstream:
--   20261013180000_inboxes_signature_embed_images.sql
--   20261020230000_inbox_folder_overrides.sql
--   20261024235300_inbox_ai_instructions.sql
--   20261018120000_inbox_sender_aliases.sql
--   20261023200000_send_review_mode_chat.sql
-- ============================================================
-- Columns and the Send As table the server reads. Everything here is off until
-- set per inbox in SQL (there is no dashboard on self-host):
--   inboxes.signature_embed_images  true = signature images sent inline (cid:)
--   inboxes.folder_overrides        e.g. '{"sent": "INBOX.Sent"}'; NULL = auto-detect
--   inboxes.ai_instructions         per-inbox instructions (a Pro feature, see 0024)
--   inbox_sender_aliases            Send As addresses; usable once verified_at is set
--   inboxes.send_review_mode='chat' the AI must confirm each send with you first
-- Hosted verifies a Send As address by emailing a code; on self-host insert the
-- row with verified_at = now() yourself. The authenticated-role grants and
-- my_workspace_ids() policy are hosted-only (no end-user sessions here).
-- chat_send_confirm_enabled is the hosted rollout gate, on for everyone since
-- 20261027190000_chat_confirm_for_everyone.
-- ============================================================

ALTER TABLE public.inboxes ADD COLUMN IF NOT EXISTS signature_embed_images boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.inbox_folder_overrides_valid(overrides jsonb)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $$
  SELECT overrides IS NULL OR (
    jsonb_typeof(overrides) = 'object'
    AND (overrides - ARRAY['sent', 'drafts', 'trash', 'spam', 'archive']) = '{}'::jsonb
    AND NOT EXISTS (
      SELECT 1
        FROM jsonb_each(overrides) AS e(key, value)
       WHERE jsonb_typeof(e.value) <> 'string'
          OR char_length(e.value #>> '{}') NOT BETWEEN 1 AND 512
          OR upper(e.value #>> '{}') = 'INBOX'
    )
    AND (SELECT count(*) FROM jsonb_each(overrides))
      = (SELECT count(DISTINCT e.value) FROM jsonb_each(overrides) AS e(key, value))
  );
$$
;

ALTER TABLE public.inboxes ADD COLUMN IF NOT EXISTS folder_overrides jsonb;
ALTER TABLE public.inboxes ADD COLUMN IF NOT EXISTS ai_instructions text;
ALTER TABLE public.inboxes ADD COLUMN IF NOT EXISTS ai_instructions_updated_at timestamp with time zone;

ALTER TABLE public.inboxes DROP CONSTRAINT IF EXISTS inboxes_folder_overrides_check;
ALTER TABLE public.inboxes ADD CONSTRAINT inboxes_folder_overrides_check
  CHECK (inbox_folder_overrides_valid(folder_overrides));
ALTER TABLE public.inboxes DROP CONSTRAINT IF EXISTS inboxes_ai_instructions_check;
ALTER TABLE public.inboxes ADD CONSTRAINT inboxes_ai_instructions_check
  CHECK (
    ai_instructions IS NULL
    OR (char_length(ai_instructions) BETWEEN 1 AND 2000
        AND ai_instructions = btrim(ai_instructions, E' \t\r\n'))
  );
ALTER TABLE public.inboxes DROP CONSTRAINT IF EXISTS inboxes_send_review_mode_check;
ALTER TABLE public.inboxes ADD CONSTRAINT inboxes_send_review_mode_check
  CHECK ((send_review_mode = ANY (ARRAY['off'::text, 'chat'::text, 'inline'::text, 'dashboard'::text])));

ALTER TABLE public.workspaces ADD COLUMN IF NOT EXISTS chat_send_confirm_enabled boolean NOT NULL DEFAULT true;

CREATE OR REPLACE FUNCTION public.inbox_sender_aliases_set_workspace()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  SELECT i.workspace_id INTO NEW.workspace_id
    FROM public.inboxes i
   WHERE i.id = NEW.inbox_id;
  IF NEW.workspace_id IS NULL THEN
    RAISE EXCEPTION 'inbox % not found', NEW.inbox_id USING ERRCODE = '23503';
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$
;

REVOKE ALL ON FUNCTION public.inbox_sender_aliases_set_workspace() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.inbox_sender_aliases_set_workspace() TO service_role;

CREATE TABLE IF NOT EXISTS public.inbox_sender_aliases (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    inbox_id uuid NOT NULL,
    workspace_id uuid NOT NULL,
    email_address text NOT NULL,
    display_name text,
    verified_at timestamp with time zone,
    code_hash text,
    code_expires_at timestamp with time zone,
    code_attempts integer DEFAULT 0 NOT NULL,
    code_sent_at timestamp with time zone,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT inbox_sender_aliases_code_attempts_check CHECK ((code_attempts >= 0)),
    CONSTRAINT inbox_sender_aliases_display_name_check CHECK (display_name IS NULL
                               OR (length(display_name) BETWEEN 1 AND 100
                                   AND display_name !~ '[[:cntrl:]<>]')),
    CONSTRAINT inbox_sender_aliases_email_address_check CHECK (((length(email_address) <= 254) AND (email_address ~ '^[^[:space:][:cntrl:]<>(),;:"\[\]\\@]+@[^[:space:][:cntrl:]<>(),;:"\[\]\\@]+\.[^[:space:][:cntrl:]<>(),;:"\[\]\\@]+$'::text)))
);

COMMENT ON TABLE public.inbox_sender_aliases IS 'Send As addresses for IMAP inboxes. Usable only when verified_at is set. Written ONLY by service-role code (POST/DELETE /api/inboxes/[id]/send-as); authenticated may SELECT every column except code_hash / code_attempts.';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.inbox_sender_aliases'::regclass AND conname = 'inbox_sender_aliases_pkey') THEN
    ALTER TABLE public.inbox_sender_aliases ADD CONSTRAINT inbox_sender_aliases_pkey PRIMARY KEY (id);
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS inbox_sender_aliases_inbox_address_key ON public.inbox_sender_aliases USING btree (inbox_id, lower(email_address));

CREATE INDEX IF NOT EXISTS inbox_sender_aliases_workspace_idx ON public.inbox_sender_aliases USING btree (workspace_id);

DROP TRIGGER IF EXISTS inbox_sender_aliases_set_workspace ON public.inbox_sender_aliases;
CREATE TRIGGER inbox_sender_aliases_set_workspace BEFORE INSERT OR UPDATE ON public.inbox_sender_aliases FOR EACH ROW EXECUTE FUNCTION public.inbox_sender_aliases_set_workspace();

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.inbox_sender_aliases'::regclass AND conname = 'inbox_sender_aliases_created_by_fkey') THEN
    ALTER TABLE public.inbox_sender_aliases ADD CONSTRAINT inbox_sender_aliases_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE SET NULL;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.inbox_sender_aliases'::regclass AND conname = 'inbox_sender_aliases_inbox_id_fkey') THEN
    ALTER TABLE public.inbox_sender_aliases ADD CONSTRAINT inbox_sender_aliases_inbox_id_fkey FOREIGN KEY (inbox_id) REFERENCES public.inboxes(id) ON DELETE CASCADE;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.inbox_sender_aliases'::regclass AND conname = 'inbox_sender_aliases_workspace_id_fkey') THEN
    ALTER TABLE public.inbox_sender_aliases ADD CONSTRAINT inbox_sender_aliases_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;
  END IF;
END $$;

ALTER TABLE public.inbox_sender_aliases ENABLE ROW LEVEL SECURITY;
