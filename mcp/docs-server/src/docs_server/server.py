"""M11 MCP Service 1 - Documentation.

Exposes `search_docs`, `get_architecture`, `get_build_instructions` over the
repository's local Markdown documentation. Runs over `stdio` transport only
(spawned by the agent harness, per the MCP spec's "Local MCP Server
Compromise" guidance) - there is no reason for this read-only documentation
lookup service to be network-reachable at all.
"""

from __future__ import annotations

import os
import re
from pathlib import Path

from mcp.server.mcpserver import MCPServer

mcp = MCPServer("cade-docs")


def _find_repo_root(start: Path) -> Path:
    """Walk up from `start` until a directory containing `docs/ARCHITECTURE.md`
    is found. Falls back to the `DOCS_REPO_ROOT` env var if set, so this
    server also works when installed/copied outside a git checkout of this
    repository."""
    override = os.environ.get("DOCS_REPO_ROOT")
    if override:
        return Path(override).resolve()
    current = start.resolve()
    for candidate in (current, *current.parents):
        if (candidate / "docs" / "ARCHITECTURE.md").is_file():
            return candidate
    raise FileNotFoundError(
        "Could not locate repo root (docs/ARCHITECTURE.md not found in any "
        f"parent of {start}); set DOCS_REPO_ROOT explicitly."
    )


REPO_ROOT = _find_repo_root(Path(__file__))
DOCS_ROOT = REPO_ROOT / "docs"


def _iter_markdown_files() -> list[Path]:
    return sorted(DOCS_ROOT.rglob("*.md"))


@mcp.tool()
def search_docs(query: str) -> list[dict[str, str]]:
    """Search local Markdown documentation under docs/ for a case-insensitive
    substring match. Returns up to 20 matches, each with the file path
    (relative to the repo root), the matching line number, and the matching
    line's text, so the caller can decide which file to read in full."""
    needle = query.strip().lower()
    if not needle:
        return []
    results: list[dict[str, str]] = []
    for path in _iter_markdown_files():
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError:
            continue
        for line_no, line in enumerate(lines, start=1):
            if needle in line.lower():
                results.append(
                    {
                        "file": str(path.relative_to(REPO_ROOT)),
                        "line": str(line_no),
                        "text": line.strip(),
                    }
                )
                if len(results) >= 20:
                    return results
    return results


@mcp.tool()
def get_architecture() -> str:
    """Return the full contents of docs/ARCHITECTURE.md - the condensed
    C4-model view of the platform (System Context, Container, Component
    diagrams)."""
    return (DOCS_ROOT / "ARCHITECTURE.md").read_text(encoding="utf-8")


@mcp.tool()
def get_build_instructions() -> str:
    """Return the repository's build/lifecycle instructions: the top-level
    Makefile targets (from README.md's quickstart) plus the full list of
    `make` targets defined in the Makefile, so a caller knows both *what*
    command to run and *why* it exists."""
    readme = REPO_ROOT / "README.md"
    makefile = REPO_ROOT / "Makefile"
    sections: list[str] = []
    if readme.is_file():
        sections.append(f"# From README.md\n\n{readme.read_text(encoding='utf-8')}")
    if makefile.is_file():
        targets = [
            line.split(":", 1)[0].strip()
            for line in makefile.read_text(encoding="utf-8").splitlines()
            if line
            and not line.startswith(("\t", " ", "#"))
            and ":" in line
            and not line.startswith(".")
            and not re.match(r"^[^:]*[:?+!]?=", line)
        ]
        sections.append("# Makefile targets\n\n" + "\n".join(f"- `make {t}`" for t in targets))
    return "\n\n---\n\n".join(sections)


def main() -> None:
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
