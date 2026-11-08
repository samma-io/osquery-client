#!/bin/bash
# Renders the osquery flags from the environment and runs osqueryd in the
# foreground. Results go to the Samma osquery gateway over mutual TLS.
set -euo pipefail

: "${OSQUERY_GATEWAY:?set OSQUERY_GATEWAY to the gateway as host:port, e.g. osquery-gateway:30516}"
export OSQUERY_GATEWAY
export OSQUERY_HOST_IDENTIFIER="${OSQUERY_HOST_IDENTIFIER:-$(hostname)}"
export OSQUERY_CERT_DIR="${OSQUERY_CERT_DIR:-/etc/osquery/certs}"
export OSQUERY_TLS_PERIOD="${OSQUERY_TLS_PERIOD:-10}"

for f in ca.crt client.crt client.key; do
  if [[ ! -r "$OSQUERY_CERT_DIR/$f" ]]; then
    echo "missing $OSQUERY_CERT_DIR/$f: mount the CA certificate and this host's client certificate and key" >&2
    exit 1
  fi
done

envsubst < /etc/osquery/osquery.flags.tpl > /etc/osquery/osquery.flags
echo "osquery-client: host ${OSQUERY_HOST_IDENTIFIER} -> https://${OSQUERY_GATEWAY}/log"

# osqueryd's own arguments win over the flagfile, so extra flags can be passed
# as container arguments.
exec /opt/osquery/bin/osqueryd --flagfile=/etc/osquery/osquery.flags "$@"
