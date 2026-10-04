-- ============================================================
-- 0016 enable row level security on every public table
-- Upstream: the ENABLE ROW LEVEL SECURITY statements throughout supabase/migrations
-- ============================================================
-- Defence in depth. The MCP server and CLI use the service_role, which has
-- BYPASSRLS, so nothing they do changes. anon/authenticated have no table
-- grants on self-host anyway; with RLS on and no policies, a token for those
-- roles would see nothing even if a grant were added by mistake.
--
-- Re-run safely: enabling RLS on a table that already has it is a no-op, and
-- tables added by later migrations should enable it themselves.
-- ============================================================

DO $$
DECLARE
  t record;
BEGIN
  FOR t IN
    SELECT c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t.relname);
  END LOOP;
END
$$;

-- rate_limit_check is SECURITY INVOKER and only meaningful for service_role.
REVOKE EXECUTE ON FUNCTION public.rate_limit_check(text, integer, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rate_limit_check(text, integer, bigint) TO service_role;
