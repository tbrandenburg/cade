#!/usr/bin/env bash
# Reconciles coder/ai/providers.yaml and coder/ai/models.yaml into a running
# Coder server. Single entrypoint for `make ai-bootstrap`.
#
# Usage: scripts/ai-bootstrap.sh [--best-effort]
#   --best-effort   exit 0 instead of 1 if Coder is unreachable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load .env from repo root if present, without overwriting already-exported
# variables (an explicit shell env always wins over the file).
if [[ -f "${REPO_ROOT}/.env" ]]; then
  while IFS= read -r line || [[ -n "${line}" ]]; do
    # Skip blank lines and comments.
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    key="${line%%=*}"
    key="${key%"${key##*[![:space:]]}"}"
    [[ -z "${key}" ]] && continue
    # Only set if not already exported.
    if [[ -z "${!key:-}" ]]; then
      export "${line?}"
    fi
  done < "${REPO_ROOT}/.env"
fi

if [[ -z "${CODER_SESSION_TOKEN:-}" ]]; then
  echo "SKIP: CODER_SESSION_TOKEN not set — run 'make ai-token' then re-run 'make ai-bootstrap'."
  exit 0
fi

exec python3 "${SCRIPT_DIR}/ai_bootstrap.py" "$@"
