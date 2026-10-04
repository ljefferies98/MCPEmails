#!/bin/sh
# ============================================================
# MCP Emails self-host, schema migration runner
# ============================================================
# Applies self-host/db/migrations/NNNN_name.sql to the database, in order,
# exactly once each, and records what it applied in selfhost.schema_migrations.
#
#   migrate.sh            apply pending migrations, then exit
#   migrate.sh serve      apply, then stay up and report healthy (compose)
#   migrate.sh status     print applied / pending migrations, change nothing
#   migrate.sh restore    REPLACE the database with a pg_dump (custom format)
#                         read from stdin, then migrate it; needs
#                         CONFIRM_RESTORE=replace-all-data
#
# Guarantees:
#   * deterministic order: files sorted by name (C locale), NNNN_ prefix;
#   * each migration runs in ONE transaction together with its history row,
#     so it either fully applies and is recorded, or leaves no trace;
#   * an advisory lock serialises concurrent runners, and a migration a
#     concurrent runner already recorded is skipped, never re-run;
#   * the first failure stops the run with a non-zero exit (and in `serve`
#     mode the container exits, so dependants never start);
#   * an applied migration whose file has since changed is refused (checksum)
#     unless MIGRATIONS_ALLOW_CHANGED=true;
#   * Postgres "already exists, skipping" notices are hidden; migrations
#     report anything worth reading with RAISE INFO / WARNING, which show;
#   * after migrating: the PostgREST login password is (re)set from
#     AUTHENTICATOR_PASSWORD and PostgREST is told to reload its schema cache.
#
# Connection: standard libpq env (PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE).
# POSIX sh only: the postgres:*-alpine image ships busybox ash.
# ============================================================
set -eu

MIGRATIONS_DIR="${MIGRATIONS_DIR:-/migrations}"
READY_FILE="${READY_FILE:-/tmp/migrations-complete}"
LOCK_KEY="hashtext('mcpemails.selfhost.migrations')"
MODE="${1:-apply}"

export PGAPPNAME="mcpemails-migrate"
PSQL="psql -X -q -v ON_ERROR_STOP=1"

log() { printf '[migrate] %s\n' "$*"; }
fail() { printf '[migrate] ERROR: %s\n' "$*" >&2; exit 1; }

# ── wait for the database ────────────────────────────────────────────────────
wait_for_db() {
  tries=0
  until pg_isready -q; do
    tries=$((tries + 1))
    [ "$tries" -ge "${DB_WAIT_SECONDS:-120}" ] && fail "database not reachable at ${PGHOST:-localhost}:${PGPORT:-5432} after ${DB_WAIT_SECONDS:-120}s"
    sleep 1
  done
  # pg_isready only proves the socket answers; prove we can log in too.
  $PSQL -tAc "SELECT 1" >/dev/null || fail "cannot log in to ${PGDATABASE:-postgres} as ${PGUSER:-postgres} (check POSTGRES_PASSWORD)"
}

# ── history table ────────────────────────────────────────────────────────────
ensure_history() {
  $PSQL <<SQL
BEGIN;
SET LOCAL client_min_messages = warning;
SELECT pg_advisory_xact_lock($LOCK_KEY) AS lock_acquired \gset
CREATE SCHEMA IF NOT EXISTS selfhost;
COMMENT ON SCHEMA selfhost IS 'MCP Emails self-host bookkeeping. Not exposed through PostgREST.';
CREATE TABLE IF NOT EXISTS selfhost.schema_migrations (
  version       text PRIMARY KEY,
  name          text NOT NULL,
  checksum      text NOT NULL,
  applied_at    timestamptz NOT NULL DEFAULT now(),
  execution_ms  integer NOT NULL
);
REVOKE ALL ON SCHEMA selfhost FROM PUBLIC;
COMMIT;
SQL
}

checksum_of() { sha256sum "$1" | cut -d' ' -f1; }

list_migrations() {
  [ -d "$MIGRATIONS_DIR" ] || fail "migrations directory $MIGRATIONS_DIR not found"
  # shellcheck disable=SC2012 # names are validated below
  ls -1 "$MIGRATIONS_DIR" | LC_ALL=C sort | while read -r f; do
    case "$f" in
      *.sql) ;;
      *) continue ;;
    esac
    echo "$f" | grep -Eq '^[0-9]{4}_[a-z0-9_]+\.sql$' \
      || fail "bad migration filename '$f' (expected NNNN_snake_case.sql)"
    echo "$f"
  done
}

history_exists() {
  [ "$($PSQL -tAc "SELECT to_regclass('selfhost.schema_migrations') IS NOT NULL")" = "t" ]
}

applied_checksum() {
  # $1 is a validated 4-digit version, safe to inline.
  $PSQL -tAc "SELECT checksum FROM selfhost.schema_migrations WHERE version = '$1'"
}

describe_state() {
  tracked=0
  history_exists && tracked=$($PSQL -tAc "SELECT count(*) FROM selfhost.schema_migrations")
  if [ "$tracked" -gt 0 ]; then
    latest=$($PSQL -tAc "SELECT version || '_' || name FROM selfhost.schema_migrations ORDER BY version DESC LIMIT 1")
    log "database is tracked: $tracked migration(s) applied, latest $latest"
  elif [ "$($PSQL -tAc "SELECT to_regclass('public.inboxes') IS NOT NULL")" = "t" ]; then
    log "database predates migration tracking (legacy 00-schema.sql install); adopting it, existing data is kept"
  else
    log "empty database; building the schema from scratch"
  fi
}

apply_one() {
  file="$1"
  version="${file%%_*}"
  name="${file#*_}"; name="${name%.sql}"
  sum="$2"
  log "applying $file"
  # One transaction: lock, re-check under the lock, run the file, record it.
  # ON_ERROR_STOP makes psql quit at the first error with the transaction
  # still open, so the server rolls all of it back.
  $PSQL \
    -v version="$version" -v name="$name" -v checksum="$sum" -v file="$MIGRATIONS_DIR/$file" <<SQL || fail "$file failed; nothing from it was applied. Fix the cause and redeploy."
BEGIN;
SET LOCAL client_min_messages = warning;
SELECT pg_advisory_xact_lock($LOCK_KEY) AS lock_acquired \gset
SELECT EXISTS (SELECT 1 FROM selfhost.schema_migrations WHERE version = :'version') AS already_applied \gset
\if :already_applied
  \echo '[migrate] ' :version 'was applied by a concurrent runner; skipping'
\else
  SELECT clock_timestamp() AS started_at \gset
  SET LOCAL search_path = public;
  \i :file
  RESET search_path;
  INSERT INTO selfhost.schema_migrations (version, name, checksum, execution_ms)
  VALUES (:'version', :'name', :'checksum',
          (extract(epoch FROM clock_timestamp() - :'started_at'::timestamptz) * 1000)::integer);
\endif
COMMIT;
SQL
}

run_migrations() {
  files=$(list_migrations)
  [ -n "$files" ] || fail "no migrations found in $MIGRATIONS_DIR"
  describe_state
  applied=0
  for f in $files; do
    version="${f%%_*}"
    sum=$(checksum_of "$MIGRATIONS_DIR/$f")
    recorded=$(applied_checksum "$version")
    if [ -n "$recorded" ]; then
      if [ "$recorded" != "$sum" ]; then
        if [ "${MIGRATIONS_ALLOW_CHANGED:-false}" = "true" ]; then
          log "WARNING: $f changed after it was applied (recorded $recorded, now $sum); not re-running it (MIGRATIONS_ALLOW_CHANGED=true)"
        else
          fail "$f changed after it was applied (recorded checksum $recorded, file now $sum). Applied migrations must never be edited; add a new migration instead. If the change is comment-only, set MIGRATIONS_ALLOW_CHANGED=true for one deploy."
        fi
      fi
      continue
    fi
    apply_one "$f" "$sum"
    applied=$((applied + 1))
  done
  # Detect a database that is ahead of this image (e.g. a rollback to an older
  # commit). The schema is additive, so this is normally safe, but say so.
  newest_file=$(echo "$files" | tail -n 1); newest_file="${newest_file%%_*}"
  ahead=$($PSQL -tAc "SELECT string_agg(version || '_' || name, ', ' ORDER BY version) FROM selfhost.schema_migrations WHERE version > '$newest_file'")
  [ -n "$ahead" ] && log "WARNING: database has migrations this image does not know about: $ahead (running an older release against a newer schema)"
  log "applied $applied new migration(s)"
}

post_migrate() {
  [ -n "${AUTHENTICATOR_PASSWORD:-}" ] || fail "AUTHENTICATOR_PASSWORD is not set; PostgREST could not log in"
  # Set from the environment on every run, so rotating it is just an env change.
  # \getenv reads it inside psql (never on a command line), and :'pw' quotes
  # it as a literal, so no value can break out of the statement.
  $PSQL <<'SQL'
\getenv pw AUTHENTICATOR_PASSWORD
ALTER ROLE authenticator WITH LOGIN PASSWORD :'pw';
SQL
  # Re-assert grants for anything a migration created, then have a running
  # PostgREST drop its schema cache so it sees new tables/columns immediately.
  $PSQL <<'SQL'
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO service_role;
NOTIFY pgrst, 'reload schema';
SQL
}

print_status() {
  files=$(list_migrations)
  describe_state
  printf '%-6s %-45s %-8s %s\n' VERSION NAME STATE APPLIED_AT
  for f in $files; do
    version="${f%%_*}"; name="${f#*_}"; name="${name%.sql}"
    row=""
    history_exists && row=$($PSQL -tAc "SELECT checksum || '|' || to_char(applied_at, 'YYYY-MM-DD HH24:MI:SS TZ') FROM selfhost.schema_migrations WHERE version = '$version'")
    if [ -z "$row" ]; then
      state=pending; at=""
    else
      at="${row#*|}"
      if [ "${row%%|*}" = "$(checksum_of "$MIGRATIONS_DIR/$f")" ]; then state=applied; else state=CHANGED; fi
    fi
    printf '%-6s %-45s %-8s %s\n' "$version" "$name" "$state" "$at"
  done
}

# Replace everything with a dump, then bring it up to date. The schemas are
# dropped first so the dump's own tables and migration history (or the lack of
# one, for a dump of a pre-tracking install) are what remain; migrating
# afterwards then adopts or continues from exactly what was restored.
restore_dump() {
  [ "${CONFIRM_RESTORE:-}" = "replace-all-data" ] \
    || fail "restore deletes every inbox, key and log in this database and replaces them with the dump. Re-run with CONFIRM_RESTORE=replace-all-data"
  dump=$(mktemp)
  cat > "$dump"
  [ -s "$dump" ] || fail "no dump on stdin (expected: ... restore < file.dump)"
  pg_restore --list "$dump" >/dev/null 2>&1 || fail "stdin is not a pg_dump custom-format (-Fc) file"
  log "restoring $(wc -c < "$dump" | tr -d ' ') bytes; existing data in ${PGDATABASE:-postgres} is being replaced"
  $PSQL <<'SQL'
BEGIN;
DROP SCHEMA IF EXISTS selfhost CASCADE;
DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;
COMMIT;
SQL
  pg_restore --no-owner --exit-on-error --dbname "${PGDATABASE:-postgres}" "$dump" \
    || fail "pg_restore failed; the database is now partially restored. Fix the cause and run restore again"
  rm -f "$dump"
  log "dump restored"
}

wait_for_db

case "$MODE" in
  apply)
    ensure_history
    run_migrations
    post_migrate
    log "schema is up to date"
    ;;
  serve)
    # Only serve mode owns the health marker; `status`/`restore` exec'd into
    # the running container must not make it look unhealthy.
    rm -f "$READY_FILE"
    ensure_history
    run_migrations
    post_migrate
    log "schema is up to date; signalling ready"
    touch "$READY_FILE"
    # Stay up so orchestrators that treat an exited container as unhealthy
    # (Coolify) show the stack as running. Exit promptly on stop.
    trap 'exit 0' TERM INT
    while :; do sleep 3600 & wait $!; done
    ;;
  status)
    print_status
    ;;
  restore)
    restore_dump
    ensure_history
    run_migrations
    post_migrate
    log "restored and up to date"
    ;;
  *)
    fail "unknown mode '$MODE' (use: apply | serve | status | restore)"
    ;;
esac
