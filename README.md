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
  accepts them. The gateway answers only once NATS has stored the batch
  (end-to-end acknowledgements), so nothing is lost between the two.
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
| `samma_process_events`: every program started (pid, parent, uid, path, exit code) | 1 min | events (below) |
| `samma_socket_events`: outbound connects and inbound accepts, not loopback or DNS | 1 min | events |
| `samma_file_events`: changes to account, sudo, SSH and cron files, `.ssh` folders and the binary folders | 1 min | events, `/` at `/host` |
| `samma_listening_ports`: port, protocol, address, owning process | 10 min | `--network=host`, `--pid=host`, `SYS_PTRACE` for the owner |
| `samma_logged_in_users`: interactive sessions | 10 min | `/var/run/utmp` |
| `samma_users`: local accounts | 10 min | `/etc/passwd` |
| `samma_admin_group_members`: members of root, sudo, wheel, adm, docker | 10 min | `/etc/passwd`, `/etc/group` |
| `samma_authorized_keys`: SSH public keys that can log in | 10 min | `/home`, `/root`, `/etc/passwd` |
| `samma_crontab`: system and user crontabs | 10 min | `/etc/crontab`, `/etc/cron.d`, `/var/spool/cron` |
| `samma_sudoers`: sudo rules | 10 min | `/etc/sudoers`, `/etc/sudoers.d` |
| `samma_kernel_modules`: loaded modules | 10 min | nothing |
| `samma_last_logins`: login and logout history | 10 min | `/var/log/wtmp` |
| `samma_processes`: pid, parent, name, path, uid | 1 h | `--pid=host` |
| `samma_kernel_uptime`: kernel version, uptime in days | 1 h | nothing |
| `samma_packages`: deb and rpm packages | 1 h | `/var/lib/dpkg` (or `/var/lib/rpm`) |
| `samma_suid_binaries`: setuid and setgid programs in `/usr` | 1 h | `/` at `/host` |
| `samma_os_version`: distribution and version | 1 h | `/etc/os-release` |

"Needs" means a read-only mount of that host path, all of which are in
[`compose.yaml`](compose.yaml). Without a mount, a query reads the container's
own file instead, which says nothing about the host.

- **Differential.** Scheduled tables send only rows that were `added` or
  `removed` since the last run. The first run on a host sends everything, with
  `counter: 0`; detection rules on these tables skip it, so a new host's
  baseline does not alert.
- **Events.** Process and socket events come from eBPF; file events come from
  inotify on the read-only `/host` mount. They are real-time, collected by
  osquery as they happen and sent once a minute.
- **Left out.** Command lines, because they carry secrets. Compilers, container
  runtimes, firewall tooling and polling commands (`ps`, `pgrep`, `loginctl`,
  `pg_isready`) are left out of process events, and DNS lookups out of socket
  events: on a busy host they are most of the volume and none of the signal.
- **Volume.** On the test host (a developer machine running Kubernetes tools and
  Docker) the events come to about 10 to 20 MiB an hour, almost all of it
  process and socket events.

## Privileges

Events need the container to trace the host's kernel. `compose.yaml` grants
`SYS_ADMIN`, `BPF`, `PERFMON` and `SYS_PTRACE`, unlimited locked memory, no
AppArmor or seccomp confinement, and the host's `/sys/kernel/debug`. It also
mounts the host's `/` read-only. **Treat the container like a root agent on the
host.** That is the price of seeing every process start and every file change.

On a host where that is not acceptable, run without events: drop the
capabilities, the security options, `memlock`, `/sys/kernel/debug` and the `/`
mount, and set `OSQUERY_EVENTS=false`. The scheduled tables still work.

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
3. **On the host:** copy [`compose.yaml`](compose.yaml) and the certificate
   folder (as `./certs`) to one directory, then:
   ```bash
   OSQUERY_CLIENT_TAG=<tag> OSQUERY_GATEWAY_IP=<node-ip> OSQUERY_HOST_IDENTIFIER=my-host \
     docker compose up -d
   ```
   `<tag>` is a published image tag (a short commit sha from `main`). The
   gateway name in the server certificate is mapped to `<node-ip>` with
   `extra_hosts`. The `osquery-client-db` volume keeps osquery's buffer and the
   differential state across restarts.

| Variable | Default | Meaning |
|---|---|---|
| `OSQUERY_GATEWAY` | required | gateway as `host:port`; the host must be in the server certificate |
| `OSQUERY_HOST_IDENTIFIER` | container hostname | `hostIdentifier` on every record |
| `OSQUERY_CERT_DIR` | `/etc/osquery/certs` | holds `ca.crt`, `client.crt`, `client.key` |
| `OSQUERY_TLS_PERIOD` | `10` | seconds between uploads |
| `OSQUERY_EVENTS` | `true` | process, socket and file events; `false` on a host without the event privileges |
| `OSQUERY_WATCHDOG_MEMORY_MB` | `400` | osquery restarts its worker above this; events in flight are lost |
| `OSQUERY_WATCHDOG_CPU_PERCENT` | `40` | the same, for sustained CPU |

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
gateway saw, which the client does not choose. Behind a Kubernetes NodePort
with the default `externalTrafficPolicy: Cluster` it is a node address, not
the host's. The client certificate's name is not passed on, so
`hostIdentifier` should match the name the certificate was issued to.

## Tests

```bash
docker run --rm -v "$PWD/gateway":/etc/osquery-gateway:ro -e NATS_URL=nats://127.0.0.1:4222 \
  timberio/vector:0.53.0-distroless-libc \
  test /etc/osquery-gateway/vector.yaml /etc/osquery-gateway/tests/osquery_split.yaml
test/e2e.sh    # client -> gateway -> NATS with a throwaway CA, plus the refusal checks
```

CI runs both, plus `osqueryd --config_check`, gitleaks and trivy, and on
`main` publishes `ghcr.io/samma-io/osquery-client:<short sha>`.
