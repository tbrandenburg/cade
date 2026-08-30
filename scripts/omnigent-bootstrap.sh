#!/usr/bin/env bash
# Issue #43 Step 2. One-time, idempotent first-admin bootstrap for the
# omnigent-server container brought up by compose.yaml (Issue #43 Step 1).
#
# omnigent-server's "accounts" auth mode never auto-creates a first admin —
# a fresh instance either waits for someone to reach the web Create-admin
# form, or (headless/CI deploys, this one included) reads a pre-seeded
# OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD env var at boot and creates the
# admin from it directly. This script only *verifies* that variable is set
# in the environment/.env and that the account actually got created; it
# never prints the password itself, only redacted confirmation.
#
# Steps:
#   1. Load .env (repo-root-relative), without overriding an already
#      exported value — same pattern as scripts/ai-bootstrap.sh.
#   2. Wait for omnigent-server's GET /health to respond (bounded retries,
#      same wait-loop style as scripts/reload-opa-policy.sh).
#   3. Check whether a first admin already exists (GET /v1/info's needs_setup) and
#      skip, or report success, without ever echoing the password.
#
# Safe to re-run: does not error or duplicate work on a second invocation.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# Load .env from repo root if present, without overwriting already-exported
# variables (an explicit shell env always wins over the file). Same
# pattern as scripts/ai-bootstrap.sh.
if [[ -f "${REPO_ROOT}/.env" ]]; then
	while IFS= read -r line || [[ -n "${line}" ]]; do
		[[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
		key="${line%%=*}"
		key="${key%"${key##*[![:space:]]}"}"
		[[ -z "${key}" ]] && continue
		if [[ -z "${!key:-}" ]]; then
			export "${line?}"
		fi
	done <"${REPO_ROOT}/.env"
fi

OMNIGENT_URL="http://127.0.0.1:${OMNIGENT_PORT:-8000}"

echo "==> Waiting for omnigent-server to become responsive (${OMNIGENT_URL}/health)"
ready=false
for _ in $(seq 1 30); do
	if curl -sf "${OMNIGENT_URL}/health" >/dev/null 2>&1; then
		ready=true
		break
	fi
	sleep 2
done
if [[ "${ready}" != "true" ]]; then
	echo "ERROR: omnigent-server did not become responsive at ${OMNIGENT_URL}/health after 60s." >&2
	echo "       Is the stack up? Run 'make up' / 'docker compose up -d omnigent-server' and check 'make status'." >&2
	exit 1
fi
echo "    omnigent-server is responsive"

if [[ -z "${OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD:-}" ]]; then
	echo "SKIP: OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD is not set — omnigent-server"
	echo "      stays in its needs-setup state; create the first admin via the"
	echo "      web Create-admin form at ${OMNIGENT_ACCOUNTS_BASE_URL:-${OMNIGENT_URL}}, or set"
	echo "      OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD in .env and re-run this script."
	exit 0
fi

# GET /v1/info's needs_setup field reports whether a first admin still
# The server itself is the source of truth for "already bootstrapped" —
# this script never tracks its own idempotency state on disk.
setup_status="$(curl -sf "${OMNIGENT_URL}/v1/info" 2>/dev/null || true)"

if echo "${setup_status}" | grep -qi '"needs_setup":false\|"needs_setup": false'; then
	echo "==> admin account already exists, skipping"
	exit 0
fi

echo "==> No admin account yet; omnigent-server reads OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD"
echo "    at its own boot time to create the first admin (this script does not call"
echo "    any creation API itself, and never prints the password value)."

# Re-check once more after informing the operator, in case the server
# just needed this env var and a restart to pick it up.
setup_status_after="$(curl -sf "${OMNIGENT_URL}/v1/info" 2>/dev/null || true)"
if echo "${setup_status_after}" | grep -qi '"needs_setup":false\|"needs_setup": false'; then
	echo "==> admin account created"
	exit 0
fi

echo "==> admin account still not created — omnigent-server may need a restart"
echo "    ('docker compose restart omnigent-server') to pick up"
echo "    OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD from .env, then re-run this script."
