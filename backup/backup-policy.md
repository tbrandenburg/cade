# Backup Policy (M14)

Classification of platform state, per `docs/plan/plan.md` M14. Scripts:
`scripts/backup.sh` (create a backup set) and `scripts/restore-test.sh`
(destroy the "MUST BACK UP" resources and restore them from a backup set,
proving the backup is actually usable).

## MUST BACK UP

| Category | Source | Mechanism |
|---|---|---|
| Platform repository | this git working tree (all local branches/tags/HEAD) | `git bundle create --all` |
| Coder database | `coder-db` Postgres container, `coder` database | `pg_dump` (custom format) |
| Temporal database | `temporal-db` Postgres container, `temporal` **and** `temporal_visibility` databases (this stack uses Postgres for both Persistence and Visibility — confirmed via `psql -l` inside `temporal-db`, no separate Elasticsearch/OpenSearch backend) | `pg_dump` per database |
| OpenBao | `openbao` container, KV-v2 secrets under `secret/` | see "OpenBao backup" below — **not** a raw volume copy |
| Workspace persistent state | every Docker volume named `coder-*-home` (the `/home/coder` mount for a Coder workspace's `docker_container`, per `coder/templates/*/main.tf`'s `docker_volume.home_volume` — includes cloned repos, worktrees, agent memory/session state, and `~/.vscode-server`) | `tar` of the volume's contents |

## REPRODUCIBLE / DON'T NEED BACKUP

containers; Docker images (rebuildable via `make *-build`); Dev Containers;
toolchains generated from Dockerfiles; build caches (`registry`,
sccache-style caches); temporary agent worktrees created purely for
in-flight session isolation (the worktree *mechanism* is reproducible —
any *uncommitted* work inside one is not distinct from the workspace-home
backup above, since worktrees live under the same `coder-*-home` volume).

## OpenBao backup — deviation from the plan's literal wording, and why

The plan's generic guidance says back up OpenBao via
`bao operator raft snapshot save` (Integrated Storage/Raft), not a raw
volume copy. **This deployment does not use the `raft` storage backend.**
`governance/openbao/config/openbao.hcl` (written in M12, unchanged here)
configures `storage "file"` — a deliberate, documented choice for this
single-node local stack with no HA requirement. Confirmed live:

```
$ docker exec openbao bao status -tls-skip-verify -address=https://127.0.0.1:8200
...
Storage Type       file
...
$ docker exec openbao bao operator raft snapshot save -tls-skip-verify -address=https://127.0.0.1:8200 /tmp/test.snap
Error taking the snapshot: ... 403 permission denied  (endpoint exists but is
meaningless without a raft storage stanza — OpenBao/Vault's own docs
restrict `operator raft snapshot` to the Integrated Storage backend)
```

`operator raft snapshot save` has no defined behavior against a `file`
backend, and — critically — Shamir unseal key shares are cryptographically
derived from one specific `bao operator init` run against one specific
storage state. Re-running `bao operator init` against an empty volume
always mints a **brand-new** master key and a brand-new set of unseal key
shares; the *old* key shares can never unseal a *newly initialized*
instance, no matter how they were backed up. The only way to make "unseal
with the backed-up key shares" true after a restore (as the plan's Manual
E2E Test step 4 requires) is to restore the **same on-disk storage state**
those keys were originally generated against — for the `file` backend,
that means the storage directory itself. This stack backs up OpenBao as
follows:

1. **Raw copy of the `file` storage directory** (`/openbao/data`, the
   `openbao_data` Docker volume) — briefly `docker compose stop openbao`
   first (this *is* the mechanism-appropriate equivalent of a raft
   snapshot for this backend: a point-in-time, consistent copy of the
   storage the master key/data actually live in), tar it, then restart.
   This is the artifact that gets restored and is what makes "unseal with
   the backed-up keys" actually possible.
2. A supplementary, human-readable **KV export** (every secret under
   `secret/devenv-cloud/*`, via `bao kv get -format=json` for each path
   found by `bao kv list`) — useful for inspection/cross-checking a
   restore, and as a disaster-recovery fallback if the raw volume were
   ever lost while the key shares survive (in that scenario a **fresh**
   `bao operator init` + this JSON replay recovers the data, just under a
   new master key/unseal shares — the KV export alone. cannot make the old
   shares valid again).
3. **Unseal keys / root-of-trust are backed up separately, never inside
   the same backup set as the data**, per the plan's explicit warning that
   a restored instance starts **sealed** and unusable without them:
   `governance/openbao/unseal/init.json` (already gitignored, produced by
   `scripts/openbao-init.sh`) is the canonical, out-of-band location for
   the unseal key shares and (until revoked) the root token. `backup.sh`
   copies it into the backup set's `openbao/` directory purely so
   `restore-test.sh` can unseal in this *local test* environment — a real
   deployment must instead keep this file in a password manager / physical
   safe, never alongside the data backup.
4. Restore path: recreate the `openbao_data` volume, extract the raw
   storage-directory tar into it, start the container against that
   restored storage (still sealed — a fresh container start never
   auto-unseals), then unseal with the **backed-up** key shares from step
   3. Policies/auth methods (AppRole, `devenv-cloud-read`) come back
   automatically since they were part of the restored storage directory —
   nothing needs to be re-bootstrapped.

This preserves the *intent* of the plan's OpenBao guidance (a
mechanism-appropriate, consistent snapshot of the actual storage backend
in use, plus unseal material tracked and restored independently of the
data) while being correct — and actually testable end-to-end — for the
storage backend this stack runs.

## Coder home persistence caveat

Per the plan and `AGENTS.md`: Coder workspace home persistence is a
**template property**, not automatic. `coder/templates/*/main.tf` pins
`docker_volume.home_volume` to `coder-${data.coder_workspace.me.id}-home`
with `lifecycle { ignore_changes = all }`, so `coder stop`/`start` never
recreates it — verified in the M14 validation below by restoring the
volume's tar archive into a volume of that exact name and confirming the
workspace's marker file survives a full destroy/recreate of the
underlying container.
