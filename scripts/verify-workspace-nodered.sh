#!/usr/bin/env bash
# verify-workspace-nodered.sh — Live verification for the Node-RED
# dashboard tile (Issue #60) on a real, already-created workspace with
# enable_nodered=true.
#
# Checks (best-effort — each check is skipped with a clear message if its
# prerequisite is unavailable; nothing here is faked):
#   1. coder_app slug "nodered" is present on the workspace's resources.
#   2. node-red process is alive inside the workspace container.
#   3. Listener is loopback-only (127.0.0.1:1880, not 0.0.0.0:1880).
#   4. GET <proxy>/nodered/flows with `Accept: application/json` returns
#      200 + a JSON array — NOTE: without that header Node-RED returns
#      the editor's HTML shell with a 200, which would be a false positive
#      if mistaken for a working flows-API response; this script always
#      passes the header explicitly.
#   5. Editor SPA itself (GET <proxy>/nodered/) loads (200, non-empty body).
#   6. GET <proxy>/nodered/nodes with Accept: json includes BOTH
#      @flowfuse/node-red-dashboard and @tbrandenburg/node-red-agents.
#
# Usage:
#   scripts/verify-workspace-nodered.sh <owner>/<workspace>

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
    has_nodered="$(echo "${workspace_json}" | python3 -c '
import json, sys
ws = json.load(sys.stdin)
slugs = []
for res in ws.get("latest_build", {}).get("resources", []):
    for app in res.get("agents", [{}])[0].get("apps", []) if res.get("agents") else []:
        slugs.append(app.get("slug"))
print("nodered" in slugs)
' 2>/dev/null || echo False)"
    check "coder_app slug 'nodered' present on workspace resources" "$([ "${has_nodered}" = "True" ] && echo 0 || echo 1)"

    proxy_path="/@${owner}/${name}.main/apps/nodered"

    editor_status="$(curl -s -o /tmp/nodered-editor-body.$$ -w '%{http_code}' \
      -H "Coder-Session-Token: ${session_token}" "${coder_url}${proxy_path}/" 2>/dev/null || echo 000)"
    editor_size="$(wc -c </tmp/nodered-editor-body.$$ 2>/dev/null || echo 0)"
    rm -f /tmp/nodered-editor-body.$$
    check "editor SPA GET .../apps/nodered/ returns 200 with non-empty body (status=${editor_status}, bytes=${editor_size})" \
      "$([ "${editor_status}" = "200" ] && [ "${editor_size}" -gt 0 ] && echo 0 || echo 1)"

    flows_json="$(curl -sf -H "Coder-Session-Token: ${session_token}" -H 'Accept: application/json' \
      "${coder_url}${proxy_path}/flows" 2>/dev/null || true)"
    is_json_array="$(echo "${flows_json}" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    print(isinstance(d, list))
except Exception:
    print(False)' 2>/dev/null || echo False)"
    check "GET .../apps/nodered/flows with Accept:json returns a JSON array" "$([ "${is_json_array}" = "True" ] && echo 0 || echo 1)"

    nodes_json="$(curl -sf -H "Coder-Session-Token: ${session_token}" -H 'Accept: application/json' \
      "${coder_url}${proxy_path}/nodes" 2>/dev/null || true)"
    has_both="$(echo "${nodes_json}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(False); sys.exit()
mods = [n.get("module", "") for n in d] if isinstance(d, list) else []
print(any("dashboard" in m for m in mods) and any("agents" in m for m in mods))
' 2>/dev/null || echo False)"
    check "GET .../apps/nodered/nodes includes both dashboard and agents packages" "$([ "${has_both}" = "True" ] && echo 0 || echo 1)"
  else
    skip "could not resolve workspace ${owner}/${name} via Coder API (proxy/API checks)"
  fi
else
  skip "no cached coder CLI session at ${coder_config_dir} (proxy/API checks)"
fi

if docker inspect "${container_name}" >/dev/null 2>&1; then
  pgrep_out="$(docker exec "${container_name}" pgrep -af node-red 2>/dev/null || true)"
  check "node-red process alive in ${container_name}" "$([ -n "${pgrep_out}" ] && echo 0 || echo 1)"

  # `ss`/`netstat` are not installed in cade/coder-workspace:latest; read
  # /proc/net/tcp directly instead. Port 1880 decimal = 0758 hex.
  listeners="$(docker exec "${container_name}" sh -c "awk 'NR>1 {print \$2}' /proc/net/tcp | grep -i ':0758$'" 2>/dev/null || true)"
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
  check "listener bound to 127.0.0.1:1880 only (entries: '${listeners}')" "$([ "${any_listener}" = "true" ] && [ "${loopback_only}" = "true" ] && echo 0 || echo 1)"
else
  skip "container ${container_name} not found locally (process/port checks)"
fi

echo ""
echo "Summary: ${pass} passed, ${fail} failed."
[ "${fail}" -eq 0 ]
