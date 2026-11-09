#!/usr/bin/env bash
# Install scripts/requirements-template-publishing.txt in a venv; set PYTHON to its interpreter.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${PYTHON:-python3}" "${SCRIPT_DIR}/template_vars.py" "$@"
