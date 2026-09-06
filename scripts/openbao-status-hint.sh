#!/usr/bin/env bash
# Issue #128: `make status` wrapper. Runs the same plain
# `docker compose ps` operators already rely on, unchanged, then appends
# one actionable hint line if `openbao` is unhealthy specifically because
# it's sealed (the most common cause - see scripts/openbao-reunseal.sh /
# scripts/openbao-init.sh).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

docker compose ps

HEALTH=$(docker inspect openbao --format '{{.State.Health.Status}}' 2>/dev/null || true)
if [[ "${HEALTH}" != "unhealthy" ]]; then
	exit 0
fi

BAO_ADDR="https://127.0.0.1:8200"
STATUS_JSON=$(docker exec openbao bao status -tls-skip-verify -address="${BAO_ADDR}" -format=json 2>/dev/null || true)
SEALED=$(echo "${STATUS_JSON}" | python3 -c "import json,sys
try:
    print(json.load(sys.stdin)['sealed'])
except Exception:
    print('unknown')" 2>/dev/null || echo "unknown")

if [[ "${SEALED}" == "True" || "${SEALED}" == "true" ]]; then
	echo ""
	echo "HINT: openbao is unhealthy because it is sealed (Sealed: true)."
	echo "      Run 'make up' again (auto-reunseal) or 'make governance-bootstrap' to unseal it manually."
fi
