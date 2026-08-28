> Mandatory: read the overall plan in full before proceeding: docs/plan/plan.md

# Phase 3 — Durable Orchestration & Capability Fabric

## M7 — Artifact Registry + Build Cache

### Objective

For embedded development especially, fresh workspaces are painful without caching. This isn't a conceptual developer-facing layer, but a missing infrastructure capability under the Development Execution Plane that M6's reproducibility goal depends on for usable performance.

Add:

```text
Artifact / Cache Services
├── local OCI registry (CNCF Distribution, Apache-2.0)
├── BuildKit cache
├── sccache / ccache
└── persistent dependency caches
```

`cache/registry/` for the registry service, `cache/sccache/` for the compiler cache (start with a persistent local directory; a dedicated `sccache-storage` compose service is optional).

**Registry must not be open/unauthenticated.** CNCF Distribution's deployment guide requires TLS and ideally access control for a production-ready registry. Bind it only to the internal compose network with no host port published, or enable basic auth. If a healthcheck is added, note that an authenticated registry returns `401` from `/v2/`, not `200` — a naive `curl -f` check will misreport it as unhealthy.

**sccache cache-key gotcha:** cache keys include absolute paths by default, so the cold/warm comparison in the Validation below will silently fail to hit cache if the two fresh workspaces mount the project at different absolute paths. Set `SCCACHE_BASEDIRS` (or use an identical mount path, e.g. `/workspace`, across workspace instances).

### Validation Milestone M7

1. Build `examples/embedded-sim` from a fresh workspace (cold cache) and record the build time.
2. Build it again from a second fresh workspace (warm cache via registry/sccache) and record the build time.
3. Confirm the second build is measurably faster, with cache hits shown in `sccache --show-stats` (or equivalent).

### Manual E2E Test M7

1. Delete any existing registry/cache volumes to guarantee a cold start.
2. Time a fresh `embedded-linux` workspace build (M6's example).
3. Delete the workspace (but not the cache volumes) and create a new one.
4. Time the build again.
5. Compare timings and cache-hit statistics.

Record in `docs/milestone-reports/M7-cache.md`.

