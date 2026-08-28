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
- 2026-08-28 (M3 review of step 00301): Committing/pushing previously-uncommitted
  deliverables (action 1) does not, by itself, prove the required "re-run E2E and
  update the milestone report" actions (2/3) were done. `git diff`/`git log --all`
  on the report file itself is required: here `docs/milestone-reports/M3-coder.md`
  was found byte-for-byte identical to the pre-existing stale version despite the
  gap step explicitly requiring it be overwritten with a freshly reproduced
  transcript. Always diff a report file against its prior committed version (or
  its content before the gap step) to confirm it was actually rewritten, not just
  re-saved as part of a bulk commit.
- 2026-08-28 (M3 step 00302): The `coder_agent` template's plain, unauthenticated
  `git clone "${repo_url}"` silently hangs/fails whenever `repo_url` is (or becomes)
  a private GitHub repo: `git` invokes Coder's built-in external-auth flow, prints
  "Open the following URL to authenticate with Git: http://.../external-auth/github"
  to `/tmp/coder-startup-script.log`, and never completes non-interactively — the
  workspace container ends up with no `/home/coder/project` at all, with no other
  error surfaced anywhere. Diagnose this class of "empty clone" failure by reading
  `/tmp/coder-startup-script.log` *inside* the workspace container first. Fixed here
  by adding an optional `github_token` `coder_parameter` (a *data source* in
  provider `coder/coder` v2.18.0, not a `resource` — and it has no `sensitive`
  attribute) wired into `GIT_ASKPASS` only for the clone step, so the token never
  lands in `.git/config`. Also: `docker exec` into a workspace container does not
  inherit the `coder_agent.env` map (e.g. `GIT_AUTHOR_NAME`, `GITHUB_TOKEN`) — that
  env is only visible to the agent's own child processes, so manual verification
  via `docker exec` needs its own `git config user.email/user.name` to commit.
- 2026-08-28 (M4 review of step 00401): Code/scripts/terraform wiring (commit `ea7201e`)
  was fully implemented and `terraform validate` passed, but `docs/milestone-reports/M4-agent-host.md`
  was never created (missing from disk and `git log --all`), and the step's own Manual
  E2E Test was never actually run — a pre-existing workspace container
  (`coder-admin-m4-e2e`) was inspected with `docker exec ... ps aux` and found to only
  run `code-server`, not a VS Code Agent Host process, and had no `.vscode/settings.json`,
  proving it predates the M4 template changes. Passing static checks (terraform validate,
  file existence) is not evidence a Manual E2E Test step was executed — always
  `docker exec` into any claimed-live container and check for the actual expected
  process/file artifacts before accepting an E2E claim.
- 2026-08-28 (M4 review of step 00402): The gap-fill for 00401 still did not write
  `docs/milestone-reports/M4-agent-host.md` (missing from disk and `git log --all`),
  and additionally left a bogus `coder create` behind: `coder show admin/m4-e2e`
  reported the agent `disconnected`/"lost connection" and `docker ps -a` (cross-checked
  with `docker inspect ... com.coder.workspace_name`) showed **no backing container at
  all** for it, while `coder templates versions list docker-workspace` returned
  "Resource not found" — proving the M4-updated `docker-workspace` template (commit
  `ea7201e`) was never actually pushed, so the workspace that was created used the
  unrelated `docker-standard` template instead. Always cross-check a `coder
  list`/`coder show` "Started" workspace against real `docker ps`/`docker inspect`
  output and against `coder templates versions list <name>` before treating it as
  evidence of an E2E run — a workspace can appear "Started" in Coder's own state while
  having no live container and being built from the wrong template entirely.
- 2026-08-28 (M4 review of step 00403): The `coder` CLI is not on `PATH` by default in
  this environment — it lives at `/tmp/coderbin/bin/coder` (and a copy under
  `/tmp/opencode/coder-cli/coder`), while the Coder server itself runs as the `coder`
  Docker container (`docker ps` shows `ghcr.io/coder/coder:v2.36.3`). A reviewer running
  a bare `coder ...` command and getting "command not found" must not conclude the CLI
  is unavailable — `find / -maxdepth 4 -iname coder -type f` locates it. Also useful:
  `coder templates pull <name> <dir> --yes` (note: no `-d`/`--dest` flag exists, the
  destination is a positional argument) lets you diff the *actually deployed* template
  source against the repo's `main.tf` byte-for-byte, which is stronger evidence than
  trusting a "Succeeded"/"Active" status alone — this step's template push finally
   matched (zero diff), even though the workspace-creation and report-writing actions
   that were supposed to follow it were still never carried out.
- 2026-08-28 (M4 review of step 00404, fifth consecutive miss): A workspace
  (`admin/m4-e2e-v2`) was finally created from the correct `docker-workspace` template
  and had a real backing container (`docker ps` confirmed), but `coder create` was run
  without the template's optional `github_token` `coder_parameter`, so the startup
  script's `git clone` against the private repo failed with "remote: Repository not
  found." — leaving `/home/coder/project` and `/home/coder/.vscode/settings.json`
  entirely absent, which silently blocks every downstream SSH/AHP verification step and
  the milestone report. Always check `docker exec <container> cat
  /tmp/coder-startup-script.log` for a successful clone (not just "container is running")
  before trusting a freshly created workspace as usable for E2E verification, and when
  creating workspaces from this template non-interactively, explicitly pass
  `github_token` (verify the exact parameter flag via `coder create --help`, it varies by
  CLI version) rather than assuming a public-repo default will work.
- 2026-08-28 (M5 implementation): `coder --global-config <dir> list` silently hides
  workspaces owned by other users — it needs `-a`/`--all` to show them, and `coder ssh`/
  `coder show` against another user's workspace fails with a generic
  `error: Resource not found or you do not have access to this resource` (no
  permission-denied-shaped message), which is easy to misdiagnose as a broken CLI or
  server instead of an ownership/auth mismatch. Run `coder whoami` first to check which
  account a given `--global-config` session is actually authenticated as before
  concluding a workspace is unreachable; if it's owned by a different user (e.g. `admin`
  vs `m3reviewer`), it's simplest to create a fresh throwaway workspace as the
  currently-authenticated user rather than trying to re-auth as the owner. Also:
  `coder create ... --yes` still prompts interactively per bool `coder_parameter` that
  has no CLI value supplied (even ones with a `default`), so every `coder_parameter` in
  a template (`github_token` *and* `agent_capable` here) must be passed explicitly via
  `--parameter` for a non-interactive create to succeed — otherwise it hangs and then
  fails with an opaque `prepare build: EOF`. Finally, `coder stop <name> --yes` followed
  by `coder start <name> --yes` fully destroys and recreates the `docker_container`
  resource (confirmed via Terraform's own "Destruction complete"/"Creation complete"
  log lines) while leaving `docker_volume.home_volume` untouched — this is the most
  realistic non-GUI proxy available for "end a session, start a new one" when proving
   that repository/user memory survives on the persistent home volume across a session
   boundary, since it's a stronger proof than merely restarting a process in-place.
- 2026-08-28 (M5 review of step 00500): The uncommitted-deliverables gap first seen in
  M3 (steps 00300/00301) recurred a third time — `scripts/create-agent-worktree.sh`,
  `scripts/cleanup-agent-worktree.sh`, `sessions/worktree-policy.md`, and
  `docs/milestone-reports/M5-sessions.md` all existed only as untracked working-tree
  files (`git log --all -- <path>` empty for every one of them), even though every
  Validation Milestone and Manual E2E Test check independently re-run against a fresh
  `docker-workspace` workspace passed exactly as reported. Since the template clones the
  *remote* repo into `~/project`, none of these scripts would actually exist in a real
  agent's checkout. This confirms it is not a one-off mistake: reviewers must run
  `git log --all -- <path>` for every path a step claims to create as the very first
  check, before spending any time re-running validation/E2E commands against the local
  working tree, since local-only files can make every check pass while the deliverable
  is still absent from what a real workspace would actually clone.
- 2026-08-28 (M9 review of step 00600): The uncommitted-deliverables gap first seen in
  M3 (steps 00300/00301, three attempts) and recurring in M5 (step 00500) happened a
  fourth time — `agent-host/srt-settings.json`, `scripts/verify-agent-tmux-session.sh`,
  `docs/milestone-reports/M9-agent.md`, and the `coder/Dockerfile`/`main.tf` diffs
  documented as "what was built" all existed only as uncommitted working-tree changes
  (`git log --all -- <path>` empty for every new file, `git status --short` showed the
  modified files as unstaged), even though the milestone report's transcripts read as
  fully genuine and internally consistent. This confirms the failure mode is systemic
  across implementers/sessions, not a one-off: treat "commit every deliverable as the
  final action of the step, before writing the milestone report" as a mandatory,
  first-class step action from now on, not an afterthought to be caught in review.
- 2026-08-28 (M9 implementation): Anthropic's Sandbox Runtime (`srt`) unconditionally
  wraps every command in an outer `bwrap --unshare-user` sandbox — `enableWeakerNestedSandbox`
  (per `@anthropic-ai/sandbox-runtime`'s `linux-sandbox-utils.js`) only changes whether
  `--cap-drop ALL` is added to that same call, it does not remove the need for a working
  user namespace at all. In this Docker/WSL2 environment `bwrap --unshare-user` fails
  outright (`bwrap: No permissions to create new namespace`) regardless of that setting,
  because Docker's *default* seccomp/AppArmor profile on the container blocks unprivileged
  userns creation — confirmed by isolating the cause: `--cap-add SYS_ADMIN` alone got
  further (a different `pivot_root` AppArmor denial), and only
  `--security-opt seccomp=unconfined --security-opt apparmor=unconfined` let the bare
  `bwrap --unshare-user ... echo ok` smoke test succeed — not a host `sysctl` issue (neither
  `kernel.unprivileged_userns_clone` nor `kernel.apparmor_restrict_unprivileged_userns`
  even exist as `/proc/sys/kernel/*` files on this WSL2 kernel). Do not add `--privileged`
  or loosen the workspace container's own seccomp/AppArmor profile in Terraform to "fix"
  this — that trades away the Rule 1 container boundary for every workspace to restore one
  optional, defense-in-depth layer, and is a security-posture decision outside a single
  milestone step's authority. Document `srt` as installed/configured but non-enforcing in
  this deployment instead of silently degrading container isolation to make it pass.
- 2026-08-28 (M9 gap-fill, step 00601): The uncommitted-deliverables gap (M3 steps
  00300/00301 x3, M5 step 00500, M9 step 00600) happened a fourth time and was
  finally resolved cleanly on the first gap-fill attempt by committing+pushing
  exactly the 5 files the step named (`agent-host/srt-settings.json`,
  `docs/milestone-reports/M9-agent.md`, `scripts/verify-agent-tmux-session.sh`,
  `coder/Dockerfile`, `coder/templates/docker-workspace/main.tf`) *before* doing
  anything else, then rebuilding/pushing the template and re-running the full E2E
  against a workspace created from a genuinely fresh `git clone` of the pushed
  remote. Confirmation chain that proved it this time (all independently
  reproducible): `git log --all -- <path>` non-empty for every path; a scratch
  `git clone` of the remote showing the files present; `coder templates pull
  docker-workspace <dir> --yes` diffed byte-for-byte against the repo (only
  `.terraform/` differed); `docker ps`/`docker inspect` confirming the created
  workspace's container actually used the just-built `devenv-cloud/coder-workspace`
  image; and `docker exec <container> cat /tmp/coder-startup-script.log` showing a
  successful clone. The lesson from step 00600 itself (do not repeat "just commit
  the files" as if novel) held: front-loading the commit+push as literally the
  first action, before any inspection or re-verification, avoided every prior
  failure mode in one pass.
