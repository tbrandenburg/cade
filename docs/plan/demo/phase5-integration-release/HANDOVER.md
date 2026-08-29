# Handover — Phase 5: Integration & Release (`0.1.0`)

## a. Executive summary

Phase 5 is the final integration phase of **devenv-cloud**, a Docker-first,
single-repository private developer platform that runs entirely on one
Linux server: remote development workspaces (Coder), agent-assisted coding
(VS Code Agent Host + `opencode`/`pi`), GitHub automation (self-hosted
runner + `gh-aw` failure investigation), durable orchestration (Temporal),
a policy-gated capability fabric for simulated lab hardware (MCP + OPA +
OpenBao), and centralized observability (Prometheus/Loki/Grafana) — with no
inbound Internet exposure and no paid cloud infrastructure.

This phase added the two capabilities that make the platform trustworthy
to actually operate, not just demo:

1. **Backup / Restore (M14)** — every category of state that cannot be
   regenerated from source (platform repo, Coder DB, Temporal DB, OpenBao,
   persistent workspace home volumes) is captured by `make backup` into a
   single timestamped artifact set, and has been proven restorable
   end-to-end, including the OpenBao unseal step (a restored OpenBao
   instance starts **sealed** and is useless without the separately
   backed-up unseal keys).
2. **Final Acceptance & Release (M15/M16)** — the full cross-service loop
   (GitHub issue → agent investigation → self-hosted-runner CI → durable
   Temporal workflow → policy-gated lab-hardware call → result posted back
   to GitHub) was run for real, plus all three "durability boundary" tests
   proving each layer (VS Code session, Temporal workflow, Coder
   workspace) independently survives the failure it claims to survive.
   The platform was tagged `0.1.0` on completion.

This handover re-verifies the live system **today**, against the actual
running stack — no mocks, no stubs, no skipped steps — and captures fresh
evidence alongside the original milestone reports under
`docs/milestone-reports/`.

## b. What works — with evidence

| Feature | Evidence |
|---|---|
| All 18 platform services (Coder, Temporal, OpenBao, OPA, MCP lab-sim, Prometheus/Loki/Grafana, self-hosted-runner support services, registry, cAdvisor) report healthy/Up on the real running stack | [`01-make-status.txt`](01-make-status.txt) |
| Governance (M12) still live-enforces policy: `opa test` 6/6, `run_test`=ALLOW, `flash_device` unapproved=DENY / approved=ALLOW, via a real MCP tool round trip against `lab-sim` | [`02-governance-verify.txt`](02-governance-verify.txt) |
| Durable orchestration baseline: a fresh Temporal workflow (`demo-durable-workflow-*`) runs end-to-end through the real `temporal-worker` container | [`03-temporal-workflow-baseline.txt`](03-temporal-workflow-baseline.txt) |
| **Durability Test 2 (Temporal, live-repeated)**: a new workflow was started, `docker compose restart temporal-worker` was issued *while it was running*, and the same workflow still completed with a correct result after the worker came back | [`04-temporal-workflow-during-restart.txt`](04-temporal-workflow-during-restart.txt) + [`05-temporal-worker-restart.txt`](05-temporal-worker-restart.txt) |
| **Backup (M14, live-repeated)**: `make backup` executed a full backup cycle across all 5 MUST-BACK-UP categories (git bundle, Coder DB pg_dump, Temporal DB pg_dump incl. Visibility, OpenBao raw-storage snapshot + KV export + unseal keys, `coder-*-home` volume tar) against the real running stack | [`06-backup-run.txt`](06-backup-run.txt) (full restore-cycle proof previously captured in `docs/milestone-reports/M14-backup.md`) |
| **Durability Test 3 (Coder, prior evidence)**: a live Coder workspace (`admin/demo-e2e`) is running today with its persistent home volume intact, including `m14-marker.txt` written during the original M14 backup/restore validation — proving the home volume has survived every workspace stop/start and container recreate since | [`07-coder-workspaces.txt`](07-coder-workspaces.txt) + [`08-coder-ssh-check.txt`](08-coder-ssh-check.txt) |
| Coder dashboard reachable and shows the healthy workspace | [`09-coder-workspaces-dashboard.png`](09-coder-workspaces-dashboard.png) |
| Grafana "Phase 4 - Observability" dashboard renders live, non-zero metrics from the actions above (Temporal activity counts, MCP request counts, container uptime) | [`10-grafana-observability-dashboard.png`](10-grafana-observability-dashboard.png) |
| GitHub loop is real: public repo, self-hosted-runner CI (`embedded-build`) completing successfully, and the `CI Failure Investigator` (`gh-aw`) workflow firing on `workflow_run` events | [`11-github-repo.txt`](11-github-repo.txt) + [`12-github-runs.txt`](12-github-runs.txt) |
| Temporal UI shows the real workflow execution history, including the workflows started during this verification | [`13-temporal-ui-workflow-history.png`](13-temporal-ui-workflow-history.png) |

The full Final E2E Test Request (A–L) and all three Durability Boundary
Tests were originally executed and recorded in
`docs/milestone-reports/M15-e2e.md` and `docs/milestone-reports/M16-final-acceptance.md`;
the items above are a fresh, independent re-verification of the
highest-risk claims (durability under failure, backup integrity, live
governance enforcement), not a re-statement of those reports.

## c. How to build and run

1. Clone the repository and `cd` into it.
2. Copy `.env.example` to `.env` and fill in the required values (GitHub
   token/App credentials, `GRAFANA_ADMIN_PASSWORD`, etc. — see
   `.env.example` comments for each).
3. `make doctor` — verifies the host meets baseline requirements
   (OS/arch/tooling/disk/network/ports) before anything else runs.
4. `make up` — starts the platform control plane (Postgres + Coder).
5. `docker compose up -d` — brings up the remaining services (self-hosted
   runner support, Temporal, MCP lab-sim, governance, observability).
6. `make governance-bootstrap` — one-time OpenBao init/unseal + credential
   rotation. Re-run this any time the `openbao` container is recreated —
   it does not auto-unseal.
7. `make status` — confirm every service shows `(healthy)`/`Up` before
   proceeding to create a workspace or trigger a workflow.
8. `make coder-workspace-build` (or `make embedded-workspace-build` for
   the embedded template) — builds the workspace image the Coder template
   provisions. Requires a clean git tree (no uncommitted changes in
   `examples/`, `coder/`, `Makefile`).
9. Create a workspace: `coder create <owner>/<name> --template
   docker-standard --parameter github_token=<token> --yes` (every
   `coder_parameter` must be passed explicitly).
10. Full walkthrough of the end-to-end scenario, including all three
    Durability Boundary Tests, is documented step-by-step in the repo's
    `AGENTS.md` under "How to run the full end-to-end scenario yourself".

## d. How to test

| Action | Expected result |
|---|---|
| `make status` | All 18 services show `Up`/`(healthy)` |
| `bash scripts/verify-governance.sh` (or `make governance-verify`) | `opa test` → `PASS: 6/6`; live MCP round trip shows `flash_device (unapproved): is_error=True` and `flash_device (approved): is_error=False` |
| Start a Temporal workflow, then `docker compose restart temporal-worker` mid-run | The workflow still completes with `result=prepared:... -> verified:prepared:...` after the worker restarts (Durability Test 2) |
| `coder stop <owner>/<name> --yes && coder start <owner>/<name> --yes`, checking a marker file written to `/home/coder` before stopping | The file exists afterward with byte-for-byte identical content (Durability Test 3) |
| `make backup` | Produces `backup/artifacts/<timestamp>/` containing a git bundle, two DB dumps, an OpenBao snapshot + unseal-key copy, and a tar of every `coder-*-home` volume |
| `make restore-test` | Destroys the MUST-BACK-UP resources and restores them from the latest backup set; verify per `backup/restore-test.md` and `docs/disaster-recovery.md` |
| Open `http://127.0.0.1:3001/d/phase4-observability` | Panels show live, non-zero data correlated with the actions above |
| `gh run list --workflow=embedded-build.yml --limit 1` | Shows a `completed`/`success` run on the self-hosted runner |

## e. Known limitations

- `gh-aw`'s MCP Gateway/AWF sandbox requires a real Docker Unix socket;
  the `runner-docker-proxy` (`tecnativa/docker-socket-proxy`) used to keep
  the self-hosted runner from having full Docker-socket access is
  explicitly unsupported by `gh-aw`, and it also has no AI-engine
  credentials configured — both limitations are documented (not silently
  worked around) in `docs/security.md`.
- OpenBao does **not** auto-unseal across a container restart/recreate —
  `make governance-bootstrap` (or `scripts/openbao-init.sh`) must be
  rerun whenever the container is recreated, or dependent services will
  report failures until it is unsealed again.
- This backend uses OpenBao's `storage "file"` backend (not `raft`), so
  backup/restore of OpenBao is a raw storage-directory snapshot plus a
  KV-level export, not `bao operator raft snapshot save` — see
  `backup/backup-policy.md` for the rationale.
- This is a local/demo-scale deployment (single Docker host, no HA, no
  paid cloud infrastructure). Wide-area/Tailscale remote access (Phase 6)
  is optional and was not exercised as part of the `0.1.0` release.
- The repository is currently **public** on GitHub — several
  self-hosted-runner safeguards (e.g. `gh-aw`'s integrity auto-filtering)
  are conditioned on this; re-verify repo visibility before relying on
  those safeguards if the repo is ever made private.
