#!/bin/sh
# ============================================================
# Self-host vs hosted schema parity, for the tables the MCP server uses.
#
#   supabase db start                       # hosted schema from supabase/migrations
#   sh self-host/tests/schema-parity.sh     # builds self-host, compares
#
# For every table the server queries (found in its source, minus the ones
# self-host deliberately omits), compares column types, nullability and
# defaults, CHECK constraints, and unique keys (the ON CONFLICT targets).
# A difference fails unless it is listed in self-host/db/parity-exceptions.tsv
# with a reason; an exception that no longer matches a difference also fails,
# so the list cannot rot.
#
# This is what catches "upstream added a column the server now selects" in
# the commit that adds it, instead of on someone's server after an upgrade.
#
# HOSTED_DB_CONTAINER overrides the Supabase CLI's database container name.
# ============================================================
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
EXCEPTIONS="$ROOT/self-host/db/parity-exceptions.tsv"
IMAGE=mcpe-migrate-parity
NET=mcpe-parity-net
PG=mcpe-parity-db
WORK=$(mktemp -d)

HOSTED=${HOSTED_DB_CONTAINER:-$(docker ps --filter name=supabase_db_ --format '{{.Names}}' | head -n 1)}
[ -n "$HOSTED" ] || { echo "no Supabase database container found; run 'supabase db start' first" >&2; exit 2; }

cleanup() {
  docker rm -f "$PG" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# Tables the server queries, minus the ones self-host deliberately leaves out
# (kept in one place: INTENTIONALLY_ABSENT in manifest.test.ts).
grep -rhoE '\.from\(\s*"[a-z_]+"' --include='*.ts' --exclude='*.test.ts' "$ROOT/supabase/functions/mcp-server" \
  | sed -E 's/.*"([a-z_]+)"/\1/' | sort -u > "$WORK/server-tables"
grep -oE '^  [a-z_]+:' "$HERE/manifest.test.ts" | tr -d ' :' | sort -u > "$WORK/absent"
TABLES=$(comm -23 "$WORK/server-tables" "$WORK/absent" | sed "s/.*/'&'/" | paste -sd, -)

describe() {
  # One line per fact: kind|table|name|definition
  cat <<SQL
\pset format unaligned
\pset tuples_only on
\pset fieldsep '|'
SELECT 'column', c.table_name, c.column_name,
       format_type(a.atttypid, a.atttypmod) || ' ' || CASE WHEN c.is_nullable = 'YES' THEN 'null' ELSE 'not null' END
       || coalesce(' default ' || c.column_default, '')
FROM information_schema.columns c
JOIN pg_attribute a ON a.attrelid = ('public.' || c.table_name)::regclass AND a.attname = c.column_name
WHERE c.table_schema = 'public' AND c.table_name IN ($TABLES);
SELECT 'check', c.relname, k.conname, pg_get_constraintdef(k.oid)
FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND k.contype = 'c' AND c.relname IN ($TABLES);
SELECT 'unique', t.relname,
       (SELECT string_agg(a.attname, ',' ORDER BY a.attname) FROM pg_attribute a WHERE a.attrelid = t.oid AND a.attnum = ANY (i.indkey))
       || coalesce(' where ' || pg_get_expr(i.indpred, i.indrelid), ''),
       'unique'
FROM pg_index i JOIN pg_class t ON t.oid = i.indrelid JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE n.nspname = 'public' AND i.indisunique AND t.relname IN ($TABLES);
SELECT 'table', c.relname, c.relname, 'exists'
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') AND c.relname IN ($TABLES);
SQL
}

echo "hosted:    $HOSTED (supabase/migrations)"
describe | docker exec -i "$HOSTED" psql -X -q -U postgres -d postgres | sort -u > "$WORK/hosted"

echo "self-host: fresh database + self-host/db/migrations"
docker build -q -t "$IMAGE" "$ROOT/self-host/db" >/dev/null
docker network create "$NET" >/dev/null
docker run -d --name "$PG" --network "$NET" -e POSTGRES_PASSWORD=x postgres:16-alpine >/dev/null
until docker exec "$PG" psql -U postgres -tAc 'select 1' >/dev/null 2>&1; do sleep 0.5; done
docker run --rm --network "$NET" -e PGHOST="$PG" -e PGUSER=postgres -e PGPASSWORD=x -e AUTHENTICATOR_PASSWORD=x "$IMAGE" >/dev/null
describe | docker exec -i "$PG" psql -X -q -U postgres -d postgres | sort -u > "$WORK/selfhost"

# A difference is identified by kind|table|name; both sides of a changed
# definition collapse to one key.
comm -23 "$WORK/hosted" "$WORK/selfhost" | sed 's/^/hosted   |/' > "$WORK/diff"
comm -13 "$WORK/hosted" "$WORK/selfhost" | sed 's/^/selfhost |/' >> "$WORK/diff"
cut -d'|' -f2-4 "$WORK/diff" | sort -u > "$WORK/diff-keys"
grep -v '^#' "$EXCEPTIONS" | grep -v '^[[:space:]]*$' | awk -F'\t' '{print $1 "|" $2 "|" $3}' | sort -u > "$WORK/excepted"

unexpected=$(comm -23 "$WORK/diff-keys" "$WORK/excepted")
stale=$(comm -13 "$WORK/diff-keys" "$WORK/excepted")

status=0
if [ -n "$unexpected" ]; then
  echo
  echo "Self-host schema differs from hosted for tables the MCP server uses:"
  echo "$unexpected" | while IFS= read -r key; do
    grep -F "|$key|" "$WORK/diff" | sed 's/^/  /'
  done
  echo
  echo "Port the upstream change as the next self-host/db/migrations/NNNN_*.sql, or, if"
  echo "self-host genuinely should differ, add 'kind<TAB>table<TAB>name<TAB>reason' to"
  echo "self-host/db/parity-exceptions.tsv."
  status=1
fi
if [ -n "$stale" ]; then
  echo
  echo "Stale entries in self-host/db/parity-exceptions.tsv (no longer a difference; remove them):"
  echo "$stale" | sed 's/^/  /'
  status=1
fi
[ "$status" -eq 0 ] && echo "parity OK: $(wc -l < "$WORK/selfhost" | tr -d ' ') facts compared across $(echo "$TABLES" | tr ',' '\n' | wc -l | tr -d ' ') tables, $(wc -l < "$WORK/excepted" | tr -d ' ') documented exception(s)"
exit "$status"
