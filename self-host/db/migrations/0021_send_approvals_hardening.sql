-- ============================================================
-- 0021 held sends: revisions, single-use dispatch, dedupe, approval window, recipient rule
-- Upstream:
--   20261016160600_send_approval_revision.sql
--   20261016160400_scheduled_sends_writer_lockdown.sql (integrity trigger, dispatch claim)
--   20261117120000_held_send_dedupe_key.sql
--   20261114110000_approval_window.sql (workspaces column)
--   20261111190100_business_admin_audit.sql (send_approvals/workspaces columns)
--   20261111190000_inbox_owner_visibility.sql (scheduled_sends.created_by)
-- ============================================================
-- Security fixes for held (approval-required) sends:
--   - send_approvals.revision is bumped by trigger on any change to what a
--     reviewer sees, and approving needs the revision that was reviewed;
--   - dispatch_scheduled_send_id makes an approval dispatch exactly once;
--   - scheduled_sends_enforce_integrity() refuses a scheduled row for another
--     workspace's inbox, or a plaintext payload that is not an approved marker;
--   - dedupe_key stops a retried fan-out-held send from queueing a second request.
-- approval_window_hours (24/72/168/336) is how long a held send stays decidable.
-- allowed_recipient_domains, when set, holds sends to other domains for approval.
-- The hosted grant/policy changes for the authenticated role are not ported:
-- self-host grants tables to service_role only (see migrate.sh, 0016).
-- ============================================================

ALTER TABLE public.send_approvals ADD COLUMN IF NOT EXISTS revision integer NOT NULL DEFAULT 1;

ALTER TABLE public.send_approvals DROP CONSTRAINT IF EXISTS send_approvals_revision_check;
ALTER TABLE public.send_approvals ADD CONSTRAINT send_approvals_revision_check
  CHECK ((revision >= 1));

CREATE OR REPLACE FUNCTION public.send_approvals_bump_revision()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $$
BEGIN
  IF NEW.payload IS DISTINCT FROM OLD.payload
     OR NEW.summary IS DISTINCT FROM OLD.summary
     OR NEW.send_at IS DISTINCT FROM OLD.send_at
     OR NEW.operation IS DISTINCT FROM OLD.operation
     OR NEW.inbox_id IS DISTINCT FROM OLD.inbox_id THEN
    NEW.revision := OLD.revision + 1;
  ELSE
    -- A writer cannot move the counter by hand (backwards would let an old
    -- rendered revision match again).
    NEW.revision := OLD.revision;
  END IF;
  RETURN NEW;
END;
$$
;

REVOKE ALL ON FUNCTION public.send_approvals_bump_revision() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.send_approvals_bump_revision() TO service_role;

DROP TRIGGER IF EXISTS send_approvals_bump_revision ON public.send_approvals;
CREATE TRIGGER send_approvals_bump_revision BEFORE UPDATE ON public.send_approvals FOR EACH ROW EXECUTE FUNCTION public.send_approvals_bump_revision();

ALTER TABLE public.send_approvals ADD COLUMN IF NOT EXISTS dispatch_scheduled_send_id uuid REFERENCES public.scheduled_sends(id) ON DELETE SET NULL;

-- Approvals that already have a dispatched scheduled row claim it, as upstream does.
UPDATE public.send_approvals sa
SET    dispatch_scheduled_send_id = m.id
FROM (
  SELECT DISTINCT ON (a.id) a.id AS approval_id, s.id
  FROM   public.send_approvals a
  JOIN   public.scheduled_sends s
    ON   s.payload_encrypted = false
   AND   jsonb_typeof(s.payload) = 'object'
   AND   s.payload ->> 'approval_id' = a.id::text
   AND   s.workspace_id = a.workspace_id
   AND   s.inbox_id = a.inbox_id
  WHERE  a.status = 'approved'
    AND  a.dispatch_scheduled_send_id IS NULL
  ORDER  BY a.id,
            abs(extract(epoch FROM (s.created_at - coalesce(a.decided_at, s.created_at)))),
            s.created_at
) m
WHERE  sa.id = m.approval_id
  AND  sa.dispatch_scheduled_send_id IS NULL;

CREATE OR REPLACE FUNCTION public.scheduled_sends_enforce_integrity()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  v_approval text;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.inboxes i
    WHERE  i.id = NEW.inbox_id
      AND  i.workspace_id = NEW.workspace_id
  ) THEN
    RAISE EXCEPTION 'scheduled_sends: inbox % does not belong to workspace %',
      NEW.inbox_id, NEW.workspace_id
      USING ERRCODE = '23514';
  END IF;

  IF NOT NEW.payload_encrypted THEN
    -- The only plaintext row the product writes is the approval marker
    -- { "approval_id": "<uuid>" } (no email content). Anything else must be
    -- encrypted.
    -- Nested rather than one OR chain: jsonb_object_keys() raises on a
    -- non-object, and SQL does not promise short-circuit evaluation.
    v_approval := NULL;
    IF jsonb_typeof(NEW.payload) = 'object' THEN
      IF (SELECT count(*) FROM jsonb_object_keys(NEW.payload)) = 1 THEN
        v_approval := NEW.payload ->> 'approval_id';
      END IF;
    END IF;
    IF v_approval IS NULL
       OR v_approval !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      RAISE EXCEPTION 'scheduled_sends: a plaintext payload must be an approval marker'
        USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.send_approvals a
      WHERE  a.id = v_approval::uuid
        AND  a.workspace_id = NEW.workspace_id
        AND  a.inbox_id = NEW.inbox_id
        AND  (TG_OP = 'UPDATE' OR a.status = 'approved')
    ) THEN
      RAISE EXCEPTION 'scheduled_sends: approval % is not an approved request of this workspace and inbox',
        v_approval
        USING ERRCODE = '23514';
    END IF;
  END IF;

  RETURN NEW;
END;
$$
;

REVOKE ALL ON FUNCTION public.scheduled_sends_enforce_integrity() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.scheduled_sends_enforce_integrity() TO service_role;

DROP TRIGGER IF EXISTS scheduled_sends_enforce_integrity ON public.scheduled_sends;
CREATE TRIGGER scheduled_sends_enforce_integrity BEFORE INSERT OR UPDATE OF workspace_id, inbox_id, payload, payload_encrypted ON public.scheduled_sends FOR EACH ROW EXECUTE FUNCTION public.scheduled_sends_enforce_integrity();

ALTER TABLE public.send_approvals ADD COLUMN IF NOT EXISTS dedupe_key text;

ALTER TABLE public.send_approvals DROP CONSTRAINT IF EXISTS send_approvals_dedupe_key_check;
ALTER TABLE public.send_approvals ADD CONSTRAINT send_approvals_dedupe_key_check
  CHECK (((dedupe_key IS NULL) OR (dedupe_key ~ '^[0-9a-f]{64}$'::text)));

CREATE INDEX IF NOT EXISTS send_approvals_pending_dedupe_idx
  ON public.send_approvals (inbox_id, dedupe_key)
  WHERE status = 'pending' AND dedupe_key IS NOT NULL;

ALTER TABLE public.send_approvals ADD COLUMN IF NOT EXISTS hold_reason text;
ALTER TABLE public.send_approvals ADD COLUMN IF NOT EXISTS requested_by uuid REFERENCES public.users(id) ON DELETE SET NULL;

ALTER TABLE public.send_approvals DROP CONSTRAINT IF EXISTS send_approvals_hold_reason_check;
ALTER TABLE public.send_approvals ADD CONSTRAINT send_approvals_hold_reason_check
  CHECK (((hold_reason IS NULL) OR (hold_reason = 'recipient_rule'::text)));

ALTER TABLE public.scheduled_sends ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES public.users(id) ON DELETE SET NULL;

ALTER TABLE public.workspaces ADD COLUMN IF NOT EXISTS approval_window_hours integer NOT NULL DEFAULT 24;
ALTER TABLE public.workspaces ADD COLUMN IF NOT EXISTS allowed_recipient_domains text[];

ALTER TABLE public.workspaces DROP CONSTRAINT IF EXISTS workspaces_approval_window_hours_check;
ALTER TABLE public.workspaces ADD CONSTRAINT workspaces_approval_window_hours_check
  CHECK ((approval_window_hours = ANY (ARRAY[24, 72, 168, 336])));
ALTER TABLE public.workspaces DROP CONSTRAINT IF EXISTS workspaces_allowed_recipient_domains_check;
ALTER TABLE public.workspaces ADD CONSTRAINT workspaces_allowed_recipient_domains_check
  CHECK (
    allowed_recipient_domains IS NULL
    OR (
      cardinality(allowed_recipient_domains) BETWEEN 1 AND 100
      AND array_position(allowed_recipient_domains, NULL) IS NULL
    )
  );
