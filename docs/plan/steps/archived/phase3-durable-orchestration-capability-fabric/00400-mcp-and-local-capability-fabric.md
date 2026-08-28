> Mandatory: read the overall plan in full before proceeding: docs/plan/plan.md

# Phase 3 — Durable Orchestration & Capability Fabric

## M11 — MCP and Local Capability Fabric

### Objective

Allow humans and agents to query private capabilities without granting arbitrary shell access. Implement two simple services. **Both must follow the MCP spec's "Local MCP Server Compromise" guidance:** use `stdio` transport (spawned by the agent harness) wherever possible; if a service instead exposes HTTP, it must require a bearer token or bind to a Unix domain socket — never an open, unauthenticated TCP port.

### MCP Service 1 — Documentation

Tools: `search_docs(query)`, `get_architecture()`, `get_build_instructions()`. Populate from local Markdown documentation. Use `stdio` transport — no reason for this service to be network-reachable.

### MCP/HTTP Service 2 — Lab Simulator

Do not use physical hardware yet. Implement `list_devices()`, `reserve_device()`, `flash_device()`, `run_test()`, `get_logs()`, `release_device()` against simulated devices.

**Bind reservation tokens to the requesting caller.** Per the MCP spec's "State Handle Hijacking" guidance, `reserve_device()`'s returned reservation ID is a server-issued state handle that must be bound server-side to the authenticated caller — `run_test()`/`get_logs()`/`release_device()` must verify the caller matches the reservation owner, not accept the ID alone as authorization.

Example state:

```json
{ "device": "ecu-demo-01", "status": "available" }
```

### Validation Milestone M11

Agent (via the harness chosen in Phase 1 M9) should be able to answer: *"Which demo ECU is currently available, and what build command should I use?"* using the appropriate tool services.

### Manual E2E Test M11

Ask the agent to: query available simulated devices, reserve one, execute approved test operation, retrieve logs, release device. Verify through service logs that calls happened through defined APIs rather than arbitrary host shell commands.

Record in `docs/milestone-reports/M11-mcp.md`.

