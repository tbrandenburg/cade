> Mandatory: read the overall plan in full before proceeding: docs/plan/plan.md

# Gap: `get_build_instructions()` misparses Makefile variable assignments as targets

## Why this matters

`mcp/docs-server/src/docs_server/server.py`'s `get_build_instructions()`
extracts Makefile target names with:

```python
targets = [
    line.split(":", 1)[0].strip()
    for line in makefile.read_text(encoding="utf-8").splitlines()
    if line
    and not line.startswith(("\t", " ", "#"))
    and ":" in line
    and not line.startswith(".")
]
```

This matches *any* unindented line containing a `:`, not just real
`target:` rule lines. The repo's `Makefile` starts with:

```make
SHELL := /bin/bash
...
COMPOSE := docker compose
```

Both `SHELL := /bin/bash` and `COMPOSE := docker compose` are variable
assignments (using `:=`), not targets — but they satisfy every filter above
(no leading whitespace/`#`/`.`, contains `:`) and get emitted as `make
SHELL` / `make COMPOSE` in the tool's output. Independently re-running the
tool via a raw stdio JSON-RPC session against the live server reproduces
this:

```
- `make SHELL`
- `make COMPOSE`
- `make doctor`
- `make up`
...
```

`make SHELL` and `make COMPOSE` are not real, runnable targets — an agent
trusting this tool's output verbatim (the entire point of M11's validation
milestone: *"what build command should I use?"*) could be misled into
suggesting a non-existent command. This is a Boy Scout finding: a bug in a
file this step created, exposed by independently re-running the step's own
validation.

## Actions

1. In `mcp/docs-server/src/docs_server/server.py`, tighten the Makefile
   target-line filter to exclude variable-assignment lines (those
   containing `:=` or `?=` before the first bare `:`), and/or require the
   `:` to not immediately follow one of the assignment operators. A simple,
   robust fix: skip any line where the substring immediately after the
   split point starts with `=` (i.e. the line was `NAME := ...` /
   `NAME ?= ...`, which is not a target rule at all) — equivalently, only
   treat a line as a target if the character before the matched `:` is not
   part of `:=`/`?=`/`+=`/`!=` and the target name doesn't already appear as
   a variable definition elsewhere in the file.
2. Add a small regression check (existing repo convention: a script under
   `scripts/` or a quick inline assertion run as part of the milestone
   report's validation output) confirming `get_build_instructions()`'s
   parsed target list contains only genuine `make <target>:` rules — no
   `SHELL`/`COMPOSE`/any other `NAME :=`/`NAME ?=` line — for the current
   `Makefile`.
3. Re-run `get_build_instructions()` (e.g. via the raw stdio JSON-RPC
   session used in review, or the `opencode` MCP tool call) and confirm the
   `# Makefile targets` section no longer lists `SHELL` or `COMPOSE`.
4. Include the corrected output in an update to
   `docs/milestone-reports/M11-mcp.md` (or a short addendum) so the fix is
   evidenced, not just claimed.
