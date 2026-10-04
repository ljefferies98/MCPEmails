-- ============================================================
-- 0007 workspace_members
-- Upstream: 20260524000000_create_initial_schema.sql (table)
--           20260526000003_workspace_invites_and_member_roles.sql (role check)
-- ============================================================
-- The server checks the key creator's role here before letting a key change a
-- workspace-wide preference (draft_editor_hide with scope=workspace). The seeded
-- operator owns the seeded workspace, so keys minted by `mcpe` qualify.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.workspace_members (
  workspace_id  uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE CASCADE,
  user_id       uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  role          text NOT NULL DEFAULT 'owner',
  joined_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workspace_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_workspace_members_user_id ON public.workspace_members (user_id);

ALTER TABLE public.workspace_members DROP CONSTRAINT IF EXISTS workspace_members_role_check;
ALTER TABLE public.workspace_members ADD CONSTRAINT workspace_members_role_check
  CHECK (role IN ('owner', 'admin', 'member', 'viewer'));

INSERT INTO public.workspace_members (workspace_id, user_id, role)
SELECT w.id, w.owner_id, 'owner'
FROM public.workspaces w
ON CONFLICT (workspace_id, user_id) DO NOTHING;
