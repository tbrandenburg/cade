# M2 Self-Hosted GitHub Runner — Milestone Report

Evidence captured for Phase 2 / Milestone M2 (Self-Hosted GitHub Runner),
per the evidence standard in `docs/INITIAL.md` Section 3 Rule 2 and
`docs/plan/plan.md` (M2 section).

- **Timestamp (UTC):** 2026-08-28T16:27Z
- **Commit:** `2c1c0b7` ("runner: M2 self-hosted GitHub Actions runner (JIT,
  socket-proxy, smoke workflow)")

## Repository visibility — REQUIRED "Private", ACTUAL "Public"

```
$ gh repo view --json visibility,nameWithOwner
{"nameWithOwner":"tbrandenburg/devenv-cloud","visibility":"PUBLIC"}
```

The plan requires this be **Private**. It is not, and this step did not
change it — visibility is a repository-owner decision with consequences
(portfolio visibility, stars, forks) outside this step's scope. This is
recorded as an **open, unresolved risk** in `docs/security.md`, with
compensating mitigations applied (workflow_dispatch-only trigger, explicit
minimal `permissions:`, JIT/ephemeral runner with no standing target,
collaborators limited to the owner). Full compliance with the plan's M2
security restriction requires either making the repository private, or a
deliberate, owner-approved long-term risk acceptance — a decision this
report surfaces rather than makes.

## What was built

- `runner/Dockerfile` — self-hosted runner image. `ubuntu:24.04` pinned by
  digest (`sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517`),
  GitHub Actions Runner `v2.337.0` pinned by version + SHA-256 checksum
  verified at build time, Docker CLI only (no daemon), no baked-in runner
  identity — always started with `--jitconfig`.
- `scripts/runner-jit-start.sh` — requests a JIT config via
  `gh api .../actions/runners/generate-jitconfig` and starts one `--rm`
  runner container per invocation.
- `compose.yaml` additions:
  - `runner-docker-proxy` (`tecnativa/docker-socket-proxy:v0.5.0`) — holds
    the real `docker.sock` (read-only bind), allow-lists only
    `CONTAINERS`/`IMAGES`/`POST`/`VERSION`/`PING`, not published to the
    host, reachable only on `platform-workspaces`.
  - `runner-health` (`nginx:1.27-alpine`) — local-only HTTP service, no
    published host port.
- `.github/workflows/runner-smoke.yml` — `workflow_dispatch` only,
  `permissions: { contents: read }`, `runs-on: [self-hosted, linux,
  private-lab, docker]`. Prints hostname, prints Docker version (via the
  proxy), runs an ephemeral `hello-world` container, curls the local-only
  health endpoint.
- `docs/security.md`, `docs/operations.md` — actual security posture and
  rebuild/patch cadence.
- `Makefile` — `runner-build`, `runner-run` targets.

## Validation Milestone M2 — commands and output

### Build the runner image

```
$ make runner-build
...
#11 naming to docker.io/devenv-cloud/runner:latest done
```

### Bring up the socket-proxy + health sidecars

```
$ make up
 Container runner-docker-proxy Started
 Container runner-health Started
$ docker compose ps
NAME                  IMAGE                                  STATUS
coder                 ghcr.io/coder/coder:v2.36.3            Up (healthy)
coder-db              postgres:17.6-alpine                   Up (healthy)
runner-docker-proxy   tecnativa/docker-socket-proxy:v0.5.0   Up
runner-health         nginx:1.27-alpine                      Up (healthy)
```

### Start a JIT runner and dispatch `runner-smoke`

```
$ bash scripts/runner-jit-start.sh &
Requesting JIT config for repo=tbrandenburg/devenv-cloud name=private-lab-1787934412 ...
Starting ephemeral runner container 'private-lab-1787934412' ...

$ docker logs private-lab-1787934412
√ Connected to GitHub
Current runner version: '2.337.0'
2026-08-28 16:26:58Z: Listening for Jobs

$ gh workflow run runner-smoke.yml
$ gh run list --workflow=runner-smoke.yml --limit 3
in_progress   runner-smoke  runner-smoke  main  workflow_dispatch  33190018489  15s  2026-08-28T16:27:05Z

$ gh run watch 33190018489 --exit-status
Run runner-smoke (33190018489) has already completed with 'success'
```

### Full job log (proves execution on the private server, not a GitHub-hosted runner)

```
Runner name: 'private-lab-1787934412'
Machine name: 'b5fcae1f8d2f'
GITHUB_TOKEN Permissions: Contents: read, Metadata: read

Run hostname
b5fcae1f8d2f                      # matches the local container ID above

Run docker version   (DOCKER_HOST=tcp://runner-docker-proxy:2375)
Client: Version: 29.1.3
Server: Docker Engine - Community, Version: 29.7.2

Run docker run --rm hello-world
Hello from Docker!
This message shows that your installation appears to be working correctly.

Run curl -fsS http://runner-health/ | head -c 200
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
```

`hostname` printed the *container's own* short ID (`b5fcae1f8d2f`), matching
`docker ps` on this host at the same moment — the job did not run on a
GitHub-hosted runner. `docker version`/`docker run` succeeded only through
`runner-docker-proxy` (no socket mounted in the runner container itself),
and `runner-health` has no published host port — both are reachable only
from inside `platform-workspaces` on this machine.

### Ephemeral cleanup confirmed

```
$ docker ps -a --filter name=private-lab
(empty — container exited and was removed via --rm)

$ gh api repos/tbrandenburg/devenv-cloud/actions/runners --jq '.runners'
[]
```

No standing runner registration remains after the job — GitHub
auto-deregistered the JIT runner as designed.

### No unintended inbound port opened

```
$ docker compose ps --format json | ... Publishers
coder                 0.0.0.0:7080->7080  (pre-existing, Coder UI — M1/M3, unrelated to this runner)
coder-db              (none published)
runner-docker-proxy   (none published)
runner-health         (none published)
```

## Manual E2E Test M2 — sandbox constraint

Per the same sandbox constraint documented in `docs/milestone-reports/M0-host.md`
and `M1-compose.md`: execution happens in a non-rebootable, non-interactive
WSL2-based sandbox/container that has no separate "outside the LAN" network
or device to physically switch to. The substituted, equivalent evidence is:

1. **GitHub.com → trigger `runner-smoke`**: done via `gh workflow run` +
   `gh run watch`, i.e. the exact same GitHub Actions API path a browser on
   another network would use — GitHub itself has no visibility into which
   network the *dispatcher* is on; only the *runner*'s network matters for
   this test, and that's the private server (`b5fcae1f8d2f`, this sandbox).
2. **Job runs on the private server**: proven above (`hostname` /
   `docker ps` correlation).
3. **Workflow calls a service available only inside the private
   environment**: proven above (`runner-health`, no published port).
4. **Result appears in GitHub**: `gh run view 33190018489` shows
   `success`, full log captured above.
5. **No inbound public port opened for this test**: `runner-docker-proxy`
   and `runner-health` publish nothing to the host; only the pre-existing
   `coder` port (7080, unrelated to M2) is published, and that binds
   `0.0.0.0` on this sandbox's own virtual interface, not a real public
   interface reachable from the Internet — this sandbox has no public IP.

**Answer to "Can GitHub execute a controlled operation on the private
server without inbound access to the private server?": YES** — the JIT
runner container established only an outbound HTTPS connection to GitHub to
register and poll; GitHub never opened a connection into this host, and no
port needed to be opened for it to happen.

## Open follow-ups (not blocking this step, tracked for awareness)

- Repository visibility remains **Public** — see `docs/security.md`. This
  is the one plan requirement not met by this step and needs an explicit
  owner decision (make private, or accept documented risk long-term).
- `docs/ARCHITECTURE.md` already described the runner container in general
  terms (L2 diagram) before this step; no changes were needed there for M2.
