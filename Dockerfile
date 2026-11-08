FROM debian:trixie-slim

# osquery from the official apt repo. The build fails unless the repo key is
# osquery's published signing key.
ARG OSQUERY_VERSION=5.24.1-1.linux
ARG OSQUERY_KEY_FPR=1484120AC4E9F8A1A577AEEE97A80C63C9D8B80B

LABEL org.opencontainers.image.source="https://github.com/samma-io/osquery-client"
LABEL org.opencontainers.image.description="osquery client that ships query results to the Samma SIEM over mutual TLS"
LABEL version="${OSQUERY_VERSION}"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN apt-get update \
 && apt-get upgrade -y --no-install-recommends \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg gettext-base \
 && curl -fsSL https://pkg.osquery.io/deb/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/osquery.gpg \
 && gpg --show-keys --with-colons /usr/share/keyrings/osquery.gpg | grep -q "^fpr:::::::::${OSQUERY_KEY_FPR}:" \
 && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/osquery.gpg] https://pkg.osquery.io/deb deb main" > /etc/apt/sources.list.d/osquery.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends "osquery=${OSQUERY_VERSION}" \
 && apt-get purge -y curl gnupg && apt-get autoremove -y \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY config/osquery.conf /etc/osquery/osquery.conf
COPY config/osquery.flags.tpl /etc/osquery/osquery.flags.tpl
COPY entrypoint.sh /entrypoint.sh
RUN chmod 0755 /entrypoint.sh && mkdir -p /var/osquery /etc/osquery/certs

# Root is required: the host view (--pid=host) reads other users' /proc entries.
ENTRYPOINT ["/entrypoint.sh"]
