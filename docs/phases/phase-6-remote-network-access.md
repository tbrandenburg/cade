# Phase 6 — Wide-Area Remote Network Access (Optional)

## Phase Objective

> From a laptop anywhere (mobile hotspot test), connect via Tailscale → AHP over SSH → VS Code Agent Host, into the same Docker workspace already proven reachable on the local network in Phase 1 (M15).

**This phase is optional and order-independent.** It has no downstream dependents: nothing in Phase 1 (M0/M1/M3/M4/M5/M9/M15), Phase 2 (GitHub automation — the runner is outbound-only), Phase 3 (Temporal/MCP), or Phase 4 (governance/observability) relies on wide-area access existing. `docs/ARCHITECTURE.md` scopes Tailscale explicitly as "interactive remote access only, never for automation." Start this phase only once there is a real second network/device to test from (e.g. a laptop on a mobile hotspot) — implementing and "validating" it without one only produces an unverifiable milestone report.

This phase was split out of Phase 1's original M15 (which conflated "reachable on the LAN" with "reachable from anywhere") — see `docs/phases/phase-1-remote-dev-agent.md`'s M15 for the local-network milestone this phase builds on.

## Required Reading (mandatory, before starting this phase)

| Milestone | Tool | Required reading |
|---|---|---|
| M16 | Tailscale | https://tailscale.com/kb/1018/acls, https://tailscale.com/kb/1223/tailscale-ssh |

---

## M16 — Wide-Area Remote Access (Tailscale)

### Objective

Prove the workspace is reachable from a genuinely different network (not just the server's own LAN), without any public port forwarding or inbound exposure. This builds on the AHP-over-SSH bridge established in Phase 1's M4, and the local reachability already proven in Phase 1's M15.

Recommended: **Tailscale Personal**. Do not publicly expose Coder.

**Configure an explicit least-privilege ACL — Tailscale's default is allow-all.** Without an `acls` section in the tailnet policy file, every device on the tailnet can reach every other device, which contradicts Rule 6. Write an ACL restricting access to the private server's Coder/SSH ports to only the devices/users that need it, and consider enabling device approval given this milestone's own "unfamiliar network" test scenario.

Target:

```text
Laptop → Tailscale → private server → Coder → workspace
```

### Validation Milestone M16

From a network outside the server LAN:

1. Connect through Tailscale.
2. Open Coder.
3. Connect VS Code.
4. Edit source.
5. Run build.

No public port forwarding should be required.

### Manual E2E Test M16

Use a mobile hotspot rather than the server's normal LAN. Confirm `VS Code → private Coder workspace` works.

Record in `docs/milestone-reports/M16-remote-tailscale.md`.

### Optional: Browser Agent Handoff Test (dev tunnel)

VS Code supports accessing remote Agent Host sessions from the browser through a dev tunnel — a stronger proof than SSH-based remote access alone, since it shows the *control surface itself* (not just the network path) is replaceable, and (unlike Tailscale) reaches the workspace without a client-side Tailscale install at all:

```text
VS Code desktop → start session → close desktop → browser Agents window → same remote host → same session
```

Mark this **optional**: dev-tunnel auth adds another connectivity mechanism on top of Tailscale. Record results, if attempted, in `docs/milestone-reports/M16-remote-tailscale.md` under a "Browser Handoff (optional)" subsection.

---

## Phase 6 Documentation & Agent Instructions Update

Before Phase 6 is considered done:

1. Update `docs/architecture.md`/`docs/operations.md` to reflect the actual Tailscale access path (tailnet name, ACL summary — no secrets/keys).
2. Update `AGENTS.md` with any Tailscale ACL quirks or connectivity gotchas discovered, and append a dated Phase 6 Lessons Learned entry.

## Phase 6 Exit Criteria

- [ ] VS Code connects to the workspace over Tailscale from outside the server's LAN (mobile hotspot test), with an explicit least-privilege ACL in place (not Tailscale's allow-all default).
- [ ] `docs/milestone-reports/M16-remote-tailscale.md` is committed with command-level evidence.
- [ ] `AGENTS.md` has an updated Phase 6 Lessons Learned entry.
