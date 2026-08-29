# Disaster Recovery — devenv-cloud

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
   of the unseal-key shares. See "OpenBao deviation" below for why this is
   the file-backend-correct equivalent of `bao operator raft snapshot
   save`, not a shortcut.
5. **Persistent workspace homes** — a `tar` of every `coder-*-home` Docker
   volume (agent sessions, git worktrees, in-progress work).

Everything else running in `docker compose` (`registry`, `prometheus`,
`grafana`, `loki`, `opa`, `lab-sim`, `otel-collector`, `promtail`,
`cadvisor`, `runner-docker-proxy`, `runner-health`) is REPRODUCIBLE —
rebuilt from the versioned config in this repo, not backed up.

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
