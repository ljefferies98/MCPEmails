-- Canonical, order-independent description of the self-host schema, used to
-- prove that a fresh install and every upgrade path end in the same place.
-- Column order is deliberately ignored (an upgraded table appends columns that
-- a fresh one may define in a different position); everything else that the
-- server or PostgREST can observe is included.
\pset format unaligned
\pset tuples_only on
\pset fieldsep '|'

SELECT 'column', table_name, column_name, format_type(a.atttypid, a.atttypmod), is_nullable, coalesce(column_default, '')
FROM information_schema.columns c
JOIN pg_attribute a ON a.attrelid = format('%I.%I', c.table_schema, c.table_name)::regclass AND a.attname = c.column_name
WHERE c.table_schema IN ('public', 'selfhost')
ORDER BY 2, 3;

SELECT 'constraint', c.relname, k.conname, pg_get_constraintdef(k.oid)
FROM pg_constraint k
JOIN pg_class c ON c.oid = k.conrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname IN ('public', 'selfhost')
ORDER BY 2, 3;

SELECT 'index', tablename, indexname, indexdef
FROM pg_indexes
WHERE schemaname IN ('public', 'selfhost')
ORDER BY 2, 3;

SELECT 'trigger', c.relname, t.tgname, pg_get_triggerdef(t.oid)
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND NOT t.tgisinternal
ORDER BY 2, 3;

SELECT 'function', p.proname, pg_get_function_identity_arguments(p.oid), md5(pg_get_functiondef(p.oid))
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
ORDER BY 2, 3;

SELECT 'rls', c.relname, c.relrowsecurity::text
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
ORDER BY 2;

SELECT 'grant', table_name, grantee, string_agg(privilege_type, ',' ORDER BY privilege_type)
FROM information_schema.role_table_grants
WHERE table_schema = 'public' AND grantee IN ('anon', 'authenticated', 'service_role')
GROUP BY table_name, grantee
ORDER BY 2, 3;

SELECT 'role', rolname, rolcanlogin::text, rolbypassrls::text, rolinherit::text
FROM pg_roles
WHERE rolname IN ('anon', 'authenticated', 'service_role', 'authenticator')
ORDER BY 2;
