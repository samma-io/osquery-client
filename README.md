# osquery-client

An osquery client that ships query results to the Samma SIEM on its own lane,
`samma.logs.osquery`, over mutual TLS. It runs as a Docker container with a
view of the host it runs on.

```
host: osquery-client (osqueryd, TLS logger, client certificate)
   │ HTTPS POST /log, mutual TLS
   ▼
cluster: osquery-gateway (Vector) ── one record per result ──▶ NATS samma.logs.osquery
                                                             └▶ siem-storage ─▶ siem_events (lane osquery)
```

- **Client** (`Dockerfile`, `entrypoint.sh`, `config/`): osqueryd 5.24.1 with
  the TLS logger. It buffers results on disk and retries until the gateway
  accepts them.
- **Gateway** (`gateway/`): Vector's `http_server` source with TLS. It only
  accepts clients whose certificate our CA signed. `osquery.vrl` splits each
  batch into one record per result and adds `source`, `feed`, `event_time`,
  `search_text` and `gateway_peer`. Status logs are dropped. The cluster
  deployment lives in `samma-io/deploy` (`siem/60-osquery-gateway.yaml`) and
  copies this config.
- **PKI** (`pki/`): scripts for the CA, the gateway's server certificate and
  one client certificate per host. Nothing they produce is committed
  (`pki/out/` is in `.gitignore`).

## What it collects

| Query | Every | Needs |
|---|---|---|
| `samma_heartbeat`: osquery version, pid, start time, now | 5 min | nothing; one row per run proves the path |
| `samma_listening_ports`: port, protocol, address, owning process | 10 min | `--network=host`, `--pid=host` |
| `samma_processes`: pid, parent, name, path, uid (no command line) | 1 h | `--pid=host` |
| `samma_logged_in_users`: interactive sessions | 10 min | `/var/run/utmp` mounted read-only |
| `samma_kernel_uptime`: kernel version, uptime in days | 1 h | nothing |

All queries are differential: after the first run, only rows that were
`added` or `removed` are sent. Command lines are left out because they can
carry secrets.

What the container does **not** see: the host's packages, users and files,
because osquery reads the container's own `/etc` and `/var/lib/dpkg`. Queries
over those need extra read-only mounts and are left out on purpose.

## Run it on a host

1. **Once, on the operator's machine:** create the CA and the gateway's
   server certificate. The gateway's Secret is made from `pki/out/server.*`
   and `ca.crt` (see `samma-io/deploy` `siem/README.md`).
   ```bash
   pki/make-ca.sh
   pki/issue-server.sh            # SAN DNS:osquery-gateway; add IP:<node-ip> to also allow the IP
   ```
2. **Per host:** issue a client certificate and copy the folder to the host.
   ```bash
   pki/issue-client.sh my-host    # -> pki/out/clients/my-host/{ca.crt,client.crt,client.key}
   ```
3. **On the host:**
   ```bash
   docker run -d --name osquery-client --restart unless-stopped \
     --pid=host --network=host \
     --add-host osquery-gateway:<node-ip> \
     -e OSQUERY_GATEWAY=osquery-gateway:30516 \
     -e OSQUERY_HOST_IDENTIFIER=my-host \
     -v /path/to/my-host:/etc/osquery/certs:ro \
     -v /var/run/utmp:/var/run/utmp:ro \
     -v osquery-client-db:/var/osquery \
     ghcr.io/samma-io/osquery-client:<tag>
   ```
   `--add-host` makes the name in the server certificate resolve to the
   cluster node. The `osquery-client-db` volume keeps osquery's buffer and the
   differential state across restarts.

| Variable | Default | Meaning |
|---|---|---|
| `OSQUERY_GATEWAY` | required | gateway as `host:port`; the host must be in the server certificate |
| `OSQUERY_HOST_IDENTIFIER` | container hostname | `hostIdentifier` on every record |
| `OSQUERY_CERT_DIR` | `/etc/osquery/certs` | holds `ca.crt`, `client.crt`, `client.key` |
| `OSQUERY_TLS_PERIOD` | `10` | seconds between uploads |

Extra container arguments are passed to `osqueryd`, e.g. `--verbose`.

## Revoking a host

There is no revocation list. A client certificate is valid for one year.
To cut a host off sooner, replace the CA, re-issue the gateway certificate,
and re-issue the certificates of the hosts you keep.

## Records

One NATS message per result, the osquery result unchanged plus the gateway's
fields:

```json
{"name": "samma_listening_ports", "action": "added", "hostIdentifier": "my-host",
 "columns": {"pid": "812", "name": "sshd", "port": "22", "protocol": "6", "family": "2", "address": "0.0.0.0"},
 "unixTime": 1794154211, "calendarTime": "Sun Nov  8 16:10:11 2026 UTC",
 "source": "osquery", "feed": "result", "event_time": "2026-11-08T16:10:11.000Z",
 "search_text": "samma_listening_ports added {...}", "gateway_peer": "192.0.2.10"}
```

`hostIdentifier` is chosen by the client. `gateway_peer` is the address the
gateway saw, so it can't be spoofed by the client itself.

## Tests

```bash
docker run --rm -v "$PWD/gateway":/etc/osquery-gateway:ro -e NATS_URL=nats://127.0.0.1:4222 \
  timberio/vector:0.53.0-distroless-libc \
  test /etc/osquery-gateway/vector.yaml /etc/osquery-gateway/tests/osquery_split.yaml
test/e2e.sh    # client -> gateway -> NATS with a throwaway CA, plus the refusal checks
```

CI runs both, plus `osqueryd --config_check`, gitleaks and trivy, and on
`main` publishes `ghcr.io/samma-io/osquery-client:<short sha>`.
