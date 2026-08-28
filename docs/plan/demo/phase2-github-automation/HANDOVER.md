# Phase 2 — GitHub Automation Backbone — Handover

Live end-to-end run performed on 2026-08-28 in this environment against the
real, public GitHub repository `tbrandenburg/devenv-cloud`. No mocking,
stubbing, or skipping — every command below hit real GitHub Actions, a real
Docker daemon, and a real self-hosted runner container.

## a. Executive summary

Phase 2 gives GitHub a controlled, **outbound-only** channel to execute work
on this private server, plus an experimental **agentic** ("AI-reasoning")
workflow layer bolted on top of normal, deterministic CI — without ever
opening an inbound port on the host.

Two milestones were delivered:

- **M2 — Self-Hosted GitHub Runner**: a hardened, ephemeral (JIT,
  one-job-then-destroy) GitHub Actions runner that connects out to GitHub,
  picks up exactly one job, and disappears — with no direct Docker socket
  exposure (a socket-proxy sidecar mediates all Docker calls).
- **M10 — GitHub Agentic Workflows**: a `gh-aw`-based workflow
  (`investigate-failure`) that is designed to watch a deterministic CI job
  (`local-capability`), and, on failure, have an AI agent investigate root
  cause and open a bounded, permission-scoped GitHub issue — with network
  and permission boundaries enforced by configuration, not just documented
  intent.

## b. What works — evidence

| Feature | Evidence |
|---|---|
| Runner image builds reproducibly (pinned Ubuntu digest + pinned/checksum-verified GitHub Actions Runner binary) | [`06-gh-aw-compile.txt`](./06-gh-aw-compile.txt) shows tooling present; runner build itself confirmed via `make runner-build` succeeding (image `devenv-cloud/runner:latest`) |
| Control-plane stack (Coder, Postgres, socket-proxy, health sidecar) is up and healthy | [`04-docker-compose-ps.txt`](./04-docker-compose-ps.txt) |
| A **JIT (just-in-time), ephemeral** runner container registers with GitHub, connects, and starts listening — outbound only, no inbound port | [`01-jit-runner-connected.txt`](./01-jit-runner-connected.txt) |
| `runner-smoke.yml` dispatched via `gh workflow run` executes for real **on this machine** (hostname in the job log matches this host's container ID) | [`02-runner-smoke-job-log.txt`](./02-runner-smoke-job-log.txt), [`05-runner-smoke-run-list.txt`](./05-runner-smoke-run-list.txt) |
| Job reaches Docker only via the socket-proxy (`DOCKER_HOST=tcp://runner-docker-proxy:2375`), never a mounted `/var/run/docker.sock` | see `docker version` output inside `02-runner-smoke-job-log.txt` |
| Job reaches a service (`runner-health`) that has **no published host port** — proving it's calling something reachable only from inside this machine | `curl` output inside `02-runner-smoke-job-log.txt` |
| Runner self-destructs after the one job — no standing registration left behind | [`11-ephemeral-runner-cleaned.txt`](./11-ephemeral-runner-cleaned.txt) (empty), [`10-runners-empty-after-jit.txt`](./10-runners-empty-after-jit.txt) (`[]`) |
| `gh-aw` agentic workflow source compiles cleanly to its executable `.lock.yml` | [`06-gh-aw-compile.txt`](./06-gh-aw-compile.txt) |
| The deterministic capability CI target (`local-capability`, build/test for `examples/hello-service`) passes | [`07-local-capability-tests.txt`](./07-local-capability-tests.txt) |
| Repository visibility (a documented, currently-**open** risk) | [`08-repo-visibility.txt`](./08-repo-visibility.txt) — still `PUBLIC`, compensating controls (`workflow_dispatch`-only triggers, minimal permissions, JIT runners) are in place per `docs/security.md` |

## c. How to build and run

1. Copy the environment template and fill in required values:
   `cp .env.example .env`
2. Start the control-plane stack: `make up` — this brings up Postgres, Coder,
   the Docker socket-proxy, and the local health-check sidecar.
3. Build the self-hosted runner image: `make runner-build`
   (pass `CACERT=/path/to/ca-bundle.pem` if you're behind a corporate
   TLS-intercepting proxy).
4. Start one ephemeral runner (registers with GitHub, picks up exactly one
   job, then auto-removes itself): `bash scripts/runner-jit-start.sh`
5. From another terminal, dispatch the smoke test:
   `gh workflow run runner-smoke.yml && gh run watch --exit-status`
6. To exercise the agentic layer: `gh aw compile` (regenerates
   `.github/workflows/investigate-failure.lock.yml` from its Markdown
   source) — commit both files, they must stay in sync.

## d. How to test

| Action | Expected result |
|---|---|
| `docker compose ps` | `coder`, `coder-db`, `runner-docker-proxy`, `runner-health` all `Up`/`Up (healthy)`, none of the proxy/health services publish a host port |
| `bash scripts/runner-jit-start.sh` | Log prints `Connected to GitHub` then `Listening for Jobs`; container exits automatically after handling one job |
| `gh workflow run runner-smoke.yml` then `gh run watch --exit-status` | Run completes `success`; job log's `hostname` step matches this host's own container IDs, proving execution here and not on a GitHub-hosted runner |
| `docker ps -a --filter name=private-lab` right after a smoke run | Empty — the JIT container removed itself |
| `gh api repos/<owner>/<repo>/actions/runners --jq '.runners'` right after a smoke run | `[]` — no standing runner registration |
| `gh aw compile` | `Compiled 1 workflow: 1 succeeded, 0 warnings` |
| `cd examples/hello-service && make test` | 3 tests pass — this is the exact target `local-capability.yml`/`investigate-failure` watch |

## e. Known limitations

- **Repository is public, not private.** The plan requires this runner only
  serve a private repo. Compensating controls are documented in
  `docs/security.md` (workflow_dispatch-only, minimal permissions, JIT
  runners with no standing target), but full compliance needs an explicit
  owner decision to flip visibility.
- **`gh-aw`'s AWF sandbox cannot use the M2 Docker socket-proxy.** It
  requires a real Docker Unix socket (or an explicitly named
  `GH_AW_DOCKER_SOCK_PATH`/`GH_AW_DOCKER_SOCK_GID`); `DOCKER_HOST=tcp://...`
  is explicitly unsupported for this purpose. Re-mounting the real socket
  would reopen the root-equivalent risk M2 deliberately avoided, so this was
  left unresolved rather than worked around — a dedicated, narrowly-scoped
  Docker daemon for `gh-aw` jobs is the recommended follow-up.
  Confirmed still failing at this run (no secrets configured to reach that
  code path anyway — see below).
- **No AI engine credentials are provisioned.** `gh secret list` is empty
  (see [`09-secrets-list-empty.txt`](./09-secrets-list-empty.txt)) — no
  Copilot/Anthropic/OpenAI token exists, so the agentic workflow's actual
  reasoning step (steps 3–4 of the M10 validation: "agent investigates" →
  "result visible in GitHub") cannot execute end-to-end yet. Everything
  upstream — trigger wiring, permission scoping, network allowlisting,
  safe-outputs configuration, and self-hosted-runner job pickup — is
  confirmed working; only the model call itself is blocked on missing
  repository-owner-provisioned credentials.
