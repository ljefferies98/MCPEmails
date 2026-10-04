#!/bin/sh
# ============================================================
# Self-host migration integration tests (needs Docker, nothing else).
#
#   sh self-host/tests/migrations.sh
#
# Proves, against real Postgres 16 containers:
#   1. fresh:       an empty database builds the full schema;
#   2. rerun:       a second run applies nothing and changes nothing;
#   3. reapply:     every migration is safe to run against a schema that
#                   already has its changes (what adoption relies on);
#   4. legacy:      a database created by the old 00-schema.sql, with data,
#                   upgrades to exactly the fresh schema and keeps its data,
#                   including the bytea credentials, which become the exact
#                   base64url strings the CLI wrote;
#   5. hand-patched: the same legacy database after the manual ALTERs and
#                   upstream idempotency migrations operators applied to get
#                   going also converges, with a warning for SMTP 587 + 'tls';
#   6. hex-patched: a `USING col::text` hand conversion is repaired;
#   7. failure:     a failing migration leaves no trace and stops the run;
#   8. checksum:    an edited, already-applied migration is refused;
#   9. concurrency: two runners at once apply everything exactly once;
#  10. status:      reports every migration;
#  11. restore:     a dump of a hand-patched legacy install restored into a new,
#                   already-migrated stack ends up identical to a fresh install.
# ============================================================
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
IMAGE=mcpe-migrate-test
NET=mcpe-migrate-test-net
PGIMG=postgres:16-alpine
PW=testpw
AUTH_PW="auth'pw\"with quotes"
WORK=$(mktemp -d)
FAILS=0

cleanup() {
  docker ps -aq --filter "label=mcpe-migrate-test" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
failed() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAILS=$((FAILS + 1)); }
check() { if eval "$2"; then pass "$1"; else failed "$1"; fi; }

echo "building migrate image"
docker build -q -t "$IMAGE" "$ROOT/self-host/db" >/dev/null
docker network create "$NET" >/dev/null

start_pg() {
  docker run -d --label mcpe-migrate-test --name "$1" --network "$NET" \
    -e POSTGRES_PASSWORD="$PW" "$PGIMG" >/dev/null
  until docker exec "$1" pg_isready -q -U postgres 2>/dev/null \
    && docker exec "$1" psql -U postgres -tAc 'select 1' >/dev/null 2>&1; do sleep 0.5; done
}

sql() { _c=$1; shift; docker exec -i "$_c" psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres -tA "$@"; }

# migrate <db> [extra docker args...] -- runs the runner, output in $WORK/<db>.log
migrate() {
  db=$1; shift
  docker run --rm --label mcpe-migrate-test --network "$NET" \
    -e PGHOST="$db" -e PGUSER=postgres -e PGPASSWORD="$PW" -e PGDATABASE=postgres \
    -e AUTHENTICATOR_PASSWORD="$AUTH_PW" "$@" "$IMAGE" > "$WORK/$db.log" 2>&1
}

snapshot() { sql "$1" < "$HERE/schema-snapshot.sql" > "$WORK/$1.snapshot"; }
same_schema() {
  diff -u "$WORK/$1.snapshot" "$WORK/$2.snapshot" > "$WORK/$1-$2.diff" && return 0
  head -40 "$WORK/$1-$2.diff" >&2
  return 1
}
n_migrations=$(ls "$ROOT/self-host/db/migrations"/*.sql | wc -l | tr -d ' ')

# The pre-tracking schema exactly as 00-schema.sql + 01-roles.sh created it.
load_legacy() {
  sql "$1" < "$HERE/fixtures/legacy-00-schema-2026-07-09.sql" >/dev/null
  sql "$1" -c "ALTER ROLE authenticator WITH PASSWORD 'legacy'" >/dev/null
  # Data as the old CLI wrote it: PostgREST cast the base64url string to bytea.
  sql "$1" >/dev/null <<'SQL'
INSERT INTO public.inboxes (id, workspace_id, provider, service, email_address, imap_host, imap_port, imap_tls,
                            smtp_host, smtp_port, smtp_tls, imap_password, status)
VALUES ('11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-000000000001', 'imap', 'generic',
        'ops@example.com', 'imap.example.com', 993, true, 'smtp.example.com', 587, true,
        's3Mio-TJNCxgIzW6c6DbtuVf1J_sniaqkfkareq9acDuAt34gw'::bytea, 'active'),
       ('22222222-2222-2222-2222-222222222222', '00000000-0000-0000-0000-000000000001', 'imap', 'generic',
        'sales@example.com', 'imap.example.com', 993, true, 'smtp.example.com', 465, true,
        'AAAA_bbbb-CCCC'::bytea, 'active');
INSERT INTO public.api_keys (id, workspace_id, created_by, name, key_prefix, key_hash, scopes, inbox_ids)
VALUES ('33333333-3333-3333-3333-333333333333', '00000000-0000-0000-0000-000000000001',
        '00000000-0000-0000-0000-000000000001', 'agent', 'mcpe_abc', 'deadbeef', '{read:email,send:email}',
        '{11111111-1111-1111-1111-111111111111,22222222-2222-2222-2222-222222222222}');
INSERT INTO public.activity_log (workspace_id, api_key_id, inbox_id, tool_name, status, created_at)
VALUES ('00000000-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333',
        '11111111-1111-1111-1111-111111111111', 'email_read', 'success', '2026-08-01T10:00:00Z');
INSERT INTO public.scheduled_sends (workspace_id, inbox_id, payload, payload_encrypted, send_at)
VALUES ('00000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        '{"v":1,"data":"abc"}', true, now() + interval '1 day');
SQL
}

legacy_data_checks() {
  db=$1
  check "$db: imap_password is text holding the original base64url string" \
    '[ "$(sql $db -c "select imap_password from inboxes where email_address = '"'"'ops@example.com'"'"'")" = "s3Mio-TJNCxgIzW6c6DbtuVf1J_sniaqkfkareq9acDuAt34gw" ]'
  check "$db: second inbox password preserved" \
    '[ "$(sql $db -c "select imap_password from inboxes where email_address = '"'"'sales@example.com'"'"'")" = "AAAA_bbbb-CCCC" ]'
  check "$db: API key, its inbox restriction and the operator seed survive" \
    '[ "$(sql $db -c "select array_length(inbox_ids,1) from api_keys where key_prefix = '"'"'mcpe_abc'"'"' and deleted_at is null")" = "2" ]'
  check "$db: activity log and scheduled send survive" \
    '[ "$(sql $db -c "select (select count(*) from activity_log) || '"'"','"'"' || (select count(*) from scheduled_sends)")" = "1,1" ]'
  check "$db: operator is owner in workspace_members" \
    '[ "$(sql $db -c "select role from workspace_members")" = "owner" ]'
  check "$db: first use is taken from history, not replayed" \
    '[ "$(sql $db -c "select onboarding_stage from workspaces")" = "value_activation" ]'
}

echo "1. fresh install"
start_pg fresh
migrate fresh && pass "runner exits 0" || { failed "runner failed"; cat "$WORK/fresh.log"; }
check "all $n_migrations migrations recorded" '[ "$(sql fresh -c "select count(*) from selfhost.schema_migrations")" = "$n_migrations" ]'
check "inbox projection columns exist (INBOX_SELECT_COLUMNS)" \
  '[ "$(sql fresh -c "select count(*) from information_schema.columns where table_schema = '"'"'public'"'"' and table_name = '"'"'inboxes'"'"' and column_name in ('"'"'imap_security'"'"','"'"'smtp_security'"'"','"'"'send_approval_required'"'"','"'"'imap_password'"'"')")" = "4" ]'
check "credential columns are text" \
  '[ "$(sql fresh -c "select string_agg(distinct data_type, '"'"','"'"') from information_schema.columns where table_name = '"'"'inboxes'"'"' and column_name in ('"'"'imap_password'"'"','"'"'oauth_access_token'"'"','"'"'oauth_refresh_token'"'"')")" = "text" ]'
check "PostgREST can log in with AUTHENTICATOR_PASSWORD (quotes and all)" \
  'docker run --rm --label mcpe-migrate-test --network "$NET" -e PGPASSWORD="$AUTH_PW" "$PGIMG" psql -h fresh -U authenticator -d postgres -tAc "select 1" >/dev/null 2>&1'
check "password not echoed in logs" '! grep -q "with quotes" "$WORK/fresh.log"'
check "row level security is on for every public table (new tables must enable it)" \
  '[ "$(sql fresh -c "select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = '"'"'public'"'"' and c.relkind in ('"'"'r'"'"','"'"'p'"'"') and not c.relrowsecurity")" = "0" ]'
check "anon and authenticated have no table privileges" \
  '[ "$(sql fresh -c "select count(*) from information_schema.role_table_grants where table_schema = '"'"'public'"'"' and grantee in ('"'"'anon'"'"','"'"'authenticated'"'"')")" = "0" ]'
snapshot fresh

echo "2. rerun is a no-op"
migrate fresh
check "applied 0 new migration(s)" 'grep -q "applied 0 new migration" "$WORK/fresh.log"'
sql fresh < "$HERE/schema-snapshot.sql" > "$WORK/fresh2.snapshot"
check "schema unchanged" 'same_schema fresh fresh2'

echo "3. every migration re-applies cleanly over its own result"
sql fresh -c "truncate selfhost.schema_migrations" >/dev/null
migrate fresh && pass "re-applying everything succeeds" || { failed "re-apply failed"; cat "$WORK/fresh.log"; }
sql fresh < "$HERE/schema-snapshot.sql" > "$WORK/fresh3.snapshot"
check "schema unchanged after re-apply" 'same_schema fresh fresh3'

echo "4. legacy 00-schema.sql install with data"
start_pg legacy
load_legacy legacy
migrate legacy && pass "upgrade succeeds" || { failed "upgrade failed"; cat "$WORK/legacy.log"; }
check "detected as legacy" 'grep -q "predates migration tracking" "$WORK/legacy.log"'
snapshot legacy
check "schema identical to a fresh install" 'same_schema fresh legacy'
legacy_data_checks legacy
check "SMTP 587 backfilled to starttls, 465 to tls" \
  '[ "$(sql legacy -c "select string_agg(smtp_port || '"'"'='"'"' || smtp_security, '"'"','"'"' order by smtp_port) from inboxes")" = "465=tls,587=starttls" ]'

# The manual fixes operators applied to keep an untracked install running.
apply_hand_patches() {
  sql "$1" >/dev/null <<'SQL'
ALTER TABLE public.api_keys ADD COLUMN card_build_notified text;
ALTER TABLE public.inboxes
  ADD COLUMN imap_security text NOT NULL DEFAULT 'tls',
  ADD COLUMN smtp_security text NOT NULL DEFAULT 'tls',
  ADD COLUMN send_approval_required boolean NOT NULL DEFAULT false;
ALTER TABLE public.inboxes ALTER COLUMN imap_password TYPE text USING encode(imap_password, 'escape');
SQL
  for m in 20260802190000_add_outbound_idempotency 20260819180000_widen_outbound_idempotency_operations \
           20260830120000_idempotency_result_snapshot 20260923090000_idempotency_draft_writes; do
    sql "$1" < "$ROOT/supabase/migrations/$m.sql" >/dev/null
  done
}

echo "5. legacy install after the usual hand patches"
start_pg patched
load_legacy patched
apply_hand_patches patched
migrate patched && pass "upgrade succeeds" || { failed "upgrade failed"; cat "$WORK/patched.log"; }
snapshot patched
check "schema identical to a fresh install" 'same_schema fresh patched'
legacy_data_checks patched
check "warns about SMTP 587 with security=tls and how to fix it" \
  'grep -q "ops@example.com uses SMTP port 587 with security=tls" "$WORK/patched.log" && grep -q "mcpe set-security --inbox ops@example.com --smtp-security starttls" "$WORK/patched.log"'
check "operator value left as set" \
  '[ "$(sql patched -c "select smtp_security from inboxes where smtp_port = 587")" = "tls" ]'

echo "6. legacy install hand-converted with USING col::text"
start_pg hexed
load_legacy hexed
sql hexed -c "ALTER TABLE public.inboxes ALTER COLUMN imap_password TYPE text USING imap_password::text" >/dev/null
check "precondition: values are hex-rendered" \
  '[ "$(sql hexed -c "select left(imap_password, 2) from inboxes limit 1")" = "\\x" ]'
migrate hexed && pass "upgrade succeeds" || { failed "upgrade failed"; cat "$WORK/hexed.log"; }
check "hex values repaired to the original strings" \
  '[ "$(sql hexed -c "select imap_password from inboxes where email_address = '"'"'ops@example.com'"'"'")" = "s3Mio-TJNCxgIzW6c6DbtuVf1J_sniaqkfkareq9acDuAt34gw" ]'

echo "7. a failing migration leaves no trace"
mkdir -p "$WORK/broken"
cp "$ROOT/self-host/db/migrations"/*.sql "$WORK/broken/"
cat > "$WORK/broken/9998_ok.sql" <<'SQL'
CREATE TABLE public.should_exist (id int);
SQL
cat > "$WORK/broken/9999_broken.sql" <<'SQL'
CREATE TABLE public.should_not_exist (id int);
SELECT 1 / 0;
SQL
chmod -R a+rX "$WORK/broken"
if migrate fresh -v "$WORK/broken:/migrations:ro"; then failed "runner should exit non-zero"; else pass "runner exits non-zero"; fi
check "error names the migration" 'grep -q "9999_broken.sql failed" "$WORK/fresh.log"'
check "earlier migrations in the same run are kept" '[ "$(sql fresh -c "select to_regclass('"'"'public.should_exist'"'"') is not null")" = "t" ]'
check "partial table rolled back" '[ "$(sql fresh -c "select to_regclass('"'"'public.should_not_exist'"'"') is null")" = "t" ]'
check "not recorded as applied" '[ "$(sql fresh -c "select count(*) from selfhost.schema_migrations where version = '"'"'9999'"'"'")" = "0" ]'
check "serve mode exits non-zero too (dependants never start)" \
  '! docker run --rm --label mcpe-migrate-test --network "$NET" -e PGHOST=fresh -e PGUSER=postgres -e PGPASSWORD="$PW" -e AUTHENTICATOR_PASSWORD=x -v "$WORK/broken:/migrations:ro" "$IMAGE" serve >/dev/null 2>&1'
sql fresh -c "drop table public.should_exist; delete from selfhost.schema_migrations where version = '9998'" >/dev/null

echo "8. an applied migration that changed is refused"
mkdir -p "$WORK/edited"
cp "$ROOT/self-host/db/migrations"/*.sql "$WORK/edited/"
echo "-- edited after release" >> "$WORK/edited/0005_api_keys_parity.sql"
chmod -R a+rX "$WORK/edited"
if migrate fresh -v "$WORK/edited:/migrations:ro"; then failed "runner should refuse"; else pass "runner refuses"; fi
check "explains why" 'grep -q "0005_api_keys_parity.sql changed after it was applied" "$WORK/fresh.log"'
migrate fresh -v "$WORK/edited:/migrations:ro" -e MIGRATIONS_ALLOW_CHANGED=true \
  && pass "MIGRATIONS_ALLOW_CHANGED=true lets it through with a warning" || failed "override did not work"

echo "9. two runners at once"
start_pg race
( migrate race ) & ( docker run --rm --label mcpe-migrate-test --network "$NET" -e PGHOST=race -e PGUSER=postgres \
    -e PGPASSWORD="$PW" -e AUTHENTICATOR_PASSWORD="$AUTH_PW" "$IMAGE" > "$WORK/race2.log" 2>&1 ) &
wait
check "every migration recorded exactly once" '[ "$(sql race -c "select count(*) from selfhost.schema_migrations")" = "$n_migrations" ]'
snapshot race
check "schema identical to a fresh install" 'same_schema fresh race'

echo "10. status mode"
docker run --rm --label mcpe-migrate-test --network "$NET" -e PGHOST=fresh -e PGUSER=postgres -e PGPASSWORD="$PW" \
  "$IMAGE" status > "$WORK/status.log" 2>&1
check "lists every migration as applied" '[ "$(grep -c " applied " "$WORK/status.log")" = "$n_migrations" ]'

echo "11. move a hand-patched legacy install into a new stack (restore mode)"
start_pg olddeploy
load_legacy olddeploy
apply_hand_patches olddeploy
docker exec olddeploy pg_dump -U postgres -d postgres -Fc > "$WORK/patched.dump"
start_pg target
migrate target   # the new deployment's first boot: full, tracked schema
restore() {
  docker run --rm -i --label mcpe-migrate-test --network "$NET" -e PGHOST=target -e PGUSER=postgres -e PGPASSWORD="$PW" \
    -e AUTHENTICATOR_PASSWORD="$AUTH_PW" "$@" "$IMAGE" restore < "$WORK/patched.dump" > "$WORK/target.log" 2>&1
}
if restore; then failed "restore must refuse without confirmation"; else pass "refuses without CONFIRM_RESTORE"; fi
check "nothing was touched by the refused restore" '[ "$(sql target -c "select count(*) from inboxes")" = "0" ]'
restore -e CONFIRM_RESTORE=replace-all-data && pass "restore succeeds" || { failed "restore failed"; cat "$WORK/target.log"; }
check "the restored legacy schema was adopted, not trusted as current" 'grep -q "predates migration tracking" "$WORK/target.log"'
snapshot target
check "schema identical to a fresh install" 'same_schema fresh target'
legacy_data_checks target
echo
if [ "$FAILS" -gt 0 ]; then echo "$FAILS check(s) failed"; exit 1; fi
echo "all migration checks passed"
