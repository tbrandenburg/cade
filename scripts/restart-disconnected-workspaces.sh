#!/usr/bin/env bash
# restart-disconnected-workspaces.sh — Recover Coder workspace agents that
# survived a host/Docker Desktop restart in a "Started" (desired-state)
# but actually-disconnected agent state (Issue #117).
#
# Background: `docker_container.workspace` resources are created directly
# by Coder's own Terraform/Docker provisioner, entirely outside docker
# compose's view. `make up`/`docker compose up -d` only ever touches the
# compose-defined platform stack, so a host/Docker Desktop restart that
# kills every running container leaves workspace agents disconnected
# forever — `coder list --all` still reports the workspace as `Started`
# (its desired state), while the agent itself never reconnects on its own.
# The only known fix is `coder stop <owner>/<workspace> --yes` followed by
# `coder start <owner>/<workspace> --yes` for each affected workspace.
#
# This script automates that per-workspace stop/start cycle, but ONLY for
# workspaces that are both (a) meant to be running (latest build status
# "running") and (b) actually disconnected (Coder-side agent status is
# anything other than "connected"). Already-healthy workspaces are left
# completely untouched — no unnecessary stop/start cycle, and
# docker_volume.home_volume (or any per-workspace volume) is never touched
# directly; only coder stop/start ever run.
#
# By design (see Issue #117) this is a separate, explicit opt-in target —
# it is NOT wired automatically into `make up`. `make up` only prints a
# one-line hint if any disconnected-but-should-be-running workspace is
# detected; recovery itself always requires this script to be run
# deliberately.
#
# Usage:
#   scripts/restart-disconnected-workspaces.sh            # detect + restart
#   scripts/restart-disconnected-workspaces.sh --check     # detect only,
#                                                           # print a count,
#                                                           # never restart
#                                                           # (used by
#                                                           # `make up`'s hint)
#
# Exit code: 0 on success (including "nothing to do"), 1 on any resolution
# error (missing CLI/session, unreachable Coder API, a workspace that
# never reaches "connected" after restart).

set -euo pipefail

check_only=false
if [ "${1:-}" = "--check" ]; then
  check_only=true
fi

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

coder_bin=""
if ! coder_bin="$(find_coder_cli)"; then
  if [ "${check_only}" = true ]; then
    # Best-effort mode (called from `make up`) — silently skip, no CLI yet.
    exit 0
  fi
  echo "ERROR: no coder CLI found on PATH or at /tmp/coderbin/bin/coder." >&2
  exit 1
fi

coder_config_dir="${CODER_CONFIG_DIR:-${HOME}/.config/coderv2}"
session_file="${coder_config_dir}/session"
url_file="${coder_config_dir}/url"

if [ ! -f "${session_file}" ] || [ ! -f "${url_file}" ]; then
  if [ "${check_only}" = true ]; then
    exit 0
  fi
  echo "ERROR: no existing coder CLI session found at ${coder_config_dir}" >&2
  echo "Log in first: coder login <url>" >&2
  exit 1
fi

coder_url="$(cat "${url_file}")"
session_token="$(cat "${session_file}")"

workspaces_json="$(curl -sf "${coder_url}/api/v2/workspaces?limit=0" \
  -H "Coder-Session-Token: ${session_token}")" || {
  if [ "${check_only}" = true ]; then
    # Coder not reachable yet (e.g. mid-`make up`) — best effort, skip.
    exit 0
  fi
  echo "ERROR: failed to list workspaces via the Coder API at ${coder_url}." >&2
  exit 1
}

# Running workspaces whose desired state is running are candidates; a
# workspace's own agent connection status is fetched per-workspace below
# via GET /api/v2/users/{owner}/workspace/{name}, which embeds
# latest_build.resources[].agents[].status — the same shape
# scripts/set-workspace-parameter.sh already relies on for build/parameter
# lookups.
mapfile -t running_refs < <(echo "${workspaces_json}" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for w in data.get("workspaces", []):
    if w.get("latest_build", {}).get("status") == "running":
        owner = w.get("owner_name")
        name = w.get("name")
        print(f"{owner}/{name}")
')

if [ "${#running_refs[@]}" -eq 0 ]; then
  if [ "${check_only}" = true ]; then
    exit 0
  fi
  echo "No running workspaces found. Nothing to check."
  exit 0
fi

disconnected_refs=()
for ref in "${running_refs[@]}"; do
  owner="${ref%%/*}"
  name="${ref##*/}"
  workspace_json="$(curl -sf "${coder_url}/api/v2/users/${owner}/workspace/${name}" \
    -H "Coder-Session-Token: ${session_token}")" || {
    echo "WARNING: failed to fetch status for ${ref}; skipping." >&2
    continue
  }
  agent_statuses="$(echo "${workspace_json}" | python3 -c '
import json, sys
data = json.load(sys.stdin)
statuses = []
for res in data.get("latest_build", {}).get("resources", []) or []:
    for agent in res.get("agents", []) or []:
        statuses.append(agent.get("status", "unknown"))
print(",".join(statuses))
')"
  if [ -z "${agent_statuses}" ]; then
    # No agents reported at all — treat as healthy/non-applicable rather
    # than guessing; nothing to reconcile for a resource with no agent.
    continue
  fi
  if [[ "${agent_statuses}" == *"connected"* ]] && [[ "${agent_statuses}" != *"disconnected"* ]]; then
    continue
  fi
  disconnected_refs+=("${ref}")
done

if [ "${check_only}" = true ]; then
  if [ "${#disconnected_refs[@]}" -gt 0 ]; then
    echo "${#disconnected_refs[@]} workspace(s) have a disconnected agent — run 'make workspaces-restart' to recover them."
  fi
  exit 0
fi

echo "Checked ${#running_refs[@]} running workspace(s); ${#disconnected_refs[@]} disconnected."

if [ "${#disconnected_refs[@]}" -eq 0 ]; then
  echo "All running workspaces already have a connected agent. Nothing to do."
  exit 0
fi

restarted_refs=()
failed_refs=()
for ref in "${disconnected_refs[@]}"; do
  echo ""
  echo "Restarting disconnected workspace: ${ref}"
  if ! "${coder_bin}" stop "${ref}" --yes; then
    echo "ERROR: 'coder stop ${ref}' failed." >&2
    failed_refs+=("${ref}")
    continue
  fi
  if ! "${coder_bin}" start "${ref}" --yes; then
    echo "ERROR: 'coder start ${ref}' failed." >&2
    failed_refs+=("${ref}")
    continue
  fi

  owner="${ref%%/*}"
  name="${ref##*/}"
  reconnected=false
  for _ in $(seq 1 30); do
    sleep 2
    poll_json="$(curl -sf "${coder_url}/api/v2/users/${owner}/workspace/${name}" \
      -H "Coder-Session-Token: ${session_token}")" || continue
    poll_statuses="$(echo "${poll_json}" | python3 -c '
import json, sys
data = json.load(sys.stdin)
statuses = []
for res in data.get("latest_build", {}).get("resources", []) or []:
    for agent in res.get("agents", []) or []:
        statuses.append(agent.get("status", "unknown"))
print(",".join(statuses))
')"
    if [ -n "${poll_statuses}" ] && [[ "${poll_statuses}" != *"disconnected"* ]] && [[ "${poll_statuses}" == *"connected"* ]]; then
      reconnected=true
      break
    fi
  done

  if [ "${reconnected}" = true ]; then
    echo "OK: ${ref} agent is now connected."
    restarted_refs+=("${ref}")
  else
    echo "ERROR: ${ref} did not reach a connected agent state after restart (waited 60s)." >&2
    failed_refs+=("${ref}")
  fi
done

echo ""
echo "=== Summary ==="
echo "Disconnected workspaces found: ${#disconnected_refs[@]}"
echo "Successfully restarted and reconnected: ${#restarted_refs[@]}"
for ref in "${restarted_refs[@]}"; do
  echo "  - ${ref}"
done
if [ "${#failed_refs[@]}" -gt 0 ]; then
  echo "Failed to recover: ${#failed_refs[@]}"
  for ref in "${failed_refs[@]}"; do
    echo "  - ${ref}"
  done
  exit 1
fi

echo "All disconnected workspaces recovered."
