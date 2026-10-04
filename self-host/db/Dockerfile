# MCP Emails self-host, schema migration image.
#
# Runs self-host/db/migrate.sh against the `db` service. It is the same
# postgres:16-alpine image the database runs, so psql always matches the
# server, and nothing beyond busybox + psql is needed.
#
# The database itself runs the stock image with NO init scripts: the schema is
# created and upgraded only by this runner, so a fresh volume and a years-old
# volume go through exactly the same, recorded, steps.
FROM postgres:16-alpine

COPY migrate.sh /usr/local/bin/mcpe-migrate
COPY migrations/ /migrations/
RUN chmod 0755 /usr/local/bin/mcpe-migrate \
 && chmod -R a+rX /migrations

# Never run as root; the runner only needs to talk to the network.
USER postgres

ENTRYPOINT ["/usr/local/bin/mcpe-migrate"]
CMD ["apply"]
