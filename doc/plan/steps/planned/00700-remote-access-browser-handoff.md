> Mandatory: read the overall plan in full before proceeding: doc/plan/plan.md

# Phase 1 — Remote Dev Environment + Agent

## M15 — Local Network / Browser Access

### Objective

Prove the workspace is reachable and usable from a client other than "localhost on the server itself" — over the local network, without opening any public port. This builds on the AHP-over-SSH bridge established in M4 and the code-server module already wired into the Coder template (M3): the Coder dashboard and the workspace's browser-based VS Code (code-server) are reachable from any device on the same network as the Coder server, and `coder config-ssh` bridges the same workspace to a normal SSH host for VS Code Desktop's Remote-SSH/Agents flows.

Wide-area access from a genuinely different network (e.g. a laptop on a mobile hotspot, via Tailscale) is **out of scope for this milestone** — see the optional `docs/phases/phase-6-remote-network-access.md` (M16), which has no dependents and can be done independently, whenever a real second network is available to test from.

Target:

```text
Another device on the same network → Coder dashboard / code-server (browser) → workspace
Another device on the same network → coder config-ssh → VS Code Desktop → workspace
```

### Validation Milestone M15

1. From a device other than the Coder server itself (or, at minimum, over `http://<server-ip>:7080` rather than `localhost`), open the Coder dashboard.
2. Open the workspace's **code-server** app — confirm the repository is visible and editable in-browser.
3. From that same device, run `coder config-ssh` and connect via VS Code Desktop's Remote-SSH to `coder.<workspace-name>`.
4. Edit source, run a build (`make -C examples/hello-service build`).

No public port forwarding or external service should be required — only reachability on the local network.

### Manual E2E Test M15

From a second device on the same LAN as the Coder server (not the server's own `localhost`): open the Coder dashboard, open code-server in the browser, confirm the repo/editor work; then connect VS Code Desktop over `coder config-ssh` and confirm the same.

Record in `docs/milestone-reports/M15-local-access.md`.
