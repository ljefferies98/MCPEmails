-- ============================================================
-- 0023 inbox owner and visibility, parked inboxes, activity_log.user_id
-- Upstream:
--   20261111190000_inbox_owner_visibility.sql (columns, owner guard, credential_inbox_scope*)
--   20261024173000_inbox_parking.sql
--   20261111190100_business_admin_audit.sql (activity_log.user_id)
-- ============================================================
-- The server scopes every credential to the inboxes its user may see
-- (credential_inbox_scope_for_key) and skips parked inboxes. Self-host has one
-- operator who owns every inbox, so in practice nothing is hidden: visibility
-- defaults to 'company' (default_inbox_visibility() is a constant here, hosted
-- reads a pricing switch) and existing inboxes are given the workspace owner.
-- inboxes_owner_guard() falls back to the workspace owner where hosted uses
-- auth.uid(). Parking (plan_limit) is a hosted billing state; the columns exist
-- so the server's reads succeed and stay NULL on self-host.
-- ============================================================

CREATE OR REPLACE FUNCTION public.default_inbox_visibility()
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $$
  -- Hosted picks 'private' when per-person Business pricing is on
  -- (pricing_switches); self-host has one operator, so every inbox is shared.
  SELECT 'company'::text;
$$
;

ALTER TABLE public.inboxes ADD COLUMN IF NOT EXISTS owner_user_id uuid REFERENCES public.users(id) ON DELETE SET NULL;
ALTER TABLE public.inboxes ADD COLUMN IF NOT EXISTS visibility text NOT NULL DEFAULT default_inbox_visibility();

ALTER TABLE public.inboxes DROP CONSTRAINT IF EXISTS inboxes_visibility_check;
ALTER TABLE public.inboxes ADD CONSTRAINT inboxes_visibility_check
  CHECK ((visibility = ANY (ARRAY['private'::text, 'company'::text])));

UPDATE public.inboxes i
   SET owner_user_id = w.owner_id
  FROM public.workspaces w
 WHERE w.id = i.workspace_id
   AND i.owner_user_id IS NULL
   AND EXISTS (SELECT 1 FROM public.users u WHERE u.id = w.owner_id);

CREATE INDEX IF NOT EXISTS inboxes_workspace_visibility_owner_idx
  ON public.inboxes USING btree (workspace_id, visibility, owner_user_id);

CREATE OR REPLACE FUNCTION public.inboxes_owner_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.owner_user_id IS NULL THEN
      -- Hosted prefers the signed-in user; self-host has no
      -- end-user sessions, so a new inbox belongs to the workspace owner.
      NEW.owner_user_id :=
        (SELECT w.owner_id FROM public.workspaces w WHERE w.id = NEW.workspace_id);
    END IF;
    -- BEFORE INSERT triggers run before ON CONFLICT's check, so a retired row
    -- no longer conflicts and the upsert takes the INSERT path.
    IF NEW.deleted_at IS NULL AND NEW.email_address IS NOT NULL THEN
      UPDATE public.inboxes o
         SET email_address = o.email_address || '#retired-' || o.id::text
       WHERE o.workspace_id = NEW.workspace_id
         AND o.email_address = NEW.email_address
         AND o.deleted_at IS NOT NULL
         AND o.owner_user_id IS DISTINCT FROM NEW.owner_user_id;
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE
  IF OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL THEN
    -- Revival: a fresh connection.
    IF NEW.owner_user_id IS NULL THEN
      NEW.owner_user_id := COALESCE(OLD.owner_user_id,
        (SELECT w.owner_id FROM public.workspaces w WHERE w.id = NEW.workspace_id));
    END IF;
    IF NEW.owner_user_id IS DISTINCT FROM OLD.owner_user_id THEN
      NEW.visibility := 'private';
    END IF;
    RETURN NEW;
  END IF;

  -- A live inbox keeps its owner. Clearing it is allowed: that is the
  -- ON DELETE SET NULL of the owner's account (blocking it would block
  -- account deletion).
  IF OLD.owner_user_id IS NOT NULL AND NEW.owner_user_id IS NOT NULL THEN
    NEW.owner_user_id := OLD.owner_user_id;
  END IF;
  RETURN NEW;
END;
$$
;

REVOKE ALL ON FUNCTION public.inboxes_owner_guard() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.inboxes_owner_guard() TO service_role;

DROP TRIGGER IF EXISTS inboxes_owner_guard ON public.inboxes;
CREATE TRIGGER inboxes_owner_guard BEFORE INSERT OR UPDATE OF owner_user_id, deleted_at ON public.inboxes FOR EACH ROW EXECUTE FUNCTION public.inboxes_owner_guard();

CREATE OR REPLACE FUNCTION public.credential_inbox_scope(p_workspace_id uuid, p_user_id uuid, p_inbox_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  v_user   uuid;
  v_hidden uuid[];
  v_ids    uuid[];
BEGIN
  SELECT COALESCE(p_user_id, w.owner_id) INTO v_user
    FROM public.workspaces w
   WHERE w.id = p_workspace_id AND w.deleted_at IS NULL;

  IF v_user IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.workspace_members wm
     WHERE wm.workspace_id = p_workspace_id AND wm.user_id = v_user
  ) THEN
    RETURN jsonb_build_object('restricted', true, 'inbox_ids', '[]'::jsonb);
  END IF;

  v_hidden := ARRAY(
    SELECT i.id FROM public.inboxes i
     WHERE i.workspace_id = p_workspace_id
       AND i.visibility = 'private'
       AND i.owner_user_id IS DISTINCT FROM v_user
  );

  IF cardinality(v_hidden) = 0 THEN
    RETURN jsonb_build_object('restricted', false, 'inbox_ids', to_jsonb(p_inbox_ids));
  END IF;

  IF p_inbox_ids IS NOT NULL AND cardinality(p_inbox_ids) > 0 THEN
    v_ids := ARRAY(SELECT x FROM unnest(p_inbox_ids) AS x WHERE NOT (x = ANY (v_hidden)));
  ELSE
    v_ids := ARRAY(
      SELECT i.id FROM public.inboxes i
       WHERE i.workspace_id = p_workspace_id
         AND NOT (i.id = ANY (v_hidden))
       ORDER BY i.id
    );
  END IF;

  RETURN jsonb_build_object('restricted', true, 'inbox_ids', to_jsonb(v_ids));
END;
$$
;

REVOKE ALL ON FUNCTION public.credential_inbox_scope(uuid,uuid,uuid[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.credential_inbox_scope(uuid,uuid,uuid[]) TO service_role;

CREATE OR REPLACE FUNCTION public.credential_inbox_scope_for_key(p_key_hash text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $$
  SELECT public.credential_inbox_scope(k.workspace_id, k.created_by, k.inbox_ids)
         || jsonb_build_object('key_id', k.id)
    FROM public.api_keys k
   WHERE k.key_hash = p_key_hash
     AND k.deleted_at IS NULL
     AND (k.expires_at IS NULL OR k.expires_at > now())
   LIMIT 1;
$$
;

REVOKE ALL ON FUNCTION public.credential_inbox_scope_for_key(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.credential_inbox_scope_for_key(text) TO service_role;

ALTER TABLE public.inboxes ADD COLUMN IF NOT EXISTS parked_at timestamp with time zone;
ALTER TABLE public.inboxes ADD COLUMN IF NOT EXISTS parked_reason text;

ALTER TABLE public.inboxes DROP CONSTRAINT IF EXISTS inboxes_parked_reason_check;
ALTER TABLE public.inboxes ADD CONSTRAINT inboxes_parked_reason_check
  CHECK ((((parked_at IS NULL) AND (parked_reason IS NULL)) OR ((parked_at IS NOT NULL) AND (parked_reason IS NOT NULL) AND (parked_reason = 'plan_limit'::text))));
ALTER TABLE public.triage_rules DROP CONSTRAINT IF EXISTS triage_rules_paused_reason_check;
ALTER TABLE public.triage_rules ADD CONSTRAINT triage_rules_paused_reason_check
  CHECK (((paused_reason IS NULL) OR (paused_reason = ANY (ARRAY['plan_limit'::text, 'inbox_parked'::text]))));

ALTER TABLE public.activity_log ADD COLUMN IF NOT EXISTS user_id uuid;

CREATE OR REPLACE FUNCTION public.activity_log_fill_user_id()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.user_id IS NULL THEN
    IF NEW.api_key_id IS NOT NULL THEN
      SELECT k.created_by INTO NEW.user_id
        FROM public.api_keys k
       WHERE k.id = NEW.api_key_id;
    END IF;
    IF NEW.user_id IS NULL THEN
      SELECT w.owner_id INTO NEW.user_id
        FROM public.workspaces w
       WHERE w.id = NEW.workspace_id;
    END IF;
  END IF;
  RETURN NEW;
END;
$$
;

REVOKE ALL ON FUNCTION public.activity_log_fill_user_id() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.activity_log_fill_user_id() TO service_role;

DROP TRIGGER IF EXISTS activity_log_fill_user_id ON public.activity_log;
CREATE TRIGGER activity_log_fill_user_id BEFORE INSERT ON public.activity_log FOR EACH ROW EXECUTE FUNCTION public.activity_log_fill_user_id();
