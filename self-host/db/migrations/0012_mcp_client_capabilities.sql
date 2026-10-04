-- ============================================================
-- 0012 mcp_client_capabilities
-- Upstream: 20260805180000_create_mcp_client_capabilities.sql
-- ============================================================
-- Observational record of MCP client handshakes, upserted on every
-- `initialize`. The upsert's ON CONFLICT target needs the non-partial unique
-- index below; without it Postgres rejects the statement (42P10).
-- ============================================================

CREATE TABLE IF NOT EXISTS public.mcp_client_capabilities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE CASCADE,
  api_key_id uuid NOT NULL REFERENCES public.api_keys(id) ON DELETE CASCADE,
  client_name text NOT NULL DEFAULT 'unknown',
  client_version text NOT NULL DEFAULT 'unknown',
  protocol_version text NOT NULL DEFAULT 'unknown',
  capabilities jsonb NOT NULL DEFAULT '{}'::jsonb,
  supports_ui boolean NOT NULL DEFAULT false,
  first_seen timestamptz NOT NULL DEFAULT now(),
  last_seen timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS mcp_client_capabilities_identity_key
  ON public.mcp_client_capabilities
  (api_key_id, client_name, client_version, protocol_version);
CREATE INDEX IF NOT EXISTS mcp_client_capabilities_workspace_last_seen_idx
  ON public.mcp_client_capabilities (workspace_id, last_seen DESC);
