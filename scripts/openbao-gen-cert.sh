#!/usr/bin/env bash
# M12 Governance Foundation. Generates a self-signed TLS cert/key pair for
# the local OpenBao listener if one doesn't already exist. Never commit the
# generated key material to git (see governance/openbao/certs/.gitignore) —
# this is a local/demo-only self-signed cert, acceptable per OpenBao's
# security model (eavesdropping is in-scope of the threat model; plain HTTP
# on the listener is not an acceptable default).
set -euo pipefail

CERT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/governance/openbao/certs"
mkdir -p "${CERT_DIR}"

if [[ -f "${CERT_DIR}/openbao.crt" && -f "${CERT_DIR}/openbao.key" ]]; then
	echo "OpenBao TLS cert already present at ${CERT_DIR}, skipping generation."
	exit 0
fi

openssl req -x509 -newkey rsa:4096 -nodes \
	-keyout "${CERT_DIR}/openbao.key" \
	-out "${CERT_DIR}/openbao.crt" \
	-days 825 \
	-subj "/CN=openbao" \
	-addext "subjectAltName=DNS:openbao,DNS:localhost,IP:127.0.0.1"

chmod 644 "${CERT_DIR}/openbao.crt"
# 640, not 600: the openbao container process runs as uid=100,gid=1000
# (not the host user's uid) but the bind-mounted certs dir is read via the
# numeric gid, which happens to match the host user's primary group on
# this stack's default setup - group-read is required for the container
# to load the key, owner-write-only still blocks all other local users.
chmod 640 "${CERT_DIR}/openbao.key"

echo "Generated self-signed OpenBao TLS cert at ${CERT_DIR}/openbao.crt"
