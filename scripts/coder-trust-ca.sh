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
# image's own existing trust bundle plus the given corporate CA into a
# writable directory inside the coder_home volume (survives container
# recreation), and prints the .env line needed to point SSL_CERT_DIR at
# it.
#
# Usage: scripts/coder-trust-ca.sh /path/to/corporate-ca-bundle.pem
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

if [ ! -f "$cacert" ]; then
  echo "ERROR: '$cacert' not found." >&2
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx coder; then
  echo "ERROR: 'coder' container is not running. Run 'make up' first." >&2
  exit 1
fi

echo "Copying the coder container's existing CA bundle into ${target_dir}..."
docker exec coder mkdir -p "$target_dir"
docker exec coder cp /etc/ssl/certs/ca-certificates.crt "${target_dir}/ca-certificates.crt"

echo "Copying corporate CA bundle (${cacert}) into ${target_dir}/corporate-ca.pem..."
docker cp "$cacert" "coder:${target_dir}/corporate-ca.pem"

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
