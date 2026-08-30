#!/usr/bin/env bash
# load-security-profiles.sh — Idempotent host-level loader for the scoped
# AppArmor profile that `coder/security-profiles/apparmor-bwrap-workspace`
# ships (Issue #23).
#
# Background: `srt` (which wraps `opencode`/`pi` by default in the
# `agent-workspace`, `docker-standard`, and `embedded-linux` Coder
# templates) shells out to `bwrap`, which needs to (1) create an
# unprivileged user namespace and (2) perform one `mount --make-rslave`
# remount immediately after entering it. Docker's default seccomp profile
# blocks (1); Docker's default `docker-default` AppArmor profile blocks
# (2). This repo ships two *scoped* replacements (not `unconfined`) under
# `coder/security-profiles/`:
#   - `seccomp-bwrap-userns.json` — referenced directly by path/content from
#     each affected template's own Terraform (`docker_container.security_opts`,
#     via `file()`), so it needs NO host-level action; it just works.
#   - `apparmor-bwrap-workspace` — an AppArmor profile SOURCE file. Unlike
#     seccomp, Docker/AppArmor cannot load a raw profile file at
#     `docker run` time; the profile must be compiled and loaded into the
#     kernel once, ahead of time, via `apparmor_parser`. THIS is the one
#     remaining manual step this script performs.
#
# This script only ever loads/reloads this one repo-owned profile — it
# never touches, unloads, or otherwise modifies any other AppArmor profile
# already loaded on the host (including Docker's own `docker-default`).
#
# HARD REQUIREMENT for the three affected Coder templates: any workspace
# created from a template that references `apparmor=cade-bwrap-workspace`
# in its `security_opts` will FAIL to start with "unable to apply apparmor
# profile" until this script has been run at least once on the Docker
# host backing the Coder server (verified live 2026-08-30, see Issue #23's
# handoff/AGENTS.md for the exact command/error). Re-run after any host
# reboot or after `apparmor_parser` state is otherwise lost -- this load
# is NOT persisted by systemd/dpkg the way a package-installed profile
# would be (this profile ships as a repo file, not a package).
#
# Usage: scripts/load-security-profiles.sh [--dry-run]
# Exit code: 0 on success (or dry-run), 1 on any failure.
#
# NOTE: this script requires root (`apparmor_parser` cannot load/replace a
# kernel-resident profile as a non-root user). It is intentionally never
# invoked automatically or with sudo by any `make`/CI target in this repo
# -- it is meant to be run manually, once, by a human operator with
# legitimate host-level access, per this repo's safety policy of never
# having an agent session run privileged host-mutating commands itself.

set -u

PROFILE_NAME="cade-bwrap-workspace"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_SRC="${REPO_ROOT}/coder/security-profiles/apparmor-bwrap-workspace"
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 [--dry-run]" >&2
      exit 1
      ;;
  esac
done

if [ ! -f "$PROFILE_SRC" ]; then
  echo "[FAIL] AppArmor profile source not found: $PROFILE_SRC" >&2
  exit 1
fi

if ! command -v apparmor_parser >/dev/null 2>&1; then
  echo "[FAIL] apparmor_parser not found on PATH -- install apparmor-utils" >&2
  exit 1
fi

echo "== cade security-profile loader (Issue #23) =="
echo "Profile:      $PROFILE_NAME"
echo "Source file:  $PROFILE_SRC"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "[DRY-RUN] Would run: apparmor_parser -r -W \"$PROFILE_SRC\""
  echo "[DRY-RUN] Would then verify with: aa-status --json | grep -q \"$PROFILE_NAME\""
  exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "[FAIL] This script must be run as root (apparmor_parser requires it)." >&2
  echo "       Re-run with: sudo scripts/load-security-profiles.sh" >&2
  exit 1
fi

# -r: replace if already loaded (idempotent re-run-safe).
# -W: warn (not fail) on unknown/obsolete rule syntax rather than aborting,
#     while still failing hard on genuine parse errors.
if apparmor_parser -r -W "$PROFILE_SRC"; then
  echo "[PASS] Loaded/replaced AppArmor profile: $PROFILE_NAME"
else
  echo "[FAIL] apparmor_parser failed to load $PROFILE_SRC" >&2
  exit 1
fi

if command -v aa-status >/dev/null 2>&1; then
  if aa-status 2>/dev/null | grep -q "$PROFILE_NAME"; then
    echo "[PASS] Verified profile is active: aa-status lists $PROFILE_NAME"
  else
    echo "[WARN] apparmor_parser succeeded but aa-status does not list $PROFILE_NAME yet" >&2
  fi
else
  echo "[WARN] aa-status not found, skipping post-load verification" >&2
fi

exit 0
