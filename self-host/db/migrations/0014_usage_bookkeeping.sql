-- ============================================================
-- 0014 usage bookkeeping: action_usage, user_usage_entitlements
-- Upstream: 20260803010000_create_action_usage_shadow_meter.sql
--           20260803020000_create_user_usage_entitlements.sql (table only)
--           20260819170500_grandfather_unlimited_inboxes.sql (unlimited_inboxes)
-- ============================================================
-- Self-host does not meter or bill. The compose file sets
-- USAGE_ENFORCEMENT_DISABLED=true, which skips the hosted allowance RPCs
-- (workspace_action_allowance, reserve_action_usage, ...), and those RPCs are
-- deliberately not ported.
--
-- Two reads/writes still happen on every call regardless of that flag, so the
-- tables exist to keep them from erroring into the logs:
--   * action_usage: one row per successful tool call (a local usage record);
--   * user_usage_entitlements: looked up for the workspace owner when the
--     per-workspace request limit is resolved. It stays empty on self-host.
-- The hosted entitlement audit table/trigger and the comped-plan trigger on
-- workspaces are hosted billing administration and are not ported.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.action_usage (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id   uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE CASCADE,
  tool_name      text NOT NULL,
  billable       boolean NOT NULL,
  quantity       integer NOT NULL DEFAULT 0,
  meter_version  integer NOT NULL DEFAULT 1,
  occurred_at    timestamptz NOT NULL DEFAULT now(),
  created_at     timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.action_usage DROP CONSTRAINT IF EXISTS action_usage_quantity_check;
ALTER TABLE public.action_usage ADD CONSTRAINT action_usage_quantity_check CHECK (quantity >= 0);
ALTER TABLE public.action_usage DROP CONSTRAINT IF EXISTS action_usage_meter_version_check;
ALTER TABLE public.action_usage ADD CONSTRAINT action_usage_meter_version_check CHECK (meter_version > 0);
ALTER TABLE public.action_usage DROP CONSTRAINT IF EXISTS action_usage_billable_quantity_check;
ALTER TABLE public.action_usage ADD CONSTRAINT action_usage_billable_quantity_check
  CHECK ((billable AND quantity > 0) OR (NOT billable AND quantity = 0));

CREATE INDEX IF NOT EXISTS action_usage_workspace_meter_occurred_idx
  ON public.action_usage (workspace_id, meter_version, occurred_at DESC);
CREATE INDEX IF NOT EXISTS action_usage_billable_workspace_occurred_idx
  ON public.action_usage (workspace_id, occurred_at DESC)
  WHERE billable;

CREATE TABLE IF NOT EXISTS public.user_usage_entitlements (
  user_id     uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
  kind        text NOT NULL,
  granted_at  timestamptz NOT NULL DEFAULT now(),
  granted_by  uuid REFERENCES public.users(id) ON DELETE SET NULL,
  reason      text NOT NULL,
  source      text NOT NULL,
  expires_at  timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.user_usage_entitlements
  ADD COLUMN IF NOT EXISTS unlimited_inboxes boolean NOT NULL DEFAULT false;

ALTER TABLE public.user_usage_entitlements DROP CONSTRAINT IF EXISTS user_usage_entitlements_kind_check;
ALTER TABLE public.user_usage_entitlements ADD CONSTRAINT user_usage_entitlements_kind_check
  CHECK (kind IN ('standard', 'comped_scale'));
ALTER TABLE public.user_usage_entitlements DROP CONSTRAINT IF EXISTS user_usage_entitlements_source_check;
ALTER TABLE public.user_usage_entitlements ADD CONSTRAINT user_usage_entitlements_source_check
  CHECK (source IN ('migration', 'support', 'promotion'));

CREATE OR REPLACE TRIGGER user_usage_entitlements_updated_at
  BEFORE UPDATE ON public.user_usage_entitlements
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
