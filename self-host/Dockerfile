# MCP Emails, self-host server image.
#
# Runs the exact same Deno MCP server that powers mcpemails.com
# (supabase/functions/mcp-server), plus the provisioning CLI (`mcpe`). No build
# step or bundler: the server is plain Deno and talks to PostgREST over HTTP.
#
# Build context is the repo root (see docker-compose.yml) so we can copy both
# the server source and the self-host CLI.
FROM denoland/deno:2.1.4

WORKDIR /app

# Server source (unmodified) + provisioning CLI.
COPY supabase/functions/mcp-server/ ./mcp-server/
COPY self-host/cli/ ./cli/

# `mcpe <command>` anywhere in the container, e.g. from Coolify's terminal.
# The container already has SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY and
# ENCRYPTION_KEY, which is everything the CLI needs.
RUN printf '#!/bin/sh\nexec deno run --allow-net --allow-env /app/cli/mcpe.ts "$@"\n' > /usr/local/bin/mcpe \
 && chmod 0755 /usr/local/bin/mcpe

# Drop root before caching, so the runtime user owns the cache it reads.
USER deno

# Pre-fetch remote dependencies (supabase-js etc.) at build time so startup
# does not depend on esm.sh being reachable. A failure here fails the build
# rather than surfacing later as a server that cannot start. The CLI's lazy
# import of supabase-js uses the same URL as the server, so it is covered too.
RUN deno cache mcp-server/index.ts cli/mcpe.ts

EXPOSE 8000

# Deno.serve(handleRequest) binds 0.0.0.0:8000 by default.
CMD ["deno", "run", "--allow-net", "--allow-env", "mcp-server/index.ts"]
