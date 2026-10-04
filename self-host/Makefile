# ============================================================
# MCP Emails, self-host
# ============================================================
# Quick start:
#   make setup        # generate .env (secrets), run once
#   make up           # build + start the stack (migrations run automatically)
#   make provision EMAIL=you@example.com IMAP_HOST=imap.example.com SMTP_HOST=smtp.example.com
#   make key          # mint an MCP API key
#
# Then point your MCP client at  http://localhost:8787  with
#   Authorization: Bearer <the key you minted>
#
# Upgrading: git pull && make up   (see README.md, "Upgrading")
# ============================================================

COMPOSE ?= docker compose
DENO_IMG ?= denoland/deno:2.1.4

.PHONY: help setup up down logs ps restart build provision set-security key keys inboxes revoke dispatch psql \
        migrate migrate-status backup restore test destroy

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

setup: ## Generate .env with fresh secrets (refuses to overwrite an existing one)
	@if [ -f .env ]; then echo ".env already exists, delete it first to regenerate (this rotates ENCRYPTION_KEY and breaks stored creds)."; exit 1; fi
	@tmp_file=$$(mktemp .env.XXXXXX); \
	trap 'rm -f "$$tmp_file"' EXIT; \
	docker run --rm -v "$(PWD)/cli:/cli:ro" $(DENO_IMG) run --allow-net --allow-env /cli/mcpe.ts gen-secrets > "$$tmp_file"; \
	test -s "$$tmp_file"; \
	mv "$$tmp_file" .env
	@echo "✓ wrote .env  (review it; keep it private; back up ENCRYPTION_KEY)"

build: ## Build the images
	$(COMPOSE) build

up: ## Build and start (or upgrade) the stack; pending migrations are applied first
	@if [ ! -f .env ]; then echo "no .env, run 'make setup' first"; exit 1; fi
	$(COMPOSE) up -d --build
	@echo "✓ MCP server on http://localhost:$${MCP_PORT:-8787}"

down: ## Stop the stack (keeps data)
	$(COMPOSE) --profile tools down

restart: ## Restart services
	$(COMPOSE) restart

ps: ## Show service status
	$(COMPOSE) ps

logs: ## Tail logs (S=mcp-server to scope to one service)
	$(COMPOSE) logs -f $(S)

# ── database ─────────────────────────────────────────────────────────────────

migrate-status: ## Show which schema migrations are applied / pending
	$(COMPOSE) exec migrate mcpe-migrate status

migrate: ## Apply pending migrations now (normally automatic on `make up`)
	$(COMPOSE) run --rm migrate apply

backup: ## Write a compressed pg_dump to backups/ (keep .env's ENCRYPTION_KEY with it)
	@mkdir -p backups
	@f=backups/mcpemails-$$(date +%Y%m%d-%H%M%S).dump; \
	$(COMPOSE) exec -T db pg_dump -U postgres -d postgres -Fc > "$$f" && echo "✓ $$f"

restore: ## REPLACE all data with a pg_dump file, then migrate it. Var: FILE
	@if [ -z "$(FILE)" ] || [ ! -s "$(FILE)" ]; then echo "usage: make restore FILE=backups/mcpemails-....dump"; exit 1; fi
	@echo "This replaces every inbox, key and log in this stack with $(FILE). Ctrl-C within 10s to abort."; sleep 10
	$(COMPOSE) exec -T -e CONFIRM_RESTORE=replace-all-data migrate mcpe-migrate restore < "$(FILE)"

psql: ## Open a psql shell on the database
	$(COMPOSE) exec db psql -U postgres -d postgres

# ── provisioning (runs the CLI in a one-off container on the stack network) ──

provision: ## Connect an IMAP/SMTP inbox. Vars: EMAIL, IMAP_HOST, SMTP_HOST [IMAP_PORT, SMTP_PORT, IMAP_SECURITY, SMTP_SECURITY, USERNAME, SERVICE, DISPLAY_NAME]
	@if [ -z "$(EMAIL)" ] || [ -z "$(IMAP_HOST)" ] || [ -z "$(SMTP_HOST)" ]; then \
	  echo "usage: make provision EMAIL=you@example.com IMAP_HOST=imap.example.com SMTP_HOST=smtp.example.com [IMAP_PORT=993 SMTP_PORT=587 SMTP_SECURITY=starttls USERNAME=.. SERVICE=generic]"; \
	  echo "password: set IMAP_PASSWORD env (export IMAP_PASSWORD=... ; make provision ...)"; exit 1; \
	fi
	$(COMPOSE) run --rm -e IMAP_PASSWORD cli provision-inbox \
	  --email "$(EMAIL)" --imap-host "$(IMAP_HOST)" --smtp-host "$(SMTP_HOST)" \
	  --imap-port "$${IMAP_PORT:-993}" --smtp-port "$${SMTP_PORT:-465}" \
	  $(if $(IMAP_SECURITY),--imap-security "$(IMAP_SECURITY)",) \
	  $(if $(SMTP_SECURITY),--smtp-security "$(SMTP_SECURITY)",) \
	  $(if $(USERNAME),--username "$(USERNAME)",) \
	  $(if $(SERVICE),--service "$(SERVICE)",) \
	  $(if $(DISPLAY_NAME),--display-name "$(DISPLAY_NAME)",)

set-security: ## Change an inbox's TLS mode. Vars: INBOX (email/id), IMAP_SECURITY and/or SMTP_SECURITY (tls|starttls)
	@if [ -z "$(INBOX)" ]; then echo "usage: make set-security INBOX=you@example.com SMTP_SECURITY=starttls"; exit 1; fi
	$(COMPOSE) run --rm cli set-security --inbox "$(INBOX)" \
	  $(if $(IMAP_SECURITY),--imap-security "$(IMAP_SECURITY)",) \
	  $(if $(SMTP_SECURITY),--smtp-security "$(SMTP_SECURITY)",)

key: ## Mint an MCP API key. Vars: NAME, SCOPES (comma), INBOX (email/id, space-separated for several), EXPIRES_DAYS
	$(COMPOSE) run --rm cli create-key \
	  $(if $(NAME),--name "$(NAME)",) \
	  $(if $(SCOPES),--scopes "$(SCOPES)",) \
	  $(foreach i,$(INBOX),--inbox "$(i)") \
	  $(if $(EXPIRES_DAYS),--expires-days "$(EXPIRES_DAYS)",)

keys: ## List active API keys
	$(COMPOSE) run --rm cli list-keys

inboxes: ## List connected inboxes
	$(COMPOSE) run --rm cli list-inboxes

revoke: ## Revoke an API key. Var: PREFIX
	@if [ -z "$(PREFIX)" ]; then echo "usage: make revoke PREFIX=mcpe_ab1"; exit 1; fi
	$(COMPOSE) run --rm cli revoke-key "$(PREFIX)"

dispatch: ## Manually flush due scheduled sends once (the dispatcher also does this every minute)
	@DISPATCH_SECRET=$$(grep '^DISPATCH_SECRET=' .env | cut -d= -f2); \
	$(COMPOSE) run --rm --no-deps --entrypoint sh dispatcher -c \
	  "curl -fsS -X POST -H 'X-Dispatch-Secret: $$DISPATCH_SECRET' http://mcp-server:8000/dispatch"

# ── development ──────────────────────────────────────────────────────────────

test: ## Run the self-host test suites (needs Docker)
	docker run --rm -v "$(CURDIR)/..:/repo" -w /repo denoland/deno:latest deno test --node-modules-dir=none --allow-read self-host/tests/
	sh tests/migrations.sh

destroy: ## Stop the stack and DELETE all data (volumes). Not an upgrade step.
	@echo "This deletes every inbox, key and log in this stack. Ctrl-C within 10s to abort."; sleep 10
	$(COMPOSE) --profile tools down -v
