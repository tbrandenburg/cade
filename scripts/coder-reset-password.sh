#!/usr/bin/env bash
# coder-reset-password.sh — Reset a Coder user's password and print the
# email address needed to actually log in with it (Coder authenticates by
# email, not username; reset-password itself only takes a username).
#
# Usage: scripts/coder-reset-password.sh <username>
#
# Interactive: prompts for the new password twice (delegated straight to
# `coder reset-password`'s own prompts). Reads DB connection details from
# .env if present, falling back to compose.yaml's defaults.

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <username>" >&2
  exit 1
fi

username="$1"
env_file="${ENV_FILE:-.env}"

pg_var() {
  local var="$1" default="$2"
  if [ -f "$env_file" ]; then
    local value
    value="$(grep -E "^${var}=" "$env_file" 2>/dev/null | tail -n1 | cut -d= -f2-)"
    [ -n "$value" ] && { echo "$value"; return; }
  fi
  echo "$default"
}

pg_user="$(pg_var CODER_PG_USER coder)"
pg_password="$(pg_var CODER_PG_PASSWORD coder)"
pg_db="$(pg_var CODER_PG_DB coder)"
postgres_url="postgresql://${pg_user}:${pg_password}@coder-db/${pg_db}?sslmode=disable"

email="$(docker exec coder-db psql -U "$pg_user" -d "$pg_db" -t -A \
  -c "SELECT email FROM users WHERE username = '${username}' AND deleted = false;" 2>/dev/null | head -n1)"

if [ -z "$email" ]; then
  echo "ERROR: no active user found with username '${username}'." >&2
  echo "List existing users with:" >&2
  echo "  docker exec coder-db psql -U ${pg_user} -d ${pg_db} -c \"SELECT username, email FROM users WHERE deleted = false;\"" >&2
  exit 1
fi

echo "Resetting password for username '${username}' (email: ${email})..."
docker exec -i coder /opt/coder reset-password "$username" --postgres-url "$postgres_url"

echo ""
echo "Log in with EMAIL (not username): ${email}"
echo "  Browser: http://localhost:7080"
echo "  CLI:     coder login http://localhost:7080"
