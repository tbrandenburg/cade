#!/usr/bin/env bash
# Issue #9 gap-fill: a self-contained "opa test + decision-API smoke check"
# that does NOT require the whole platform stack (compose.yaml's `opa`,
# `lab-sim`, etc.) to be up. Runs a throwaway, job-scoped `opa` container
# against the current governance/opa/policy/*.rego files, so it can be
# invoked from a plain CI runner (GitHub Actions) or locally, unlike
# scripts/verify-governance.sh which requires a live `docker compose up`
# stack (opa + lab-sim + the M11 MCP venv).
#
# This intentionally mirrors, but does not replace, the live
# reload-opa-policy.sh / verify-governance.sh pair: those two prove the
# *running* opa container has picked up a policy change on this single
# host; this script proves the *merged* policy is provably correct before
# it ever reaches that host (docs/security.md "OPA policy reload").
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY_DIR="${REPO_ROOT}/governance/opa/policy"
OPA_IMAGE="openpolicyagent/opa:1.9.0"
CONTAINER_NAME="opa-policy-check-$$"

cleanup() {
	docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> [1/2] opa test ${POLICY_DIR}"
docker run --rm -v "${POLICY_DIR}:/policy:ro" "${OPA_IMAGE}" test /policy

echo ""
echo "==> [2/2] Job-scoped decision-API smoke check (no full platform stack)"
docker run -d --name "${CONTAINER_NAME}" -p 18181:8181 \
	-v "${POLICY_DIR}:/policy:ro" "${OPA_IMAGE}" \
	run --server --addr 0.0.0.0:8181 /policy >/dev/null

ready=false
for _ in $(seq 1 20); do
	if curl -sf http://127.0.0.1:18181/health >/dev/null 2>&1; then
		ready=true
		break
	fi
	sleep 0.5
done
if [ "${ready}" != "true" ]; then
	echo "FAIL: job-scoped opa container did not become responsive" >&2
	docker logs "${CONTAINER_NAME}" >&2 || true
	exit 1
fi

LAB_DECISION=$(curl -s -X POST http://127.0.0.1:18181/v1/data/lab/authz/allow \
	-d '{"input":{"action":"run_test"}}')
echo "    lab/authz/allow(run_test) -> ${LAB_DECISION}"
echo "${LAB_DECISION}" | grep -q '"result":true' || {
	echo "FAIL: expected lab.authz run_test to be ALLOWed (got: ${LAB_DECISION})" >&2
	exit 1
}

FLASH_DENY_DECISION=$(curl -s -X POST http://127.0.0.1:18181/v1/data/lab/authz/allow \
	-d '{"input":{"action":"flash_device","approved":false}}')
echo "    lab/authz/allow(flash_device, unapproved) -> ${FLASH_DENY_DECISION}"
echo "${FLASH_DENY_DECISION}" | grep -q '"result":false' || {
	echo "FAIL: expected unapproved flash_device to be DENIED (got: ${FLASH_DENY_DECISION})" >&2
	exit 1
}

BUILD_DECISION=$(curl -s -X POST http://127.0.0.1:18181/v1/data/build/authz/allow \
	-d '{"input":{"image":"cade/coder-workspace:latest"}}')
echo "    build/authz/allow(image=cade/coder-workspace:latest) -> ${BUILD_DECISION}"
echo "${BUILD_DECISION}" | grep -q '"result":true' || {
	echo "FAIL: expected known-good build image to be ALLOWed (got: ${BUILD_DECISION})" >&2
	exit 1
}

BUILD_DENY_DECISION=$(curl -s -X POST http://127.0.0.1:18181/v1/data/build/authz/allow \
	-d '{"input":{"image":"evil/unknown:latest"}}')
echo "    build/authz/allow(image=evil/unknown:latest) -> ${BUILD_DENY_DECISION}"
echo "${BUILD_DENY_DECISION}" | grep -q '"result":false' || {
	echo "FAIL: expected unknown build image to be DENIED (got: ${BUILD_DENY_DECISION})" >&2
	exit 1
}

echo ""
echo "OPA policy check OK: opa test passed, lab.authz and build.authz both"
echo "verified ALLOW/DENY as expected on a job-scoped opa server."
