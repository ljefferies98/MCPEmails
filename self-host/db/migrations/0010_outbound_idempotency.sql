-- ============================================================
-- 0010 outbound_idempotency
-- Upstream: 20260802190000_add_outbound_idempotency.sql
--           20260802220000_link_idempotency_to_send_approvals.sql
--           20260819180000_widen_outbound_idempotency_operations.sql
--           20260830120000_idempotency_result_snapshot.sql
--           20260923090000_idempotency_draft_writes.sql
-- ============================================================
-- Any call that passes idempotency_key claims a row here before touching the
-- mailbox. Without the table the claim fails and the server refuses the call
-- with idempotency_unavailable, by design: it never sends without the
-- protection the caller asked for.
--
-- The unique (api_key_id, operation, key_digest) constraint is what detects a
-- concurrent retry, and the expires_at default is what lets a key be reused
-- after 24 hours. Both are asserted below even if the table was hand-created.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.outbound_idempotency (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  api_key_id uuid NOT NULL REFERENCES public.api_keys(id) ON DELETE CASCADE,
  operation text NOT NULL,
  key_digest text NOT NULL,
  request_digest text NOT NULL,
  status text NOT NULL DEFAULT 'processing',
  completed_at timestamptz,
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '24 hours'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.outbound_idempotency
  ADD COLUMN IF NOT EXISTS approval_id uuid REFERENCES public.send_approvals(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS result_snapshot jsonb;

ALTER TABLE public.outbound_idempotency
  ALTER COLUMN status SET DEFAULT 'processing',
  ALTER COLUMN expires_at SET DEFAULT (now() + interval '24 hours');

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_index i
    JOIN pg_class t ON t.oid = i.indrelid
    WHERE t.oid = 'public.outbound_idempotency'::regclass
      AND i.indisunique
      AND i.indpred IS NULL
      AND (SELECT array_agg(a.attname::text ORDER BY a.attname)
             FROM pg_attribute a
            WHERE a.attrelid = t.oid AND a.attnum = ANY (i.indkey))
          = ARRAY['api_key_id', 'key_digest', 'operation']
  ) THEN
    ALTER TABLE public.outbound_idempotency
      ADD CONSTRAINT outbound_idempotency_api_key_id_operation_key_digest_key
      UNIQUE (api_key_id, operation, key_digest);
  END IF;
END
$$;

ALTER TABLE public.outbound_idempotency DROP CONSTRAINT IF EXISTS outbound_idempotency_operation_check;
ALTER TABLE public.outbound_idempotency ADD CONSTRAINT outbound_idempotency_operation_check
  CHECK (operation IN (
    'email_send',
    'email_reply',
    'email_forward',
    'draft_send',
    'schedule_create',
    'email_move',
    'email_copy',
    'email_move_batch',
    'email_copy_batch',
    'email_delete',
    'email_delete_batch',
    'email_flag',
    'email_archive',
    'email_search_and_move',
    'email_search_and_delete',
    'draft_create',
    'draft_reply',
    'draft_update',
    'draft_delete'
  ));

ALTER TABLE public.outbound_idempotency DROP CONSTRAINT IF EXISTS outbound_idempotency_status_check;
ALTER TABLE public.outbound_idempotency ADD CONSTRAINT outbound_idempotency_status_check
  CHECK (status IN ('processing', 'pending_approval', 'succeeded', 'failed', 'unknown'));

CREATE INDEX IF NOT EXISTS outbound_idempotency_expires_at_idx
  ON public.outbound_idempotency (expires_at);
CREATE INDEX IF NOT EXISTS outbound_idempotency_approval_id_idx
  ON public.outbound_idempotency (approval_id)
  WHERE approval_id IS NOT NULL;
