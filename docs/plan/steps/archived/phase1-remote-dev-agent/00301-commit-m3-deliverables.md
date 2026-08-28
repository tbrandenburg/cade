> Gap-fill step for 00300-coder-development-workspace.md (review finding).

# Gap: M3 deliverables were never committed, so the E2E validation report describes an impossible workflow

## Why this matters

Reviewing `docs/plan/steps/in-review/00300-coder-development-workspace.md`, every file
the step claims to have created exists **only as uncommitted working-tree changes**:

```
$ git status --short
 M .gitignore
 M AGENTS.md
?? .env.example
?? Makefile
?? coder/
?? compose.yaml
?? doc/
?? docs/milestone-reports/M1-compose.md
?? docs/milestone-reports/M3-coder.md
?? examples/
?? scripts/
```

`git ls-files | grep -E "^(coder|examples|Makefile|compose.yaml)"` returns nothing —
none of `coder/Dockerfile`, `coder/templates/docker-workspace/`,
`examples/hello-service/`, `Makefile`, or `compose.yaml` have ever been part of a
commit, on any branch (`git log --oneline --all -- coder examples/hello-service` is
empty).

`coder/templates/docker-workspace/main.tf` has the `coder_agent` clone the
`repo_url` variable, which defaults to
`https://github.com/tbrandenburg/devenv-cloud.git` — i.e. the **remote** repository,
not this local working tree. Independent re-verification confirmed this is fatal to
the milestone's own claims:

1. Brought up `compose.yaml` for real (`docker compose up -d`), built
   `devenv-cloud/coder-workspace:latest` for real (`make coder-workspace-build`,
   cache-hit, reproducible), pushed the `docker-standard` template for real via the
   `coder` CLI inside the `coder` container, and created a real workspace
   (`coder create admin/m3-review-test --template docker-standard --yes`).
2. Inside the running workspace container, `git status` on the auto-cloned repo
   showed a clean checkout of `origin/main` — but `ls /home/coder/project` proved
   the checkout contains **no** `examples/`, `coder/`, `Makefile`, or `compose.yaml`
   (confirmed against `git show origin/main --stat`, whose last commit is
   `8065916`, predating all M3 work).
3. Consequently `make -C examples/hello-service build` inside the freshly cloned
   workspace fails with `make: *** examples/hello-service: No such file or
   directory. Stop.` — the exact opposite of what
   `docs/milestone-reports/M3-coder.md` reports (`build: OK`, `3/3 tests OK`).

The milestone report's "Validation Milestone M3" and "Manual E2E Test M3" sections
therefore describe a sequence of commands that cannot have produced the transcript
shown, because the workspace clones the *remote* repository, and the remote never
had these files. Either the report's transcript was fabricated/copied from a local
(non-cloned) run, or it was run once before against a different, since-diverged
remote state — either way the milestone's own required question ("Could a new
developer become productive without configuring the development environment
manually?") is currently **unverifiable as documented**, because a real
`Create Workspace → docker-standard` today clones a repo missing the very
example this milestone depends on.

Everything else independently re-verified as correct and reproducible:
`coder/Dockerfile` builds cache-hit-clean and produces the exact toolchain
versions the report claims (`git 2.43.0`, `Python 3.12.3`, `node v20.20.2`,
`gh 2.98.0`, `Docker 29.7.2`); the non-root `coder` user/uid/gid setup works;
`examples/hello-service`'s `make build`/`make test` pass when run directly against
the tracked-on-disk files; the Terraform template pushes and provisions cleanly
(5 resources created) once the documented `DOCKER_GID`/`CACERT` prerequisites are
supplied correctly.

## Required actions

1. Commit all M3 (and any other currently-uncommitted-but-completed) deliverables
   to the repository on the appropriate branch, at minimum:
   - `Makefile`, `compose.yaml`, `.env.example`
   - `coder/Dockerfile`, `coder/templates/docker-workspace/`
   - `examples/hello-service/`
   - `scripts/` (referenced by `make doctor`)
   - `doc/` (plan tree, if not already tracked elsewhere) and
     `docs/milestone-reports/M1-compose.md`, `docs/milestone-reports/M3-coder.md`
   - Push to whatever remote/branch `coder/templates/docker-workspace/variables.tf`'s
     `repo_url` default (or the CI-configured override) actually points the
     workspace template at.
2. Re-run the full Validation Milestone M3 and Manual E2E Test M3 sequence
   **against a freshly created workspace cloning the now-updated remote**, end to
   end, and re-capture real command transcripts (do not reuse the existing
   `docs/milestone-reports/M3-coder.md` transcript, since it cannot be reproduced
   as-is).
3. Update `docs/milestone-reports/M3-coder.md` with the corrected, reproducible
   transcript, keeping the existing "GitHub push credentials" caveat for step 9 of
   the Manual E2E Test if it still applies in the CI/agent environment used to
   redo the run.
4. As a process safeguard, add a check (either in `make coder-workspace-build`'s
   preconditions, in CI, or as a one-line note in
   `coder/templates/docker-workspace/README.md`) that fails loudly if
   `git status --short` shows uncommitted files under `examples/`, `coder/`, or
   `Makefile` before a template push — to prevent this specific
   working-tree-vs-remote drift from silently invalidating future milestone
   evidence.
