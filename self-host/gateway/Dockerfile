# MCP Emails self-host, gateway image.
#
# The nginx config is baked in at build time instead of bind-mounted from the
# host. A file bind mount fails on platforms that do not have the file at the
# expected host path when the container is created (Coolify reports it as
# "not a directory"), and baking it in makes the gateway identical everywhere.
FROM nginx:1.27-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
