# Restore Test Log (M14)

Record of the M14 Validation Milestone / Manual E2E Test, run against the
real stack (not a dry run) on 2026-08-29.

## Setup

- Backup set name: `m14-e2e-test` (`backup/artifacts/m14-e2e-test/` —
  gitignored, ~246 MB; not committed, per `backup/artifacts/` in
  `.gitignore`).
- Workspace under test: `admin/demo-e2e` (`docker-standard` template),
  container `coder-admin-demo-e2e`, home volume
  `coder-25b6ebca-5e45-40e0-96f7-9635cca1053b-home`.

## 1. Create marker / workflow / secret / session data

```
$ docker exec coder-admin-demo-e2e bash -lc "echo 'm14-marker-20260829T064800Z-8032' > /home/coder/m14-marker.txt"
$ docker exec -u coder coder-admin-demo-e2e bash -lc \
    "git -C /home/coder/project worktree add /home/coder/worktrees/m14-session -b agent/m14-session; \
     echo 'm14 session data' > /home/coder/worktrees/m14-session/session-marker.txt"
$ make temporal-demo-start
workflow_id=demo-durable-workflow-eea73faa run_id=01a04c46-d79a-7d97-a878-30fa0d1de0ea
$ bao kv put secret/devenv-cloud/m14-test marker="m14-test-secret-20260829T064610Z"
Success! Data written to: secret/data/devenv-cloud/m14-test
```

## 2. `make backup` (named for this log via `scripts/backup.sh m14-e2e-test`)

```
$ bash scripts/backup.sh m14-e2e-test
==> Backup set: .../backup/artifacts/m14-e2e-test
==> [1/5] Platform repository (git bundle, all refs)
==> [2/5] Coder database (pg_dump)
==> [3/5] Temporal database (pg_dump: temporal + temporal_visibility)
==> [4/5] OpenBao (raw storage-directory snapshot + KV export + unseal-key material)
    Stopping openbao for a consistent storage-directory snapshot
    Copied unseal key shares ...
    Exported 1 secret(s) under secret/devenv-cloud/.
==> [5/5] Workspace persistent state (coder-*-home volumes)
    Archiving volume: coder-25b6ebca-5e45-40e0-96f7-9635cca1053b-home
==> Backup complete: .../backup/artifacts/m14-e2e-test
```

(`make backup` with no argument does the same thing, naming the set after
the current UTC timestamp instead.)

## 3. Destroy the MUST-BACK-UP resources only

```
$ docker stop coder-admin-demo-e2e && docker rm coder-admin-demo-e2e
$ docker compose stop coder coder-db temporal temporal-db temporal-ui temporal-worker openbao
$ docker compose rm -f coder coder-db temporal temporal-db temporal-ui temporal-worker openbao
$ docker volume rm devenv-cloud_coder_db_data devenv-cloud_temporal_db_data \
    devenv-cloud_openbao_data coder-25b6ebca-5e45-40e0-96f7-9635cca1053b-home
```

`registry`, `prometheus`, `grafana`, `loki`, `opa`, `lab-sim`,
`runner-docker-proxy`, `runner-health`, `cadvisor`, `otel-collector`,
`promtail` were left untouched throughout (REPRODUCIBLE set, per
`backup/backup-policy.md`).

## 4. `make restore-test` (run as its constituent steps for this log — see
milestone report for the single-command form)

1. **Coder database** — `pg_restore --clean --if-exists` into a fresh
   `coder-db`. Verified:
   ```
   $ docker exec coder-db psql -U coder -d coder -c "select name from workspaces;"
   ...
   demo-e2e
   ...
   ```
2. **Temporal database** — `pg_restore` of `temporal` +
   `temporal_visibility` into a fresh `temporal-db`, `temporal` server
   brought back up against it. Verified:
   ```
   $ docker exec temporal-db psql -U temporal -d temporal -c "select count(*) from executions;"
    count
   -------
       23
   $ docker exec temporal temporal --address 127.0.0.1:7233 workflow show \
       --workflow-id demo-durable-workflow-eea73faa
   ...
     22  ...  WorkflowExecutionCompleted
   Results:
     Status          COMPLETED
     Result          "prepared:demo-c6cd68fa -> verified:prepared:demo-c6cd68fa"
   ```
   Full Event History intact, including the completion the worker recorded
   before the destroy.
3. **OpenBao** — fresh `openbao_data` volume, raw storage-directory tar
   extracted into it, container started against the restored storage
   (came back `Initialized: true, Sealed: true` — proving it's the
   *restored* storage, not a fresh init), then unsealed with the
   **backed-up** key shares from `backup/artifacts/m14-e2e-test/openbao/init.json`:
   ```
   $ docker exec openbao bao operator unseal ... <key1/2/3 from backup>
   ...
   Sealed          false
   $ docker exec openbao bao kv get -format=json secret/devenv-cloud/m14-test
   ...
   "marker": "m14-test-secret-20260829T064610Z"
   ```
   Confirms the *original* unseal key shares — not a freshly-generated
   set — are what unseal the restored instance, and the test secret
   survives.
4. **Workspace persistent home** — fresh volume created from
   `coder-25b6ebca-...-home.tar.gz`:
   ```
   $ docker run --rm -v coder-25b6ebca-...-home:/data alpine:3.20 sh -c \
       "cat /data/m14-marker.txt; cat /data/worktrees/m14-session/session-marker.txt"
   m14-marker-20260829T064800Z-8032
   m14 session data
   ```
   Byte-for-byte identical to what was written in step 1.
5. **Coder brought back up**, workspace `admin/demo-e2e` stopped/started
   (forces Terraform to recreate `docker_container.workspace` against the
   **existing, restored** `docker_volume.home_volume` — same name, per its
   `lifecycle { ignore_changes = all }`):
   ```
   $ coder stop demo-e2e --yes && coder start demo-e2e --yes
   ...
   The demo-e2e workspace has been started ...
   $ docker exec coder-admin-demo-e2e cat /home/coder/m14-marker.txt
   m14-marker-20260829T064800Z-8032
   $ docker exec coder-admin-demo-e2e git -C /home/coder/worktrees/m14-session branch --show-current
   agent/m14-session
   ```

## Result

All five checks in `docs/plan/steps/.../00100-backup-restore.md`'s
Validation Milestone M14 passed:

- [x] Workspace marker file — byte-for-byte identical after full
      destroy/recreate of the container **and** the volume.
- [x] Temporal workflow — Event History fully intact, including
      `WorkflowExecutionCompleted`.
- [x] OpenBao secret — retrievable after a genuine restore (unsealed with
      the *backed-up* key shares, not a freshly generated set).
- [x] Agent/session data (M5 worktree + branch) — intact inside the
      restored workspace-home volume.
- [x] Every "MUST BACK UP" category restored independently; every
      "REPRODUCIBLE" service was left running throughout, untouched.

Post-stack health after restore: `docker compose ps` — all 18 services
`Up`/healthy, including `coder`, `coder-db`, `temporal`, `temporal-db`,
`temporal-ui`, `temporal-worker`, `openbao`.
