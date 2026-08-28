#!/usr/bin/env bash
# verify-docs-server-makefile-targets.sh — Regression check for the
# devenv-docs MCP server's get_build_instructions() Makefile target parser
# (Step 00402). Confirms the parsed target list only contains genuine
# `make <target>:` rules — no `SHELL`/`COMPOSE`/any other `NAME :=`/`NAME ?=`
# variable-assignment line from the repo's Makefile.
#
# Usage: scripts/verify-docs-server-makefile-targets.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

output="$(cd "$repo_root/mcp/docs-server" && uv run python3 -c '
from docs_server.server import get_build_instructions
print(get_build_instructions())
')"

echo "$output" | sed -n '/# Makefile targets/,$p'

for banned in SHELL COMPOSE; do
    if echo "$output" | grep -q "\`make ${banned}\`"; then
        echo "FAIL: 'make ${banned}' incorrectly parsed as a Makefile target" >&2
        exit 1
    fi
done

if ! echo "$output" | grep -q '`make doctor`'; then
    echo "FAIL: expected real target 'make doctor' missing from parsed output" >&2
    exit 1
fi

echo "PASS: no variable-assignment lines parsed as Makefile targets"
