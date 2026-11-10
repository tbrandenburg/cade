#!/usr/bin/env bash
# Bootstrap, resume, provision an operator, or explicitly rotate CADE secrets.
# Secret input is handled privately by the Python helper; never enable tracing.
set +x
set -euo pipefail
exec python3 "$(dirname "${BASH_SOURCE[0]}")/openbao_admin.py" "$@"
