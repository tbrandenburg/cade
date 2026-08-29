> Mandatory: read the overall plan in full before proceeding: docs/plan/plan.md

# Phase 4 — Governance & Observability

## Gap: M12/M12.1 governance deliverables are entirely uncommitted

Independent review of the closed step
`docs/plan/steps/in-review/00200-e2e-governance-denial-proof.md` found that
every file this step (and the preceding M12 governance-foundation step)
claims to have created is **untracked in git** — `git ls-files governance/`
returns zero files, and the following are all `??` in `git status`:

- `governance/` (entire directory: OPA policy + tests, OpenBao config,
  certs, unseal material)
- `mcp/lab-sim/src/lab_sim/policy.py`
- `scripts/openbao-init.sh`
- `scripts/verify-governance.sh`
- `docs/milestone-reports/M12-governance.md`

This directly repeats the exact pitfall already documented in this repo's
own `AGENTS.md` under "Before trusting any 'blocker' or 'done' claim":
*"uncommitted files don't exist for a workspace that clones from the
remote (the single biggest cause of false 'done' claims)"* and *"Commit +
push every deliverable as the first action of a step, before writing the
milestone report."* All live validation in this review (`opa test`,
`scripts/verify-governance.sh`, live OPA decision API calls) passed
against the **local working tree only** — a fresh clone of `origin/main`
would have none of this governance stack and would fail every one of
these checks.

Note: `docs/security.md`'s M12 section and `scripts/openbao-gen-cert.sh`
were already committed in `3ddaba9`, so this gap is scoped to the
remaining, still-untracked files listed above.

## Actions

1. Review `.gitignore` to confirm only the intended secret-bearing paths
   are excluded (`governance/openbao/certs/*.crt`, `*.key`,
   `governance/openbao/data/`, `governance/openbao/unseal/`) and that no
   other governance file is accidentally ignored.
2. `git add` and commit the following, in a commit that matches this
   repo's conventional-commit style:
   - `governance/opa/policy/lab_authz.rego`
   - `governance/opa/policy/lab_authz_test.rego`
   - `governance/openbao/config/openbao.hcl`
   - any other tracked-worthy file under `governance/` not covered by
     `.gitignore`
   - `mcp/lab-sim/src/lab_sim/policy.py`
   - `scripts/openbao-init.sh`
   - `scripts/verify-governance.sh`
   - `docs/milestone-reports/M12-governance.md`
3. Push the commit to `origin/main` and verify with
   `git log origin/main..HEAD --oneline` (must be empty) and
   `git ls-files governance/ | wc -l` (must be non-zero).
4. Re-run `bash scripts/verify-governance.sh` against a fresh clone (or at
   minimum confirm `git status --short` is clean for all files above) to
   prove the governance stack is reproducible from `origin/main` alone,
   not just the current working tree.
