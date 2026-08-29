#!/usr/bin/env bash
# M14 Backup / Restore. Creates one timestamped backup set under
# backup/artifacts/<timestamp>/ covering every "MUST BACK UP" category from
# backup/backup-policy.md:
#
#   1. Platform repository  -> git bundle (--all refs, full history).
#   2. Coder database       -> pg_dump (custom format).
#   3. Temporal database    -> pg_dump of BOTH `temporal` and
#                               `temporal_visibility` (same Postgres
#                               instance backs Persistence + Visibility
#                               here - no separate ES/OpenSearch store).
#   4. OpenBao               -> application-level KV export (see
#                               backup/backup-policy.md for why this
#                               deployment - `storage "file"`, not `raft` -
#                               cannot use `bao operator raft snapshot
#                               save`) plus the out-of-band unseal-key
#                               material needed to unseal a restored
#                               instance.
#   5. Workspace persistent state -> tar of every `coder-*-home` Docker
#                               volume.
#
# Usage: scripts/backup.sh [backup-name]
#   backup-name defaults to a UTC timestamp (YYYYmmddTHHMMSSZ).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

BACKUP_NAME="${1:-$(date -u +%Y%m%dT%H%M%SZ)}"
OUT_DIR="${REPO_ROOT}/backup/artifacts/${BACKUP_NAME}"
mkdir -p "${OUT_DIR}"/{repo,coder-db,temporal-db,openbao,workspaces}

echo "==> Backup set: ${OUT_DIR}"

# --- 1. Platform repository -------------------------------------------------
echo "==> [1/5] Platform repository (git bundle, all refs)"
git bundle create "${OUT_DIR}/repo/platform.bundle" --all

# --- 2. Coder database -------------------------------------------------------
echo "==> [2/5] Coder database (pg_dump)"
docker exec coder-db pg_dump -U "${CODER_PG_USER:-coder}" -Fc "${CODER_PG_DB:-coder}" \
	>"${OUT_DIR}/coder-db/coder.dump"

# --- 3. Temporal database ----------------------------------------------------
echo "==> [3/5] Temporal database (pg_dump: temporal + temporal_visibility)"
docker exec temporal-db pg_dump -U "${TEMPORAL_PG_USER:-temporal}" -Fc temporal \
	>"${OUT_DIR}/temporal-db/temporal.dump"
docker exec temporal-db pg_dump -U "${TEMPORAL_PG_USER:-temporal}" -Fc temporal_visibility \
	>"${OUT_DIR}/temporal-db/temporal_visibility.dump"

# --- 4. OpenBao ---------------------------------------------------------------
echo "==> [4/5] OpenBao (raw storage-directory snapshot + KV export + unseal-key material)"
BAO_ADDR="https://127.0.0.1:8200"
INIT_FILE="${REPO_ROOT}/governance/openbao/unseal/init.json"

# 4a. Raw copy of the `file` storage directory - the mechanism-appropriate
# equivalent of `bao operator raft snapshot save` for this backend (see
# backup/backup-policy.md: old Shamir unseal keys can only ever unseal the
# SAME storage state they were generated against, never a freshly
# `bao operator init`-ed one). Stop briefly for a consistent copy, then
# restart and re-unseal so the running stack isn't left sealed.
if docker ps --format '{{.Names}}' | grep -qx openbao; then
	echo "    Stopping openbao for a consistent storage-directory snapshot"
	docker compose stop openbao >/dev/null
	docker run --rm \
		-v devenv-cloud_openbao_data:/data:ro \
		-v "${OUT_DIR}/openbao:/backup" \
		alpine:3.20 \
		tar czf /backup/openbao-data.tar.gz -C /data .
	docker compose start openbao >/dev/null
	for _ in $(seq 1 30); do
		status="$(docker inspect --format '{{.State.Health.Status}}' openbao 2>/dev/null || true)"
		[[ "${status}" != "starting" ]] && break
		sleep 1
	done
	if [[ -f "${INIT_FILE}" ]]; then
		UNSEAL_KEYS_RESTART="$(python3 -c "import json; print('\n'.join(json.load(open('${INIT_FILE}'))['unseal_keys_b64'][:3]))" 2>/dev/null || true)"
		while IFS= read -r key; do
			[[ -z "${key}" ]] && continue
			docker exec openbao bao operator unseal -tls-skip-verify -address="${BAO_ADDR}" "${key}" >/dev/null 2>&1 || true
		done <<<"${UNSEAL_KEYS_RESTART}"
	fi
else
	echo "    openbao container not running - skipping raw storage-directory snapshot."
fi

if [[ -f "${INIT_FILE}" ]]; then
	cp "${INIT_FILE}" "${OUT_DIR}/openbao/init.json"
	echo "    Copied unseal key shares from ${INIT_FILE}."
	echo "    NOTE: a real deployment keeps this OUT of the data backup set"
	echo "    (password manager / physical safe) - see backup-policy.md."
else
	echo "    WARNING: ${INIT_FILE} not found - restore will not be able to"
	echo "    unseal a fresh OpenBao instance without the unseal keys from"
	echo "    wherever they were relocated to out-of-band." >&2
fi

BAO_TOKEN="${BAO_TOKEN:-}"
if [[ -z "${BAO_TOKEN}" && -f "${INIT_FILE}" ]]; then
	BAO_TOKEN="$(python3 -c "import json; print(json.load(open('${INIT_FILE}'))['root_token'])" 2>/dev/null || true)"
fi

bao_kv_export() {
	local path="$1"
	docker exec -e BAO_ADDR="${BAO_ADDR}" -e BAO_SKIP_VERIFY=true -e BAO_TOKEN="${BAO_TOKEN}" \
		openbao bao kv get -format=json "${path}" 2>/dev/null
}

SEALED="$(docker exec openbao bao status -tls-skip-verify -address="${BAO_ADDR}" -format=json 2>/dev/null \
	| python3 -c "import json,sys
try:
    print(json.load(sys.stdin)['sealed'])
except Exception:
    print('true')")"

if [[ "${SEALED}" == "True" || "${SEALED}" == "true" ]]; then
	echo "    OpenBao is sealed - skipping live KV export (unseal-key backup above still succeeds)."
elif [[ -z "${BAO_TOKEN}" ]]; then
	echo "    No BAO_TOKEN available (root token already revoked and none supplied via \$BAO_TOKEN) - skipping live KV export."
else
	PATHS="$(docker exec -e BAO_ADDR="${BAO_ADDR}" -e BAO_SKIP_VERIFY=true -e BAO_TOKEN="${BAO_TOKEN}" \
		openbao bao kv list -format=json secret/devenv-cloud 2>/dev/null | python3 -c "import json,sys
try:
    print('\n'.join(json.load(sys.stdin)))
except Exception:
    pass")"
	: >"${OUT_DIR}/openbao/kv-export.json"
	echo "[" >"${OUT_DIR}/openbao/kv-export.json"
	first=1
	while IFS= read -r name; do
		[[ -z "${name}" ]] && continue
		json="$(bao_kv_export "secret/devenv-cloud/${name}")"
		[[ -z "${json}" ]] && continue
		[[ ${first} -eq 0 ]] && echo "," >>"${OUT_DIR}/openbao/kv-export.json"
		first=0
		python3 -c "import json,sys
d = json.loads(sys.argv[2])
print(json.dumps({'path': 'secret/devenv-cloud/' + sys.argv[1], 'data': d['data']['data']}))" \
			"${name}" "${json}" >>"${OUT_DIR}/openbao/kv-export.json"
	done <<<"${PATHS}"
	echo "]" >>"${OUT_DIR}/openbao/kv-export.json"
	COUNT="$(python3 -c "import json; print(len(json.load(open('${OUT_DIR}/openbao/kv-export.json'))))")"
	echo "    Exported ${COUNT} secret(s) under secret/devenv-cloud/."
fi

# --- 5. Workspace persistent state -------------------------------------------
echo "==> [5/5] Workspace persistent state (coder-*-home volumes)"
VOLUMES="$(docker volume ls --format '{{.Name}}' | grep -E '^coder-.*-home$' || true)"
if [[ -z "${VOLUMES}" ]]; then
	echo "    No coder-*-home volumes found - nothing to back up (no workspace created yet)."
else
	while IFS= read -r vol; do
		[[ -z "${vol}" ]] && continue
		echo "    Archiving volume: ${vol}"
		docker run --rm \
			-v "${vol}:/data:ro" \
			-v "${OUT_DIR}/workspaces:/backup" \
			alpine:3.20 \
			tar czf "/backup/${vol}.tar.gz" -C /data .
	done <<<"${VOLUMES}"
fi

echo "${BACKUP_NAME}" >"${REPO_ROOT}/backup/artifacts/LATEST"
echo "==> Backup complete: ${OUT_DIR}"
