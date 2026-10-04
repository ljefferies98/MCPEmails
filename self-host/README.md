# Self-host MCP Emails

Run the **exact MCP server that powers [mcpemails.com](https://mcpemails.com)** on your own
machine, against your own database. Your mailbox credentials never leave infrastructure you
control: they are encrypted with a key only you hold, decrypted only in your container, at the
moment a tool call needs them. No account, no API keys held by us, no Stripe, no telemetry.

This is part of our [trust & security commitment](https://mcpemails.com/security): the server is
open and auditable, and you can verify "email is fetched live and never stored" by running it
yourself and watching the network.

> **Scope.** This is the headless server: the MCP endpoint, its database, and a CLI to connect
> mailboxes and mint keys. It is **IMAP/SMTP-first** (Fastmail, iCloud, Yahoo, Zoho, Yandex, Gmail
> app passwords, or any generic IMAP host). Gmail/Outlook OAuth and the web dashboard are part of the
> hosted product and are intentionally out of scope here: they pull in OAuth client secrets, a
> session layer, and billing that a single-operator self-host does not need.

**Contents:** [What you get](#what-you-get) · [Environment variables](#environment-variables) ·
[Quick start (any Docker host)](#quick-start-any-docker-host) · [Deploy on Coolify](#deploy-on-coolify) ·
[Connect an inbox](#connect-an-inbox) · [TLS: 465 vs 587](#tls-implicit-tls-465-vs-starttls-587) ·
[API keys](#api-keys) · [Upgrading](#upgrading) · [Migrations](#migrations) ·
[Backups](#backups-and-housekeeping) · [Troubleshooting](#troubleshooting) ·
[Contributors](#for-contributors-changing-the-schema)

---

## What you get

```
┌──────────────┐   JSON-RPC over HTTPS   ┌─────────────────────────────┐
│  MCP client  │  Authorization: Bearer  │  mcp-server  (Deno, :8000)  │
│ Claude/Cursor│ ─────────────────────▶  │  decrypts creds, fetches    │ ──▶ your mail
└──────────────┘     mcpe_… API key      │  live from your provider    │     (IMAP/SMTP)
                                         └────────────┬────────────────┘
                                                      │ supabase-js
                                         ┌────────────▼───────┐  ┌──────────────┐
                                         │ gateway (nginx)    │─▶│ PostgREST    │
                                         └────────────────────┘  └──────┬───────┘
                                                                        │
                                 ┌──────────────┐  applies     ┌────────▼───────┐
                                 │ migrate      │ ───────────▶ │ Postgres 16    │
                                 │ (runs first) │  migrations  │ volume: pgdata │
                                 └──────────────┘              └────────────────┘
```

Every service is on a private Docker network. Only `mcp-server` is meant to be reachable, and only
through a TLS-terminating proxy (Coolify's, Caddy, or your own) or on `127.0.0.1` locally.

| Service | Image | Role |
| --- | --- | --- |
| `db` | `postgres:16-alpine` | Inboxes (encrypted creds), hashed API keys, activity log, scheduled sends, automations. Data lives in the named volume `pgdata`. |
| `migrate` | built from `db/` | Applies pending schema migrations, then reports healthy. Nothing below starts until it has. |
| `postgrest` | `postgrest/postgrest` | The REST layer the server talks to (`supabase-js`) |
| `gateway` | built from `gateway/` (nginx) | Serves PostgREST under the `/rest/v1/` path the server expects; healthy only when PostgREST has loaded the schema |
| `mcp-server` | built from this repo's `supabase/functions/mcp-server` | The MCP server itself, listening on **port 8000**. Also contains the `mcpe` CLI. |
| `dispatcher` | `curlimages/curl` | Once a minute: sends due scheduled emails (`/dispatch`) and runs due automations (`/triage-dispatch`) |

Start-up order is enforced with health checks: `db` → `migrate` → `postgrest` → `gateway` →
`mcp-server` → `dispatcher`. If a migration fails, the stack stops at `migrate` and the error is
in its log; on an upgrade, the previous `mcp-server` keeps running meanwhile.

## Environment variables

Generate all of them at once with `make setup` (writes `.env`) or, without `make`:

```bash
docker run --rm -v "$PWD/self-host/cli:/cli:ro" denoland/deno:2.1.4 \
  run --allow-net --allow-env /cli/mcpe.ts gen-secrets
```

| Variable | Required | What it is |
| --- | --- | --- |
| `POSTGRES_PASSWORD` | yes | Postgres superuser password. Stored in the volume on first start. |
| `AUTHENTICATOR_PASSWORD` | yes | PostgREST's login. Re-applied by `migrate` on every start, so you can rotate it. |
| `JWT_SECRET` | yes | Secret PostgREST verifies tokens with. |
| `SERVICE_ROLE_JWT` | yes | Token the server and CLI present to PostgREST. Must be signed with `JWT_SECRET` (`gen-secrets` does this). |
| `ENCRYPTION_KEY` | yes | 64 hex chars (32 bytes), AES-256-GCM key for credentials at rest. **See the warning below.** |
| `DISPATCH_SECRET` | yes | Guards `/dispatch` and `/triage-dispatch`. |
| `APP_URL` | recommended | Your public URL, e.g. `https://mcp.example.com`. Used in links the server returns. |
| `MCP_PORT` | no | Local loopback port (default `8787`). Ignored on Coolify. |
| `USAGE_ENFORCEMENT_DISABLED` | no | Defaults to `true`. Self-host has no plans or billing; leave it. |
| `SMTP_RELAY_URL`, `SMTP_RELAY_HOSTS` | no | Optional SMTP egress relay, see [docs/smtp-relay.md](../docs/smtp-relay.md). |
| `MIGRATIONS_ALLOW_CHANGED` | no | Escape hatch, see [Migrations](#migrations). |

> [!WARNING]
> **Never regenerate or change `ENCRYPTION_KEY` after you have provisioned an inbox.** Every stored
> mailbox password, scheduled send and pending approval is encrypted with it; a different key makes
> all of them permanently unreadable, and there is no recovery. Upgrades never touch it. Store a copy
> somewhere safe, separately from your database backups (a backup without the key is useless, and
> the two together are your mail credentials). On Coolify, do not use a "generate" button for it on
> a redeploy, and do not delete the variable.

## Quick start (any Docker host)

```bash
cd self-host

# 1. Generate secrets. Writes .env; run once, keep it private.
make setup

# 2. Build and start. Migrations run automatically before the server starts.
make up

# 3. Connect a mailbox (see "Connect an inbox" for providers and TLS).
export IMAP_PASSWORD='your-app-specific-password'
make provision EMAIL=you@example.com \
  IMAP_HOST=imap.fastmail.com SMTP_HOST=smtp.fastmail.com SERVICE=fastmail

# 4. Mint an MCP API key (printed once, copy it now).
make key NAME="my agent"
```

Point any MCP client at **`http://localhost:8787`** with the key as a bearer token:

```jsonc
{
  "mcpServers": {
    "mcpemails": {
      "url": "http://localhost:8787",
      "headers": { "Authorization": "Bearer mcpe_your_key_here" }
    }
  }
}
```

Locally, `docker compose` (and therefore `make`) automatically merges
`docker-compose.override.yml`, which publishes the server on `127.0.0.1:8787` only. It is never
reachable from your LAN or the internet that way. For remote access over HTTPS without Coolify, use
the bundled Caddy overlay:

```bash
MCP_PUBLIC_HOST=mcp.example.com APP_URL=https://mcp.example.com \
docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d --build
```

(Create the DNS record first and open ports 80/443; Caddy obtains the certificate. With an existing
reverse proxy, proxy to the `mcp-server` container on port 8000, preserve the `Authorization`
header, and never expose port 8000 without TLS.)

## Deploy on Coolify

> A step-by-step walkthrough, including moving an existing deployment's data across, is in
> [DEPLOY-COOLIFY.md](DEPLOY-COOLIFY.md).

Coolify builds everything from your Git repository. Nothing is pasted into Coolify and nothing
needs to exist on the server beforehand.

1. **New resource → Application → your Git repository** (a public URL, or a private repo via a
   GitHub App / deploy key). Branch: the one you deploy, e.g. `main`.
2. **Build pack: Docker Compose.**
   - **Base Directory: `/self-host`**
   - **Docker Compose Location: `/docker-compose.yml`**

   Coolify runs Compose with the base directory as the project directory. Build contexts in the
   file (`./db`, `./gateway`, and `..` for the server, which needs the repo root) resolve inside
   Coolify's checkout. Coolify passes the file with `-f`, so `docker-compose.override.yml` (the
   local loopback port) is *not* loaded, which is what you want.
3. **Environment Variables.** Generate a set once (see [Environment variables](#environment-variables))
   and paste them in (Developer view accepts the whole `.env` block). Coolify marks the required
   ones (`${VAR:?}` in the compose file) and refuses to deploy while any is empty. Set `APP_URL` to
   your MCP URL, e.g. `https://mcp.example.com`. Do not paste `MCP_PORT`; it is unused here.
4. **Domains.** On the **`mcp-server`** service only, set the domain **with the container port**:
   `https://mcp.example.com:8000`. The `:8000` tells Coolify's proxy which container port to route
   to; clients still use `https://mcp.example.com` on 443. Leave every other service without a
   domain. `db`, `postgrest` and `gateway` publish no ports and must stay internal.
5. **Deploy.** Watch the `migrate` service's logs for `[migrate] schema is up to date`. Then
   `mcp-server` starts and becomes healthy.
6. **Provision inboxes and keys** from Coolify's **Terminal**, connected to the **`mcp-server`**
   container. It already has the database URL, service token and `ENCRYPTION_KEY`:

   ```sh
   IMAP_PASSWORD='app-password' mcpe provision-inbox --email you@example.com \
     --imap-host imap.example.com --smtp-host smtp.example.com --smtp-port 587
   mcpe create-key --name "my agent"
   mcpe list-inboxes
   ```

   (A password typed in a terminal can end up in shell history; on a shared server, prefer
   `read -rs IMAP_PASSWORD; export IMAP_PASSWORD` first.)

7. Your MCP endpoint is the **root URL**: `https://mcp.example.com`, with
   `Authorization: Bearer mcpe_…`. There is no `/api/mcp` path on self-host.

The `migrate` container stays running (idle) after it finishes, so Coolify shows the application as
healthy. That is intentional: a container that exits after doing its job is shown as a failure by
some platforms.

## Connect an inbox

```bash
export IMAP_PASSWORD='app-specific-password'   # read from env, not argv, so it stays out of `ps`
make provision EMAIL=you@example.com IMAP_HOST=imap.example.com SMTP_HOST=smtp.example.com \
  SMTP_PORT=587 [IMAP_PORT=993] [USERNAME=login-if-not-the-address] [SERVICE=generic] [DISPLAY_NAME="You"]
# same thing inside the container (e.g. Coolify terminal):
mcpe provision-inbox --email you@example.com --imap-host imap.example.com --smtp-host smtp.example.com \
  --smtp-port 587 [--imap-port 993] [--imap-security tls|starttls] [--smtp-security tls|starttls] \
  [--username login] [--service generic] [--display-name "You"]
```

Re-running `provision-inbox` for the same address updates it in place (same inbox id, so keys
restricted to it keep working); use that to change a password. To provision several company
mailboxes, run it once per address.

| Provider | `SERVICE` | IMAP host | SMTP host | Ports |
| --- | --- | --- | --- | --- |
| Fastmail | `fastmail` | `imap.fastmail.com` | `smtp.fastmail.com` | 993 / 465 |
| iCloud | `icloud` | `imap.mail.me.com` | `smtp.mail.me.com` | 993 / 587 |
| Yahoo | `yahoo` | `imap.mail.yahoo.com` | `smtp.mail.yahoo.com` | 993 / 465 |
| Zoho | `zoho` | `imap.zoho.com` | `smtp.zoho.com` | 993 / 465 |
| Yandex | `yandex` | `imap.yandex.com` | `smtp.yandex.com` | 993 / 465 |
| Gmail (app password) | `gmail` | `imap.gmail.com` | `smtp.gmail.com` | 993 / 465 |
| Any IMAP host | `generic` | *your host* | *your host* | usually 993 / 465 or 587 |

All of these require an **app-specific password** (not your login password) and IMAP/SMTP access
enabled in the provider's settings.

**Example: a generic host where port 465 is blocked (e.g. Migadu from some VPS providers).**

```sh
IMAP_PASSWORD='mailbox-password' mcpe provision-inbox --email ops@yourcompany.example \
  --imap-host imap.migadu.com --imap-port 993 \
  --smtp-host smtp.migadu.com --smtp-port 587 \
  --service generic --display-name "Ops"
#  ✓ connected ops@yourcompany.example (generic, imap imap.migadu.com:993 tls / smtp smtp.migadu.com:587 starttls)
```

## TLS: implicit TLS (465) vs STARTTLS (587)

Mail servers offer two ways to encrypt a connection, and each port expects exactly one:

| Mode (`--*-security`) | How it connects | Usual ports |
| --- | --- | --- |
| `tls` (implicit TLS, "SSL/TLS") | TLS handshake from the first byte | IMAP **993**, SMTP **465** |
| `starttls` | Plain connection, then upgraded with `STARTTLS` before logging in | IMAP **143**, SMTP **587** (and 25) |

Both are encrypted before the password is sent; neither is "less secure" in practice. What matters
is that the mode matches the port. A mismatch does not fail cleanly: implicit TLS against a STARTTLS
port (or the reverse) waits for a greeting that never comes and **hangs until the timeout**.

- The CLI picks the mode from the port (993/465 → `tls`, 143/587/25 → `starttls`). For any other
  port it refuses to guess and asks for `--imap-security` / `--smtp-security`.
- The server uses the stored mode as is, whatever the port.
- **Port 465 hangs but 587 works** (common on cloud VPSs, which often filter 465 outbound): provision
  with `--smtp-port 587`. STARTTLS is chosen automatically. To check from the server:
  `nc -vz smtp.example.com 465` vs `nc -vz smtp.example.com 587`.
- To change an existing inbox without re-entering its password:
  `mcpe set-security --inbox you@example.com --smtp-security starttls` (or
  `make set-security INBOX=you@example.com SMTP_SECURITY=starttls`).
- `mcpe list-inboxes` shows each inbox's host, port and mode.

## API keys

```bash
make key NAME="assistant"                                   # all default scopes, every inbox
make key NAME="ops bot" INBOX="ops@co.example sales@co.example" SCOPES=read:email,send:email
make key NAME="triage" SCOPES=read:email,manage:folders,manage:automations EXPIRES_DAYS=90
make keys                    # list (prefixes only)
make revoke PREFIX=mcpe_ab1  # revoke
# in the container:
mcpe create-key --name "ops bot" --inbox ops@co.example --inbox sales@co.example --scopes read:email,send:email
```

- A key is printed **once**; only its SHA-256 hash is stored.
- `--inbox` is repeatable. One key can be bound to several mailboxes; without `--inbox` it can use
  every inbox, including ones provisioned later. With several inboxes, tools take
  `inbox`/`inbox_id`, and `inbox_list` shows what the key can reach.
- Default scopes: `read:email`, `send:email`, `manage:folders`, `delete:email`, `manage:drafts`,
  `manage:contacts`, `schedule:email`. Also available on request: `search:email`, and
  `manage:automations` (rules that act on mail unattended; they run every minute via the dispatcher).

Start a session with `inbox_list`. The server exposes the same action-based tools as the hosted
product (`email_read`, `email_compose`, `email_organize`, `draft`, `schedule`, `signature_get`, …).
Send-like calls accept an `idempotency_key`, which makes retries safe; it is enforced, and a call
with a key is refused rather than sent unprotected if the record cannot be written.

## Upgrading

The database schema upgrades itself. Each deploy runs `migrate` first, which applies whatever
migrations the new commit brings, in order, and only then starts the new server. Your volume, and
with it every inbox, key, credential and setting, is kept.

**Docker host:**

```bash
cd self-host
make backup          # optional but recommended before any upgrade
git pull
make up              # = docker compose up -d --build
make migrate-status  # optional: confirm everything is "applied"
```

**Coolify:** push or pull the new commit to the branch and click **Redeploy** (or enable automatic
deploys). That is all. Do not delete the volume, and do not regenerate any variable.

**Coming from a pre-migration self-host install** (anything that used `self-host/db/00-schema.sql`):
upgrade exactly as above. `migrate` recognises the old layout, logs
`database predates migration tracking … adopting it`, and brings it up to date in place:

- it converts the stored passwords from `bytea` to the text the server expects, keeping their value;
- it adds every missing column and table (`imap_security`, `smtp_security`,
  `send_approval_required`, `card_build_notified`, `outbound_idempotency`, …);
- it is safe if you already added some of these by hand, and repairs a `USING col::text`
  conversion that stored `\x…` hex.
- Inboxes whose existing TLS mode contradicts their port (e.g. SMTP 587 with `tls`, typically left
  by a manual `ADD COLUMN … DEFAULT 'tls'`) are **not** changed. `migrate` prints a `WARNING` with
  the exact `mcpe set-security` command to fix each one.

### Moving an existing install into a new deployment

A *new* deployment gets a *new* volume. Switching a Coolify app from pasted compose to this Git-based
setup creates a new resource, and it starts empty. Upgrading in place only applies when the volume
stays the same. To carry your inboxes, keys and settings across, copy the database once:

1. **Dump the old database** (on the server, using the old stack's `db` container;
   `docker ps --filter name=db` finds it):

   ```sh
   docker exec <old-db-container> pg_dump -U postgres -d postgres -Fc > mcpemails-old.dump
   ```

2. **Create and deploy the new stack** as in [Deploy on Coolify](#deploy-on-coolify), with the **same
   `ENCRYPTION_KEY`** as the old one. This is mandatory; the stored passwords are encrypted with it.
   The other secrets may be new.
3. **Restore into the new stack** through its `migrate` container. Restore replaces whatever the new
   database holds, then migrates the restored data. An old, untracked schema is adopted exactly as in
   an in-place upgrade.

   ```sh
   docker exec -i -e CONFIRM_RESTORE=replace-all-data <new-migrate-container> mcpe-migrate restore < mcpemails-old.dump
   # Docker host with make:  make restore FILE=mcpemails-old.dump
   ```

4. **Check it**: `mcpe list-inboxes` and `mcpe list-keys` (Terminal → `mcp-server`). Your existing API
   keys keep working. Watch the restore output for `WARNING` lines, such as an SMTP port/TLS mismatch
   with its `mcpe set-security` fix.
5. Point your MCP clients' URL at the new domain if it changed. Only then stop the old resource, and
   keep its volume until you are sure.

Rolling back to an older commit is safe for the schema (migrations only add); `migrate` will log
that the database has migrations the image does not know about.

The Postgres **major** version stays at 16. Moving to a newer major version is a dump/restore
operation (see Backups), never an image bump on the existing volume.

## Migrations

- Live in [`db/migrations/`](db/migrations/), named `NNNN_description.sql`, applied in numeric order.
- Recorded in the table `selfhost.schema_migrations` (version, name, SHA-256 checksum, time, duration).
  The `selfhost` schema is not exposed through PostgREST.
- Each migration runs in **one transaction** together with its history row: it is either fully
  applied and recorded, or not applied at all. The first failure stops the run, `migrate` exits
  non-zero, and nothing after it starts (Compose reports `dependency failed to start`). Fix the cause
  and redeploy; it resumes from the failed migration.
- An advisory lock makes concurrent runs safe; a migration is never applied twice.
- An already-applied migration whose file has **changed** is refused (checksum mismatch), because
  re-running edited history is how data gets damaged. If the change is known to be harmless (a
  comment), set `MIGRATIONS_ALLOW_CHANGED=true` for one deploy; the old version is not re-run.
- After migrating, `migrate` re-applies `AUTHENTICATOR_PASSWORD` and tells PostgREST to reload its
  schema cache, so new columns are visible without restarting anything.
- Fresh installs and upgrades take the **same path**: there is no separate "initial schema". A new
  database starts at `0001_baseline` (the original self-host schema) and moves forward like any other.

**Checking status:**

```bash
make migrate-status
# or: docker compose exec migrate mcpe-migrate status
# Coolify: Terminal → migrate container → mcpe-migrate status
```

```
[migrate] database is tracked: 16 migration(s) applied, latest 0016_row_level_security
VERSION NAME                                          STATE    APPLIED_AT
0001   baseline                                      applied  2026-10-03 16:49:03 UTC
0002   credentials_as_text                           applied  2026-10-03 16:49:03 UTC
...
```

`STATE` is `applied`, `pending` (will run on the next start), or `CHANGED` (file edited after
applying). Re-run pending migrations by hand with `make migrate`.

## Backups and housekeeping

```bash
make backup   # → backups/mcpemails-YYYYMMDD-HHMMSS.dump  (pg_dump custom format)
# Coolify / no make:
docker compose exec -T db pg_dump -U postgres -d postgres -Fc > mcpemails.dump
```

Restore (into this or a new stack with the **same `ENCRYPTION_KEY`**). This replaces all current data:

```bash
make restore FILE=backups/mcpemails-YYYYMMDD-HHMMSS.dump
# or: docker compose exec -T -e CONFIRM_RESTORE=replace-all-data migrate mcpe-migrate restore < file.dump
```

Use this rather than a bare `pg_restore --clean`. Restore resets the schema and the migration history
together, so the history always describes the tables that were actually restored. It then migrates
the result forward.

- **Back up `ENCRYPTION_KEY` too**, separately. Without it the dump's credentials are useless; with
  it, the dump *is* your mail credentials, so protect it accordingly.
- Coolify can also schedule volume or database backups. The volume to protect is `pgdata`.
- `activity_log` and `action_usage` grow by one row per tool call and are not pruned
  automatically (the hosted product partitions and expires them). To keep 90 days:
  `make psql` → `DELETE FROM activity_log WHERE created_at < now() - interval '90 days'; DELETE FROM action_usage WHERE occurred_at < now() - interval '90 days';`

## Security notes

- **Credentials at rest** are AES-256-GCM ciphertext under `ENCRYPTION_KEY`, as are scheduled-send
  payloads and pending approvals.
- **API keys** are stored only as SHA-256 hashes (`mcpe_` + 64 hex).
- **Network exposure:** the database, PostgREST and gateway publish no ports. Expose only
  `mcp-server`, and only through TLS (Coolify's proxy, the Caddy overlay, or your own).
- Row-level security is enabled on every table; only the server's service role (which bypasses it)
  has table grants.
- **No outbound calls to us.** The server talks only to your mail providers and your own database.
- **Single-tenant.** One workspace and one operator are seeded. Multi-user workspaces, roles, SSO and
  the dashboard are hosted-only.

## How it maps to the hosted product

The `mcp-server` container runs `supabase/functions/mcp-server/` **unmodified**, the same code as
production.

| | Hosted (mcpemails.com) | Self-host |
| --- | --- | --- |
| Backend | Supabase (Postgres + PostgREST + Auth + Vault + cron) | Postgres + PostgREST only |
| Schema | `supabase/migrations` | `self-host/db/migrations`, ported from the former, checked for parity in CI |
| Connect a mailbox / mint a key | Web dashboard | `mcpe` CLI / `make` |
| Scheduled sends, automations | `pg_cron` + `pg_net` + Vault | the `dispatcher` service |
| Usage plans and caps | ✅ | none (unmetered) |
| Gmail / Outlook OAuth | ✅ | ✗ (IMAP/SMTP; Gmail via app password) |

## Troubleshooting

- **Deploy stops at `migrate` / "dependency failed to start".** Read the `migrate` log. It names
  the failing file and the Postgres error, e.g.
  `[migrate] ERROR: 0007_….sql failed; nothing from it was applied`. Nothing was half-applied, and
  the previously running server is untouched. Fix the cause and redeploy.
- **`… changed after it was applied (recorded checksum …)`.** A migration file was edited after it
  ran. Don't edit applied migrations; if it's a comment-only change, deploy once with
  `MIGRATIONS_ALLOW_CHANGED=true`.
- **`cannot log in … (check POSTGRES_PASSWORD)`.** The password in your env no longer matches the one
  stored in the volume when it was first created. Restore the original value. Changing it requires
  `ALTER ROLE postgres PASSWORD …` inside the database first.
- **`inbox_not_found` for an inbox that `mcpe list-inboxes` shows.** Run `make migrate-status`.
  Anything pending means the schema is behind the server; redeploy so `migrate` runs. Also check the
  key's inbox restriction (`make keys`).
- **`Invalid or revoked API key` for every key, after upgrading from an old install.** Same cause
  (missing `api_keys` column); fixed by letting `migrate` run.
- **`Failed to decode base64` on IMAP tools.** The database still has the old `bytea` credential
  columns. Letting `migrate` run converts them (migration `0002`).
- **`idempotency_unavailable`.** The `outbound_idempotency` table is missing (migration `0010`), or
  `ENCRYPTION_KEY` is unset. The server refuses rather than sending without the protection you asked for.
- **Sending hangs / times out.** TLS mode vs port mismatch, or the port is blocked; see
  [TLS: 465 vs 587](#tls-implicit-tls-465-vs-starttls-587).
- **`postgrest` restarts / gateway never healthy.** Check `AUTHENTICATOR_PASSWORD` and `JWT_SECRET`
  are set. `migrate` re-applies the authenticator password on each start, so a changed value only
  needs a redeploy.
- **Scheduled sends never go out.** The `dispatcher` service must be running and `DISPATCH_SECRET`
  must be the same for it and `mcp-server`. Its log prints any non-2xx response.
- **A Postgres log line `relation "public.oauth_refresh_tokens" does not exist`** once, around the
  first tool call: harmless. The server checks whether a key came from the hosted OAuth flow while
  recording first use; that table is hosted-only.
- **`make setup` says `.env` already exists.** It refuses to overwrite it, because regenerating
  `ENCRYPTION_KEY` would orphan stored credentials.

Never fix a schema problem by deleting the `pgdata` volume. `make destroy` deletes every inbox, key
and credential; it is not an upgrade or repair step.

## For contributors: changing the schema

The hosted migrations in `supabase/migrations/` cannot run here: they depend on Supabase Auth
(`auth.users`, `auth.uid()`), `extensions.moddatetime`, `pg_cron`, `pg_net` and Vault, and some
schedule jobs against the hosted project's URL. So self-host keeps its own migrations, ported by
hand, with three checks that make forgetting impossible to miss:

1. **Every upstream migration is classified** in [`db/upstream-migrations.tsv`](db/upstream-migrations.tsv)
   as `ported`, `partial` or `skipped` (with a reason). `tests/manifest.test.ts` fails on any that
   isn't, and on any table or RPC the server calls that no self-host migration creates (unless
   listed as intentionally absent, with why).
2. **Schema parity**: `tests/schema-parity.sh` compares column types/defaults/nullability, checks
   and unique keys of every table the server uses against the hosted schema built from
   `supabase/migrations`. Intended differences live in
   [`db/parity-exceptions.tsv`](db/parity-exceptions.tsv); stale exceptions fail too.
3. **Upgrade safety**: `tests/migrations.sh` builds a fresh database, upgrades a legacy one with
   data (including hand-patched variants), re-applies every migration over its own result, and checks
   failure rollback, checksum refusal and concurrent runners.

When an upstream migration touches anything the server reads or writes:

- add `db/migrations/NNNN_short_name.sql` (next number). Write it **idempotently**
  (`ADD COLUMN IF NOT EXISTS`, `DROP CONSTRAINT IF EXISTS` + `ADD`, `CREATE TABLE IF NOT EXISTS`),
  with no `BEGIN`/`COMMIT` (the runner owns the transaction) and no `CONCURRENTLY`. Use
  `public.set_updated_at()` for `updated_at` triggers. Enable RLS on new tables. Use the hosted
  constraint names;
- list the upstream file as `ported`/`partial` in `db/upstream-migrations.tsv`;
- never edit a migration that has shipped; add another one.

```bash
make test                                   # static checks + migration integration tests
supabase db start && sh tests/schema-parity.sh
```

CI runs all three (`Self-host (migrations + stack)` job), and production deploys wait for it.
