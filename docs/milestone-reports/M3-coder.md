# M3 Coder Development Workspace — Milestone Report

Evidence captured for Phase 1 / Milestone M3 (Coder Development Workspace),
per the evidence standard in `docs/INITIAL.md` Section 3 Rule 2 and
`docs/plan/plan.md` (M3 section).

- **Timestamp (UTC):** 2026-08-28T12:14Z
- **Re-captured by:** step `00302-recapture-m3-e2e-transcript.md`, against a
  freshly created workspace cloning `origin/main` at commit `f8b1243`
  ("coder: remove unsupported sensitive attr on coder_parameter data
  source"), after two prior gap-fill attempts (00301, 00302 investigation)
  found the previous transcript in this file was never actually reproduced.

## What was built (this step's contribution)

- `coder/templates/docker-workspace/main.tf` — added an optional
  `github_token` template parameter (`data "coder_parameter" "github_token"`).
  When empty (the default), the `coder_agent` startup script behaves exactly
  as before: an anonymous `git clone` of `repo_url`. When set, the startup
  script exports `GIT_ASKPASS` pointing at a throwaway script that emits the
  token, so `git clone` can authenticate non-interactively — the token is
  never written into `.git/config` or shown by `git remote -v`.

## Why this was needed (root cause of the previous gap)

Investigating the orphaned `coder-admin-m3-review-verify` workspace/container
found via `docker ps` (no `/home/coder/project` at all) led to its
`/tmp/coder-startup-script.log`:

```
Cloning into '/home/coder/project'...
Open the following URL to authenticate with Git:
http://localhost:7080/external-auth/github
```

`https://github.com/tbrandenburg/devenv-cloud.git` currently returns HTTP 401
on an anonymous `git-upload-pack` info/refs request — the repository is
private — so the previously-committed template's plain, unauthenticated
`git clone "${repo_url}"` can never succeed non-interactively. This is a real
defect for the current (private) state of the repo, not a flake: the
`coder_agent` startup script has no way to supply credentials, so it prints
the Coder external-auth URL and then hangs/fails, leaving no clone. The
`github_token` parameter above fixes this without changing behavior for a
public `repo_url`.

## Sandbox constraint

This is a non-interactive container sandbox with no attached display, so the
VS Code GUI steps in the Manual E2E Test ("open VS Code", "Agents window")
could not be driven directly. Everything reachable via `docker`/`coder` CLI
and the Coder HTTP API was exercised for real, end-to-end, against the same
live Coder deployment brought up from this repository's own `compose.yaml` —
no part of the workspace/template logic itself was mocked.

## Validation Milestone M3 (real transcript, re-executed for this step)

```
$ docker ps --filter name=coder --format '{{.Names}}\t{{.Status}}'
coder      Up 5 minutes (healthy)
coder-db   Up 5 minutes (healthy)

$ git add coder/templates/docker-workspace/main.tf
$ git commit -m "coder: support optional GitHub token for cloning private repo_url"
$ git push origin main
   3de638a..7cf695b  main -> main
# (one follow-up fix commit after a first push attempt used the wrong
#  Terraform block type; final state pushed as 0ceef51..f8b1243)

$ make coder-workspace-build
...
#10 naming to docker.io/devenv-cloud/coder-workspace:latest done

$ coder templates push docker-standard --directory coder/templates/docker-workspace --yes
...
Updated version at Aug 28 14:08:24!

$ coder create admin/m3-recapture --template docker-standard --yes \
    --parameter "github_token=<redacted>"
...
The m3-recapture workspace has been created at Aug 28 14:09:01!
```

Inside the freshly created workspace container
(`docker exec -u coder coder-admin-m3-recapture ...`):

```
$ ls /home/coder/project
.env.example  .git  .gitignore  AGENTS.md  LICENSE  Makefile  README.md
coder  compose.yaml  doc  docs  examples  scripts

$ git status
On branch main
Your branch is up to date with 'origin/main'.
nothing to commit, working tree clean

$ git log -1
commit f8b124327301d753009481476d2c3de9538e41d7
Author: Tom Brandenburg (XC/ESX1-SE) <tom.brandenburg@se.bosch.com>
Date:   Fri Aug 28 14:08:01 2026 +0200

    coder: remove unsupported sensitive attr on coder_parameter data source

$ git remote -v
origin  https://github.com/tbrandenburg/devenv-cloud.git (fetch)
origin  https://github.com/tbrandenburg/devenv-cloud.git (push)
# (no token embedded in the remote URL or .git/config, confirming the
#  GIT_ASKPASS approach does not leak the credential onto disk)

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
PRETTY_NAME="Ubuntu 24.04.4 LTS"
git version 2.43.0
Python 3.12.3
v20.20.2
gh version 2.98.0 (2026-08-20)
Docker version 29.7.2, build a7dcaa6
```

## Manual E2E Test M3 (real transcript, re-executed against a second fresh workspace, `m3-e2e`)

| # | Step | Result |
|---|---|---|
| 1 | Delete the existing workspace | PASS — `coder delete admin/m3-recapture --yes` |
| 2 | Create a completely fresh workspace | PASS — `coder create admin/m3-e2e --template docker-standard --yes --parameter github_token=<redacted>` |
| 3 | Connect using VS Code | NOT APPLICABLE in this headless sandbox (no display); connectivity is proven at the transport layer via `docker exec` into the same running Agent Host container the VS Code Remote/Agents flow would attach to. Full GUI validation is deferred to a workstation with VS Code installed. |
| 4 | Confirm the repository exists | PASS — `git status` inside the workspace shows a clean checkout of `main` from `https://github.com/tbrandenburg/devenv-cloud.git` at commit `f8b1243` |
| 5 | Build the sample | PASS — `make -C examples/hello-service build` → `build: OK` |
| 6 | Run tests | PASS — `make -C examples/hello-service test` → 3/3 tests OK |
| 7 | Edit one line | PASS — appended a line to `examples/hello-service/test_hello.py` inside the workspace |
| 8 | Commit the change on a test branch | PASS — `git checkout -b m3-validation-test && git commit -m "test: M3 workspace validation touch"` succeeded inside the workspace (`96440a1`) |
| 9 | Push the branch to GitHub | **BLOCKED** — `git push origin m3-validation-test` fails with `fatal: could not read Username for 'https://github.com': No such device or address`. The `github_token` parameter used in step 2 is only wired into the clone step's `GIT_ASKPASS`, not into a persistent push credential, so the workspace still has no outbound push credentials by default. This remains an environment/credential limitation, not a defect in the workspace or template: the workspace ships `git`, `gh`, and SSH client, and a developer with their own GitHub credentials configured (via `gh auth login`, an SSH key, or a credential helper) would be able to push normally. |

Additional durability check performed beyond the minimum manual test list:
`coder stop admin/m3-e2e && coder start admin/m3-e2e` replaces the container
(`docker_container.workspace` is destroyed and recreated) while
`docker_volume.home_volume` survives — after the restart, `git status` still
reported the `m3-validation-test` branch checked out with a clean tree and
`git log -1` still showed commit `96440a1`, confirming the persistent-home-
volume contract this milestone (and later M4) depends on.

## Cleanup

All test workspaces created for this re-capture (`m3-recapture`, `m3-e2e`),
as well as the pre-existing orphaned `m3-review-verify` workspace found at
the start of this step, were deleted via `coder delete <name> --yes`.
`coder list --all` confirms no workspaces remain:

```
$ coder list --all
No workspaces found! Create one:

  coder create <name>
```

## Answer to the required question

**"Could a new developer become productive without configuring the
development environment manually?"**

**YES** — for everything short of (a) the developer's own GitHub push
credentials, and (b) an optional read credential (`github_token` parameter)
needed only because this particular repository is currently private. Both
are personal/deployment-specific and out of scope for the workspace
image/template to provide by default. From `Create Workspace →
docker-standard`, a developer gets: `git`, `python3`/`make` toolchain,
`node`, `gh`, and `docker` CLI, a repository already cloned into
`/home/coder/project`, and a persistent home volume — all without installing
a single extra package by hand.
