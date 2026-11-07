#!/usr/bin/env bash
# coder-trust-ca.sh — Make the `coder` server container's own Terraform
# runs (terraform init, during workspace provisioning) trust a corporate
# TLS-intercepting proxy's CA when reaching registry.terraform.io.
#
# Why this is needed: the `ghcr.io/coder/coder` image is pulled prebuilt
# (no repo-owned Dockerfile to bake a CACERT secret into, unlike
# coder-workspace-build/temporal-worker-build/lab-sim-build), and its
# non-root runtime user (uid 1000) cannot write into the root-owned
# /etc/ssl/certs. Terraform (a Go binary) trusts every file found under
# $SSL_CERT_DIR (or, if unset, its compiled-in default directories,
# which already include /etc/ssl/certs) — so this script copies the
# image's current trust bundle plus the given corporate CA into a
# writable directory inside the coder_home volume (survives container
# recreation), and prints the .env line needed to point SSL_CERT_DIR at
# it.
#
# Re-run after each Coder image update to refresh public roots:
#   scripts/coder-trust-ca.sh /path/to/corporate-ca-bundle.pem
#
# Verified mechanism (2026-08-29): reproduced the exact "x509: certificate
# signed by unknown authority" failure by overriding SSL_CERT_DIR to an
# empty directory, then confirmed terraform init succeeds again once the
# system bundle + a CA are both present in a directory SSL_CERT_DIR points
# to — no image rebuild, no root access inside the container required.

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 /path/to/corporate-ca-bundle.pem" >&2
  exit 1
fi

cacert="$1"
target_dir="/home/coder/.local-ca-certs"

if [ ! -s "$cacert" ]; then
  echo "ERROR: corporate CA bundle is missing or empty." >&2
  exit 1
fi

# Parse every certificate in the PEM bundle before touching persistent trust.
if ! command -v openssl >/dev/null 2>&1 || ! openssl crl2pkcs7 -nocrl -certfile "$cacert" -outform DER -out /dev/null 2>/dev/null; then
  echo "ERROR: corporate CA bundle must contain valid PEM certificate(s)." >&2
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx coder; then
  echo "ERROR: 'coder' container is not running. Run 'make up' first." >&2
  exit 1
fi

echo "Refreshing the Coder system CA bundle in ${target_dir}..."
docker exec coder mkdir -p "$target_dir"
docker exec coder sh -ec '
  test -s /etc/ssl/certs/ca-certificates.crt
  cp /etc/ssl/certs/ca-certificates.crt "$1/ca-certificates.crt.new"
  mv "$1/ca-certificates.crt.new" "$1/ca-certificates.crt"
' sh "$target_dir"

echo "Copying corporate CA bundle (${cacert}) into ${target_dir}/corporate-ca.pem..."
docker cp --follow-link "$cacert" "coder:${target_dir}/corporate-ca.pem.new"
docker exec coder mv "${target_dir}/corporate-ca.pem.new" "${target_dir}/corporate-ca.pem"

echo ""
echo "Done. To apply it, add this to .env:"
echo ""
echo "  CODER_SSL_CERT_DIR=${target_dir}"
echo ""
echo "Then recreate the coder container so it picks up the new env var:"
echo ""
echo "  docker compose up -d coder"
echo ""
echo "Retry workspace creation afterward."
echo "Re-run this script after each Coder image update to refresh public roots."
