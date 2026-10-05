-- ============================================================
-- 0017 web-client markers on workspaces and api_keys
-- Upstream: 20261004100000_web_client_enabled.sql
--           20261004100100_web_client_api_key_kind.sql (column, check, index)
-- ============================================================
-- The hosted web mail client (apps/client + the client-api edge function) is
-- not part of self-host, but these columns live on tables the MCP server
-- reads: /triage-preview now filters api_keys on `kind IS NULL`, so the
-- column has to exist for that query to succeed. Every self-host key is an
-- ordinary key, so kind stays NULL and web_client_enabled stays false.
-- The hosted RLS policies (auth.uid()) are not ported; see 0016.
-- ============================================================

ALTER TABLE public.workspaces
  ADD COLUMN IF NOT EXISTS web_client_enabled boolean NOT NULL DEFAULT false;

ALTER TABLE public.api_keys
  ADD COLUMN IF NOT EXISTS kind text;
ALTER TABLE public.api_keys DROP CONSTRAINT IF EXISTS api_keys_kind_check;
ALTER TABLE public.api_keys ADD CONSTRAINT api_keys_kind_check
  CHECK (kind IS NULL OR kind IN ('web_client'));

CREATE UNIQUE INDEX IF NOT EXISTS api_keys_one_web_client_per_workspace_idx
  ON public.api_keys (workspace_id)
  WHERE kind = 'web_client' AND deleted_at IS NULL;
