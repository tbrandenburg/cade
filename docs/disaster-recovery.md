# Disaster Recovery — cade

The real backup/restore procedure verified end-to-end in Milestone M14
(`docs/milestone-reports/M14-backup.md`). Read `backup/backup-policy.md`
for the full MUST BACK UP / REPRODUCIBLE classification this procedure is
built against.

## What is backed up (MUST BACK UP)

`scripts/backup.sh <name>` writes one timestamped set under
`backup/artifacts/<name>/` (gitignored — treat a retained set as
sensitive, see `docs/security.md` M14 section):

1. **Platform repository config** — a full `git bundle` of the repo.
2. **Coder database** — `pg_dump` of `coder-db` (workspace metadata,
   template versions).
3. **Temporal database** — `pg_dump` of both the `temporal` and
   `temporal_visibility` databases (same Postgres instance in this stack —
   workflow/activity history and durable state).
4. **OpenBao** — a raw, point-in-time `tar` of `/openbao/data` (the
   `storage "file"` backend's on-disk state), plus a KV export and a copy
   of the unseal-key shares in the legacy disposable M14 harness. **Do not
   retain that combined artifact as an operational backup.** Separate the
   shares and remove plaintext KV exports from retained storage backups;
   keep the operator password in a third, independent password-manager
   item/location. See "OpenBao deviation" below for why this is
   the file-backend-correct equivalent of `bao operator raft snapshot
   save`, not a shortcut.
5. **Persistent workspace homes** — a `tar` of every `coder-*-home` Docker
   volume (agent sessions, git worktrees, in-progress work).

Everything else running in `docker compose` (`registry`, `prometheus`,
`grafana`, `loki`, `opa`, `lab-sim`, `otel-collector`, `alloy`,
`cadvisor`, `runner-docker-proxy`, `runner-health`) is REPRODUCIBLE —
rebuilt from the versioned config in this repo, not backed up. Alloy's
positions volume is not backed up; losing it can replay retained Docker logs.

## OpenBao deviation from the plan's literal wording

This deployment uses `storage "file"` (`governance/openbao/config/
openbao.hcl`, an M12 decision), not Integrated Storage/Raft, so
`bao operator raft snapshot save` has no defined behavior here. Shamir
unseal key shares are cryptographically tied to one specific
`bao operator init` run against one specific storage state — re-running
`bao operator init` against an empty volume always mints a **new** master
key and **new** shares, so old shares could never unseal a freshly
re-initialized instance no matter how well they were backed up. The only
way to make "unseal with the backed-up keys" literally true for the
`file` backend is to restore the same on-disk storage state those keys
were generated against — hence the raw `/openbao/data` tar, not a KV
replay + re-init.

## Backup procedure

```bash
make backup
# equivalent to: bash scripts/backup.sh
# or, to name the set explicitly: bash scripts/backup.sh <name>
```

Produces `backup/artifacts/<name>/` (an auto-generated timestamp if no
name is given) containing all five categories above. Delete the set once
verified/no longer needed — it is disposable test evidence by default,
not a retained archive (wire this into an out-of-band, encrypted
retention target before relying on it for a real incident).

## Restore procedure

```bash
make restore-test
# equivalent to: bash scripts/restore-test.sh
# or, against a specific named set: bash scripts/restore-test.sh <name>
```

`scripts/restore-test.sh` destroys **only** the MUST BACK UP resources
(`coder`, `coder-db`, `temporal`, `temporal-db`, `temporal-ui`,
`temporal-worker`, `openbao` containers, plus `coder_db_data`,
`temporal_db_data`, `openbao_data`, and every `coder-*-home` volume) and
restores all of them from the named backup set in one shot, exit code 0
on success. REPRODUCIBLE services are never touched.

## Verification checklist (what M14 actually checked, not just "restore succeeded")

- **Coder DB** — `select name from workspaces` lists the pre-backup
  workspace(s).
- **Temporal DB** — `select count(*) from executions` matches, and
  `temporal workflow show --workflow-id <id>` returns the full Event
  History including `WorkflowExecutionCompleted` for a workflow that ran
  before the backup.
- **OpenBao** — restored storage comes back `Initialized: true, Sealed:
  true` (proves it's the *restored* state, not a fresh init); unseals
  successfully with the **backed-up** key shares (3-of-5 threshold); a
  test secret written before backup is still retrievable afterward.
- **Persistent workspace home** — a marker file written into
  `/home/coder` before the backup is byte-for-byte identical after
  restore (not just "the file exists") — see the same marker-file pattern
  used for Durability Test 3 in `AGENTS.md`'s M16 walkthrough.
- **Coder itself** — `coder stop <ws> --yes && coder start <ws> --yes`
  after restore recreates `docker_container.workspace` against the
  restored `docker_volume.home_volume` (fixed name, `lifecycle {
  ignore_changes = all }`) and the live container mounts the restored
  content.
- **Full-stack health** — `docker compose ps` shows every service
  healthy/running post-restore, including the ones never destroyed.

## Recovery time / data loss expectations

Restore of all five MUST BACK UP categories against a local backup set
completes in well under 5 minutes (single `scripts/restore-test.sh`
invocation, no manual intervention). Recovery point is exactly the backup
set's timestamp — any writes to Coder/Temporal/OpenBao/workspace-home
state after that timestamp and before the incident are lost, by design
(this is a point-in-time backup, not continuous replication).

## OpenBao locked-out administration recovery

First try the [existing-administrator operator provisioning procedure](/docs/operations.md#add-the-operator-to-an-existing-instance-with-a-valid-administrator).
The routine `cade-operator` deliberately cannot mint root or manage auth.
OpenBao 2.6's authenticated `/sys/generate-root-token/*` needs a usable
privileged login; unseal shares alone do not authorize it. The normal
listener must keep legacy unauthenticated root generation disabled (2.6.5
default). Never wipe/reinitialize storage as an administration workaround.

If no administrator works, recover **only a stopped disposable copy** of
the file backend, with its matching 3-of-5 shares. Preserve the original
unchanged. This is a temporary normal-mode server with a recovery-only
listener, **not** `bao server -recovery` (that is a different facility).

1. Arrange a maintenance window, stop writers and the source server using
   your deployment's normal lifecycle, and make a consistent offline copy
   of `/openbao/data`. Do not copy a live file backend or attach two servers
   to one storage directory. Keep an untouched backup and record a hash
   inventory of the stopped original. Check `ss -ltn` before creating any
   service; the drill below requires no host ports.
2. Prepare a private absolute directory (`$copy`) with `data/` containing
   **the copied backend only**, `certs/openbao.{crt,key}` containing your
   test listener's certificate/key, and `openbao.hcl` copied from
   `/governance/openbao/config/openbao.hcl`. The certificate must cover
   `127.0.0.1`. Ensure the chosen non-root container UID can read the key and
   write copied storage; do not broaden permissions on original data.
   Keep matching shares in an owner-only `BAO_INIT_FILE` **outside** this
   copy. Keep the new operator password in a different owner-only file.
3. In the **copied** configuration only, set the listener address to
   `127.0.0.1:8200` and add inside `listener "tcp"`:

   ```hcl
   disable_unauthed_generate_root_endpoints = false
   ```

4. Run this bounded, fail-fast recipe from the repo root, after replacing
   the three private paths. No share/token/password is an argument or log:

   ```bash
   (
     set -euo pipefail
     set +x
     copy=/private/disposable-openbao-copy
     export BAO_INIT_FILE=/private/separate-matching-shares.json
     password_file=/private/separate-operator-password
     export BAO_CONTAINER="cade-bao-recovery-${RANDOM}-${RANDOM}"
     export BAO_ADDR=https://127.0.0.1:8200
     export BAO_CACERT=/openbao/certs/openbao.crt
     export BAO_RECOVERY_DISPOSABLE_COPY=yes
     start_copy() {
       docker run -d --name "$BAO_CONTAINER" --network none \
         --user "$(id -u):$(id -g)" --cap-drop ALL \
         --security-opt no-new-privileges --entrypoint bao \
         -v "$copy/data:/openbao/data" \
         -v "$copy/certs:/openbao/certs:ro" \
         -v "$copy/openbao.hcl:/openbao/config/recovery.hcl:ro" \
         openbao/openbao:2.6.5 server -config=/openbao/config/recovery.hcl
       python3 - <<'PY'
   import sys, time
   sys.path.insert(0, "scripts")
   from openbao_client import Bao, BaoError
   for attempt in range(30):
       try:
           status = Bao().status()
           if status["version"] != "2.6.5":
               raise SystemExit("Unexpected server version")
           break
       except BaoError:
           time.sleep(1)
   else:
       raise SystemExit("Isolated listener did not become ready")
   PY
     }
     start_copy
     python3 scripts/openbao_recover_operator.py --password-file "$password_file"
     docker stop -t 5 "$BAO_CONTAINER"
     docker rm "$BAO_CONTAINER"
     # Remove the legacy setting by restoring the repository's normal config.
     cp governance/openbao/config/openbao.hcl "$copy/openbao.hcl"
     unset BAO_RECOVERY_DISPOSABLE_COPY
     start_copy
     bash scripts/openbao-init.sh
     python3 - <<'PY'
   import getpass, sys
   sys.path.insert(0, "scripts")
   from openbao_client import login, verify_normal_listener
   operator = login(getpass.getpass("Recovered operator password: "))
   path = "secret/data/devenv-cloud/recovery-check"
   operator.write(path, {"data": {"value": "first"}})
   operator.write(path, {"data": {"value": "second"}})
   if operator.read(path)["data"]["data"] != {"value": "second"}:
       raise SystemExit("Recovered data check failed")
   verify_normal_listener()  # Requires exactly legacy 405 and authenticated 403.
   print("Recovered operator works; normal listener rejects unauthenticated root generation")
   PY
     docker stop -t 5 "$BAO_CONTAINER"
     docker rm "$BAO_CONTAINER"
   )
   ```

The helper checks `--network none`, no shared network/published ports,
non-root and non-privileged operation before submitting shares. It uses
verified TLS and the legacy quorum API only on that isolated listener,
holds the one-time pad in memory and saves recovered root in an owner-only
`BAO_INIT_FILE.recovery-pending` cleanup journal **outside the backend copy**
before provisioning. Keep this journal private, outside Git, with the shares;
never print its contents. A retry revokes and verifies any journaled root
before generating another. Success replaces its contents with a clean marker.
The helper attempts revocation even if provisioning fails and requires HTTP
403 plus an unsealed server before reporting success. The normal-listener
check requires exactly legacy HTTP 405 and authenticated HTTP 403; TLS,
connection, unexpected status, and server failures are not denial evidence.

A durable `generating` marker precedes quorum. If interrupted before the
recovered token is saved (including a lost final response), the helper blocks
automatic retry/cutover rather than forgetting a possibly issued root. Preserve
the journal and both backends; independently reconcile generated root accessors
on the isolated copy with quorum-authorized administration before clearing
that marker. Malformed/unsafe journals also block recovery. Never delete or
reset a pending journal merely to make a retry pass. A timeout does not prove
a mutation failed server-side. Local disk failure after server initialization
or root issuance still requires manual recovery; do not discard storage/shares.

If any step fails, keep the original and copied backend/shares, stop **only
the exact owned recovery container**, and inspect the failing prerequisite.
Do not expose the recovery listener, change the normal listener, discard
original data, or claim recovery from a successful HTTP status alone. An
interrupted quorum attempt may need explicit cancellation on this isolated
copy before retry; never cancel another operator's attempt blindly.

After the copy passes the normal-listener checks and the original's hash
inventory is unchanged, arrange a separate approved restoration/cutover
using your platform restore procedure. Do not point an existing running
container at replaced storage. Store retained encrypted backend backup,
unseal shares, and operator password in three separate locations. Remove
ephemeral init/root exports from the host after securing the shares.

### Reproducible disposable drill

```bash
python3 scripts/tests/openbao_tls_e2e.py
```

This opt-in test uses the real scripts and `openbao/openbao:2.6.5`, fresh
dummy storage/certificates, uniquely named non-root containers, no network
or published ports, and cleans up its owned containers. It verifies TLS,
bootstrap/root revocation, fresh scoped create/update/read, read-only and
out-of-scope denial, forced-rotation failure, non-rotating re-unseal,
provisioning/login failure resume, recovery on stopped copied storage,
temporary-root revocation, and restored normal-listener denial. It compares
the stopped original's contents before/after recovery. It never accesses
the platform's existing OpenBao container, volume, certificate, or shares.
It also uses `nginx:1.27-alpine` for an isolated TLS-to-HTTP redirect
regression: the real CLI reaches the TLS 307 listener but sends no request
to the HTTP sink, despite an inherited redirect-following setting.
Evidence: [issue #170 report](/docs/milestone-reports/issue-170-openbao-operator.md).
