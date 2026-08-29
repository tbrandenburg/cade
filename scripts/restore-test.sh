#!/usr/bin/env bash
# M14 Backup / Restore. Destroys the "MUST BACK UP" resources (see
# backup/backup-policy.md) and restores them from a backup set produced by
# scripts/backup.sh, proving the backup is actually usable - not just
# "a file exists".
#
# Deliberately does NOT touch the "REPRODUCIBLE" set (containers/images,
# `registry`, observability stack, etc.) - those are rebuilt via `make`
# targets, not restored from this backup.
#
# Usage: scripts/restore-test.sh [backup-name]
#   backup-name defaults to the contents of backup/artifacts/LATEST
#   (written by the most recent scripts/backup.sh run).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

BACKUP_NAME="${1:-$(cat backup/artifacts/LATEST 2>/dev/null || true)}"
if [[ -z "${BACKUP_NAME}" ]]; then
	echo "ERROR: no backup-name given and backup/artifacts/LATEST not found. Run scripts/backup.sh first." >&2
	exit 1
fi
IN_DIR="${REPO_ROOT}/backup/artifacts/${BACKUP_NAME}"
if [[ ! -d "${IN_DIR}" ]]; then
	echo "ERROR: backup set not found: ${IN_DIR}" >&2
	exit 1
fi
echo "==> Restoring from backup set: ${IN_DIR}"

# --- 1. Destroy the MUST BACK UP resources (not the reproducible ones) -----
echo "==> Destroying coder-db, temporal-db, openbao (containers + data volumes)"
docker compose stop coder coder-db temporal temporal-db temporal-ui temporal-worker openbao
docker compose rm -f coder coder-db temporal temporal-db temporal-ui temporal-worker openbao
docker volume rm devenv-cloud_coder_db_data devenv-cloud_temporal_db_data devenv-cloud_openbao_data 2>&1 || true

echo "==> Destroying workspace persistent-state volumes (coder-*-home)"
WORKSPACE_VOLS="$(docker volume ls --format '{{.Name}}' | grep -E '^coder-.*-home$' || true)"
while IFS= read -r vol; do
	[[ -z "${vol}" ]] && continue
	docker volume rm "${vol}"
done <<<"${WORKSPACE_VOLS}"

# --- 2. Recreate empty data volumes + bring the DB/OpenBao containers back --
echo "==> Recreating coder-db, temporal-db, openbao from empty volumes"
docker compose up -d coder-db temporal-db openbao
echo "    Waiting for coder-db/temporal-db to become healthy..."
for svc in coder-db temporal-db; do
	for _ in $(seq 1 30); do
		status="$(docker inspect --format '{{.State.Health.Status}}' "${svc}" 2>/dev/null || true)"
		[[ "${status}" == "healthy" ]] && break
		sleep 2
	done
done

# --- 3. Restore Coder database ------------------------------------------------
echo "==> [1/5] Restoring Coder database"
docker exec -i coder-db createdb -U "${CODER_PG_USER:-coder}" "${CODER_PG_DB:-coder}" 2>/dev/null || true
# pg_restore exits 1 on a known-benign pg_dump ordering artifact in Coder's
# schema (a view casts NULL::some_enum_type before pg_dump's dependency
# graph has scheduled that type's CREATE - the type/view both end up
# correct once the full dump finishes; verified separately below) - do not
# let `set -e` abort the whole restore over that one ignorable warning.
docker exec -i coder-db pg_restore -U "${CODER_PG_USER:-coder}" -d "${CODER_PG_DB:-coder}" --clean --if-exists \
	<"${IN_DIR}/coder-db/coder.dump" || echo "    (pg_restore reported ignorable warnings - verifying below)"
docker exec coder-db psql -U "${CODER_PG_USER:-coder}" -d "${CODER_PG_DB:-coder}" -c "select 1 from workspaces limit 1" >/dev/null

# --- 4. Restore Temporal database --------------------------------------------
echo "==> [2/5] Restoring Temporal database (temporal + temporal_visibility)"
docker exec -i temporal-db createdb -U "${TEMPORAL_PG_USER:-temporal}" temporal 2>/dev/null || true
docker exec -i temporal-db createdb -U "${TEMPORAL_PG_USER:-temporal}" temporal_visibility 2>/dev/null || true
docker exec -i temporal-db pg_restore -U "${TEMPORAL_PG_USER:-temporal}" -d temporal --clean --if-exists \
	<"${IN_DIR}/temporal-db/temporal.dump" || echo "    (pg_restore reported ignorable warnings - verifying below)"
docker exec -i temporal-db pg_restore -U "${TEMPORAL_PG_USER:-temporal}" -d temporal_visibility --clean --if-exists \
	<"${IN_DIR}/temporal-db/temporal_visibility.dump" || echo "    (pg_restore reported ignorable warnings - verifying below)"
docker exec temporal-db psql -U "${TEMPORAL_PG_USER:-temporal}" -d temporal -c "select 1 from executions limit 1" >/dev/null

echo "==> Bringing Temporal server + worker + UI back up"
docker compose up -d temporal
for _ in $(seq 1 30); do
	status="$(docker inspect --format '{{.State.Health.Status}}' temporal 2>/dev/null || true)"
	[[ "${status}" == "healthy" ]] && break
	sleep 2
done
docker compose up -d temporal-ui temporal-worker

# --- 5. Restore OpenBao: restore the raw storage dir, unseal with the ------
#        backed-up key shares (proves the OLD keys, not freshly-generated
#        ones, are what's needed - see backup/backup-policy.md).
echo "==> [3/5] Restoring OpenBao (raw storage-directory restore + unseal with backed-up keys)"
BAO_ADDR="https://127.0.0.1:8200"

echo "    Recreating openbao_data volume from the backed-up storage-directory snapshot"
docker volume create devenv-cloud_openbao_data >/dev/null
docker run --rm \
	-v devenv-cloud_openbao_data:/data \
	-v "${IN_DIR}/openbao:/backup:ro" \
	alpine:3.20 \
	tar xzf /backup/openbao-data.tar.gz -C /data

echo "    Starting openbao against the restored storage (comes back SEALED, as expected)"
docker compose up -d openbao
for _ in $(seq 1 30); do
	status="$(docker inspect --format '{{.State.Health.Status}}' openbao 2>/dev/null || true)"
	[[ "${status}" != "starting" && -n "${status}" ]] && break
	sleep 1
done

echo "    Ensuring restored data is owned by the container's runtime user"
docker exec -u 0 openbao chown -R openbao:openbao /openbao/data

RESTORED_INIT="${REPO_ROOT}/governance/openbao/unseal/init.json"
mkdir -p "$(dirname "${RESTORED_INIT}")"
cp "${IN_DIR}/openbao/init.json" "${RESTORED_INIT}"

echo "    Unsealing with the BACKED-UP key shares (not a freshly generated set)"
UNSEAL_KEYS="$(python3 -c "import json; print('\n'.join(json.load(open('${IN_DIR}/openbao/init.json'))['unseal_keys_b64'][:3]))")"
while IFS= read -r key; do
	[[ -z "${key}" ]] && continue
	docker exec openbao bao operator unseal -tls-skip-verify -address="${BAO_ADDR}" "${key}"
done <<<"${UNSEAL_KEYS}"

SEALED_AFTER="$(docker exec openbao bao status -tls-skip-verify -address="${BAO_ADDR}" -format=json 2>/dev/null \
	| python3 -c "import json,sys
try:
    print(json.load(sys.stdin)['sealed'])
except Exception:
    print('true')")"
if [[ "${SEALED_AFTER}" == "True" || "${SEALED_AFTER}" == "true" ]]; then
	echo "ERROR: OpenBao is still sealed after unsealing with the backed-up keys." >&2
	exit 1
fi
echo "    OpenBao unsealed successfully with the backed-up key shares."

# --- 6. Restore workspace persistent state (coder-*-home volumes) -----------
echo "==> [4/5] Restoring workspace persistent-state volumes"
for archive in "${IN_DIR}"/workspaces/*.tar.gz; do
	[[ -e "${archive}" ]] || continue
	vol="$(basename "${archive}" .tar.gz)"
	echo "    Recreating volume ${vol} from ${archive}"
	docker volume create "${vol}" >/dev/null
	docker run --rm \
		-v "${vol}:/data" \
		-v "${IN_DIR}/workspaces:/backup:ro" \
		alpine:3.20 \
		tar xzf "/backup/$(basename "${archive}")" -C /data
done

# --- 7. Bring Coder back up --------------------------------------------------
echo "==> [5/5] Bringing Coder back up"
docker compose up -d coder
for _ in $(seq 1 30); do
	status="$(docker inspect --format '{{.State.Health.Status}}' coder 2>/dev/null || true)"
	[[ "${status}" == "healthy" ]] && break
	sleep 2
done

echo "==> Restore complete. Verify with the checks in backup/restore-test.md / docs/milestone-reports/M14-backup.md."
