#!/usr/bin/env bash
# `make status` wrapper. Runs the same plain `docker compose ps` operators
# already rely on, unchanged, then appends actionable hint lines for the
# handful of services whose unhealthy/restarting state has a known,
# one-line fix - so a fresh-environment `make status` doesn't read like an
# unexplained failure.
#   - Issue #128: openbao unhealthy because it's sealed (see
#     scripts/openbao-reunseal.sh / scripts/openbao-init.sh).
#   - registry restart-looping because it's never been bootstrapped (see
#     the `registry-bootstrap` Makefile target's own doc comment).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

docker compose ps

HEALTH=$(docker inspect openbao --format '{{.State.Health.Status}}' 2>/dev/null || true)
if [[ "${HEALTH}" == "unhealthy" ]]; then
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
fi

REGISTRY_STATE=$(docker inspect registry --format '{{.State.Status}}' 2>/dev/null || true)
if [[ "${REGISTRY_STATE}" == "restarting" && ! -f "${REPO_ROOT}/cache/registry/auth/htpasswd" ]]; then
	echo ""
	echo "HINT: registry is restart-looping because it has never been bootstrapped."
	echo "      Run 'make registry-bootstrap USER=<user> PASSWORD=<password>' (one-time, credentials are operator-chosen)."
fi
