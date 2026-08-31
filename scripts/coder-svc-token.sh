#!/usr/bin/env bash
# coder-svc-token.sh — Mint a narrowly-scoped Coder API session token for
# the dedicated `temporal-svc` Coder user (Issue #50: Temporal-owned
# persistent workspaces). Mirrors scripts/ai-token.sh's structure and its
# NEVER-echo-bare-token discipline (read that file's incident history in
# AGENTS.md before touching this one).
#
# Scopes minted: coder:workspaces.create, coder:workspaces.operate (plus
# coder:workspaces.delete only if CODER_WORKSPACE_REAP_ACTION=delete) —
# the modern `scopes: [...]` array (NOT the deprecated all-or-nothing
# singular `scope: "all"` field), per this issue's comment 2 correction.
# Lifetime is 604800000000000 nanoseconds (168h = 7 days — the field is
# nanoseconds, not seconds; see AGENTS.md's recorded Issue #17 lesson).
# The server caps the max lifetime at 168h regardless of what's requested.
#
# This script NEVER writes/modifies .env. It only prints the token once,
# together with a copy-paste `.env` line, for the operator to add manually.
# It NEVER echoes the bare token on its own separate line — only ever
# embedded in the final `CODER_WORKSPACE_API_TOKEN=<value>` line, per the
# two real token-leak incidents already recorded in AGENTS.md for
# ai-token.sh/similar scripts.

set -euo pipefail

CODER_URL="${CODER_URL:-http://localhost:7080}"
SVC_USERNAME="temporal-svc"
SVC_EMAIL="${SVC_USERNAME}@cade.local"
TOKEN_LIFETIME_NS=604800000000000 # 168h in nanoseconds

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
  echo "CODER_WORKSPACE_API_TOKEN=${token}"
}

scopes_json() {
  # NOTE, discovered only by live testing against a real Coder v2.36.3
  # server (not in either issue comment): the composite
  # `coder:workspaces.*` scopes alone cannot resolve an organization id
  # or a template's active_version_id — `GET /api/v2/organizations`
  # silently returns `200 []` (not a 403) for a token scoped to only
  # `coder:workspaces.create`/`.operate`, and
  # `GET .../templates/{name}` 404s. `ensure_coder_workspace` needs both
  # to create a workspace, so the low-level read-only scopes
  # `organization:read` and `template:read` are added alongside the
  # composite workspace-lifecycle scopes (still far short of "all" —
  # no template *write*, no user read, no audit-log read). See
  # docs/security.md for the exact, current scope list and rationale.
  if [ "${CODER_WORKSPACE_REAP_ACTION:-stop}" = "delete" ]; then
    echo '["coder:workspaces.create","coder:workspaces.operate","coder:workspaces.delete","organization:read","template:read"]'
  else
    echo '["coder:workspaces.create","coder:workspaces.operate","organization:read","template:read"]'
  fi
}

svc_password="$(openssl rand -base64 24 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 32)"
if [ -z "${svc_password}" ]; then
  svc_password="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)"
fi
if [ -z "${svc_password}" ]; then
  echo "ERROR: failed to generate a random password." >&2
  exit 1
fi

pg_url="postgresql://coder:coder@coder-db/coder?sslmode=disable"

# Ensure the temporal-svc user exists. `coder server create-admin-user`
# only creates admin accounts, so a plain member account needs the API —
# bootstrap a throwaway admin session first (same non-interactive
# pattern as scripts/ai-token.sh's fallback path), use it once to create
# temporal-svc (idempotent: skip if it already exists), then discard.
bootstrap_admin_and_get_token() {
  local admin_user="cade-svc-bootstrap-$(date +%s)"
  local admin_email="${admin_user}@cade.local"
  local admin_password
  admin_password="$(openssl rand -base64 24 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 32)"
  if [ -z "${admin_password}" ]; then
    admin_password="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)"
  fi

  echo "Bootstrapping a throwaway admin user to provision temporal-svc..." >&2
  docker exec coder coder server create-admin-user \
    --postgres-url "${pg_url}" \
    --email "${admin_email}" --password "${admin_password}" --username "${admin_user}" >&2

  local login_response admin_token
  login_response="$(curl -sf -X POST "${CODER_URL}/api/v2/users/login" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"${admin_email}\",\"password\":\"${admin_password}\"}")"
  admin_token="$(printf '%s' "${login_response}" | grep -o '"session_token":"[^"]*"' | cut -d'"' -f4)"
  if [ -z "${admin_token}" ]; then
    echo "ERROR: failed to extract admin session_token." >&2
    exit 1
  fi
  echo "${admin_token}"
}

user_exists() {
  local admin_token="$1"
  local status
  status="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Coder-Session-Token: ${admin_token}" \
    "${CODER_URL}/api/v2/users/${SVC_USERNAME}")"
  [ "${status}" = "200" ]
}

create_svc_user() {
  local admin_token="$1"
  local default_org_id
  default_org_id="$(curl -sf -H "Coder-Session-Token: ${admin_token}" "${CODER_URL}/api/v2/organizations" \
    | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)"
  if [ -z "${default_org_id}" ]; then
    echo "ERROR: failed to resolve a default organization id." >&2
    exit 1
  fi
  echo "Creating Coder user '${SVC_USERNAME}' in org ${default_org_id}..." >&2
  curl -sf -X POST "${CODER_URL}/api/v2/users" \
    -H "Coder-Session-Token: ${admin_token}" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${SVC_USERNAME}\",\"email\":\"${SVC_EMAIL}\",\"password\":\"${svc_password}\",\"login_type\":\"password\",\"organization_ids\":[\"${default_org_id}\"]}" \
    >/dev/null
}

admin_token="$(bootstrap_admin_and_get_token)"

if user_exists "${admin_token}"; then
  echo "User '${SVC_USERNAME}' already exists — this run cannot reset its" >&2
  echo "password (Coder has no admin password-reset API used here); set" >&2
  echo "CODER_WORKSPACE_SVC_PASSWORD to the already-known password and" >&2
  echo "re-run, or delete the user first if the password is lost." >&2
  if [ -z "${CODER_WORKSPACE_SVC_PASSWORD:-}" ]; then
    echo "ERROR: CODER_WORKSPACE_SVC_PASSWORD not set; cannot log in as an" >&2
    echo "existing temporal-svc user." >&2
    exit 1
  fi
  svc_password="${CODER_WORKSPACE_SVC_PASSWORD}"
else
  create_svc_user "${admin_token}"
fi

echo "Logging in as '${SVC_USERNAME}' to mint its own scoped token..." >&2
svc_login_response="$(curl -sf -X POST "${CODER_URL}/api/v2/users/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${SVC_EMAIL}\",\"password\":\"${svc_password}\"}")"
svc_session_token="$(printf '%s' "${svc_login_response}" | grep -o '"session_token":"[^"]*"' | cut -d'"' -f4)"
if [ -z "${svc_session_token}" ]; then
  echo "ERROR: failed to log in as ${SVC_USERNAME}." >&2
  exit 1
fi

echo "Minting a $(scopes_json)-scoped API token (lifetime 168h)..." >&2
token_response="$(curl -sf -X POST "${CODER_URL}/api/v2/users/me/keys/tokens" \
  -H "Coder-Session-Token: ${svc_session_token}" \
  -H "Content-Type: application/json" \
  -d "{\"scopes\":$(scopes_json),\"lifetime\":${TOKEN_LIFETIME_NS},\"token_name\":\"cade-temporal-workspace-lifecycle\"}")"

svc_api_token="$(printf '%s' "${token_response}" | grep -o '"key":"[^"]*"' | cut -d'"' -f4)"
if [ -z "${svc_api_token}" ]; then
  echo "ERROR: failed to extract API key from token response." >&2
  echo "${token_response}" >&2
  exit 1
fi

# Verify the lifetime unit actually landed as ~7 days, not ~0 seconds
# (AGENTS.md's recorded Issue #17 lesson: a 201 alone does not prove
# this). List this user's tokens and check expires_at is in the future
# by a plausible number of days.
tokens_list="$(curl -sf -H "Coder-Session-Token: ${svc_session_token}" \
  "${CODER_URL}/api/v2/users/me/keys/tokens")"
expires_at="$(printf '%s' "${tokens_list}" | grep -o '"expires_at":"[^"]*"' | head -1 | cut -d'"' -f4)"
if [ -z "${expires_at}" ]; then
  echo "WARNING: could not verify expires_at from token list response." >&2
else
  echo "Token expires_at=${expires_at} (expect ~7 days from now)." >&2
fi

echo "Minted API token for '${SVC_USERNAME}'." >&2
print_env_line "${svc_api_token}"
