> Mandatory: read the overall plan in full before proceeding: doc/plan/plan.md

# Phase 1 — Remote Dev Environment + Agent

## M15 — Remote Access / Browser Handoff

### Objective

Automation already works without inbound access once the GitHub runner exists (Phase 2), but Phase 1's deliverable is specifically the *interactive* remote path — pulled forward here because without it the workspace is only reachable on the local LAN, not "remote." This builds on the AHP-over-SSH bridge established in M4.

Recommended: **Tailscale Personal**. Do not publicly expose Coder.

**Configure an explicit least-privilege ACL — Tailscale's default is allow-all.** Without an `acls` section in the tailnet policy file, every device on the tailnet can reach every other device, which contradicts Rule 6. Write an ACL restricting access to the private server's Coder/SSH ports to only the devices/users that need it, and consider enabling device approval given M15's own "unfamiliar network" test scenario.

Target:

```text
Laptop → Tailscale → private server → Coder → workspace
```

### Validation Milestone M15

From a network outside the server LAN:

1. Connect through Tailscale.
2. Open Coder.
3. Connect VS Code.
4. Edit source.
5. Run build.

No public port forwarding should be required.

### Manual E2E Test M15

Use a mobile hotspot rather than the server's normal LAN. Confirm `VS Code → private Coder workspace` works.

Record in `docs/milestone-reports/M15-remote.md`.

### Optional: Browser Agent Handoff Test

VS Code supports accessing remote Agent Host sessions from the browser through a dev tunnel — a stronger proof than SSH-based remote access alone, since it shows the *control surface itself* (not just the network path) is replaceable:

```text
VS Code desktop → start session → close desktop → browser Agents window → same remote host → same session
```

Mark this **optional** for the initial implementation (dev-tunnel auth adds another connectivity mechanism). Record results, if attempted, in `docs/milestone-reports/M15-remote.md` under a "Browser Handoff (optional)" subsection.

