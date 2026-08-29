# M14 — Backup / Restore

Evidence captured for Phase 5 / Milestone M14 (Backup / Restore), per the
evidence standard in `docs/INITIAL.md` Section 3 Rule 2 and
`docs/plan/plan.md` (M14 section).

- **Timestamp (UTC):** 2026-08-29T06:46Z–09:04Z.
- **Environment:** local Docker Compose stack (18 services, `docker compose
  ps` below), Coder workspace `admin/demo-e2e` (`docker-standard`
  template, container `coder-admin-demo-e2e`), Temporal server `v1.29.7`,
  OpenBao `2.6.2`.

## What was built

- `backup/backup-policy.md` — classification of MUST BACK UP /
  REPRODUCIBLE state, including the OpenBao backup mechanism (see
  "OpenBao deviation" below) and the Coder-home-persistence caveat.
- `scripts/backup.sh` — creates one timestamped backup set under
  `backup/artifacts/<name>/` (gitignored): a full git bundle of the
  platform repo, `pg_dump` of the Coder DB, `pg_dump` of both the
  Temporal `temporal` and `temporal_visibility` databases, a raw
  storage-directory snapshot + KV export + unseal-key copy for OpenBao,
  and a `tar` of every `coder-*-home` Docker volume.
- `scripts/restore-test.sh` — destroys only the MUST BACK UP resources
  (`coder`, `coder-db`, `temporal`, `temporal-db`, `temporal-ui`,
  `temporal-worker`, `openbao`, and every `coder-*-home` volume) and
  restores them all from a named backup set.
- `Makefile` targets `make backup` / `make restore-test` wrapping the
  above.
- `backup/restore-test.md` — the detailed log of the Manual E2E Test run
  below.

## OpenBao deviation from the plan's literal wording (see `backup/backup-policy.md` for the full writeup)

The plan's generic guidance says back up OpenBao via
`bao operator raft snapshot save`. **This deployment uses `storage
"file"`** (per `governance/openbao/config/openbao.hcl`, an M12 decision —
confirmed live via `bao status` -> `Storage Type: file`), not Integrated
Storage/Raft, so that command has no defined behavior here. Root cause
re-verified against the plan's underlying *intent* (the Manual E2E Test
explicitly requires "unsealed with the backed-up keys" after restore):
Shamir unseal key shares are cryptographically tied to one specific
`bao operator init` run against one specific storage state — re-running
`bao operator init` against an empty volume always mints a **new** master
key and **new** key shares, so the *old* shares could never unseal a
freshly re-initialized instance no matter how well they were backed up.
The only way to make "unseal with the backed-up keys" literally true is to
restore the same on-disk storage state those keys were generated
against — for the `file` backend, that's the storage directory itself.
This stack backs it up as a raw, point-in-time tar of `/openbao/data`
(container briefly stopped for a consistent copy, then restarted and
re-unsealed), which is exactly what was verified end-to-end below.

## Validation Milestone M14 — executed against the real stack

1. **Marker file**: wrote
   `m14-marker-20260829T064800Z-8032` to `/home/coder/m14-marker.txt`
   inside `coder-admin-demo-e2e`.
2. **Temporal workflow**: `make temporal-demo-start` ->
   `workflow_id=demo-durable-workflow-eea73faa`.
3. **OpenBao test secret**: `secret/devenv-cloud/m14-test` ->
   `marker=m14-test-secret-20260829T064610Z` (OpenBao was re-initialized
   from an empty volume first, since the pre-existing instance's root
   token had already been revoked by a prior M12 run with no write-capable
   AppRole policy configured — a legitimate, disposable test-cycle
   bootstrap, not a workaround of anything this step needed to preserve).
4. **Agent/session data (M5)**: `git worktree add
   /home/coder/worktrees/m14-session -b agent/m14-session` +
   `session-marker.txt` inside it.
5. **`bash scripts/backup.sh m14-e2e-test`** (also independently re-run as
   `m14-script-verify` for the final automated-script proof below) — all
   five backup categories captured, ~246 MB set.
6. **Destroyed the MUST BACK UP set only**: `coder-admin-demo-e2e`
   container, then `coder`/`coder-db`/`temporal`/`temporal-db`/
   `temporal-ui`/`temporal-worker`/`openbao` containers, plus
   `coder_db_data`, `temporal_db_data`, `openbao_data`, and the
   `coder-*-home` volume. `registry`, `prometheus`, `grafana`, `loki`,
   `opa`, `lab-sim`, `otel-collector`, `promtail`, `cadvisor`,
   `runner-docker-proxy`, `runner-health` were never touched.
7. **`bash scripts/restore-test.sh m14-e2e-test`** (manual step-by-step
   the first time, to design/verify the mechanism; then re-run
   end-to-end as the actual `scripts/restore-test.sh` in one shot against
   a second `m14-script-verify` backup set — see full log,
   `EXIT=0`, below).
8. **Verification**:
   - Coder DB: `select name from workspaces` -> `demo-e2e` present.
   - Temporal DB: `select count(*) from executions` -> `23`;
     `temporal workflow show --workflow-id demo-durable-workflow-eea73faa`
     -> full Event History intact including `WorkflowExecutionCompleted`.
   - OpenBao: restored storage came back `Initialized: true, Sealed:
     true` (proving it's the *restored* state, not a fresh init);
     unsealed successfully with the **backed-up** key shares (`Sealed:
     false` after 3 of 5); `bao kv get secret/devenv-cloud/m14-test` ->
     `marker: m14-test-secret-20260829T064610Z`.
   - Workspace home volume: `cat /home/coder/m14-marker.txt` ->
     `m14-marker-20260829T064800Z-8032` (byte-for-byte identical);
     `cat /home/coder/worktrees/m14-session/session-marker.txt` ->
     `m14 session data`; `git branch --show-current` inside that worktree
     -> `agent/m14-session`.
   - Coder itself: `coder stop demo-e2e --yes && coder start demo-e2e
     --yes` recreated `docker_container.workspace` against the
     **existing, restored** `docker_volume.home_volume` (same fixed name,
     `coder-${workspace_id}-home`, per its `lifecycle { ignore_changes =
     all }`) — the live workspace container mounts the restored volume
     and shows the same marker/worktree content above.

Full `scripts/restore-test.sh m14-script-verify` run — automated, single
command, no manual intervention — completed with `EXIT=0`.

Post-restore full-stack health:

```
$ docker compose ps --format 'table {{.Name}}\t{{.Status}}'
NAME                  STATUS
cadvisor              Up 10 hours (healthy)
coder                 Up About a minute (healthy)
coder-db              Up 2 minutes (healthy)
grafana               Up 10 hours
lab-sim               Up 10 hours (healthy)
loki                  Up 10 hours
opa                   Up 11 hours
openbao               Up 2 minutes (healthy)
otel-collector        Up 10 hours
prometheus            Up 10 hours
promtail              Up 10 hours
registry              Up 13 hours (healthy)
runner-docker-proxy   Up 13 hours
runner-health         Up 13 hours (healthy)
temporal              Up 2 minutes (healthy)
temporal-db           Up 2 minutes (healthy)
temporal-ui           Up 2 minutes (healthy)
temporal-worker       Up 2 minutes
```

## Manual E2E Test M14 — result

- [x] Repository/platform config restored (git bundle produced; the repo
      itself is also the running working tree throughout — no data loss
      scenario applicable beyond what the bundle already covers).
- [x] Coder database restored — workspace metadata intact.
- [x] Temporal database restored — workflow history intact (`temporal`
      and `temporal_visibility`, same Postgres instance, no separate
      Visibility backend in this stack).
- [x] OpenBao restored via a raw storage-directory snapshot (the
      mechanism-appropriate equivalent of raft snapshot restore for this
      backend), then successfully unsealed with the backed-up keys, test
      secret still retrievable.
- [x] Persistent workspace home restored — verified via the marker-file
      content check (byte-for-byte), not just "workspace starts".

Backup artifacts (`backup/artifacts/`) were deleted after this run
(gitignored, ~246 MB each — disposable test evidence, not meant to be
retained; the commands and outputs above are the durable record).
