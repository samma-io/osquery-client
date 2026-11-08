#!/usr/bin/env bash
# Creates the CA that signs the gateway's server certificate and every client
# certificate. Run once, on the operator's machine. ca.key never leaves it:
# whoever holds it can admit any host to the SIEM.
#
#   pki/make-ca.sh            -> pki/out/ca.crt, pki/out/ca.key
set -euo pipefail
cd "$(dirname "$0")"
umask 077
mkdir -p out
if [[ -e out/ca.key ]]; then
  echo "pki/out/ca.key already exists; refusing to overwrite the CA" >&2
  exit 1
fi
openssl ecparam -name prime256v1 -genkey -noout -out out/ca.key
openssl req -x509 -new -key out/ca.key -sha256 -days 3650 \
  -subj "/O=samma-io/CN=samma osquery CA" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -out out/ca.crt
chmod 644 out/ca.crt
echo "CA written to pki/out/ca.crt (key: pki/out/ca.key, keep it private)"
