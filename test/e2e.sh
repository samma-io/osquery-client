#!/usr/bin/env bash
# End-to-end test of client -> gateway -> NATS, with a throwaway CA.
#
#   test/e2e.sh          builds the client, starts the stack, waits for
#                        results on samma.logs.osquery, checks that clients
#                        without a valid certificate are refused, tears down.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
compose=(docker compose -f "$here/docker-compose.yml")
cleanup() { E2E_PKI=$work/pki "${compose[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT

# Throwaway CA, server and client certificates, plus a second CA whose client
# certificate the gateway must refuse.
cp -r "$here/../pki" "$work/pki-src"
"$work/pki-src/make-ca.sh" >/dev/null 2>&1
"$work/pki-src/issue-server.sh" >/dev/null 2>&1
"$work/pki-src/issue-client.sh" e2e-client >/dev/null 2>&1
mkdir -p "$work/pki/server" "$work/pki/client"
cp "$work/pki-src/out/server.crt" "$work/pki-src/out/server.key" "$work/pki-src/out/ca.crt" "$work/pki/server/"
cp "$work/pki-src/out/clients/e2e-client/"* "$work/pki/client/"
cp -r "$here/../pki" "$work/rogue-src"
"$work/rogue-src/make-ca.sh" >/dev/null 2>&1
"$work/rogue-src/issue-client.sh" rogue >/dev/null 2>&1
# The containers run as different users; the throwaway keys may be world-readable.
chmod a+rx "$work" "$work/rogue-src"
chmod -R a+rX "$work/pki" "$work/rogue-src/out"
chmod a+r "$work"/pki/*/*.key "$work/rogue-src/out/clients/rogue/client.key"
export E2E_PKI=$work/pki

"${compose[@]}" up -d --build --quiet-pull >/dev/null 2>&1 || "${compose[@]}" up -d --build
echo "stack up; waiting for results on samma.logs.osquery"

count() {
  "${compose[@]}" run --rm --no-deps nats-init sh -c \
    'nats -s nats://nats:4222 stream info E2E_LOGS --json' 2>/dev/null \
    | sed -n 's/.*"messages": *\([0-9]*\).*/\1/p' | head -1
}
n=0
for _ in $(seq 1 60); do
  n=$(count || echo 0); n=${n:-0}
  [[ $n -ge 3 ]] && break
  sleep 2
done
if [[ $n -lt 3 ]]; then
  echo "FAIL: only ${n} messages on samma.logs.osquery" >&2
  "${compose[@]}" logs --tail=40 gateway client >&2
  exit 1
fi
echo "ok: ${n} messages on samma.logs.osquery"

echo "one message:"
"${compose[@]}" run --rm --no-deps nats-init sh -c \
  'nats -s nats://nats:4222 stream get E2E_LOGS 1 --json' 2>/dev/null \
  | python3 -c 'import json,sys,base64; print(json.dumps(json.loads(base64.b64decode(json.load(sys.stdin)["data"])), indent=1))'

# The gateway must refuse: no client certificate, a certificate from another CA,
# and plain HTTP.
net=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$("${compose[@]}" ps -q gateway)")
docker pull -q curlimages/curl:8.11.1 >/dev/null
probe() { docker run --rm --network "$net" -v "$work":/w:ro curlimages/curl:8.11.1 -sS -o /dev/null -w '%{http_code}' --max-time 5 "$@" 2>&1 || true; }
body='{"log_type":"result","data":[{"name":"probe"}]}'
ok=$(probe --cacert /w/pki/client/ca.crt --cert /w/pki/client/client.crt --key /w/pki/client/client.key \
  -H 'content-type: application/json' -d "$body" https://osquery-gateway:8443/log)
nocert=$(probe --cacert /w/pki/client/ca.crt -H 'content-type: application/json' -d "$body" https://osquery-gateway:8443/log)
rogue=$(probe --cacert /w/pki/client/ca.crt --cert /w/rogue-src/out/clients/rogue/client.crt \
  --key /w/rogue-src/out/clients/rogue/client.key -H 'content-type: application/json' -d "$body" https://osquery-gateway:8443/log)
plain=$(probe -H 'content-type: application/json' -d "$body" http://osquery-gateway:8443/log)
echo "valid cert: $ok | no cert: ${nocert:0:60} | other CA: ${rogue:0:60} | plain http: ${plain:0:60}"
[[ $ok == 200 ]] || { echo "FAIL: valid client refused" >&2; exit 1; }
for r in "$nocert" "$rogue" "$plain"; do
  [[ $r == 200 ]] && { echo "FAIL: gateway accepted a client it must refuse" >&2; exit 1; }
done
echo "PASS"
