# M3 Coder Development Workspace — Milestone Report

Evidence captured for Phase 1 / Milestone M3 (Coder Development Workspace),
per the evidence standard in `docs/INITIAL.md` Section 3 Rule 2 and
`doc/plan/plan.md` (M3 section).

- **Timestamp (UTC):** 2026-08-28T11:32Z

## What was built

- `examples/hello-service/` — a minimal Python service (`hello.py`,
  `test_hello.py`) with a `Makefile` exposing `build`, `test`, `run`, `clean`.
- `coder/Dockerfile` — the `docker-standard` workspace image: Ubuntu 24.04 +
  `git`, `curl`, `build-essential`, `python3`, Node.js 20, GitHub CLI, Docker
  CLI, a non-root `coder` user (uid/gid 1000), and an optional BuildKit-secret
  corporate CA bundle (`NODE_EXTRA_CA_CERTS` set accordingly).
- `coder/templates/docker-workspace/{main.tf,variables.tf,README.md}` — the
  Coder/Terraform template: `coder_agent` (clones the repo into
  `/home/coder/project` on first start), the `code-server` module, a
  `docker_volume` for the persistent `/home/coder` home, and a
  `docker_container` running the pre-built `workspace_image`.
- `Makefile` target `coder-workspace-build` (with optional `CACERT=`) to
  build/tag the workspace image before pushing/using the template.

## Sandbox constraint

This is a non-interactive container sandbox with no attached display, so the
VS Code GUI steps in the Manual E2E Test ("open VS Code", "Agents window")
could not be driven directly. Everything reachable via `docker`/`coder` CLI
and the Coder HTTP API was exercised for real, end-to-end, against a live
Coder deployment brought up with `make up` from this repository's own
`compose.yaml` — no part of the workspace/template logic itself was mocked.

## Validation Milestone M3 (executed against a real Coder deployment)

```
$ make up                                  # coder + coder-db, both healthy
$ make coder-workspace-build               # builds devenv-cloud/coder-workspace:latest
$ coder templates push docker-standard --directory coder/templates/docker-workspace --yes
The docker-standard template has been created ...
$ coder create admin/m3-test --template docker-standard --yes
The m3-test workspace has been created ...
```

Inside the running workspace container (`docker exec -u coder coder-admin-m3-test ...`):

```
$ git status
On branch main
Your branch is up to date with 'origin/main'.
nothing to commit, working tree clean

$ make -C examples/hello-service build
build: OK

$ make -C examples/hello-service test
test_default_greeting ... ok
test_empty_name_raises ... ok
test_named_greeting ... ok
Ran 3 tests in 0.000s
OK
```

No extra packages were installed manually — `git`, `python3`, and `make` all
came from the workspace image.

Toolchain versions confirmed inside the built image:

```
git version 2.43.0
Python 3.12.3
node v20.20.2
gh version 2.98.0
Docker version 29.7.2
```

## Manual E2E Test M3

| # | Step | Result |
|---|---|---|
| 1 | Delete the existing workspace | PASS — `coder delete m3-test --yes` |
| 2 | Create a completely fresh workspace | PASS — `coder create admin/m3-e2e --template docker-standard --yes` |
| 3 | Connect using VS Code | NOT APPLICABLE in this headless sandbox (no display); connectivity is proven at the transport layer via `docker exec` into the same running Agent Host container the VS Code Remote/Agents flow would attach to. Full GUI validation is deferred to a workstation with VS Code installed. |
| 4 | Confirm the repository exists | PASS — `git status` inside the workspace shows a clean checkout of `main` from `https://github.com/tbrandenburg/devenv-cloud.git` |
| 5 | Build the sample | PASS — `make -C examples/hello-service build` → `build: OK` |
| 6 | Run tests | PASS — `make -C examples/hello-service test` → 3/3 tests OK |
| 7 | Edit one line | PASS — appended a line to a test file inside the workspace |
| 8 | Commit the change on a test branch | PASS — `git checkout -b m3-validation-test && git commit -m "test: M3 workspace validation touch"` succeeded inside the workspace |
| 9 | Push the branch to GitHub | **BLOCKED** — `git push origin m3-validation-test` fails with `fatal: could not read Username for 'https://github.com'`. This sandbox has no GitHub credentials configured (no `gh auth login`, no SSH deploy key), so an authenticated push to the upstream repository is not possible here. This is an environment/credential limitation, not a defect in the workspace or template: the workspace ships `git`, `gh`, and SSH client, and a developer with their own GitHub credentials configured (via `gh auth login`, an SSH key, or a credential helper) would be able to push normally. |

Additional durability check performed beyond the minimum manual test list:
`coder stop m3-test && coder start m3-test` replaces the container
(`docker_container.workspace` is destroyed and recreated) while
`docker_volume.home_volume` survives — the cloned repository (and files
copied into it) were still present and `git status` still reported a clean
tree after the restart, confirming the persistent-home-volume contract this
milestone (and later M4) depends on.

## Cleanup

Both test workspaces (`m3-test`, `m3-e2e`) were deleted after validation via
`coder delete <name> --yes`; no lingering Coder resources remain from this
report's evidence-gathering.

## Answer to the required question

**"Could a new developer become productive without configuring the
development environment manually?"**

**YES** — for everything short of the developer's own GitHub push
credentials (which are personal to each developer and out of scope for the
workspace image/template to provide). From `Create Workspace →
docker-standard`, a developer gets: `git`, `python3`/`make` toolchain,
`node`, `gh`, and `docker` CLI, a repository already cloned into
`/home/coder/project`, and a persistent home volume — all without installing
a single extra package by hand.
