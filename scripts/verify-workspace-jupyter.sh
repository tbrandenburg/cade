#!/usr/bin/env bash
# verify-workspace-jupyter.sh — Live verification for the JupyterLab
# dashboard tile (Issue #60) on a real, already-created workspace with
# enable_jupyter=true.
#
# Checks (best-effort — each check is skipped with a clear message if its
# prerequisite, e.g. a logged-in coder CLI session or docker access to the
# workspace's container, is unavailable; nothing here is faked):
#   1. coder_app slug "jupyter" is present on the workspace's resources
#      (GET /api/v2/workspaces/{id}).
#   2. jupyter-lab process is alive inside the workspace container
#      (docker exec ... pgrep -af jupyter-lab).
#   3. Listener is loopback-only, not exposed on all interfaces
#      (ss -ltnp | grep 8888 shows 127.0.0.1:8888, not 0.0.0.0:8888).
#   4. Proxied HTTP round trip through Coder's own agent proxy, with a
#      valid session token, returns 200 JSON from the Jupyter API.
#   5. The same URL WITHOUT a session token/cookie is NOT 200 (i.e. Coder's
#      own proxy auth is actually the only thing gating access — Issue #60
#      §1's core security claim).
#
# Usage:
#   scripts/verify-workspace-jupyter.sh <owner>/<workspace>

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <owner>/<workspace>" >&2
  exit 1
fi

workspace_ref="$1"
owner="${workspace_ref%%/*}"
name="${workspace_ref##*/}"

if [[ "${workspace_ref}" != */* ]]; then
  echo "ERROR: pass <owner>/<workspace> explicitly (this script does not resolve 'me')." >&2
  exit 1
fi

coder_config_dir="${CODER_CONFIG_DIR:-${HOME}/.config/coderv2}"
session_file="${coder_config_dir}/session"
url_file="${coder_config_dir}/url"

pass=0
fail=0

check() {
  local desc="$1" ok="$2"
  if [ "${ok}" = "0" ]; then
    echo "PASS: ${desc}"
    pass=$((pass + 1))
  else
    echo "FAIL: ${desc}"
    fail=$((fail + 1))
  fi
}

skip() {
  echo "SKIP: $1"
}

container_name="coder-${owner}-$(echo "${name}" | tr '[:upper:]' '[:lower:]')"

if [ -f "${session_file}" ] && [ -f "${url_file}" ]; then
  coder_url="$(cat "${url_file}")"
  session_token="$(cat "${session_file}")"

  workspace_json="$(curl -sf "${coder_url}/api/v2/users/${owner}/workspace/${name}" \
    -H "Coder-Session-Token: ${session_token}" 2>/dev/null || true)"

  if [ -n "${workspace_json}" ]; then
    has_jupyter="$(echo "${workspace_json}" | python3 -c '
import json, sys
ws = json.load(sys.stdin)
slugs = []
for res in ws.get("latest_build", {}).get("resources", []):
    for app in res.get("agents", [{}])[0].get("apps", []) if res.get("agents") else []:
        slugs.append(app.get("slug"))
print("jupyter" in slugs)
' 2>/dev/null || echo False)"
    check "coder_app slug 'jupyter' present on workspace resources" "$([ "${has_jupyter}" = "True" ] && echo 0 || echo 1)"

    workspace_proxy_path="/@${owner}/${name}.main/apps/jupyter"
    body="$(curl -sf -H "Coder-Session-Token: ${session_token}" \
      "${coder_url}${workspace_proxy_path}/api" 2>/dev/null || true)"
    check "proxied GET .../apps/jupyter/api with session token returns data" "$([ -n "${body}" ] && echo 0 || echo 1)"

    status_noauth="$(curl -s -o /dev/null -w '%{http_code}' "${coder_url}${workspace_proxy_path}/api" 2>/dev/null || echo 000)"
    check "unauthenticated proxied request is NOT 200 (got ${status_noauth})" "$([ "${status_noauth}" != "200" ] && echo 0 || echo 1)"
  else
    skip "could not resolve workspace ${owner}/${name} via Coder API (proxy/API checks)"
  fi
else
  skip "no cached coder CLI session at ${coder_config_dir} (proxy/API checks)"
fi

if docker inspect "${container_name}" >/dev/null 2>&1; then
  pgrep_out="$(docker exec "${container_name}" pgrep -af jupyter-lab 2>/dev/null || true)"
  check "jupyter-lab process alive in ${container_name}" "$([ -n "${pgrep_out}" ] && echo 0 || echo 1)"

  # `ss`/`netstat` are not installed in cade/coder-workspace:latest; read
  # /proc/net/tcp directly instead (always available, no extra dependency).
  # Port 8888 decimal = 22B8 hex; local_addr is little-endian hex IP:PORT.
  listeners="$(docker exec "${container_name}" sh -c "awk 'NR>1 {print \$2}' /proc/net/tcp | grep -i ':22B8$'" 2>/dev/null || true)"
  loopback_only="true"
  any_listener="false"
  while read -r entry; do
    [ -z "${entry}" ] && continue
    any_listener="true"
    addr_hex="${entry%%:*}"
    if [ "${addr_hex}" != "0100007F" ]; then
      loopback_only="false"
    fi
  done <<EOF
${listeners}
EOF
  check "listener bound to 127.0.0.1:8888 only (entries: '${listeners}')" "$([ "${any_listener}" = "true" ] && [ "${loopback_only}" = "true" ] && echo 0 || echo 1)"
else
  skip "container ${container_name} not found locally (process/port checks)"
fi

echo ""
echo "Summary: ${pass} passed, ${fail} failed."
[ "${fail}" -eq 0 ]
