#!/usr/bin/env bash
# Detects drift between cade's canonical repository identity/visibility
# assumptions (.env's REPO_SLUG / ASSUMED_VISIBILITY) and live GitHub reality
# (Issue #102).
#
# This is a warn-only drift *detector*, not a gate -- it never fails unless
# --exit-code is passed explicitly (reserved for future CI use; not used by
# `make doctor` today). Every environment-dependent condition (gh missing,
# gh unauthenticated, REPO_SLUG unset) degrades gracefully to a warning,
# following scripts/doctor.sh's check_security_profiles precedent exactly.
#
# Usage: scripts/verify-repo-identity.sh [--exit-code]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

EXIT_CODE_ON_DRIFT=0
for arg in "$@"; do
  case "$arg" in
    --exit-code) EXIT_CODE_ON_DRIFT=1 ;;
  esac
done

if [ -t 1 ]; then
  C_GREEN='\033[0;32m'
  C_YELLOW='\033[0;33m'
  C_RESET='\033[0m'
else
  C_GREEN=''
  C_YELLOW=''
  C_RESET=''
fi

DRIFT_FOUND=0

pass() {
  printf "${C_GREEN}[PASS]${C_RESET} %s\n" "$1"
}

warn() {
  printf "${C_YELLOW}[WARN]${C_RESET} %s\n" "$1"
  DRIFT_FOUND=1
}

# Load .env from repo root if present, without overwriting already-exported
# variables (matches scripts/verify-template-vars.sh:34-46's exact convention).
if [[ -f "${REPO_ROOT}/.env" ]]; then
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    key="${line%%=*}"
    key="${key%"${key##*[![:space:]]}"}"
    [[ -z "${key}" ]] && continue
    if [[ -z "${!key:-}" ]]; then
      export "${line?}"
    fi
  done < "${REPO_ROOT}/.env"
fi

if ! command -v gh >/dev/null 2>&1; then
  warn "gh not found -- cannot verify repo identity/visibility drift"
  exit 0
fi

if ! gh auth status >/dev/null 2>&1; then
  warn "gh not authenticated -- skipping identity/visibility drift check"
  exit 0
fi

if [[ -z "${REPO_SLUG:-}" ]]; then
  warn "REPO_SLUG not set in .env -- see .env.example (Issue #102)"
  exit 0
fi

REPO_INFO="$(gh repo view "${REPO_SLUG}" --json nameWithOwner,visibility,isFork,parent 2>&1)"
if [[ $? -ne 0 ]]; then
  warn "gh repo view '${REPO_SLUG}' failed -- cannot verify identity/visibility drift: ${REPO_INFO}"
  exit 0
fi

LIVE_NAME="$(echo "${REPO_INFO}" | jq -r '.nameWithOwner')"
LIVE_VISIBILITY="$(echo "${REPO_INFO}" | jq -r '.visibility')"
LIVE_IS_FORK="$(echo "${REPO_INFO}" | jq -r '.isFork')"
LIVE_PARENT="$(echo "${REPO_INFO}" | jq -r '.parent.nameWithOwner // empty')"

if [[ "${LIVE_NAME}" != "${REPO_SLUG}" ]]; then
  warn "live nameWithOwner '${LIVE_NAME}' != REPO_SLUG '${REPO_SLUG}'"
else
  pass "live nameWithOwner matches REPO_SLUG (${REPO_SLUG})"
fi

ASSUMED_VISIBILITY_NORM="$(echo "${ASSUMED_VISIBILITY:-public}" | tr '[:upper:]' '[:lower:]')"
LIVE_VISIBILITY_NORM="$(echo "${LIVE_VISIBILITY}" | tr '[:upper:]' '[:lower:]')"
if [[ "${LIVE_VISIBILITY_NORM}" != "${ASSUMED_VISIBILITY_NORM}" ]]; then
  warn "live visibility '${LIVE_VISIBILITY}' != ASSUMED_VISIBILITY '${ASSUMED_VISIBILITY:-public}' -- update ASSUMED_VISIBILITY in .env if deliberate"
else
  pass "live visibility matches ASSUMED_VISIBILITY (${ASSUMED_VISIBILITY_NORM})"
fi

if [[ "${LIVE_IS_FORK}" == "true" ]]; then
  warn "this checkout's target (${REPO_SLUG}) is a fork of '${LIVE_PARENT}' -- trust assumptions in docs/security.md do not apply"
else
  pass "not a fork"
fi

if [[ "${DRIFT_FOUND}" -eq 0 ]]; then
  pass "no repo identity/visibility drift detected"
fi

if [[ "${EXIT_CODE_ON_DRIFT}" -eq 1 && "${DRIFT_FOUND}" -eq 1 ]]; then
  exit 1
fi
exit 0
