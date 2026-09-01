#!/usr/bin/env bash
# verify-workspace-jupyter.sh — Live verification for the JupyterLab
# dashboard tile on a real, already-created workspace with
# enable_jupyter=true.
#
# Issue #83: rewritten for subdomain-mode routing (`coder_app.jupyter`'s
# `subdomain = true`) — the previous version assumed path-based routing
# through `/@owner/ws.../apps/jupyter`, which is superseded. This version
# resolves the real subdomain hostname Coder assigns from the live
# workspace API response (`app.subdomain_name`, confirmed present on each
# `apps[]` entry once `subdomain = true` is set on that coder_app — see
# this script's own live-verification handoff for the exact JSON observed).
#
# Checks (best-effort — each check is skipped with a clear message if its
# prerequisite, e.g. a logged-in coder CLI session or docker access to the
# workspace's container, is unavailable; nothing here is faked):
#   1. coder_app slug "jupyter" is present on the workspace's resources,
#      and its subdomain hostname is resolved from the live API response.
#   2. jupyter-lab process is alive inside the workspace container
#      (docker exec ... pgrep -af jupyter-lab), listening on 8889.
#   3. Listener is loopback-only, not exposed on all interfaces
#      (checked via /proc/net/tcp, port 8889 = 22B9 hex).
#   4. Proxied HTTP round trip through Coder's real subdomain-routed proxy,
#      with a valid session token, returns 200 JSON from the Jupyter API.
#   5. The same subdomain URL WITHOUT a session token/cookie is NOT 200
#      (i.e. Coder's own proxy auth is still the only thing gating access
#      in subdomain mode too — this is a HARD requirement, unchanged from
#      path-based mode).
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
    jupyter_app_json="$(echo "${workspace_json}" | python3 -c '
import json, sys
ws = json.load(sys.stdin)
for res in ws.get("latest_build", {}).get("resources", []):
    for agent in res.get("agents", []) or []:
        for app in agent.get("apps", []) or []:
            if app.get("slug") == "jupyter":
                print(json.dumps(app))
                sys.exit(0)
print("")
' 2>/dev/null || true)"

    check "coder_app slug '"'"'jupyter'"'"' present on workspace resources" "$([ -n "${jupyter_app_json}" ] && echo 0 || echo 1)"

    subdomain_host=""
    if [ -n "${jupyter_app_json}" ]; then
      # Resolve whichever field Coder's live API actually populates for a
      # subdomain=true app. Live-verified (Issue #83): `subdomain_name` is
      # a bare label only (e.g. "jupyter--<ws>--<owner>"), not a full
      # hostname — it must be combined with the deployment's
      # wildcard_access_url (GET /api/v2/deployment/config) to build the
      # actual routable host, e.g. "jupyter--ws--owner.192.168.0.20.nip.io".
      subdomain_label="$(echo "${jupyter_app_json}" | python3 -c '
import json, sys
app = json.load(sys.stdin)
print(app.get("subdomain_name") or "")
' 2>/dev/null || true)"

      if [ -n "${subdomain_label}" ]; then
        deployment_json="$(curl -sf "${coder_url}/api/v2/deployment/config" \
          -H "Coder-Session-Token: ${session_token}" 2>/dev/null || true)"
        wildcard_url="$(echo "${deployment_json}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print((d.get("config") or {}).get("wildcard_access_url") or "")
' 2>/dev/null || true)"
        # wildcard_url looks like "*.192.168.0.20.nip.io" — strip the "*."
        # prefix and prepend our resolved subdomain label instead.
        wildcard_domain="${wildcard_url#\*.}"
        if [ -n "${wildcard_domain}" ] && [ "${wildcard_domain}" != "${wildcard_url}" ]; then
          subdomain_host="${subdomain_label}.${wildcard_domain}"
        fi
      fi
    fi

    if [ -n "${subdomain_host}" ]; then
      # Build a full URL against the resolved host, reusing CODER_ACCESS_URL's
      # scheme and port (wildcard DNS resolves the hostname; the port is not
      # part of the DNS name itself).
      scheme="$(echo "${coder_url}" | sed -n 's~^\(https\?\)://.*~\1~p')"
      port_suffix="$(echo "${coder_url}" | sed -n 's~^https\?://[^:]*\(:[0-9]\+\)\?.*~\1~p')"
      proxy_url="${scheme}://${subdomain_host}${port_suffix}"

      body="$(curl -sf -H "Coder-Session-Token: ${session_token}" \
        "${proxy_url}/api" 2>/dev/null || true)"
      check "proxied GET <jupyter-subdomain>/api with session token returns data" "$([ -n "${body}" ] && echo 0 || echo 1)"

      status_noauth="$(curl -s -o /dev/null -w '%{http_code}' "${proxy_url}/api" 2>/dev/null || echo 000)"
      check "unauthenticated proxied request is NOT 200 (got ${status_noauth})" "$([ "${status_noauth}" != "200" ] && echo 0 || echo 1)"
    else
      skip "could not resolve jupyter subdomain hostname from workspace API response (proxy checks)"
    fi
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
  # Port 8889 decimal = 22B9 hex; local_addr is little-endian hex IP:PORT.
  listeners="$(docker exec "${container_name}" sh -c "awk 'NR>1 {print \$2}' /proc/net/tcp | grep -i ':22B9$'" 2>/dev/null || true)"
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
  check "listener bound to 127.0.0.1:8889 only (entries: '${listeners}')" "$([ "${any_listener}" = "true" ] && [ "${loopback_only}" = "true" ] && echo 0 || echo 1)"
else
  skip "container ${container_name} not found locally (process/port checks)"
fi

echo ""
echo "Summary: ${pass} passed, ${fail} failed."
[ "${fail}" -eq 0 ]
