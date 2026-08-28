> Mandatory: read the overall plan in full before proceeding: docs/plan/plan.md

# Phase 1 — Remote Dev Environment + Agent

## M3 — Coder Development Workspace

### Objective

A developer must be able to request a development environment containing git checkout, toolchain, dependencies, build tools, and VS Code remote support — without manually configuring a machine.

### First Workspace Type

Implement `docker-standard` using Coder Community + Docker + Dev Container concepts. The workspace should automatically clone this same repository.

### Workspace Contents

Install at minimum: `git`, `curl`, `build-essential`, `python`, `node` (or another simple runtime), GitHub CLI, Docker CLI if required. Use a project-specific non-root user.

M9 later adds `bubblewrap`, `socat`, and `ripgrep` to this image to support sandboxing the agent CLIs with `srt` (Anthropic Sandbox Runtime).

**Optional corporate/TLS-intercepting-proxy CA bundle** — if the build host sits behind a MITM proxy (e.g. Netskope, or another corporate root CA), plain `apt-get`/`curl`/`npm` calls inside `coder/Dockerfile` fail with `SELF_SIGNED_CERT_IN_CHAIN`. Follow the pattern from [`pixel-agents-adt`](https://github.com/tbrandenburg/pixel-agents-adt)'s `Dockerfile`/`Makefile`/`AGENTS.md`: accept the bundle as a [BuildKit secret](https://docs.docker.com/build/building/secrets/) (`docker build --secret id=cacert,src=<path>`, never a build arg or `COPY`, so it never lands in image layers), install it into the OS trust store, and also set `NODE_EXTRA_CA_CERTS` since `npm`/Node ignore the OS store by default:

```dockerfile
RUN --mount=type=secret,id=cacert \
    if [ -s /run/secrets/cacert ]; then \
      cp /run/secrets/cacert /usr/local/share/ca-certificates/corporate-ca.crt \
      && update-ca-certificates; \
    fi
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
```

Expose it as an optional `Makefile` variable (`CACERT ?=`), e.g. `make build CACERT=/path/to/ca-bundle.pem`, so the default `make build`/`docker build` on unrestricted networks stays a no-op.

### Example Application

Create `examples/hello-service/`, supporting `make build`, `make test`, `make run` inside the workspace. The test suite may be tiny — the purpose is proving the environment contract.

### Coder Template

`coder/templates/docker-workspace/` must: create workspace container, mount persistent home volume, clone repository, start Coder agent, expose VS Code connection, start in project directory.

This persistent home volume is also where M4's Agent Host state lives — see M4 for the exact directory layout. Only `/home/coder` (or equivalent) survives a container replace; the rest of the workspace container is ephemeral.

**Template governance (per Coder's own security best practices):** push template revisions via `coder templates push` in CI with a dedicated non-human account — don't grant Template Admin broadly, and never inline credentials in the Terraform template (Coder persists template versions indefinitely; a secret committed into one revision stays recoverable even after a later "fix"). Pass credentials via `TF_VAR_*` / Coder parameters instead.

### Validation Milestone M3

From Coder: `Create Workspace → docker-standard`. Inside VS Code:

```bash
git status
make -C examples/hello-service build
make -C examples/hello-service test
```

Everything must pass without installing extra packages manually.

### Manual E2E Test M3

1. Delete the existing workspace.
2. Create a completely fresh workspace.
3. Connect using VS Code.
4. Confirm the repository exists.
5. Build the sample.
6. Run tests.
7. Edit one line.
8. Commit the change on a test branch.
9. Push the branch to GitHub.

Record results in `docs/milestone-reports/M3-coder.md`. The report must explicitly answer: *"Could a new developer become productive without configuring the development environment manually?"* Expected answer: YES.
