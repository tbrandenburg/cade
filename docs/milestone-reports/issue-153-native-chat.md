# Issue #153 — native chat startup

**Partial mitigation, not a first-attempt reliability fix.** On 2026-11-09,
the locked docs dependencies were precompiled during trusted workspace startup.
In same-sandbox controls, docs-MCP initialization fell from 4.53 seconds to
2.10 seconds. No timeout or sandbox setting was changed.

Real Coder dashboard sessions on both `docker-workspace` and `agent-workspace`
eventually completed native docs search, command/file operations, network and
outside-relay denial, approval/rejection, and relay-loss checks. Marker bytes
survived stop/start. Both required recovery or retries, so these results do not
prove repeatable first-attempt startup.

An instrumented Docker run showed the precompiled docs process receiving about
2.39 seconds of CPU over 30.33 seconds while CPU and I/O pressure were high.
That observation does not establish the cause of every timeout. The detailed
investigation remains in the issue work branch; [#153](https://github.com/tbrandenburg/cade/issues/153)
remains open for reliability work.

The source-matched image launcher suites passed 15/15 checks for each workspace
image, and the trusted-startup regression passed with the pinned uv version.
Disposable workspaces, templates and conversations were removed after the run.
