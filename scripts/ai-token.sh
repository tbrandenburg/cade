#!/usr/bin/env bash
# ai-token.sh — Obtain a Coder API session token for AI agent bootstrap use
# (e.g. `coder/ai/*.yaml` tooling), preferring an already-logged-in CLI
# session and only falling back to a fresh admin user as a last resort.
#
# Path 1 (preferred): if a `coder` CLI session is already logged in, create
# a long-lived API token from it via `coder tokens create`. No new user is
# created in this path.
#
# Path 2 (fallback): if there is no logged-in CLI session, bootstrap a
# throwaway admin user directly against the Coder Postgres DB (the
# non-interactive pattern documented in AGENTS.md's 2026-08-29 entry), log
# in via the HTTP API, and print the resulting session token. This creates
# a PERSISTENT admin account that cannot delete or suspend itself — see the
# warning printed at runtime.
#
# This script NEVER writes/modifies .env. It only prints the token once,
# together with a copy-paste `.env` line, for the operator to add manually.

set -euo pipefail

find_coder_cli() {
  if command -v coder >/dev/null 2>&1; then
    echo "coder"
    return 0
  fi
  if [ -x /tmp/coderbin/bin/coder ]; then
    echo "/tmp/coderbin/bin/coder"
    return 0
  fi
  return 1
}

print_env_line() {
  local token="$1"
  echo ""
  echo "Copy-paste .env line (this script did NOT write it for you):"
  echo "CODER_SESSION_TOKEN=${token}"
}

CODER_URL="${CODER_URL:-http://localhost:7080}"

coder_bin=""
if coder_bin="$(find_coder_cli)"; then
  echo "Found coder CLI at: ${coder_bin}"
  echo "Attempting to reuse an existing logged-in CLI session..."
  if token_output="$("${coder_bin}" tokens create --lifetime 90d -n "cade-ai-bootstrap" 2>&1)"; then
    echo "Created API token from existing CLI session."
    echo "${token_output}"
    print_env_line "${token_output}"
    exit 0
  fi
  echo "No usable logged-in CLI session (or token creation failed):" >&2
  echo "${token_output}" >&2
else
  echo "No coder CLI found on PATH or at /tmp/coderbin/bin/coder." >&2
fi

echo ""
echo "=============================================================="
echo "WARNING: falling back to creating a NEW PERSISTENT admin user."
echo "This account CANNOT delete or suspend itself (documented Coder"
echo "limitation — see AGENTS.md 'Lessons Learned', 2026-08-29 entry)."
echo "If another admin session becomes available later, clean this"
echo "account up manually with: coder users delete <username>"
echo "=============================================================="
echo ""

random_suffix="$(date +%s)"
username="cade-ai-bootstrap-${random_suffix}"
email="${username}@cade.local"
password="$(openssl rand -base64 24 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 32)"
if [ -z "${password}" ]; then
  password="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)"
fi
if [ -z "${password}" ]; then
  echo "ERROR: failed to generate a random password." >&2
  exit 1
fi

pg_url="postgresql://coder:coder@coder-db/coder?sslmode=disable"

echo "Creating admin user '${username}' (email: ${email})..."
docker exec coder coder server create-admin-user \
  --postgres-url "${pg_url}" \
  --email "${email}" --password "${password}" --username "${username}"

echo "Logging in to obtain a session token..."
login_response="$(curl -sf -X POST "${CODER_URL}/api/v2/users/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${email}\",\"password\":\"${password}\"}")"

session_token="$(printf '%s' "${login_response}" | grep -o '"session_token":"[^"]*"' | cut -d'"' -f4)"

if [ -z "${session_token}" ]; then
  echo "ERROR: failed to extract session_token from login response." >&2
  echo "${login_response}" >&2
  exit 1
fi

echo "Created admin user '${username}' and obtained session token."
echo "${session_token}"
print_env_line "${session_token}"
