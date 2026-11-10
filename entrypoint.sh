#!/bin/bash
# Renders the osquery flags from the environment and runs osqueryd in the
# foreground. Results go to the Samma osquery gateway over mutual TLS.
set -euo pipefail

: "${OSQUERY_GATEWAY:?set OSQUERY_GATEWAY to the gateway as host:port, e.g. osquery-gateway:30516}"
export OSQUERY_GATEWAY
export OSQUERY_HOST_IDENTIFIER="${OSQUERY_HOST_IDENTIFIER:-$(hostname)}"
export OSQUERY_CERT_DIR="${OSQUERY_CERT_DIR:-/etc/osquery/certs}"
export OSQUERY_TLS_PERIOD="${OSQUERY_TLS_PERIOD:-10}"
# osquery's watchdog restarts the worker above these; events in flight are lost.
# The defaults (200 MB, 10 %) are too low for eBPF events on a busy host.
export OSQUERY_WATCHDOG_MEMORY_MB="${OSQUERY_WATCHDOG_MEMORY_MB:-400}"
export OSQUERY_WATCHDOG_CPU_PERCENT="${OSQUERY_WATCHDOG_CPU_PERCENT:-40}"

# Real-time process, socket and file events (eBPF and inotify). They need the
# extra privileges and mounts in compose.yaml; set OSQUERY_EVENTS=false on a
# host that runs the container without them.
case "${OSQUERY_EVENTS:-true}" in
  true)  export OSQUERY_EVENTS=true  OSQUERY_DISABLE_EVENTS=false ;;
  false) export OSQUERY_EVENTS=false OSQUERY_DISABLE_EVENTS=true ;;
  *) echo "OSQUERY_EVENTS must be true or false" >&2; exit 1 ;;
esac

for f in ca.crt client.crt client.key; do
  if [[ ! -r "$OSQUERY_CERT_DIR/$f" ]]; then
    echo "missing $OSQUERY_CERT_DIR/$f: mount the CA certificate and this host's client certificate and key" >&2
    exit 1
  fi
done

envsubst < /etc/osquery/osquery.flags.tpl > /etc/osquery/osquery.flags
echo "osquery-client: host ${OSQUERY_HOST_IDENTIFIER} -> https://${OSQUERY_GATEWAY}/log (events: ${OSQUERY_EVENTS})"

# osqueryd's own arguments win over the flagfile, so extra flags can be passed
# as container arguments.
exec /opt/osquery/bin/osqueryd --flagfile=/etc/osquery/osquery.flags "$@"
