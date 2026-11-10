#!/usr/bin/env bash
# make up's best-effort unseal only; never initialize, provision, or rotate.
set +x
set -euo pipefail
exec python3 "$(dirname "${BASH_SOURCE[0]}")/openbao_admin.py" --reunseal-only
