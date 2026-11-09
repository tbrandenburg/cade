#!/usr/bin/env bash
# Issue a scoped token to a private file; see docs/operations.md for installation.
set -euo pipefail

if ! command -v coder >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
  echo "ERROR: coder, python3, and openssl are required." >&2
  exit 1
fi

lookup() {
  coder users list --output json 2>/dev/null | python3 -c '
import json, sys, uuid
users = [u for u in json.load(sys.stdin) if u.get("username") == "temporal-svc"]
if len(users) > 1:
    raise SystemExit("duplicate temporal-svc users")
if users:
    user = users[0]
    if user.get("roles"):
        raise SystemExit("temporal-svc has elevated site roles")
    print(uuid.UUID(user["id"]), user["status"])
'
}

if ! user="$(lookup)"; then
  echo "ERROR: cannot inspect temporal-svc; authenticate as a Coder owner." >&2
  exit 1
fi
if [[ -z "$user" ]]; then
  if ! coder users create --username temporal-svc --email temporal-svc@cade.local >/dev/null 2>&1; then
    echo "ERROR: service-user creation failed; check whether it exists before retrying." >&2
    exit 1
  fi
  if ! user="$(lookup)" || [[ -z "$user" ]]; then
    echo "ERROR: cannot verify the newly created service user." >&2
    exit 1
  fi
fi
read -r user_id status <<<"$user"
if [[ "$status" != active ]]; then
  if ! coder users activate temporal-svc >/dev/null 2>&1; then
    echo "ERROR: cannot activate temporal-svc." >&2
    exit 1
  fi
fi

action="${CODER_WORKSPACE_REAP_ACTION:-stop}"
case "$action" in
  stop) delete_scope=() ;;
  delete) delete_scope=(--scope coder:workspaces.delete) ;;
  *) echo "ERROR: CODER_WORKSPACE_REAP_ACTION must be stop or delete." >&2; exit 1 ;;
esac

base=/tmp
[[ -d /tmp/opencode ]] && base=/tmp/opencode
umask 077
directory="$(mktemp -d "$base/cade-coder-token.XXXXXXXX")"
name="cade-temporal-$(openssl rand -hex 8)"
echo "Creating token $name; if the request fails, check that name before retrying."
if ! coder tokens create --user temporal-svc --name "$name" --lifetime 7d \
  --scope coder:workspaces.create --scope coder:workspaces.operate \
  --scope organization:read --scope template:read --scope user:read \
  "${delete_scope[@]}" --allow "user:$user_id" --allow 'organization:*' \
  --allow 'organization_member:*' --allow 'template:*' --allow 'workspace:*' \
  >"$directory/token" 2>/dev/null; then
  echo "ERROR: token request failed; a token may exist under $name." >&2
  exit 1
fi
if [[ ! -s "$directory/token" ]]; then
  echo "ERROR: token response was empty; check $name before retrying." >&2
  exit 1
fi
echo "Token saved privately to $directory/token; see docs/operations.md to install it."
