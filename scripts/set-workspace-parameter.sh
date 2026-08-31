#!/usr/bin/env bash
# set-workspace-parameter.sh — Generic helper to retroactively set a single
# mutable `coder_parameter` value on an EXISTING workspace, without needing
# to delete/recreate it.
#
# Extracted (Issue #60 Task 6) from the original, single-purpose
# scripts/set-workspace-temporal-tile.sh (Issue #50 §10 / PR #53), which is
# now a thin wrapper around this script. Both of that script's hard-won,
# live-verified behaviours are preserved here unchanged:
#   1. `coder update` on a RUNNING workspace internally performs
#      stop-then-start as TWO SEPARATE builds, and only forwards
#      --parameter/--always-prompt to the first (stop) one — the second
#      (start) build silently drops them and falls back to an
#      INTERACTIVE prompt, which hangs/fails non-interactively with
#      "error: start workspace: EOF". Reproduced live for temporal_owned;
#      never call `coder update`. Explicitly `coder stop` first (only if
#      currently running), then a single `coder start --always-prompt
#      --parameter ...` call.
#   2. Per this repo's own documented Coder gotcha (every `coder_parameter`
#      must be passed explicitly or the build can misbehave), ALL current
#      parameter values are fetched from the Coder API first and re-sent
#      unchanged alongside the one being changed, so no other parameter
#      (e.g. `github_token`, `agent_capable`) is silently reset to its
#      template default.
#
# Explicitly rejected alternative (Issue #60): a `docker exec`-into-container
# installer (Issue #49's pattern) could start a process but could never make
# a `coder_app` tile appear — `coder_app` is a Terraform resource, so a
# rebuild (stop+start, exactly what this script does) is required
# regardless of which parameter is being flipped.
#
# Usage:
#   scripts/set-workspace-parameter.sh <owner>/<workspace> <param_name> <value>
#   scripts/set-workspace-parameter.sh <workspace> <param_name> <value>   # current user
#
# Examples:
#   scripts/set-workspace-parameter.sh alice/dev enable_jupyter true
#   scripts/set-workspace-parameter.sh alice/dev enable_jupyter false
#   scripts/set-workspace-parameter.sh alice/dev temporal_owned true

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
  echo "Usage: $0 <owner>/<workspace>|<workspace> <param_name> <value>" >&2
  exit 1
}

if [ "$#" -ne 3 ]; then
  usage
fi

workspace_ref="$1"
param_name="$2"
value="$3"

coder_bin=""
if ! coder_bin="$(find_coder_cli)"; then
  echo "ERROR: no coder CLI found on PATH or at /tmp/coderbin/bin/coder." >&2
  echo "Log in first (see scripts/ai-token.sh for the non-interactive bootstrap pattern)." >&2
  exit 1
fi

# Resolve owner/name. If no owner was given, use the Coder API's "me"
# alias (resolves to whoever the current CLI session is logged in as).
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
  echo "(needed to look up the workspace's current parameter values via the API)." >&2
  echo "Log in first: coder login <url>" >&2
  exit 1
fi

coder_url="$(cat "${url_file}")"
session_token="$(cat "${session_file}")"

echo "Using coder CLI at: ${coder_bin}"
echo "Looking up current parameters and status for ${owner}/${name}..."

workspace_json="$(curl -sf "${coder_url}/api/v2/users/${owner}/workspace/${name}" \
  -H "Coder-Session-Token: ${session_token}")" || {
  echo "ERROR: failed to resolve workspace ${owner}/${name} via the Coder API." >&2
  exit 1
}

build_id="$(echo "${workspace_json}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["latest_build"]["id"])')"
current_status="$(echo "${workspace_json}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["latest_build"]["status"])')"

current_params_json="$(curl -sf "${coder_url}/api/v2/workspacebuilds/${build_id}/parameters" \
  -H "Coder-Session-Token: ${session_token}")" || {
  echo "ERROR: failed to fetch current build parameters." >&2
  exit 1
}

# Build the --parameter flags: current values for every OTHER parameter,
# overridden with the requested value for the one being changed.
parameter_flags=()
while IFS=$'\t' read -r pname pvalue; do
  if [ "${pname}" = "${param_name}" ]; then
    continue
  fi
  parameter_flags+=(--parameter "${pname}=${pvalue}")
done < <(echo "${current_params_json}" | python3 -c '
import json, sys
for p in json.load(sys.stdin):
    print(p["name"], p["value"], sep="\t")
')
parameter_flags+=(--parameter "${param_name}=${value}")

echo "Setting ${param_name}=${value} on workspace: ${owner}/${name}"
echo "(this stops [if running] and (re)starts the workspace's container; its home_volume is untouched — Durability Test 3 applies)"
echo ""

if [ "${current_status}" = "running" ]; then
  "${coder_bin}" stop "${owner}/${name}" --yes
fi
"${coder_bin}" start "${owner}/${name}" --always-prompt "${parameter_flags[@]}"

echo ""
echo "Done. ${param_name}=${value} applied to ${owner}/${name}."
