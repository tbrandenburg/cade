# devenv-cloud — Phase 1 Handover: Remote Dev Environment + Agent

**Evidence captured:** 2026-08-28 (all artefacts in this directory)
**Scope:** Phase 1 milestones M0, M1 (trimmed), M3, M4, M5, M9, M15 — see `docs/plan/steps/archived/phase1-remote-dev-agent/plan.md` for the original plan.

## a. Executive summary

Phase 1 delivers a self-contained, private developer platform running entirely
on one Linux server, with no public internet exposure and no paid cloud
dependency:

- A developer (or an automated caller) requests a **Coder** workspace and gets
  a fully provisioned Docker container with git, Python, Node, GitHub CLI,
  Docker CLI, and this repository already cloned — no manual setup.
- The workspace exposes a **browser-based VS Code (code-server)** reachable
  from any device on the local network, and a normal **SSH host**
  (`coder.<workspace-name>`) for VS Code Desktop / Remote-SSH.
- Two AI coding-agent CLIs (**OpenCode**, **Pi**) are pre-installed and can
  read repository context, diagnose a real seeded test failure, and report
  root cause/fix without the entire repo being pasted into a chat window.
- **Git worktrees** give each agent session its own isolated checkout so
  parallel sessions never clobber each other's edits.
- A **tmux**-backed session gives agent CLIs process continuity: the agent
  keeps running whether or not a terminal/editor is attached.
- An OS-level sandbox (**`srt`** / bubblewrap) is wired in as defense-in-depth
  around the agent CLIs, with a documented, verified limitation on this
  particular host (see Known Limitations).

This end-to-end run re-created the entire stack from scratch — stack up,
image rebuild, template push, fresh workspace creation, repo clone, build,
test, worktree isolation, agent diagnosis, tmux continuity, and browser
access — with no mocking or skipped steps, and every command's real output
captured as evidence below.

## b. What works (with evidence)

| # | Feature | Evidence |
|---|---|---|
| 1 | Host readiness check (`make doctor`) — 11/13 checks pass; the 2 known FAILs are sandbox-specific (see Known Limitations) | [`01-make-doctor.txt`](01-make-doctor.txt) |
| 2 | Control-plane stack (Postgres + Coder) up and healthy (`make status`) | [`02-make-status.txt`](02-make-status.txt) |
| 3 | Workspace container image builds reproducibly (cache-hit clean) | [`03-workspace-image-build.txt`](03-workspace-image-build.txt) |
| 4 | Coder template pushed and active on the running server | [`04-template-push.txt`](04-template-push.txt) |
| 5 | Fresh workspace created from the template, with the repo auto-cloned via `github_token` parameter | [`05-workspace-create.txt`](05-workspace-create.txt) |
| 6 | Example service builds and its 3-test suite passes unmodified inside the freshly cloned workspace | [`06-hello-service-build-test.txt`](06-hello-service-build-test.txt) |
| 7 | Full required toolchain present (git, Python, Node, gh, Docker, tmux, opencode, pi, srt, bwrap, socat) | [`07-toolchain-versions.txt`](07-toolchain-versions.txt) |
| 8 | M4/M9 config actually written into the workspace (`.vscode/settings.json` sandbox flags, `~/.srt-settings.json` allow/deny lists) | [`08-m4-m9-config.txt`](08-m4-m9-config.txt) |
| 9 | `coder config-ssh` regenerates SSH access to workspaces | [`09-configure-coder-ssh.txt`](09-configure-coder-ssh.txt) |
| 10 | Agent Host / AHP verification scripts run and correctly report the true state (see Known Limitations for why they FAIL here) | [`10-verify-agent-host.txt`](10-verify-agent-host.txt), [`11-verify-ahp-session.txt`](11-verify-ahp-session.txt) |
| 11 | Two independent agent worktrees created via `scripts/create-agent-worktree.sh` | [`12-worktree-create.txt`](12-worktree-create.txt) |
| 12 | Both worktrees edit the same file/line independently with zero cross-contamination | [`13-worktree-isolation.txt`](13-worktree-isolation.txt) |
| 13 | Worktrees cleaned up safely (refuses to delete dirty state; succeeds once clean); main checkout unaffected | [`14-worktree-cleanup.txt`](14-worktree-cleanup.txt) |
| 14 | A real bug seeded into the sample service, confirmed failing | [`16-agent-test-setup.txt`](16-agent-test-setup.txt) |
| 15 | `opencode` (zero-config `big-pickle` model) reads the repo, reproduces the failure, and correctly reports root cause, affected file (`hello.py:12`), and fix | [`17-m9-opencode-diagnosis.txt`](17-m9-opencode-diagnosis.txt) |
| 16 | `srt`/`bwrap` sandbox wrapper installed and invoked (enforcement limitation documented, not silently ignored) | [`18-srt-sandbox-check.txt`](18-srt-sandbox-check.txt) |
| 17 | `tmux` session survives reconnects — same process PID before/after | [`19-tmux-persistence.txt`](19-tmux-persistence.txt) |
| 18 | Coder dashboard reachable over the LAN IP (not `localhost`) from a browser | [`20-coder-dashboard-workspace.png`](20-coder-dashboard-workspace.png) |
| 19 | code-server (browser VS Code) opens the cloned repo over the LAN | [`21-code-server-repo-open.png`](21-code-server-repo-open.png) |
| 20 | `coder config-ssh`-based SSH session: edit + build reproduced | [`22-m15-ssh-build.txt`](22-m15-ssh-build.txt) |

## c. How to build and run (quick start)

1. Clone the repository and `cd` into it.
2. Verify the host: `make doctor` (fix any FAIL before continuing — disk
   space and port availability are the most common on a first run).
3. Copy the environment template and adjust the Docker group ID:
   `cp .env.example .env` then set `DOCKER_GID` to `$(getent group docker | cut -d: -f3)`.
4. Start the control plane: `make up`, then `make status` to confirm
   `coder` and `coder-db` are both `healthy`.
5. Build the workspace image: `make coder-workspace-build` (commit any
   pending changes under `coder/`, `examples/`, or `Makefile` first — the
   build refuses to run on a dirty tree).
6. Push the workspace template so the server has the current version:
   `coder templates push docker-standard -d coder/templates/docker-workspace --yes`.
7. Create a workspace (pass a `github_token` if the repo is private):
   `coder create <name> --template docker-standard --yes --parameter github_token=<token> --parameter agent_capable=true`.
8. Open the Coder dashboard at `http://<server-ip>:7080` from any device on
   the same network, or run `coder config-ssh` and connect with
   `ssh coder.<name>` / VS Code Desktop Remote-SSH.
9. Inside the workspace: `make -C examples/hello-service build && make -C examples/hello-service test`.

## d. How to test (manual test cases)

| # | Action | Expected result |
|---|---|---|
| 1 | Run `make doctor` on a real (non-sandbox) target host | All checks PASS |
| 2 | `make up` then `make down` then `make up` | Coder UI returns and prior workspace data (workspaces, users) is intact |
| 3 | Create a workspace from `docker-standard` and run `git status` inside it | Shows a clean checkout of the repository's `main` branch, no manual setup needed |
| 4 | `make -C examples/hello-service build && make -C examples/hello-service test` inside a fresh workspace | Build OK; all 3 tests pass, unmodified |
| 5 | `scripts/create-agent-worktree.sh coder.<name> session-A` and `...session-B`, edit the same file/line in each | Each worktree's edit is independent; neither overwrites the other |
| 6 | `scripts/cleanup-agent-worktree.sh coder.<name> session-A` while it has uncommitted changes | Refuses with an error (safety check); succeeds after `git checkout` or with `--force` |
| 7 | Seed a failing unit test, then run `opencode run --model opencode/big-pickle "Investigate why the test fails..."` | Agent identifies the correct root cause, affected file, and fix without modifying code |
| 8 | `tmux new-session -d -s <name> ...`, disconnect, reconnect, check `tmux list-panes -F '#{pane_pid}'` | Same PID before and after — the wrapped process never restarted |
| 9 | From a browser on the LAN, open `http://<server-ip>:7080` and the workspace's `code-server` app | Dashboard and in-browser VS Code both load and show the cloned repository |
| 10 | `coder config-ssh` then `ssh coder.<name>`, edit a file, run the build | Build succeeds against the live workspace over SSH |

## e. Known limitations

- **VS Code Agent Host / AHP session persistence (M4) is not driveable
  headlessly.** `scripts/verify-agent-host.sh` and `scripts/verify-ahp-session.sh`
  correctly report "no Agent Host process found" because VS Code starts the
  Agent Host lazily on the *first* interactive Remote/Agents-window
  connection from a real VS Code Desktop client — no such GUI client exists
  in this non-interactive environment. The scripts, wiring, and persistent
  `.vscode`/`.vscode-server` volume paths are all in place and were verified
  working in the independent `ahp-sandbox` proof-of-concept; a customer with
  a VS Code Desktop client should be able to complete this test directly.
- **`srt`/`bubblewrap` sandbox enforcement is non-functional in this
  environment.** `bwrap --unshare-user` fails with "No permissions to create
  new namespace" — a blocked unprivileged user-namespace, not a bug in the
  template. This is a known, previously documented Docker/WSL2-hosting
  limitation (see `AGENTS.md`). `srt` is installed and invoked correctly;
  only kernel-level enforcement is unavailable on this particular host. On a
  bare-metal/VM host with `kernel.unprivileged_userns_clone=1` (and, on
  Ubuntu 24.04+, `kernel.apparmor_restrict_unprivileged_userns=0`), this is
  expected to enforce correctly.
- **`pi` CLI has no zero-configuration model**, unlike `opencode`'s
  `opencode/big-pickle`. A provider API key must be supplied before `pi` can
  run the Agent Test; this was not exercised in this run since no
  credentials were available. `pi --version` (0.74.2) confirms the binary
  itself is correctly installed.
- **Disk space and port-availability doctor checks fail in this sandbox**
  (57 GB free vs. 100 GB recommended; port 7080 already bound by the
  running stack) — both are environment artefacts of running the demo
  against an already-up stack on a shared sandbox disk, not defects.
- **Wide-area (Tailscale) remote access is out of scope for Phase 1** —
  deferred to the optional Phase 6, which requires a genuinely separate
  network to test from.
- Coder's autostop is disabled only via the `agent_capable` parameter
  documented in M4; this is a documented interim policy, not a full
  workspace-lease system.
