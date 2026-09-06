#!/usr/bin/env bash
# Issue #128: automatic re-unseal, folded into `make up`. OpenBao's unseal
# state is in-memory only (Shamir seal, no auto-unseal mechanism) - any
# container restart/recreate drops it and `bao status` starts exiting
# non-zero, which the compose healthcheck reports as `(unhealthy)` forever
# until an operator notices and manually re-runs `make governance-bootstrap`.
#
# This script replays ONLY the unseal step using the key shares already
# recorded in governance/openbao/unseal/init.json (written by
# scripts/openbao-init.sh on first-ever bootstrap). It deliberately does
# NOT touch credential rotation, AppRole/policy setup, or root-token
# revocation - see scripts/openbao-init.sh for that (opt-in via
# FORCE_ROTATE=1 for routine re-unseal-only runs).
#
# Safe/best-effort by design: exits 0 in every case where there is nothing
# actionable to do here (openbao not up yet, never initialized, init.json
# missing, or already unsealed) so `make up` never fails because of this
# step - the operator-owned first-time bootstrap remains
# `make governance-bootstrap`.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

BAO_ADDR="https://127.0.0.1:8200"
INIT_FILE="${REPO_ROOT}/governance/openbao/unseal/init.json"

# Wait (briefly) for the openbao container to exist and answer at all - it
# may still be starting right after `docker compose up -d`. `bao status`
# exits non-zero both when sealed (2) and when unreachable, so probe by
# content (a parseable JSON status), not exit code.
STATUS_JSON=""
for _ in $(seq 1 20); do
	CANDIDATE=$(docker exec openbao bao status -tls-skip-verify -address="${BAO_ADDR}" -format=json 2>/dev/null || true)
	if echo "${CANDIDATE}" | python3 -c "import json,sys; json.load(sys.stdin)" >/dev/null 2>&1; then
		STATUS_JSON="${CANDIDATE}"
		break
	fi
	sleep 2
done

if [[ -z "${STATUS_JSON}" ]]; then
	echo "SKIP: openbao-reunseal - container not reachable yet, leaving it to the next 'make up' or a manual 'make governance-bootstrap'."
	exit 0
fi

INITIALIZED=$(echo "${STATUS_JSON}" | python3 -c "import json,sys
try:
    print(json.load(sys.stdin)['initialized'])
except Exception:
    print('false')")
SEALED=$(echo "${STATUS_JSON}" | python3 -c "import json,sys
try:
    print(json.load(sys.stdin)['sealed'])
except Exception:
    print('true')")

if [[ "${INITIALIZED}" != "True" && "${INITIALIZED}" != "true" ]]; then
	echo "SKIP: openbao-reunseal - not yet initialized. Run 'make governance-bootstrap' for first-time bootstrap."
	exit 0
fi

if [[ "${SEALED}" != "True" && "${SEALED}" != "true" ]]; then
	echo "openbao-reunseal: already unsealed, nothing to do."
	exit 0
fi

if [[ ! -f "${INIT_FILE}" ]]; then
	echo "SKIP: openbao-reunseal - openbao is sealed but ${INIT_FILE} is missing, cannot unseal without the recorded key shares. Restore it from the out-of-band store, then run 'make governance-bootstrap'."
	exit 0
fi

UNSEAL_KEYS=$(python3 -c "import json; print('\n'.join(json.load(open('${INIT_FILE}'))['unseal_keys_b64'][:3]))" 2>/dev/null || true)
if [[ -z "${UNSEAL_KEYS}" ]]; then
	echo "SKIP: openbao-reunseal - ${INIT_FILE} did not contain usable unseal keys."
	exit 0
fi

echo "==> openbao is sealed - replaying unseal (3-of-5 threshold) from ${INIT_FILE}"
while IFS= read -r key; do
	docker exec openbao bao operator unseal -tls-skip-verify -address="${BAO_ADDR}" "${key}" >/dev/null 2>&1 || true
done <<<"${UNSEAL_KEYS}"

STATUS_JSON_AFTER=$(docker exec openbao bao status -tls-skip-verify -address="${BAO_ADDR}" -format=json 2>/dev/null || true)
SEALED_AFTER=$(echo "${STATUS_JSON_AFTER}" | python3 -c "import json,sys
try:
    print(json.load(sys.stdin)['sealed'])
except Exception:
    print('true')")

if [[ "${SEALED_AFTER}" == "True" || "${SEALED_AFTER}" == "true" ]]; then
	echo "WARNING: openbao-reunseal - still sealed after replay attempt. Run 'make governance-bootstrap' manually."
	exit 0
fi

echo "openbao-reunseal: unsealed successfully."
