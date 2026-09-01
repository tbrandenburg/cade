#!/usr/bin/env bash
# Detects server-side Coder template-variable drift (Issue #73).
#
# Coder persists Terraform-managed template variable *values* server-side,
# independent of each .tf file's `default`, across every `templates push`
# (Terraform-Cloud-style workspace variables) -- unless a push explicitly
# overrides them with `--variable`. This means a variable's `.tf` default can
# change (e.g. the devenv-cloud -> cade rebrand) without ever taking effect
# on an already-pushed template, silently, with no error at push time or at
# workspace-create time.
#
# This script fetches each of the 4 live templates' active-version variables
# via the Coder API and diffs each variable's live `value` against its
# `default` as declared in that template's own `variables.tf`, printing a
# PASS/DRIFT line per variable and failing loudly (non-zero exit) if any
# live value differs from its `.tf` default.
#
# A live value that legitimately differs from the `.tf` default on purpose
# (a deliberate override) is not distinguished from an accidental one by
# this script -- per Issue #73's acceptance criteria, any such override must
# be handled by updating the `.tf` default itself (so the two stay in sync)
# rather than left as a silent, undocumented drift.
#
# Usage: scripts/verify-template-vars.sh
# Requires: CODER_SESSION_TOKEN env var (or ~/.config/coderv2/session, same
# fallback the `coder` CLI itself uses) and the Coder server reachable at
# CODER_URL (default http://localhost:7080).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CODER_URL="${CODER_URL:-http://localhost:7080}"

# Load .env from repo root if present, without overwriting already-exported
# variables (matches scripts/ai-bootstrap.sh's convention).
if [[ -f "${REPO_ROOT}/.env" ]]; then
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    key="${line%%=*}"
    key="${key%"${key##*[![:space:]]}"}"
    [[ -z "${key}" ]] && continue
    if [[ -z "${!key:-}" ]]; then
      export "${line?}"
    fi
  done < "${REPO_ROOT}/.env"
fi

TOKEN="${CODER_SESSION_TOKEN:-}"
if [[ -z "${TOKEN}" && -f "${HOME}/.config/coderv2/session" ]]; then
  TOKEN="$(cat "${HOME}/.config/coderv2/session")"
fi
if [[ -z "${TOKEN}" ]]; then
  echo "SKIP: no Coder session token available (set CODER_SESSION_TOKEN or run 'coder login')." >&2
  exit 0
fi

# dir-name:template-name pairs. Confirmed live via 'coder templates list'
# (per AGENTS.md's stale-docker-standard lesson -- never assume names).
declare -A TEMPLATE_MAP=(
  [docker-workspace]="docker-workspace"
  [embedded-linux]="embedded-linux"
  [devcontainer]="devcontainer"
  [agent-workspace]="agent-workspace"
)

overall_status=0

for dir in docker-workspace embedded-linux devcontainer agent-workspace; do
  tf_name="${TEMPLATE_MAP[${dir}]}"
  vars_tf="${REPO_ROOT}/coder/templates/${dir}/variables.tf"

  if [[ ! -f "${vars_tf}" ]]; then
    echo "FAIL: ${vars_tf} not found"
    overall_status=1
    continue
  fi

  active_version_id="$(curl -sf -H "Coder-Session-Token: ${TOKEN}" \
    "${CODER_URL}/api/v2/templates" \
    | python3 -c "
import json, sys
name = sys.argv[1]
data = json.load(sys.stdin)
for t in data:
    if t['name'] == name:
        print(t['active_version_id'])
        break
" "${tf_name}")"

  if [[ -z "${active_version_id}" ]]; then
    echo "FAIL: could not resolve active_version_id for template '${tf_name}' (is it pushed?)"
    overall_status=1
    continue
  fi

  live_vars_json="$(curl -sf -H "Coder-Session-Token: ${TOKEN}" \
    "${CODER_URL}/api/v2/templateversions/${active_version_id}/variables")"

  echo "=== ${tf_name} (${dir}/variables.tf) ==="

  drift_found="$(python3 - "${vars_tf}" "${live_vars_json}" <<'PYEOF'
import json, re, sys

vars_tf_path = sys.argv[1]
live_vars = json.loads(sys.argv[2])

with open(vars_tf_path, "r", encoding="utf-8") as f:
    tf_text = f.read()

# Minimal, dependency-free parse of each `variable "<name>" { ... default = "<value>" ... }`
# block. Good enough for this repo's variables.tf files (single-line string
# defaults only) -- not a general HCL parser.
tf_defaults = {}
for block_match in re.finditer(r'variable\s+"([^"]+)"\s*{([^}]*)}', tf_text, re.DOTALL):
    name, body = block_match.group(1), block_match.group(2)
    default_match = re.search(r'default\s*=\s*"([^"]*)"', body)
    if default_match:
        tf_defaults[name] = default_match.group(1)

any_drift = False
for v in live_vars:
    name = v["name"]
    live_value = v["value"]
    if name not in tf_defaults:
        # Variable has no string default in .tf (e.g. required, no default) -- skip.
        continue
    tf_default = tf_defaults[name]
    if live_value == tf_default:
        print(f"  PASS  {name}")
    else:
        any_drift = True
        print(f"  DRIFT {name}: live={live_value!r} .tf default={tf_default!r}")

print("DRIFT_FOUND" if any_drift else "NO_DRIFT")
PYEOF
)"

  echo "${drift_found}" | grep -v '^DRIFT_FOUND$\|^NO_DRIFT$' || true

  if echo "${drift_found}" | grep -q '^DRIFT_FOUND$'; then
    overall_status=1
  fi
done

if [[ "${overall_status}" -ne 0 ]]; then
  echo
  echo "FAIL: template-variable drift detected -- see DRIFT lines above."
  echo "Fix with: coder templates push <name> -d coder/templates/<dir> --yes --variable '<name>=<tf-default>' ..."
  exit 1
fi

echo
echo "PASS: all live template variables match their .tf defaults."
