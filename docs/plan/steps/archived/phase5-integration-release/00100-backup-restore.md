> Mandatory: read the overall plan in full before proceeding: docs/plan/plan.md

# Phase 5 — Integration & Release

## M14 — Backup / Restore

### Objective

By this point the stack has state scattered across many services. `scripts/backup.sh` / `scripts/restore-test.sh` were created early in the plan but never actually validated with a real milestone. **A backup nobody has restored is not a backup strategy.**

### Classify State

```text
MUST BACK UP
platform repository
Coder database
Temporal database (incl. Visibility store, if on a separate backend from Persistence — confirm this stack uses Postgres for both)
OpenBao
important workspace state (persistent /home/coder, incl. agent memory/session state)

REPRODUCIBLE / DON'T NEED BACKUP
containers
Docker images you can rebuild
Dev Containers
toolchains generated from Dockerfiles
build caches (registry, sccache)
temporary agent worktrees
```

Document this classification in `backup/backup-policy.md`, including:

- **OpenBao:** back up via `bao operator raft snapshot save` (Integrated Storage/Raft), not a raw volume copy, and separately back up the unseal keys/KMS reference — a restored instance starts **sealed** and unusable without them.
- **Coder home persistence is a template property, not automatic** — verify the workspace templates pin the home volume to an immutable resource ID (`coder_workspace.me.id`) with `lifecycle { ignore_changes = all }`; a naive template can silently wipe the "persistent" volume on restart.

### Validation Milestone M14

1. Create workspace, and write a marker file with a unique, timestamped value into `/home/coder`.
2. Create Temporal workflow.
3. Store test secret (in OpenBao, per Phase 4 M12).
4. Create agent/session data (per Phase 1 M4/M5).
5. Run `make backup` (OpenBao via raft snapshot save; unseal keys backed up separately).
6. Destroy relevant containers/volumes (the "MUST BACK UP" set only).
7. Run `make restore-test` (OpenBao via raft snapshot restore, then unseal).
8. Verify state: workspace (marker file byte-for-byte identical — not just "workspace starts"), workflow, secret, and agent/session data are all recovered.

### Manual E2E Test M14

Run the 8-step sequence above against the real stack — not a dry run. Confirm each of the four "MUST BACK UP" categories independently:

1. Repository/platform config restored.
2. Coder database restored (workspace metadata intact).
3. Temporal database restored (workflow history intact, including Visibility store if separate).
4. OpenBao restored via raft snapshot restore, then successfully unsealed with the backed-up keys, test secret still retrievable.
5. Persistent workspace home restored — verified via the marker-file content check, not just "workspace starts."

Record in `backup/restore-test.md` and `docs/milestone-reports/M14-backup.md`.
