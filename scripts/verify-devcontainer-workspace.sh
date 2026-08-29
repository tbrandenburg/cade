#!/usr/bin/env bash
# Read-only validation for the `devcontainer` Coder template (issue #6 MVP,
# hardening follow-up issue #6b). Does NOT run `coder create` or mutate the
# live stack -- see AGENTS.md's note on why a full live E2E (workspace
# create, inner-container inspect, Durability Test 3) needs a documented
# `coder login` bootstrap this environment did not have. This script only
# proves the artifacts an integrator needs before attempting that live E2E
# are present and structurally valid:
#   1. `coder/templates/devcontainer/main.tf`/`variables.tf` exist and
#      `terraform validate` passes.
#   2. The pre-built `cade/devcontainer-bootstrap:latest` outer/bootstrap
#      image (built by `make devcontainer-workspace-build`) exists locally.
#   3. `examples/hello-service/.devcontainer/devcontainer.json` is valid JSON.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

TEMPLATE_DIR="coder/templates/devcontainer"

echo "==> [1/3] Terraform template files present"
for f in main.tf variables.tf; do
	if [ ! -f "${TEMPLATE_DIR}/${f}" ]; then
		echo "FAIL: ${TEMPLATE_DIR}/${f} not found" >&2
		exit 1
	fi
	echo "    found ${TEMPLATE_DIR}/${f}"
done

echo ""
echo "==> [1/3] terraform validate"
docker run --rm -v "${REPO_ROOT}/${TEMPLATE_DIR}:/tf" -w /tf hashicorp/terraform:1.9 init -backend=false >/dev/null
docker run --rm -v "${REPO_ROOT}/${TEMPLATE_DIR}:/tf" -w /tf hashicorp/terraform:1.9 validate || {
	echo "FAIL: terraform validate failed for ${TEMPLATE_DIR}" >&2
	exit 1
}

echo ""
echo "==> [2/3] cade/devcontainer-bootstrap:latest image present locally"
if ! docker image inspect cade/devcontainer-bootstrap:latest >/dev/null 2>&1; then
	echo "FAIL: cade/devcontainer-bootstrap:latest not found -- run 'make devcontainer-workspace-build' first" >&2
	exit 1
fi
echo "    found cade/devcontainer-bootstrap:latest"

echo ""
echo "==> [3/3] Reference devcontainer.json files are valid JSON"
for f in \
	examples/hello-service/.devcontainer/devcontainer.json \
	examples/embedded-sim/.devcontainer/devcontainer.json; do
	if [ ! -f "${f}" ]; then
		echo "FAIL: ${f} not found" >&2
		exit 1
	fi
	jq empty "${f}" || {
		echo "FAIL: ${f} is not valid JSON" >&2
		exit 1
	}
	echo "    ${f} is valid JSON"
done

echo ""
echo "=================================================================="
echo "devcontainer workspace verification PASSED (read-only checks only:"
echo "terraform validate, bootstrap image present, reference"
echo "devcontainer.json files valid). A live 'coder create --template"
echo "devcontainer' E2E still requires an authenticated Coder session --"
echo "not covered by this script."
echo "=================================================================="
