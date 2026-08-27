# Implementation Plan — Docker-First Private Developer Platform

## 1. Goal

Build a **single-repository, Docker-first private developer platform** that demonstrates the 2027-style development architecture discussed earlier:

- VS Code as the human control surface
- persistent/remote agent sessions
- paid LLM access where desired
- Coder Community for remote development workspaces
- Docker + Dev Containers as the default execution environment
- GitHub Free as repository and coordination plane
- self-hosted GitHub Actions runner using outbound connectivity only
- GitHub Agentic Workflows (`gh-aw`) for repository-centric reasoning
- Temporal OSS for durable orchestration
- MCP/internal APIs for tools and context
- optional Keycloak, OpenBao, OPA, OpenTelemetry, and Grafana for governance and observability

The setup must:

1. Run primarily on **one Linux server**.
2. Be reproducible from **one Git repository**.
3. Require no paid infrastructure services.
4. Require no inbound Internet exposure for automation.
5. Use Docker wherever reasonably possible.
6. Allow later addition of GCP without redesigning the platform.
7. Include explicit validation milestones.
8. Require the implementing developer to perform manual end-to-end tests before proceeding to the next milestone.

---

# 2. Target Architecture

```text
                          GitHub.com
                 repos / issues / PR / Actions
                            ▲
                            │
                  outbound HTTPS only
                            │
                            ▼
┌──────────────────────────────────────────────────────────┐
│                 PRIVATE LINUX SERVER                     │
│                                                          │
│  Docker Engine + Docker Compose                          │
│                                                          │
│  ┌─────────────┐   ┌─────────────┐                       │
│  │    Coder    │   │  Temporal   │                       │
│  │ Community   │   │    OSS      │                       │
│  └──────┬──────┘   └──────┬──────┘                       │
│         │                 │                              │
│         │                 ├── Temporal workers           │
│         │                 │                              │
│         ▼                 ▼                              │
│  ┌──────────────────────────────────────┐                │
│  │ Development / Agent Containers       │                │
│  │                                      │                │
│  │ repo + toolchain + agent + tests     │                │
│  └──────────────────────────────────────┘                │
│                                                          │
│  ┌──────────────────────────────────────┐                │
│  │ GitHub Self-hosted Runner            │                │
│  │ outbound connection to GitHub        │                │
│  └──────────────┬───────────────────────┘                │
│                 │                                        │
│        ┌────────┼──────────────┐                         │
│        ▼        ▼              ▼                         │
│      Docker   Temporal       Local APIs                  │
│      builds   workflows      / lab simulation            │
│                                                          │
│  ┌─────────┐ ┌─────────┐ ┌─────┐ ┌───────────────┐      │
│  │OpenBao  │ │Keycloak │ │ OPA │ │ MCP services  │      │
│  └─────────┘ └─────────┘ └─────┘ └───────────────┘      │
│                                                          │
│  ┌───────────────────────────────────────────────┐       │
│  │ OpenTelemetry → Grafana                       │       │
│  └───────────────────────────────────────────────┘       │
└──────────────────────────────────────────────────────────┘

                ▲
                │ LAN / optional Tailscale
                │
             VS Code
```

Note: the diagram shows the target end-state after all milestones are complete. `OpenBao`, `Keycloak`, and `OPA` are not present until Milestone 9 and are added incrementally, not deployed alongside Coder/Temporal from the start — see Section 15 for their actual (deferred, partly optional) rollout order.

---

# 3. Core Architectural Rules

The junior developer should follow these rules throughout the implementation.

## Rule 1 — Docker first, not Docker only

Use Docker for:

- Coder
- Temporal
- PostgreSQL
- GitHub runner
- MCP servers
- OpenBao
- Keycloak
- OPA
- OpenTelemetry
- Grafana
- development workspaces
- build environments
- agent runtimes

Do not introduce Kubernetes, GCP, Incus, or Proxmox in the initial implementation.

Add a VM escape hatch later only if a real embedded workload requires:

- custom kernels
- USB/JTAG drivers
- PCI passthrough
- Windows
- nested virtualization
- hardware-specific kernel modules

---

## Rule 2 — One repository is the source of truth

A clean checkout of the repository plus local secrets must be sufficient to recreate the system.

Do not manually configure containers and then leave the configuration undocumented.

Any manual action must either:

- become a script, or
- be documented explicitly.

### Evidence standard for milestone reports

A screenshot alone is not sufficient proof. Every milestone report must include, alongside any screenshots:

- the exact command(s) run,
- the captured stdout/stderr (redirect with `| tee` or `> file.log`),
- the process exit code (`echo $?`),
- and a timestamp.

Save raw command logs under `docs/milestone-reports/<milestone>/` next to the report so results are independently reproducible and reviewable without relying on a rendered image.

---

## Rule 3 — Never commit secrets

Never commit:

- `.env`
- API keys
- GitHub PATs
- runner registration tokens
- Copilot/OpenAI/Claude/Gemini credentials
- OpenBao root/unseal secrets
- Coder session tokens
- private SSH keys

Commit only:

```text
.env.example
```

with placeholder values.

### Interim secret handling before Milestone 9 (OpenBao)

OpenBao is not deployed until Milestone 9, but the runner (M2), Coder workspaces (M3), and the agent/harness (M6) all require real credentials long before that. Until OpenBao exists:

- Store all real secrets in a local `.env` file with permissions `chmod 600`, never in tracked files.
- Reference `.env` values from `compose.yaml` only through `env_file:` / `${VAR}` interpolation — never hardcode a secret in a committed YAML file.
- Treat every credential introduced before M9 (GitHub runner registration token, Coder admin password, LLM API key) as temporary: rotate it once OpenBao is available in M9, and record the rotation in `docs/milestone-reports/M9-governance.md`.
- `scripts/doctor.sh` must fail loudly if it detects a secret-shaped string (e.g. `ghp_`, `sk-`) inside any tracked file, as an early regression guard.

---

## Rule 4 — GitHub remains the coordination plane

GitHub owns:

```text
Git
Issues
PRs
Actions
workflow state
agentic workflow triggers
```

The private server performs execution.

---

## Rule 5 — Different automation tools have different responsibilities

```text
GitHub Actions
    deterministic execution

gh-aw
    repository-centric reasoning

Temporal
    durable orchestration
```

Do not build one giant workflow system that tries to replace all three.

---

## Rule 6 — No arbitrary external access to the private server

Automation access:

```text
GitHub
   ↓
self-hosted runner
   ↓
private services
```

Interactive access:

```text
Laptop
   ↓
LAN / Tailscale
   ↓
Coder / VS Code
```

Do not expose Docker, Temporal, OpenBao, Coder, or internal APIs directly to the public Internet.

---

# 4. Repository Structure

Create:

```text
private-dev-platform/
│
├── README.md
├── Makefile
├── compose.yaml
├── .env.example
├── .gitignore
├── VERSION.md
│
├── docs/
│   ├── architecture.md
│   ├── operations.md
│   ├── security.md
│   ├── disaster-recovery.md
│   └── milestone-reports/
│
├── scripts/
│   ├── doctor.sh
│   ├── bootstrap.sh
│   ├── wait-for-services.sh
│   ├── register-runner.sh
│   ├── unregister-runner.sh
│   ├── backup.sh
│   └── restore-test.sh
│
├── runner/
│   ├── Dockerfile
│   ├── entrypoint.sh
│   └── README.md
│
├── coder/
│   ├── Dockerfile
│   ├── templates/
│   │   └── docker-workspace/
│   │       ├── main.tf
│   │       ├── variables.tf
│   │       └── README.md
│   └── examples/
│
├── temporal/
│   ├── worker/
│   │   ├── Dockerfile
│   │   └── src/
│   ├── workflows/
│   └── README.md
│
├── mcp/
│   ├── docs-server/
│   └── lab-server/
│
├── governance/
│   ├── keycloak/
│   ├── openbao/
│   └── opa/
│
├── observability/
│   ├── otel/
│   └── grafana/
│
├── devcontainers/
│   └── base/
│       ├── devcontainer.json
│       └── Dockerfile
│
├── examples/
│   ├── hello-service/
│   │   ├── .devcontainer/
│   │   ├── src/
│   │   └── tests/
│   │
│   └── embedded-sim/
│       ├── .devcontainer/
│       ├── src/
│       ├── tests/
│       └── scripts/
│
└── .github/
    ├── workflows/
    │   ├── platform-ci.yml
    │   ├── runner-smoke.yml
    │   ├── durable-demo.yml
    │   └── local-capability.yml
    │
    └── agentic-workflows/
        └── investigate-failure.md
```

---

# 5. Standard Make Targets

The junior developer must maintain these commands as the stable interface to the repository:

```bash
make doctor
make bootstrap
make up
make down
make status
make logs
make test
make runner-register
make runner-unregister
make coder-init
make e2e
make backup
make restore-test
```

A user should not need to memorize Docker Compose commands.

### Script test coverage

`make test` must include automated tests for the repository's own automation scripts (`doctor.sh`, `bootstrap.sh`, `wait-for-services.sh`, `register-runner.sh`, `unregister-runner.sh`, `backup.sh`, `restore-test.sh`), not only the example applications. Use `shellcheck` for static analysis and `bats` (or an equivalent shell-testing framework) for behavioral tests covering at least: expected success path, missing-dependency failure path, and idempotency (running twice does not corrupt state). Do not treat these scripts as untested glue code — they are the operational core of the platform.

---

# 6. Milestone 0 — Host Preparation

## Objective

Establish a known-good Linux host.

Recommended baseline:

```text
Ubuntu LTS / Debian stable
x86-64
16 GB RAM minimum
32 GB recommended
100+ GB free disk
Docker Engine
Docker Compose plugin
Git
GNU Make
curl
jq
```

Do not install Kubernetes.

---

## Tasks

Create `scripts/doctor.sh`.

It must verify:

- Linux host
- architecture
- Docker available
- Docker daemon reachable
- Docker Compose available
- Git available
- curl available
- jq available
- enough disk space
- outbound HTTPS connectivity to GitHub
- ports required by the stack are available

Example expected behavior:

```bash
./scripts/doctor.sh
```

Output:

```text
[OK] Docker
[OK] Docker Compose
[OK] Git
[OK] outbound github.com connectivity
[OK] free disk: 312 GB
[OK] required ports
```

---

## Validation Milestone M0

Run:

```bash
make doctor
```

Acceptance criterion:

```text
all required checks = PASS
```

Do not continue otherwise.

---

## Manual E2E Test M0

The junior developer must manually perform:

1. Reboot the server.
2. Log back in.
3. Run:

```bash
docker run --rm hello-world
```

4. Run:

```bash
git clone <platform-repository>
cd private-dev-platform
make doctor
```

5. Record the result in:

```text
docs/milestone-reports/M0-host.md
```

Include:

- OS version
- Docker version
- Compose version
- hostname
- CPU
- RAM
- free disk
- screenshot or pasted output showing PASS

Only merge M0 after this report exists.

---

# 7. Milestone 1 — Compose Foundation

## Objective

Prove that the platform can be brought up and down predictably.

Initially include only:

```text
PostgreSQL
Coder
Temporal
Temporal UI
```

Do not add governance or observability yet.

---

## Compose Requirements

Every service must have:

- pinned image version
- explicit network
- named volume if persistent
- restart policy
- health check where supported

Create networks:

```text
platform-control
platform-workspaces
```

Do not use `network_mode: host`.

---

## Commands

Implement:

```bash
make up
make down
make status
make logs
```

`make up` should ultimately execute something equivalent to:

```bash
docker compose up -d
```

but hide implementation details from users.

---

## Validation Milestone M1

Run:

```bash
make up
make status
```

Verify:

```text
coder          healthy
coder-db       healthy
temporal       healthy
temporal-db    healthy
temporal-ui    healthy
```

Then:

```bash
make down
make up
```

Verify all persistent data remains valid.

---

## Manual E2E Test M1

The junior developer must:

1. Start the stack.
2. Open Coder UI in a browser.
3. Open Temporal UI.
4. Stop all containers:

```bash
make down
```

5. Start everything again:

```bash
make up
```

6. Confirm both UIs return.

Create:

```text
docs/milestone-reports/M1-compose.md
```

Record:

- commands
- screenshots
- container status
- startup time
- restart result

---

# 8. Milestone 2 — Self-Hosted GitHub Runner

## Objective

Give GitHub an **outbound-only execution channel** into the private server.

This is strategically important because the server may have little or no inbound Internet accessibility.

Architecture:

```text
GitHub Actions
      │
      │ outbound runner connection
      ▼
private runner
      │
      ▼
local Docker / APIs
```

---

## Runner Requirements

Build the runner image in:

```text
runner/Dockerfile
```

Do not depend on an opaque third-party runner image.

The runner container should:

- download a pinned GitHub Actions Runner version
- persist runner configuration in a named volume
- connect outbound only
- use labels:

```text
self-hosted
linux
private-lab
docker
```

---

## Important Security Restriction

For the initial implementation:

```text
ONLY private repository workflows may target this runner.
```

This must be actively enforced, not merely stated as intent:

- Confirm and record repository visibility as `Private` in `docs/milestone-reports/M2-runner.md`.
- Do not enable this runner on any repository accepting external forks or contributions.
- Configure branch protection so `runner-smoke.yml` and any workflow targeting `[self-hosted, private-lab]` can only be triggered by collaborators with write access (`workflow_dispatch` restricted to the default branch, no `pull_request` trigger from forks).

Do not use:

```text
pull_request_target
```

with this runner, and do not add a `pull_request` trigger sourced from fork branches to any workflow that targets `[self-hosted, private-lab]`.

Do not mount `/var/run/docker.sock` directly into the runner container.

Direct Docker socket access is equivalent to unauthenticated root on the host: any workflow (including one introduced by a future mistake, dependency, or compromised action) can escape the container entirely. This must be mitigated, not merely documented.

Use one of the following instead, in order of preference:

1. **Rootless / isolated execution** — run job containers through `sysbox-runc` or a rootless Docker daemon so the runner can launch containers without host-level socket exposure.
2. **Docker-in-Docker (DinD) sidecar** — give the runner its own isolated Docker daemon (a `docker:dind` sidecar container) instead of the host socket, so a compromised job cannot reach host containers/volumes.
3. **Socket proxy** — if a proxy is unavoidable, put `docker-socket-proxy` (or equivalent) in front of the socket, allow-listing only the specific API calls the runner needs (e.g. `build`, `run` on approved images) and denying host-level operations (`exec` into arbitrary containers, volume mounts of host paths, `--privileged`).

If, after evaluating these options, direct socket access is still chosen for a specific milestone, this must be recorded as an explicit, time-boxed risk acceptance in `docs/security.md` — not silently accepted in this plan.

---

## GitHub Workflow

Create:

```text
.github/workflows/runner-smoke.yml
```

Manual trigger:

```yaml
workflow_dispatch:
```

Target:

```text
[self-hosted, private-lab]
```

The job should:

- print hostname
- print Docker version
- run an ephemeral test container
- call a local health endpoint

---

## Validation Milestone M2

From GitHub:

```text
Actions → runner-smoke → Run workflow
```

Expected result:

```text
PASS
```

The log must prove it executed on the private server.

---

## Manual E2E Test M2

This test must demonstrate the primary design requirement:

### Before the test

Confirm that the server has no intentionally opened inbound public port.

### Test

From another network or device:

1. Open GitHub.com.
2. Trigger `runner-smoke`.
3. Watch the workflow start.
4. Verify the job runs on the private server.
5. Verify the workflow calls a service available only inside the private environment.
6. Verify the result appears in GitHub.

Create:

```text
docs/milestone-reports/M2-runner.md
```

Explicitly answer:

```text
Can GitHub execute a controlled operation on the private server
without inbound access to the private server?
```

Expected answer:

```text
YES
```

---

# 9. Milestone 3 — Coder Development Workspace

## Objective

A developer must be able to request a development environment containing:

```text
Git checkout
toolchain
dependencies
build tools
VS Code remote support
```

without manually configuring a machine.

---

## First Workspace Type

Implement:

```text
docker-standard
```

using:

```text
Coder Community
+
Docker
+
Dev Container concepts
```

The workspace should automatically clone this same repository.

---

## Workspace Contents

Install at minimum:

```text
git
curl
build-essential
python
node or another simple runtime
GitHub CLI
Docker CLI if required
```

Use a project-specific non-root user.

---

## Example Application

Create:

```text
examples/hello-service/
```

It should support:

```bash
make build
make test
make run
```

inside the workspace.

The test suite may be tiny.

The purpose is proving the environment contract.

---

## Coder Template

`coder/templates/docker-workspace/` must:

1. create workspace container
2. mount persistent home volume
3. clone repository
4. start Coder agent
5. expose VS Code connection
6. start in project directory

---

## Validation Milestone M3

From Coder:

```text
Create Workspace
→ docker-standard
```

Inside VS Code:

```bash
git status
make -C examples/hello-service build
make -C examples/hello-service test
```

Everything must pass without installing extra packages manually.

---

## Manual E2E Test M3

The junior developer must:

1. Delete the existing workspace.
2. Create a completely fresh workspace.
3. Connect using VS Code.
4. Confirm the repository exists.
5. Build the sample.
6. run tests.
7. edit one line.
8. commit the change on a test branch.
9. push the branch to GitHub.

Record results in:

```text
docs/milestone-reports/M3-coder.md
```

The report must explicitly answer:

```text
Could a new developer become productive without configuring
the development environment manually?
```

Expected answer:

```text
YES
```

---

# 10. Milestone 4 — Embedded Simulation Workspace

## Objective

Prove that the same Coder/Docker model supports an embedded-style toolchain.

This milestone does **not** require physical hardware.

Use simulated tooling.

---

## Example

Create:

```text
examples/embedded-sim/
```

Possible toolchain:

```text
gcc
cmake
ninja
qemu-user or a small emulator
```

A simple example could:

1. compile a C application
2. execute tests
3. produce a firmware-like binary artifact
4. run a simulated target

Example:

```bash
make configure
make build
make test
make simulate
```

---

## Workspace Type

Create:

```text
embedded-linux
```

as a Docker workspace containing the full toolchain.

Do not require host package installation.

---

## Validation Milestone M4

Fresh workspace:

```text
embedded-linux
```

must successfully execute:

```bash
make -C examples/embedded-sim clean
make -C examples/embedded-sim build
make -C examples/embedded-sim test
make -C examples/embedded-sim simulate
```

---

## Manual E2E Test M4

Delete the workspace first.

Then:

```text
Coder → New Workspace → embedded-linux
```

Verify that a completely clean environment can produce the target artifact.

Record:

```text
artifact filename
compiler version
test output
simulation output
```

in:

```text
docs/milestone-reports/M4-embedded.md
```

---

# 11. Milestone 5 — Temporal Durable Workflow

## Objective

Prove durable orchestration independently of GitHub agents.

Implement a deliberately simple workflow:

```text
start
 ↓
activity A
 ↓
wait 30 seconds
 ↓
activity B
 ↓
finish
```

---

## Required Demonstration

The workflow must survive worker failure.

Example:

```text
Temporal
   │
   ├─ Activity: prepare_build
   │
   ├─ Timer: 30 seconds
   │
   └─ Activity: verify_build
```

---

## Validation Milestone M5

Start workflow.

During timer:

```bash
docker compose stop temporal-worker
```

Wait several seconds.

Then:

```bash
docker compose start temporal-worker
```

Expected:

```text
workflow continues
workflow completes
workflow state not lost
```

---

## Manual E2E Test M5

The junior developer must deliberately:

1. start the durable demo
2. kill worker container (`docker compose kill temporal-worker`)
3. restart the Temporal server component only (`docker compose restart temporal`) — do not reboot the host for this step
4. restart worker (`docker compose start temporal-worker`)
5. verify workflow resumes
6. inspect Temporal UI history

Record screenshots and workflow ID in:

```text
docs/milestone-reports/M5-temporal.md
```

Explicitly answer:

```text
Did the process survive worker failure without manual state reconstruction?
```

Expected:

```text
YES
```

---

# 12. Milestone 6 — Agent/Harness Integration

## Objective

Introduce an actual paid or subscribed LLM.

Choose exactly one initial provider:

```text
GitHub Copilot
OR
Claude
OR
OpenAI
OR
Gemini
```

Do not integrate four providers simultaneously.

Recommended first option:

```text
GitHub Copilot
```

because GitHub is already the coordination plane.

---

## Local Agent Harness

This platform standardizes on two CLI-based agent harnesses, both already installed and confirmed working:

```text
opencode   (OpenCode CLI, v1.18.21)
pi         (Pi CLI, v0.84.2)
```

Install both into the agent workspace — this is not optional, since both are the supported harnesses for this platform. Test the Agent Test below with each. The harness software itself should remain replaceable at the interface level (each just needs to see repository context and call the same MCP/API surface later phases expose).

---

## Agent Test

Create a deliberately failing unit test in a branch.

Ask the agent:

```text
Investigate why the test fails.
Do not modify code.
Return:
- root cause
- affected file
- recommended fix
```

---

## Validation Milestone M6

The model must:

- see repository context
- identify the known failure
- not require manual copying of the entire repository into chat

---

## Manual E2E Test M6

The junior developer must:

1. create fresh agent workspace
2. authenticate the selected provider
3. intentionally break the sample project
4. ask the agent to diagnose it
5. compare the diagnosis with the known problem
6. save transcript/evidence

Record in:

```text
docs/milestone-reports/M6-agent.md
```

---

# 13. Milestone 7 — GitHub Agentic Workflows

## Objective

Add:

```text
gh-aw
```

without replacing normal Actions.

Architecture:

```text
GitHub event
    ↓
gh-aw
    ↓
reason
    ↓
safe decision
    ↓
deterministic workflow
```

---

## First Agentic Workflow

Create:

```text
.github/agentic-workflows/investigate-failure.md
```

It should:

1. inspect a failed Actions run
2. inspect relevant repository files
3. describe probable root cause
4. create a bounded output

Do not initially let it:

- deploy
- modify infrastructure
- control Docker host arbitrarily
- manipulate hardware

---

## Keep Deterministic Capabilities Separate

Example normal workflow:

```text
.github/workflows/local-capability.yml
```

This performs:

```text
build
test
simulation
```

The agent can request the capability, but should not reimplement the capability itself.

---

## Validation Milestone M7

Create known build failure.

Expected lifecycle:

```text
CI fails
 ↓
agentic workflow executes
 ↓
agent investigates
 ↓
result is visible in GitHub
```

---

## Manual E2E Test M7

The junior developer must:

1. introduce the documented test failure
2. push branch
3. observe deterministic CI fail
4. trigger or observe `gh-aw`
5. review agent reasoning
6. verify the agent did not perform unauthorized actions

Record:

```text
docs/milestone-reports/M7-gh-aw.md
```

---

# 14. Milestone 8 — MCP and Local Capability Fabric

## Objective

Allow humans and agents to query private capabilities without granting arbitrary shell access.

Implement two simple services.

---

## MCP Service 1 — Documentation

Provide tools such as:

```text
search_docs(query)
get_architecture()
get_build_instructions()
```

Populate it from local Markdown documentation.

---

## MCP/HTTP Service 2 — Lab Simulator

Do not use physical hardware yet.

Implement:

```text
list_devices()
reserve_device()
flash_device()
run_test()
get_logs()
release_device()
```

against simulated devices.

Example state:

```json
{
  "device": "ecu-demo-01",
  "status": "available"
}
```

---

## Validation Milestone M8

Agent should be able to answer:

```text
Which demo ECU is currently available,
and what build command should I use?
```

using the appropriate tool services.

---

## Manual E2E Test M8

Ask the agent to:

1. query available simulated devices
2. reserve one
3. execute approved test operation
4. retrieve logs
5. release device

Verify through service logs that calls happened through defined APIs rather than arbitrary host shell commands.

Record:

```text
docs/milestone-reports/M8-mcp.md
```

---

# 15. Milestone 9 — Governance Foundation

Do not build enterprise-scale security.

Implement enough to prove the architecture.

---

## OpenBao

Use for:

```text
LLM API secrets
demo device credentials
service credentials
```

No secret should need to appear in source code.

---

## OPA

Implement at least three example policies:

```text
allow read_device
allow run_test
deny flash_device_without_approval
```

---

## Keycloak

Use only if identity experimentation is required.

Otherwise make this service optional through:

```text
docker compose --profile governance
```

---

## Validation Milestone M9

Attempt:

```text
run_test
```

Expected:

```text
ALLOW
```

Attempt:

```text
flash_device
```

without approval.

Expected:

```text
DENY
```

---

## Manual E2E Test M9

The junior developer must intentionally try an unauthorized operation.

The test only passes if the system rejects it.

Record:

```text
docs/milestone-reports/M9-governance.md
```

Include the exact policy decision.

---

# 16. Milestone 10 — Observability

## Objective

Make executions visible across:

```text
GitHub runner
Temporal worker
MCP service
lab simulation
```

Deploy:

```text
OpenTelemetry Collector
Grafana OSS
```

Optional additional local backend:

```text
Prometheus
Loki
Tempo
```

Only add those if needed.

---

## Minimum Dashboard

Display:

```text
service uptime
Temporal activity count
MCP request count
lab API request count
workflow failures
```

---

## Validation Milestone M10

Execute:

```text
sample build
Temporal workflow
MCP request
```

All three must produce observable telemetry.

---

## Manual E2E Test M10

Junior developer:

1. execute complete local test
2. open Grafana
3. find execution
4. correlate timestamps across services

Record screenshots in:

```text
docs/milestone-reports/M10-observability.md
```

---

# 17. Milestone 11 — Remote Interactive Access

Automation already works without inbound access because the GitHub runner connects outbound.

Now optionally add interactive remote access.

Recommended:

```text
Tailscale Personal
```

Do not publicly expose Coder.

Target:

```text
Laptop
  │
Tailscale
  │
private server
  │
Coder
  │
workspace
```

---

## Validation Milestone M11

From a network outside the server LAN:

1. connect through Tailscale
2. open Coder
3. connect VS Code
4. edit source
5. run build

No public port forwarding should be required.

---

## Manual E2E Test M11

Use a mobile hotspot rather than the server's normal LAN.

Confirm:

```text
VS Code → private Coder workspace
```

works.

Record:

```text
docs/milestone-reports/M11-remote.md
```

---

# 18. Final Milestone — Complete End-to-End Scenario

This is the most important acceptance test.

The junior developer should not be told to fake any step.

Use the simulated embedded project.

---

## Scenario

### Step 1 — Create problem

Create a GitHub issue:

```text
Embedded simulator regression: demo ECU validation failing
```

---

### Step 2 — Agent investigation

Trigger:

```text
gh-aw failure investigator
```

Agent must:

```text
inspect issue
inspect repository
inspect latest CI
reason about failure
```

---

### Step 3 — Deterministic local build

Agent or workflow invokes approved deterministic GitHub Action.

Execution:

```text
GitHub
 ↓
self-hosted runner
 ↓
Docker
 ↓
embedded build
```

---

### Step 4 — Start durable process

Workflow starts:

```text
Temporal validation workflow
```

Temporal must orchestrate:

```text
reserve simulated device
 ↓
wait
 ↓
run simulated test
 ↓
retrieve logs
```

---

### Step 5 — Capability call

Temporal activity calls:

```text
Lab / Device API
```

The API must go through policy checks.

---

### Step 6 — Simulated validation

Run:

```text
firmware artifact
+
simulated ECU
```

Return structured result.

---

### Step 7 — Agent evaluates output

Agent reads result and reports:

```text
failure cause
recommended fix
test evidence
```

---

### Step 8 — GitHub receives result

Result must appear in GitHub as one of:

```text
workflow summary
issue comment
PR comment
check result
```

---

# 19. Final Manual E2E Test Request

The implementing junior developer must execute this test personally.

No automated test is accepted as a substitute.

## Test Instructions

Start from a clean machine state:

```bash
make down
docker system prune
```

Do not delete persistent named volumes unless the test explicitly requires it.

Then:

### A. Start platform

```bash
make up
```

Verify health.

---

### B. Create fresh Coder workspace

```text
embedded-linux
```

Connect VS Code.

---

### C. Modify sample embedded code

Create a deliberate regression.

Commit and push branch.

---

### D. Observe GitHub CI

Normal deterministic CI should fail.

---

### E. Run agent investigation

Trigger `gh-aw`.

Verify meaningful diagnosis.

---

### F. Start approved local capability

Trigger the deterministic workflow.

Verify GitHub sends the job to:

```text
self-hosted private runner
```

---

### G. Verify private execution

On the server:

```bash
docker ps
```

Confirm the build/test workload actually ran locally.

---

### H. Verify durable orchestration

Start Temporal validation workflow.

During execution:

```bash
docker compose restart temporal-worker
```

Workflow must still complete.

---

### I. Verify tool fabric

Observe:

```text
Temporal
 ↓
Lab API
 ↓
simulated ECU
```

---

### J. Verify governance

Attempt one deliberately prohibited operation.

OPA must reject it.

---

### K. Verify observability

Find the test execution in Grafana/telemetry.

---

### L. Verify GitHub result

Final result must appear back in GitHub.

---

# 20. Final Acceptance Criteria

The implementation is complete only if all of the following are true:

- [ ] Fresh clone can bootstrap the stack.
- [ ] No secret is committed.
- [ ] Docker Compose owns the platform lifecycle.
- [ ] GitHub self-hosted runner works without inbound public access.
- [ ] Coder can create a fresh Docker development workspace.
- [ ] Workspace automatically obtains repository source.
- [ ] Workspace contains a working custom build toolchain.
- [ ] VS Code can attach to the workspace.
- [ ] Normal GitHub Actions run deterministic CI.
- [ ] `gh-aw` performs repository-centric reasoning.
- [ ] Temporal survives worker interruption.
- [ ] MCP/internal APIs expose controlled capabilities.
- [ ] Simulated device operations work.
- [ ] OPA can deny an unsafe action.
- [ ] Secrets are not stored in source.
- [ ] Important execution events are observable.
- [ ] End-to-end flow begins in GitHub and returns a result to GitHub.
- [ ] Interactive access does not require public exposure of the server.
- [ ] All milestone reports are committed.

---

# 21. Development Workflow for the Junior Developer

Each milestone should use:

```text
main
 │
 └── milestone/M1-compose
 └── milestone/M2-runner
 └── milestone/M3-coder
 ...
```

For every milestone:

1. create branch
2. implement only that milestone
3. run automated validation
4. execute manual E2E validation
5. create milestone report
6. open PR
7. review changes
8. merge only after acceptance criteria pass

Do not implement three milestones simultaneously.

---

# 22. Recommended Implementation Order

```text
M0  Host readiness
 ↓
M1  Docker Compose base
 ↓
M2  GitHub self-hosted runner
 ↓
M3  Coder standard workspace
 ↓
M4  Embedded Docker workspace
 ↓
M5  Temporal durability
 ↓
M6  LLM / coding agent
 ↓
M7  gh-aw
 ↓
M8  MCP + Lab API simulation
 ↓
M9  governance
 ↓
M10 observability
 ↓
M11 remote access
 ↓
FINAL E2E
```

Do not start with the AI components.

First make:

```text
GitHub
+
Docker
+
Coder
+
runner
+
Temporal
```

boringly reliable.

Then add agents.

---

# 23. Versioning Policy

`VERSION.md` tracks the platform's release version, not individual milestones.

Milestones (M0–M11) are implementation stages, not releases. Do not tag or version-bump per milestone.

Rules:

- While any milestone from Section 6–17 is incomplete, the platform is pre-release. `VERSION.md` should read:

  ```text
  unreleased
  ```

- Once every checkbox in Section 20 (Final Acceptance Criteria) is checked and the Final Milestone (Section 18) end-to-end scenario passes, set:

  ```text
  0.1.0
  ```

- After `0.1.0`, use standard SemVer (`MAJOR.MINOR.PATCH`) for subsequent changes:

  ```text
  MAJOR — breaking change to the developer-facing contract (Make targets, repo layout, workspace types)
  MINOR — backward-compatible capability added (new workspace type, new MCP tool, new milestone-like feature)
  PATCH — bug fix, security patch, dependency bump with no behavior change
  ```

- Record every version bump as a dated entry in `VERSION.md` with a one-line summary of what changed.

---

# 24. Future GCP Extension

GCP should not be required for the initial implementation.

Later, preserve the same logical architecture:

```text
Coder
 │
 ├── local Docker workspace
 │
 └── GCP workspace
```

and:

```text
GitHub Actions
 │
 ├── private runner
 │
 └── GCP runner
```

and:

```text
Temporal
 │
 ├── local worker
 │
 └── GCP worker
```

The developer experience should remain:

```text
VS Code
 ↓
choose workspace
 ↓
work
```

The workflow should remain:

```text
GitHub
 ↓
reason / orchestrate / execute
 ↓
result
```

Cloud should therefore become **another execution location**, not another development platform.

---

# 25. Final Design Principle

The implementation should prove this model:

```text
            HUMAN
              │
              ▼
          VS CODE
              │
              ▼
        WORK SESSION
              │
              ▼
        AGENT / HUMAN
              │
              ▼
       CODER WORKSPACE
          Docker
              │
              ▼
           GITHUB
              │
       ┌──────┼───────┐
       ▼      ▼       ▼
    Actions  gh-aw  Temporal
       │      │       │
       └──────┼───────┘
              ▼
        APPROVED APIs
              │
              ▼
     simulated / real world
```

The platform is successful when changing:

```text
local Docker
```

to:

```text
GCP
```

or changing:

```text
simulated ECU
```

to:

```text
real ECU
```

does **not** require redesigning the developer experience or coordination model.

That is the architecture the implementation should optimize for.

