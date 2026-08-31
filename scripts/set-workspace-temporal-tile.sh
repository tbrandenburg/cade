#!/usr/bin/env bash
# set-workspace-temporal-tile.sh — Convenience wrapper to retroactively
# enable (or disable) the "Temporal Workflows" dashboard tile
# (`coder_app.temporal`, Issue #50 §10 / PR #53) on an EXISTING
# `docker-standard` workspace, without needing to delete/recreate it.
#
# Background: the tile is gated by the `temporal_owned` mutable
# `coder_parameter` (default "false"). Temporal's own
# `ensure_coder_workspace` Activity always sets it "true" at CREATE time
# for every `tw-*` workspace it creates — but a workspace created any
# other way (a human `coder create`, or a `tw-*` workspace that predates
# this parameter's existence) has no way to pick up the tile short of
# recreating the workspace, unless its parameter value is explicitly
# updated via a rebuild. This script does that non-destructively: same
# durability guarantee as any other build — `docker_volume.home_volume`
# is untouched (see AGENTS.md's Coder/Terraform/Docker section,
# Durability Test 3).
#
# This script is a thin wrapper, not new functionality — it exists purely
# so nobody has to remember the exact CLI incantation (or the owner/name
# addressing form) by hand. It does NOT mint tokens, does NOT touch
# OpenBao, and does NOT require CODER_WORKSPACE_API_TOKEN — it reuses
# whatever `coder` CLI session is already logged in (reads its session
# token/URL from the CLI's own config dir, same assumption as
# scripts/ai-token.sh's "Path 1": an existing logged-in session).
#
# Usage:
#   scripts/set-workspace-temporal-tile.sh <owner>/<workspace> [true|false]
#   scripts/set-workspace-temporal-tile.sh <workspace> [true|false]   # current user
#
# Examples:
#   scripts/set-workspace-temporal-tile.sh temporal-svc/tw-demo        # enable (default)
#   scripts/set-workspace-temporal-tile.sh temporal-svc/tw-demo true   # enable, explicit
#   scripts/set-workspace-temporal-tile.sh temporal-svc/tw-demo false  # disable
#
# NOTE (found by live-testing this script against the real running
# stack, not assumed from `coder update`/`coder start --help` alone):
#   1. `coder update` on a RUNNING workspace internally performs
#      stop-then-start as TWO SEPARATE builds, and only forwards
#      --parameter/--always-prompt to the first (stop) one — the second
#      (start) build silently drops them and falls back to an
#      INTERACTIVE prompt, which hangs/fails non-interactively with
#      "error: start workspace: EOF". Reproduced live. Fixed here by
#      never calling `coder update`: explicitly `coder stop` first (only
#      if currently running), then a single `coder start --always-prompt
#      --parameter ...` call.
#   2. Per this repo's own documented Coder gotcha (every
#      `coder_parameter` must be passed explicitly or the build can
#      misbehave), all of `docker-standard`'s parameters must be sent,
#      not just `temporal_owned` — this script fetches the workspace's
#      CURRENT parameter values from the Coder API first and re-sends
#      them unchanged alongside the new `temporal_owned` value, so
#      `github_token`/`agent_capable` are never silently reset to their
#      template defaults.

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
  echo "Usage: $0 <owner>/<workspace>|<workspace> [true|false]" >&2
  exit 1
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  usage
fi

workspace_ref="$1"
value="${2:-true}"

if [ "${value}" != "true" ] && [ "${value}" != "false" ]; then
  echo "ERROR: second argument must be 'true' or 'false' (got: ${value})" >&2
  usage
fi

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
# overridden with the requested value for temporal_owned.
parameter_flags=()
while IFS=$'\t' read -r pname pvalue; do
  if [ "${pname}" = "temporal_owned" ]; then
    continue
  fi
  parameter_flags+=(--parameter "${pname}=${pvalue}")
done < <(echo "${current_params_json}" | python3 -c '
import json, sys
for p in json.load(sys.stdin):
    print(p["name"], p["value"], sep="\t")
')
parameter_flags+=(--parameter "temporal_owned=${value}")

echo "Setting temporal_owned=${value} on workspace: ${owner}/${name}"
echo "(this stops [if running] and (re)starts the workspace's container; its home_volume is untouched — Durability Test 3 applies)"
echo ""

if [ "${current_status}" = "running" ]; then
  "${coder_bin}" stop "${owner}/${name}" --yes
fi
"${coder_bin}" start "${owner}/${name}" --always-prompt "${parameter_flags[@]}"

echo ""
if [ "${value}" = "true" ]; then
  echo "Done. The 'Temporal Workflows' tile should now appear on ${owner}/${name}'s workspace page."
else
  echo "Done. The 'Temporal Workflows' tile has been removed from ${owner}/${name}'s workspace page."
fi
