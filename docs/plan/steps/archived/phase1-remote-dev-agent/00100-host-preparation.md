> Mandatory: read the overall plan in full before proceeding: docs/plan/plan.md

# Phase 1 — Remote Dev Environment + Agent

## M0 — Host Preparation

### Objective

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

### Tasks

Create `scripts/doctor.sh`. It must verify:

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
- outbound HTTPS connectivity to `update.code.visualstudio.com` and `vscode.download.prss.microsoft.com` (required by M4: VS Code's Agents window auto-installs a CLI binary + ~223 MB server bundle containing the Copilot harness on first remote connect — verified in the independent [`ahp-sandbox`](https://github.com/tbrandenburg/ahp-sandbox) POC; without it, M4 fails with no GitHub-connectivity-shaped error to explain why)
- ports required by the stack are available

### Validation Milestone M0

```bash
make doctor
```

Acceptance criterion: all required checks = PASS. Do not continue otherwise.

### Manual E2E Test M0

1. Reboot the server.
2. Log back in.
3. `docker run --rm hello-world`
4. `git clone <platform-repository> && cd private-dev-platform && make doctor`
5. Record the result in `docs/milestone-reports/M0-host.md`, including OS version, Docker version, Compose version, hostname, CPU, RAM, free disk, and command output/exit codes per the evidence standard in Section 3 Rule 2.

Only merge M0 after this report exists.
