> Mandatory: read the overall plan in full before proceeding: docs/plan/plan.md
> Escalation for: docs/plan/steps/in-review/00404-complete-m4-e2e-workspace-and-report.md
> (fifth consecutive miss on the same deliverable: 00401, 00402, 00403, 00404, and now this)

# ESCALATION: `docs/milestone-reports/M4-agent-host.md` still does not exist after five attempts — requires human intervention

## Why this matters

Independent re-verification of `00404` at review time:

- `docs/milestone-reports/M4-agent-host.md` **still does not exist** on disk (`ls
  docs/milestone-reports/` shows only `M0-host.md`, `M1-compose.md`, `M3-coder.md`) and
  `git log --all -- docs/milestone-reports/M4-agent-host.md` returns empty. This is now
  the **fifth** consecutive step (00401, 00402, 00403, 00404, and this escalation) whose
  sole or primary purpose includes producing this one file, and it is still missing.
- A workspace was in fact created this time — `coder list -a` shows `admin/m4-e2e-v2`
  (template `docker-workspace`, version `varied_lang29`, `Started`, `healthy=false`) and
  `docker ps` confirms a real, running backing container (`coder-admin-m4-e2e-v2`,
  image `devenv-cloud/coder-workspace:latest`, up ~1 min at review time). So action 2 of
  `00404` was attempted.
- However, the workspace is **not usable for the required verification**: its startup
  log (`docker exec coder-admin-m4-e2e-v2 cat /tmp/coder-startup-script.log`) shows:
  ```
  Cloning into '/home/coder/project'...
  remote: Repository not found.
  fatal: repository 'https://github.com/tbrandenburg/devenv-cloud.git/' not found
  ```
  This is the same private-repo-clone failure mode documented as a known pitfall in
  `AGENTS.md` (M3 step 00302 lesson) — the `docker-workspace` template exposes an
  optional `github_token` `coder_parameter` for exactly this case
  (`coder/templates/docker-workspace/main.tf`), but this workspace was created without
  supplying it. As a direct consequence: `/home/coder/project` does not exist,
  `/home/coder/.vscode/settings.json` does not exist (confirmed via `docker exec ... ls`),
  and none of actions 3-6 of `00404` (SSH config, `verify-agent-host.sh`,
  `verify-ahp-session.sh`, Manual E2E Test, report write) were ever attempted or could
  have succeeded against this container.
- No commit was made for `docs/milestone-reports/M4-agent-host.md` — action 7 of `00404`
  was not reached.

Per the escalation clause written into `00404` itself: *"If this gap-fill also fails to
produce the report, the next reviewer must stop creating further identically-scoped
gap-fills and instead flag this as a systemic implementer failure requiring human
intervention."* This step follows that instruction: it is **not** another "do the same 8
actions again" gap-fill. It records the concrete, previously-unidentified root cause
(missing `github_token` parameter on workspace creation) so a human or a differently-scoped
follow-up can break the cycle, and it asks for human sign-off before any further automated
attempt at this specific deliverable.

## Required actions

1. **Do not** spawn another gap-fill that repeats `00404`'s action list verbatim. A human
   (or a session with confirmed interactive access to supply/store a valid GitHub token
   secret) must decide how the `github_token` parameter is meant to be supplied in this
   environment for non-interactive `coder create` calls before workspace-creation-based
   verification can succeed at all.
2. Once a valid `github_token` (or equivalent auth) is available, create the workspace
   with it explicitly, e.g.:
   `coder create admin/m4-e2e-v3 --template docker-workspace --yes -p github_token=<token>`
   (confirm the actual parameter-passing flag against `coder create --help`, since `-p`
   syntax varies by CLI version), then verify `/home/coder/project` and
   `/home/coder/.vscode/settings.json` exist before proceeding to the SSH/AHP checks.
3. Clean up the currently-orphaned, unusable `admin/m4-e2e-v2` workspace
   (`coder delete admin/m4-e2e-v2 --yes`) so it does not accumulate alongside future
   attempts and confuse subsequent reviewers about which container is the live one.
4. Only after a workspace with a successful clone is confirmed, resume actions 3-8 of
    `docs/plan/steps/in-review/00404-complete-m4-e2e-workspace-and-report.md` verbatim
   (SSH config, `verify-agent-host.sh`, `verify-ahp-session.sh`, settings.json check,
   Manual E2E Test attempt, write and commit `docs/milestone-reports/M4-agent-host.md`).
5. If a human determines that no non-interactive credential can be provisioned in this
   environment, the report itself must say so explicitly and record that the M4
   Manual E2E Test could not be completed for that documented reason — do not leave the
   deliverable silently missing forever.
