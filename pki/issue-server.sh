#!/usr/bin/env bash
# Issues the gateway's server certificate. Every name a client uses in
# OSQUERY_GATEWAY must be a subjectAltName. The default DNS name is
# osquery-gateway; give a client that name with --add-host when it reaches the
# gateway by IP.
#
#   pki/issue-server.sh [SAN ...]     e.g. DNS:osquery-gateway IP:192.0.2.10
#   -> pki/out/server.crt, pki/out/server.key (valid 1 year)
set -euo pipefail
cd "$(dirname "$0")"
umask 077
[[ -r out/ca.key ]] || { echo "no pki/out/ca.key: run pki/make-ca.sh first" >&2; exit 1; }
sans=("DNS:osquery-gateway" "$@")
san=$(IFS=,; echo "${sans[*]}")
openssl ecparam -name prime256v1 -genkey -noout -out out/server.key
openssl req -new -key out/server.key -subj "/O=samma-io/CN=osquery-gateway" -out out/server.csr
openssl x509 -req -in out/server.csr -CA out/ca.crt -CAkey out/ca.key -CAcreateserial \
  -days 365 -sha256 -out out/server.crt \
  -extfile <(printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=%s\n' "$san")
rm -f out/server.csr
chmod 644 out/server.crt
echo "server certificate for ${san} written to pki/out/server.crt"
