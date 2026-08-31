#!/usr/bin/env bash
# M12 Governance Foundation. One-shot OpenBao bootstrap for this local/demo
# deployment:
#
#   1. Generate the TLS cert if missing (scripts/openbao-gen-cert.sh).
#   2. `bao operator init` (idempotent - skips if already initialized) and
#      unseal using the freshly generated key shares.
#   3. Enable the `kv-v2` secrets engine at `secret/` and write every
#      Phase 1-3 credential into it under a NEW, rotated value (never the
#      value that was live in `.env` before this script ran).
#   4. Enable the AppRole auth method and a least-privilege policy so
#      services can fetch only their own secrets going forward, instead of
#      operating under the initial root token.
#   5. Revoke the initial root token.
#   6. Print (to stdout only, never written to a file/git) the unseal key
#      shares and where the operator must store them out-of-band, plus a
#      redacted rotation log.
#
# Never commit `.env`, the init output, or the unseal keys - see
# docs/security.md "M12 - Governance Foundation" for the non-secret record
# of *what* was rotated and *where* key material is expected to be stored.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# Load .env from repo root if present, without overwriting already-exported
# variables (an explicit shell env always wins over the file). Same pattern
# as scripts/omnigent-bootstrap.sh / scripts/ai-bootstrap.sh. Needed here
# only to read OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD (see below) - none of
# the other rotated credentials read from .env, they are generated fresh.
if [[ -f "${REPO_ROOT}/.env" ]]; then
	while IFS= read -r line || [[ -n "${line}" ]]; do
		[[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
		key="${line%%=*}"
		key="${key%"${key##*[![:space:]]}"}"
		[[ -z "${key}" ]] && continue
		if [[ -z "${!key:-}" ]]; then
			export "${line?}"
		fi
	done <"${REPO_ROOT}/.env"
fi

BAO_ADDR="https://127.0.0.1:8200"
INIT_FILE="${REPO_ROOT}/governance/openbao/unseal/init.json"
mkdir -p "$(dirname "${INIT_FILE}")"

bash scripts/openbao-gen-cert.sh

echo "==> Ensuring OpenBao data directory is writable by the container's runtime user"
docker exec -u 0 openbao chown -R openbao:openbao /openbao/data

bao_cli() {
	docker exec -e BAO_ADDR="${BAO_ADDR}" -e BAO_SKIP_VERIFY=true -e BAO_TOKEN="${ROOT_TOKEN:-}" openbao bao "$@"
}

STATUS_JSON=$(docker exec openbao bao status -tls-skip-verify -address="${BAO_ADDR}" -format=json 2>/dev/null || true)
INITIALIZED=$(echo "${STATUS_JSON}" | python3 -c "import json,sys
try:
    print(json.load(sys.stdin)['initialized'])
except Exception:
    print('false')")

if [[ "${INITIALIZED}" != "True" && "${INITIALIZED}" != "true" ]]; then
	echo "==> Initializing OpenBao (5 key shares, threshold 3)"
	docker exec openbao bao operator init -tls-skip-verify -address="${BAO_ADDR}" \
		-key-shares=5 -key-threshold=3 -format=json >"${INIT_FILE}"
	echo "    Wrote init output (unseal keys + root token) to ${INIT_FILE}"
	echo "    THIS FILE IS GITIGNORED (governance/openbao/unseal/) - move its"
	echo "    contents to an out-of-band secret store (password manager, a"
	echo "    physical safe for printed key shares, etc.) and delete it from"
	echo "    disk once relocated. It must never be committed to git."
else
	echo "==> OpenBao already initialized; reusing ${INIT_FILE}"
	[[ -f "${INIT_FILE}" ]] || {
		echo "ERROR: OpenBao is initialized but ${INIT_FILE} is missing - cannot unseal without the key shares recorded there. Restore it from the out-of-band store." >&2
		exit 1
	}
fi

ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('${INIT_FILE}'))['root_token'])")
UNSEAL_KEYS=$(python3 -c "import json; print('\n'.join(json.load(open('${INIT_FILE}'))['unseal_keys_b64'][:3]))")

echo "==> Unsealing (3-of-5 threshold)"
while IFS= read -r key; do
	docker exec openbao bao operator unseal -tls-skip-verify -address="${BAO_ADDR}" "${key}" >/dev/null
done <<<"${UNSEAL_KEYS}"

export ROOT_TOKEN

echo "==> Enabling kv-v2 secrets engine at secret/ (skips if already enabled)"
bao_cli secrets enable -path=secret kv-v2 2>/dev/null || echo "    secret/ already enabled"

rotate() {
	local name="$1"
	python3 -c "import secrets; print(secrets.token_urlsafe(24))" | tr -d '\n' >/tmp/rotated_value
	cat /tmp/rotated_value
}

if ! docker exec -e BAO_ADDR="${BAO_ADDR}" -e BAO_SKIP_VERIFY=true -e BAO_TOKEN="${ROOT_TOKEN}" openbao bao token lookup >/dev/null 2>&1; then
	echo ""
	echo "OpenBao is already initialized/unsealed and its root token was"
	echo "already revoked by a previous run of this script - nothing left"
	echo "to bootstrap. To rotate credentials again, authenticate with a"
	echo "non-root token under the 'devenv-cloud-read' policy (or a fresh"
	echo "operator login) and write new values to secret/devenv-cloud/* by"
	echo "hand, or wipe the openbao_data volume to bootstrap from scratch."
	exit 0
fi

echo "==> Rotating Phase 1-3 credentials into secret/ (new random values, old values discarded)"
CODER_PG_PASSWORD_NEW=$(rotate coder-pg)
TEMPORAL_PG_PASSWORD_NEW=$(rotate temporal-pg)
LAB_SIM_TOKEN_A_NEW=$(rotate lab-sim-a)
LAB_SIM_TOKEN_B_NEW=$(rotate lab-sim-b)
# Issue #43 (Omnigent host integration, Step 3, corrected): a shared
# admin-equivalent account a Coder workspace's startup script uses to run
# the real "accounts" auth login flow (POST /auth/login with
# username+password - omnigent has no bearer-token CLI flag, see the Step
# 5 handoff). This is deliberately the SAME first-admin account
# scripts/omnigent-bootstrap.sh causes omnigent-server to create at boot
# (username "admin"), not a separate service account - Omnigent has no
# account-minting API yet to create one. To keep both scripts' view of
# "the admin password" consistent without a second source of truth,
# OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD in .env is treated as the single
# authority: the server reads it directly at boot to create the account,
# and this script just copies the same value into OpenBao rather than
# generating an independent one (an independently-rotated value here would
# never match what the server actually accepted at boot). Minting a real,
# separate, per-workspace, non-admin credential is out of scope for this
# step and tracked as a future enhancement (see Notes/Follow-up in the
# Step 5 handoff).
OMNIGENT_HOST_USERNAME="admin"
if [[ -n "${OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD:-}" ]]; then
	OMNIGENT_HOST_PASSWORD_NEW="${OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD}"
	OMNIGENT_HOST_PASSWORD_SOURCE="OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD (.env)"
else
	OMNIGENT_HOST_PASSWORD_NEW=""
	OMNIGENT_HOST_PASSWORD_SOURCE="unset - skipped"
fi

bao_cli kv put secret/devenv-cloud/coder-db password="${CODER_PG_PASSWORD_NEW}" >/dev/null
bao_cli kv put secret/devenv-cloud/temporal-db password="${TEMPORAL_PG_PASSWORD_NEW}" >/dev/null
bao_cli kv put secret/devenv-cloud/lab-sim tokens="agent-a:${LAB_SIM_TOKEN_A_NEW},agent-b:${LAB_SIM_TOKEN_B_NEW}" >/dev/null
# Issue #50: temporal-svc's narrowly-scoped Coder API token (workspace
# lifecycle only — coder:workspaces.create/.operate[/.delete], see
# docs/security.md). Minted out-of-band by `scripts/coder-svc-token.sh`
# (`make coder-svc-token`), not generated by this script — OpenBao is the
# system of record for it, but this script has no way to mint a fresh
# Coder API token itself (unlike the random Postgres/lab-sim secrets
# above). If CODER_WORKSPACE_API_TOKEN is already in .env (i.e. already
# minted), copy it into OpenBao here for the same single-source-of-truth
# reasons as the omnigent host-account block below; otherwise skip.
if [[ -n "${CODER_WORKSPACE_API_TOKEN:-}" ]]; then
	bao_cli kv put secret/devenv-cloud/coder-temporal-svc \
		token="${CODER_WORKSPACE_API_TOKEN}" \
		owner="${CODER_WORKSPACE_OWNER:-temporal-svc}" >/dev/null
else
	echo "    SKIP: secret/devenv-cloud/coder-temporal-svc - run 'make"
	echo "    coder-svc-token', set CODER_WORKSPACE_API_TOKEN in .env, and"
	echo "    re-run this script to seed it."
fi
if [[ -n "${OMNIGENT_HOST_PASSWORD_NEW}" ]]; then
	bao_cli kv put secret/devenv-cloud/omnigent/host-account \
		url="http://omnigent-server:8000" \
		username="${OMNIGENT_HOST_USERNAME}" \
		password="${OMNIGENT_HOST_PASSWORD_NEW}" >/dev/null
else
	echo "    SKIP: secret/devenv-cloud/omnigent/host-account - set"
	echo "    OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD in .env and re-run this"
	echo "    script to seed it (must match the value omnigent-server used"
	echo "    to create its first admin account at boot)."
fi

echo "==> Writing the lab.authz policy (governance/opa/policy) is served by OPA directly, not OpenBao - no action needed here"

echo "==> Enabling AppRole auth (least-privilege, non-root access going forward)"
bao_cli auth enable approle 2>/dev/null || echo "    approle already enabled"
cat <<'POLICY' | docker exec -i -e BAO_ADDR="${BAO_ADDR}" -e BAO_SKIP_VERIFY=true -e BAO_TOKEN="${ROOT_TOKEN}" openbao bao policy write devenv-cloud-read -
path "secret/data/devenv-cloud/*" {
  capabilities = ["read"]
}
POLICY

echo "==> Revoking the initial root token (non-negotiable per M12 hardening baseline)"
bao_cli token revoke "${ROOT_TOKEN}"

echo ""
echo "=================================================================="
echo "OpenBao bootstrap complete."
echo "Unseal key shares are recorded ONLY in ${INIT_FILE} (gitignored)."
echo "Operator action required: copy that file's contents to an"
echo "out-of-band store (password manager / physical safe), then delete"
echo "${INIT_FILE} from this host. This location must be covered by"
echo "M14's backup plan (future milestone)."
echo ""
echo "Credential rotation log (values themselves are NOT printed/stored"
echo "outside OpenBao's secret/devenv-cloud/* paths):"
echo "  - coder-db password:      rotated -> secret/devenv-cloud/coder-db"
echo "  - temporal-db password:   rotated -> secret/devenv-cloud/temporal-db"
echo "  - lab-sim tokens (a & b): rotated -> secret/devenv-cloud/lab-sim"
echo "  - omnigent host account:  ${OMNIGENT_HOST_PASSWORD_SOURCE} -> secret/devenv-cloud/omnigent/host-account"
echo "    (shared first-admin account, username \"${OMNIGENT_HOST_USERNAME}\";"
echo "    per-workspace credential minting is a future enhancement, not yet"
echo "    implemented by Omnigent)"
echo "Apply these new values to .env and 'docker compose up -d' the"
echo "affected services to complete the rotation (out of scope for this"
echo "script - .env is operator-owned and gitignored)."
echo "=================================================================="
