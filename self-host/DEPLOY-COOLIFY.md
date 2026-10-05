# Deploying MCP Emails self-host on Coolify

A step-by-step guide to deploying `self-host/docker-compose.yml` from your Git repository (or fork)
on Coolify. It covers a first deploy, moving data across from an existing deployment, adding
mailboxes and keys, and upgrading. Background and reference material is in [README.md](README.md).

Placeholders used below: `mcpemails.example.com` is your MCP domain, `you@yourcompany.example` is a
mailbox, and `<…-container>` is a container name you look up with `docker ps`.

---

## 1. Get the code onto the branch Coolify deploys

Merge the changes into the branch Coolify will deploy (usually `main`), or point Coolify at the
feature branch if you want to try it before merging.

## 2. If you already run MCP Emails: back up first

Skip this step on a brand-new install.

A new Coolify application gets a **new, empty volume**. If you are replacing an existing deployment
(for example one created from a pasted compose file), copy its data across once. Steps 8 and 9 show how.

SSH into the server and find the **current** database container:

```sh
docker ps --format '{{.Names}}' | grep -i db
```

Dump it:

```sh
docker exec <old-db-container> pg_dump -U postgres -d postgres -Fc > ~/mcpemails-old.dump
ls -lh ~/mcpemails-old.dump    # must not be 0 bytes
```

Copy the existing deployment's **`ENCRYPTION_KEY`** into a password manager. You must reuse it
exactly. Every stored mailbox password is encrypted with it, and a different key makes them
permanently unreadable.

## 3. Generate secrets

On the server, or any machine with Docker:

```sh
git clone https://github.com/<you>/MCPEmails.git /tmp/mcpe && cd /tmp/mcpe/self-host
docker run --rm -v "$PWD/cli:/cli:ro" denoland/deno:2.1.4 run --allow-net --allow-env /cli/mcpe.ts gen-secrets
```

Keep the output private. **If you are replacing an existing deployment, replace the generated
`ENCRYPTION_KEY` with your old one.**

## 4. Create the Coolify application

1. **+ New → Application → Public Repository**, or **Private Repository (GitHub App)** for a private
   repo. Enter the repository URL and the branch from step 1.
2. **Build Pack: Docker Compose**
   - **Base Directory:** `/self-host`
   - **Docker Compose Location:** `/docker-compose.yml`
3. **Continue.** Coolify reads the compose file and lists the services: `db`, `migrate`,
   `postgrest`, `gateway`, `mcp-server`, `dispatcher`.

The base directory matters: Coolify runs Compose from it, so the repo-relative build contexts in the
file resolve inside Coolify's checkout. Nothing has to exist on the server beforehand, and nothing is
pasted into Coolify.

## 5. Environment variables

**Environment Variables → Developer view.** Paste the values from step 3:

```
POSTGRES_PASSWORD=<from gen-secrets>
AUTHENTICATOR_PASSWORD=<from gen-secrets>
JWT_SECRET=<from gen-secrets>
SERVICE_ROLE_JWT=<from gen-secrets>
ENCRYPTION_KEY=<from gen-secrets, or your OLD key if replacing a deployment>
DISPATCH_SECRET=<from gen-secrets>
APP_URL=https://mcpemails.example.com
```

Save. Leave out `MCP_PORT`, which is only used for local Docker. Coolify will not deploy while a
required variable is empty.

## 6. Domain

On the **`mcp-server`** service only, set **Domains** to:

```
https://mcpemails.example.com:8000
```

The `:8000` tells Coolify's proxy which container port to route to; clients still use plain
`https://mcpemails.example.com` on port 443. Leave every other service without a domain: the database,
PostgREST and gateway must stay internal.

If you are replacing an existing deployment, either move the DNS record to this application now, or
use a temporary subdomain until you have checked it (step 10).

## 7. Deploy

Click **Deploy**. The `migrate` service's logs should end with:

```
[migrate] empty database; building the schema from scratch
[migrate] applied 16 new migration(s)
[migrate] schema is up to date; signalling ready
```

`mcp-server` then starts and turns healthy. If the deploy stops at `migrate`, its log names the
failing migration and the database error; see Troubleshooting in [README.md](README.md#troubleshooting).

A brand-new install continues at step 10.

## 8. Find the new migrate container

Only needed if you are replacing a deployment. On the server:

```sh
docker ps --format '{{.Names}}' | grep migrate
```

## 9. Restore your old data into the new stack

```sh
docker exec -i -e CONFIRM_RESTORE=replace-all-data <new-migrate-container> mcpe-migrate restore < ~/mcpemails-old.dump
```

Expect `database predates migration tracking … adopting it` (or `database is tracked …` for a dump
from a stack that already had migrations), then `restored and up to date`.

**Read any `WARNING` lines.** For example, an inbox stored with SMTP port 587 and `tls` would hang
on send; the warning prints the exact command that fixes it (see step 10).

Use this restore command rather than a bare `pg_restore`: it resets the schema and the migration
history together, then migrates the restored data forward.

## 10. Check it

In Coolify, open **Terminal** on the **`mcp-server`** container:

```sh
mcpe list-inboxes     # SMTP on port 587 should say "starttls", 465 should say "tls"
mcpe list-keys
```

If an inbox shows SMTP `587 tls`:

```sh
mcpe set-security --inbox you@yourcompany.example --smtp-security starttls
```

Then, from your MCP client (URL `https://mcpemails.example.com`, header
`Authorization: Bearer mcpe_…`, using your existing key if you restored data):

- `inbox_list` should list your inboxes;
- `email_read` should read mail;
- a send with an `idempotency_key` should work.

If you replaced a deployment, stop the old Coolify application only once all of this works, and
keep its volume for a few days before deleting it.

## 11. Add mailboxes and API keys

In the **`mcp-server`** Terminal. To keep the password out of shell history:

```sh
read -rs IMAP_PASSWORD; export IMAP_PASSWORD
```

Then connect the mailbox:

```sh
mcpe provision-inbox --email you@yourcompany.example \
  --imap-host imap.example.com --imap-port 993 \
  --smtp-host smtp.example.com --smtp-port 587 \
  --service generic --display-name "Ops"
```

For Migadu, see [Migadu mailboxes](#migadu-mailboxes) below.

The TLS mode follows the port: 993 and 465 use implicit TLS, 143, 587 and 25 use STARTTLS. For any
other port, pass `--imap-security` / `--smtp-security` (`tls` or `starttls`). Running the command
again for the same address updates that mailbox in place (for example to change the password).

Mint a key restricted to several mailboxes (`--inbox` repeats; omit it to allow every inbox):

```sh
mcpe create-key --name "company agent" \
  --inbox ops@yourcompany.example --inbox sales@yourcompany.example
```

The key is printed once. Copy it then.

### Migadu mailboxes

| Setting | Value |
| --- | --- |
| IMAP server | `imap.migadu.com`, port **993**, implicit TLS (SSL/TLS) |
| SMTP server | `smtp.migadu.com`, port **587** with STARTTLS, or port **465** with implicit TLS |
| Username | the **full email address** (the default, so no `--username` needed) |
| Password | the **mailbox password** set in Migadu's admin panel |
| `--service` | `generic` |

Use **port 587** unless you know 465 works from your server. Some VPS hosts block or filter outbound
465, and a blocked port does not fail cleanly: sends hang until they time out. Test from the server
with `nc -vz smtp.migadu.com 465` and `nc -vz smtp.migadu.com 587`.

In the **`mcp-server`** Terminal, once per mailbox:

```sh
read -rs IMAP_PASSWORD; export IMAP_PASSWORD

mcpe provision-inbox --email you@yourcompany.example \
  --imap-host imap.migadu.com --imap-port 993 \
  --smtp-host smtp.migadu.com --smtp-port 587 \
  --service generic --display-name "Your Name"
```

Expected result:

```
✓ connected you@yourcompany.example (generic, imap imap.migadu.com:993 tls / smtp smtp.migadu.com:587 starttls)
```

The CLI picks the TLS mode from the ports: 993 uses implicit TLS and 587 uses STARTTLS, so no
`--*-security` flags are needed. If you would rather use 465, pass `--smtp-port 465`; that selects
implicit TLS.

To provision several Migadu mailboxes, run `read -rs …` and `provision-inbox` once for each address,
then mint a key covering all of them with repeated `--inbox` flags (above).

Migadu notes:

- **Sending as an alias or identity:** mail goes out from the address you provisioned. To send from
  another address on the same domain, set it up as an identity on that mailbox in Migadu first;
  Migadu may refuse a sender address the mailbox is not allowed to use.
- **Changing a mailbox password in Migadu:** run the same `provision-inbox` command again with the
  new password. The mailbox is updated in place, and keys that include it keep working.
- **An existing mailbox shows `smtp 587 tls`** in `mcpe list-inboxes` (possible after migrating
  from an older install): fix it with
  `mcpe set-security --inbox you@yourcompany.example --smtp-security starttls`.

## 12. Upgrading later

Push or merge to the deployed branch and click **Redeploy** (or enable automatic deploys).
`migrate` applies any new schema migrations before the new server starts; your volume and data are
kept.

- **Migration status:** Terminal → `migrate` container → `mcpe-migrate status`.
- **If a migration fails:** the deploy stops, the previously running server keeps serving, and the
  `migrate` log names the file and the error. Nothing from the failed migration is applied.

## Never

- delete the `pgdata` volume to "fix" something;
- regenerate or change `ENCRYPTION_KEY`;
- publish ports for `db`, `postgrest` or `gateway`, or expose port 8000 without TLS.

## Optional: CI on your fork

GitHub often disables Actions on forks. To run the repository's checks (including the self-host
migration and schema-parity job) on your pull requests, enable them in your fork's **Actions** tab.
