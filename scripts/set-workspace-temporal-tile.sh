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
# Issue #60: the actual "fetch current params, stop-if-running, single
# `coder start --always-prompt --parameter ...`" mechanics that used to
# live directly in this file have been extracted, unchanged, into the
# generic scripts/set-workspace-parameter.sh (reused by
# scripts/set-workspace-jupyter.sh and scripts/set-workspace-nodered.sh
# too) — this file is now a thin wrapper around that generic script,
# keeping its own filename and CLI contract byte-compatible (referenced
# in AGENTS.md and docs). See scripts/set-workspace-parameter.sh for the
# full mechanics/gotcha writeup (`coder update`'s two-separate-builds
# footgun, resending every current parameter value).
#
# Usage:
#   scripts/set-workspace-temporal-tile.sh <owner>/<workspace> [true|false]
#   scripts/set-workspace-temporal-tile.sh <workspace> [true|false]   # current user
#
# Examples:
#   scripts/set-workspace-temporal-tile.sh temporal-svc/tw-demo        # enable (default)
#   scripts/set-workspace-temporal-tile.sh temporal-svc/tw-demo true   # enable, explicit
#   scripts/set-workspace-temporal-tile.sh temporal-svc/tw-demo false  # disable

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: $0 <owner>/<workspace>|<workspace> [true|false]" >&2
  exit 1
fi

value="${2:-true}"
if [ "${value}" != "true" ] && [ "${value}" != "false" ]; then
  echo "ERROR: second argument must be 'true' or 'false' (got: ${value})" >&2
  exit 1
fi

exec "${script_dir}/set-workspace-parameter.sh" "$1" temporal_owned "${value}"
