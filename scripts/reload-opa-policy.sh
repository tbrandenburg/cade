#!/usr/bin/env bash
# Restart the live `opa` container so it picks up the current
# governance/opa/policy/*.rego files. The policy dir is bind-mounted
# read-only (compose.yaml, service `opa`) and OPA's `run --server` mode
# does NOT hot-reload that mount - only a process restart re-reads it.
#
# Steps:
#   1. `docker compose restart opa`.
#   2. Poll OPA's health endpoint until it responds again (bounded retries).
#   3. Smoke-query both known policy packages (build.authz, lab.authz) to
#      confirm the restarted server actually has them loaded.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

echo "==> Restarting opa container to pick up current governance/opa/policy/*.rego"
docker compose restart opa

echo ""
echo "==> Waiting for OPA to become responsive"
ready=false
for _ in $(seq 1 10); do
	if curl -sf http://127.0.0.1:8181/health >/dev/null 2>&1; then
		ready=true
		break
	fi
	sleep 1
done
if [ "${ready}" != "true" ]; then
	echo "FAIL: OPA did not become responsive after restart" >&2
	exit 1
fi
echo "    OPA is responsive"

echo ""
echo "==> Smoke query: lab.authz.allow"
LAB_DECISION=$(curl -s -X POST http://127.0.0.1:8181/v1/data/lab/authz/allow \
	-d '{"input":{"action":"run_test"}}')
echo "    lab/authz/allow(run_test) -> ${LAB_DECISION}"
echo "${LAB_DECISION}" | grep -q '"result"' || {
	echo "FAIL: lab.authz policy not loaded after opa restart (got: ${LAB_DECISION})" >&2
	exit 1
}

echo ""
echo "==> Smoke query: build.authz.allow"
BUILD_DECISION=$(curl -s -X POST http://127.0.0.1:8181/v1/data/build/authz/allow \
	-d '{"input":{"image":"cade/coder-workspace:latest"}}')
echo "    build/authz/allow(image=cade/coder-workspace:latest) -> ${BUILD_DECISION}"
echo "${BUILD_DECISION}" | grep -q '"result":true' || {
	echo "FAIL: build.authz policy not loaded after opa restart (got: ${BUILD_DECISION})" >&2
	exit 1
}

echo ""
echo "OPA policy reload OK: opa restarted, both lab.authz and build.authz loaded."
