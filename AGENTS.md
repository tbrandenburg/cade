# AGENTS.md — devenv-cloud

Instructions and accumulated knowledge for any AI agent (human or automated) working in this repository. Update this file at the end of every phase per `docs/phases/README.md`.

## How to use this file

- Read this file before starting work on any phase or milestone.
- Read `docs/ARCHITECTURE.md` alongside it — a condensed C4-model (Context/Container/Component) view of the platform, based on `docs/devenv-cloud.png` and `docs/INITIAL.md` Section 2. Use it for quick orientation; `docs/INITIAL.md` remains authoritative for details.
- Update it before closing out a phase — do not leave it stale.
- Keep entries dated and attributed to a phase/milestone so history stays traceable.
- Prefer appending to "Lessons Learned" over rewriting history; only edit "Guidelines" when a rule changes.

## Guidelines

_(Populated incrementally as phases complete. Each phase adds concrete, binding guidance discovered during its implementation — not restated theory from `docs/INITIAL.md`.)_

## Agent Instructions

_(Concrete, current instructions for whichever CLI harness — `opencode` or `pi` — is operating in this repo: how to invoke platform commands, what not to touch, where secrets live, how to run validations.)_

## Lessons Learned

_(Dated log, one entry per phase, of what broke, what surprised us, and what to avoid next time.)_

- 2026-08-28 (M0 review of step 00101): A gap-fill step was moved to `in-review` without
  actually producing its own required deliverable (`docs/milestone-reports/M0-host.md` was
  never created, even though the underlying tooling it depended on — `make doctor`,
  `docker run --rm hello-world` — worked correctly). Reviewers must independently verify
  that every artifact a step file promises to create actually exists on disk, not just that
  the checks it depends on pass.
- 2026-08-28 (M0 review of step 00102): The very same gap recurred a second time — a
  second gap-fill step closed itself without creating `docs/milestone-reports/M0-host.md`,
  again only re-verifying that `make doctor`/`docker run --rm hello-world` still work.
  Re-verifying dependent tooling is not evidence the step's own deliverable was produced;
  always check for the deliverable file on disk (`ls`/`git log --all -- <path>`) as the
  first, non-negotiable step of reviewing any gap-fill whose sole purpose is to create a
  specific file.
- 2026-08-28 (M0 review of step 00102, third occurrence): Reviewed again — `docs/milestone-reports/M0-host.md`
  is still missing on disk and in `git log --all`, despite two prior gap-fill steps (00101, 00102)
  existing solely to create it. A third gap-fill (00103) was raised. If this recurs again, escalate:
  stop spawning more gap-fill steps with the same instructions and instead flag that the
  implementer is systematically unable/unwilling to perform this specific action, so a human
  can intervene.
- 2026-08-28 (M0 review of step 00103): Confirmed `docs/milestone-reports/M0-host.md` now exists on
  disk, is committed (`git log --all -- docs/milestone-reports/M0-host.md` shows commit `3b97dea`),
  and independently re-running `docker run --rm hello-world` and `make doctor` reproduces the exact
  PASS/exit-0 results documented in the report. Third gap-fill attempt succeeded where the first two
  did not — evidence the escalation path (explicit third gap-fill with prior failures cited) is
  effective; no further gap needed for this deliverable.
- 2026-08-28 (M3 implementation): Three non-obvious pitfalls building `coder/Dockerfile` and
  `coder/templates/docker-workspace/`: (1) `ubuntu:24.04` already ships a `ubuntu` group/user at
  uid/gid 1000, so a plain `groupadd --gid 1000 coder` fails — detect and rename the existing
  group/user instead of assuming a fresh id space. (2) A `RUN --mount=type=secret,id=cacert`
  layer that ran once without the secret present gets BuildKit-cached as a no-op; a later build
  invoked *with* `--secret id=cacert,...` silently reuses that stale cached layer unless the
  build is re-run with `--no-cache` (at least for that layer) — don't trust "the secret step
  didn't error" as proof the cert was actually installed. (3) `coder templates push` only
  uploads the template's own directory to the provisioner, not the surrounding repository, so a
  `docker_image` resource cannot reference a Dockerfile via `${path.module}/../../...` — build
  and tag the workspace image out-of-band first (`make coder-workspace-build`) and have the
  Terraform `docker_container` reference that pre-built tag by name instead.
- 2026-08-28 (M3 review of step 00300): Independent re-verification found the entire
  `coder/`, `examples/`, `Makefile`, `compose.yaml` tree existed only as uncommitted
  working-tree changes (`git ls-files` showed none tracked, `git log --all` showed no
  commits touching them). Because the Coder workspace template clones the *remote*
  repository, not the local working tree, a real `coder create` against the real
  remote produced a workspace missing `examples/hello-service` entirely, so
  `make -C examples/hello-service build` failed — contradicting the milestone
  report's claimed passing transcript. Always `git status --short` / `git log --all
  -- <path>` for every path a step claims to have created, *before* trusting any
  milestone report's command transcript, especially for steps whose validation
  depends on cloning this same repository from a remote.
