#!/usr/bin/env bash
# verify-agent-capable-autostop.sh — Ensure an agent_capable=true workspace
# actually has Coder-side autostop disabled (`ttl_ms == null`), and fix it
# if not (Issue #74).
#
# Background: the `docker-workspace` template's startup script cannot
# disable autostop from inside the workspace container itself — the only
# Coder credential ever present there (`$CODER_AGENT_TOKEN`) authenticates
# the workspace-agent protocol, not the CLI/API user-session protocol
# `coder schedule stop`/`PUT /api/v2/workspaces/{id}/ttl` require. Confirmed
# live: the agent token is a bare UUID, not a `<key-id>:<secret>` API key,
# and coderd rejects it with "Invalid API key format" for any user-session
# API call. See coder/templates/docker-workspace/main.tf's Issue #74 comment
# and AGENTS.md's Issue #74 entry for the full evidence trail.
#
# This script instead does it the only way that actually works: using an
# already-authenticated `coder` CLI session on the HOST (same session
# `coder create` itself was run with), exactly as
# scripts/set-workspace-parameter.sh does for other post-create tweaks.
#
# Usage:
#   scripts/verify-agent-capable-autostop.sh <owner>/<workspace>
#   scripts/verify-agent-capable-autostop.sh <workspace>   # current user
#
# Behavior:
#   - If the workspace's `agent_capable` parameter is not "true": prints an
#     info message and exits 0 (nothing to check/fix).
#   - If `ttl_ms` is already null: PASS, exits 0.
#   - If `ttl_ms` is set: runs `coder schedule stop <owner>/<workspace>
#     manual` to clear it, re-checks via the API, then PASS/FAIL.
#
# Exit code: 0 on PASS (or nothing to do), 1 on FAIL or any resolution error.

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

usage() {
  echo "Usage: $0 <owner>/<workspace>|<workspace>" >&2
  exit 1
}

if [ "$#" -ne 1 ]; then
  usage
fi

workspace_ref="$1"

coder_bin=""
if ! coder_bin="$(find_coder_cli)"; then
  echo "ERROR: no coder CLI found on PATH or at /tmp/coderbin/bin/coder." >&2
  exit 1
fi

if [[ "${workspace_ref}" == */* ]]; then
  owner="${workspace_ref%%/*}"
  name="${workspace_ref##*/}"
else
  owner="me"
  name="${workspace_ref}"
fi

coder_config_dir="${CODER_CONFIG_DIR:-${HOME}/.config/coderv2}"
session_file="${coder_config_dir}/session"
url_file="${coder_config_dir}/url"

if [ ! -f "${session_file}" ] || [ ! -f "${url_file}" ]; then
  echo "ERROR: no existing coder CLI session found at ${coder_config_dir}" >&2
  echo "Log in first: coder login <url>" >&2
  exit 1
fi

coder_url="$(cat "${url_file}")"
session_token="$(cat "${session_file}")"

echo "Resolving workspace ${owner}/${name} via the Coder API..."
workspace_json="$(curl -sf "${coder_url}/api/v2/users/${owner}/workspace/${name}" \
  -H "Coder-Session-Token: ${session_token}")" || {
  echo "ERROR: failed to resolve workspace ${owner}/${name} via the Coder API." >&2
  exit 1
}

workspace_id="$(echo "${workspace_json}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
build_id="$(echo "${workspace_json}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["latest_build"]["id"])')"

agent_capable="$(curl -sf "${coder_url}/api/v2/workspacebuilds/${build_id}/parameters" \
  -H "Coder-Session-Token: ${session_token}" | python3 -c '
import json, sys
for p in json.load(sys.stdin):
    if p["name"] == "agent_capable":
        print(p["value"])
        break
else:
    print("false")
')"

if [ "${agent_capable}" != "true" ]; then
  echo "INFO: ${owner}/${name} has agent_capable=${agent_capable} (not \"true\") — no autostop-disable check applies here."
  exit 0
fi

check_ttl_disabled() {
  curl -sf "${coder_url}/api/v2/workspaces/${workspace_id}" \
    -H "Coder-Session-Token: ${session_token}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("null" if d.get("ttl_ms") is None else str(d["ttl_ms"]))
'
}

ttl_ms="$(check_ttl_disabled)"
if [ "${ttl_ms}" = "null" ]; then
  echo "PASS: ${owner}/${name} is agent_capable=true and ttl_ms is already null (autostop disabled)."
  exit 0
fi

echo "ttl_ms=${ttl_ms} on ${owner}/${name} (agent_capable=true) — disabling autostop via 'coder schedule stop ... manual'..."
"${coder_bin}" schedule stop "${owner}/${name}" manual

ttl_ms="$(check_ttl_disabled)"
if [ "${ttl_ms}" = "null" ]; then
  echo "PASS: ${owner}/${name} now has ttl_ms=null (autostop disabled)."
  exit 0
fi

echo "FAIL: ${owner}/${name} still has ttl_ms=${ttl_ms} after 'coder schedule stop ... manual'." >&2
exit 1
