> Mandatory: read the overall plan in full before proceeding: docs/plan/plan.md

# Phase 3 — Durable Orchestration & Capability Fabric

## M6 — Embedded Simulation Workspace

### Objective

Prove that the same Coder/Docker model from Phase 1 M3 supports an embedded-style toolchain. Does **not** require physical hardware — use simulated tooling.

### Example

Create `examples/embedded-sim/`. Possible toolchain: `gcc`, `cmake`, `ninja`, `qemu-user` or a small emulator. **Caveat:** `qemu-user` only emulates userspace/syscalls for a cross-compiled binary against the target's libc — no MMIO/interrupts/peripherals/boot process. Good for "compile → run → check exit code/stdout," not a hardware simulator; for bare-metal firmware use `qemu-system` with a machine model instead. A simple example could compile a C application, execute tests, produce a firmware-like binary artifact, and run a simulated target:

```bash
make configure
make build
make test
make simulate
```

### Workspace Type

Create `embedded-linux` as a Docker workspace containing the full toolchain. Do not require host package installation.

### Toolchain Provenance

The buildchain should not just be "latest ubuntu + random apt installs." Use a `Dockerfile` with a pinned base, pinned tool versions, and a recorded image digest — pushed to the local OCI registry introduced in M7. This gives a workspace a reproducible identity: repo revision + Dev Container revision + toolchain image digest. If the build host sits behind a corporate/TLS-intercepting proxy, apply the same optional `CACERT`/BuildKit-secret pattern documented in Phase 1's M3 rather than inventing a second mechanism.

### Validation Milestone M6

Fresh `embedded-linux` workspace must successfully execute:

```bash
make -C examples/embedded-sim clean
make -C examples/embedded-sim build
make -C examples/embedded-sim test
make -C examples/embedded-sim simulate
```

### Manual E2E Test M6

Delete the workspace first, then `Coder → New Workspace → embedded-linux`. Verify a completely clean environment can produce the target artifact.

Record artifact filename, compiler version, image digest, test output, simulation output in `docs/milestone-reports/M6-embedded.md`.

