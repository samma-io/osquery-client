#!/usr/bin/env bash
# Issues one host's client certificate. The gateway admits any certificate this
# CA signed, so issue one per host and keep the list: a host is cut off by
# letting its certificate expire (1 year) or by replacing the CA.
#
#   pki/issue-client.sh <host-name>
#   -> pki/out/clients/<host-name>/{ca.crt,client.crt,client.key}
#      ready to mount at /etc/osquery/certs
set -euo pipefail
cd "$(dirname "$0")"
umask 077
name=${1:?usage: pki/issue-client.sh <host-name>}
[[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "bad host name: $name" >&2; exit 2; }
[[ -r out/ca.key ]] || { echo "no pki/out/ca.key: run pki/make-ca.sh first" >&2; exit 1; }
dir="out/clients/$name"
mkdir -p "$dir"
openssl ecparam -name prime256v1 -genkey -noout -out "$dir/client.key"
openssl req -new -key "$dir/client.key" -subj "/O=samma-io/OU=osquery-client/CN=$name" -out "$dir/client.csr"
openssl x509 -req -in "$dir/client.csr" -CA out/ca.crt -CAkey out/ca.key -CAcreateserial \
  -days 365 -sha256 -out "$dir/client.crt" \
  -extfile <(printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n')
rm -f "$dir/client.csr"
cp out/ca.crt "$dir/ca.crt"
# osqueryd runs as root in the container and reads the key; 0600 is enough.
chmod 600 "$dir/client.key"
chmod 644 "$dir/client.crt" "$dir/ca.crt"
echo "client certificate for $name written to pki/$dir"
