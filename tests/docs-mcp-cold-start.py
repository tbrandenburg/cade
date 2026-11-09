"""Opt-in real MCP cold start: python3 tests/docs-mcp-cold-start.py.

Requires uv and cached packages or package-index access; not backend test discovery.
Runs the repository command without a preexisting environment or manual sync.
Checks offline reuse and dependency drift without changing the committed lock.
"""

import asyncio
import json
import os
import shutil
import signal
import subprocess
import tempfile
from pathlib import Path


async def response(reader: asyncio.StreamReader, identifier: int) -> dict[str, object]:
    while True:
        line = await asyncio.wait_for(reader.readline(), timeout=120)
        assert line, "docs MCP exited before responding"
        message = json.loads(line)
        if message.get("id") == identifier:
            assert "error" not in message, "docs MCP returned a protocol error"
            return message["result"]


async def exchange(directory: Path, command: list[str], env: dict[str, str]) -> None:
    with tempfile.TemporaryFile() as errors:
        process = await asyncio.create_subprocess_exec(
            *command,
            cwd=directory,
            env=env,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=errors,
            start_new_session=True,
        )
        assert process.stdin is not None
        assert process.stdout is not None

        async def send(message: dict[str, object]) -> None:
            process.stdin.write((json.dumps(message) + "\n").encode())
            await process.stdin.drain()

        try:
            await send(
                {
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "initialize",
                    "params": {
                        "protocolVersion": "2025-11-25",
                        "capabilities": {},
                        "clientInfo": {"name": "cold-start-check", "version": "1"},
                    },
                }
            )
            initialized = await response(process.stdout, 1)
            assert initialized["protocolVersion"] == "2025-11-25"
            assert initialized["serverInfo"]["name"] == "cade-docs"
            await send({"jsonrpc": "2.0", "method": "notifications/initialized"})
            await send({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
            catalog = await response(process.stdout, 2)
            assert "search_docs" in {tool["name"] for tool in catalog["tools"]}
            await send(
                {
                    "jsonrpc": "2.0",
                    "id": 3,
                    "method": "tools/call",
                    "params": {
                        "name": "search_docs",
                        "arguments": {"query": "System Context"},
                    },
                }
            )
            result = await response(process.stdout, 3)
            assert not result.get("isError", False)
            text = "\n".join(item.get("text", "") for item in result["content"])
            assert "docs/ARCHITECTURE.md" in text
            assert "System Context" in text
            await send(
                {
                    "jsonrpc": "2.0",
                    "id": 4,
                    "method": "tools/call",
                    "params": {"name": "search_docs", "arguments": {"query": "   "}},
                }
            )
            empty = await response(process.stdout, 4)
            assert not empty.get("isError", False)
            assert empty["content"] == []
        finally:
            if process.returncode is None:
                os.killpg(process.pid, signal.SIGTERM)
            try:
                await asyncio.wait_for(process.wait(), timeout=5)
            except TimeoutError:
                os.killpg(process.pid, signal.SIGKILL)
                await asyncio.wait_for(process.wait(), timeout=5)


def main() -> None:
    repo = Path(__file__).resolve().parents[1]
    config = json.loads((repo / "opencode.jsonc").read_text())["mcp"]["devenv-docs"]
    uv = shutil.which("uv")
    assert uv, "uv must be installed"
    with tempfile.TemporaryDirectory(
        prefix="docs-mcp-cold-",
        dir="/tmp/opencode" if Path("/tmp/opencode").is_dir() else None,
    ) as temporary:
        root = Path(temporary)
        directory = root / config["cwd"]
        directory.mkdir(parents=True)
        source = repo / config["cwd"]
        for filename in ("pyproject.toml", "uv.lock"):
            shutil.copy2(source / filename, directory / filename)
        shutil.copytree(
            source / "src",
            directory / "src",
            ignore=shutil.ignore_patterns("__pycache__"),
        )
        (root / "docs").mkdir()
        shutil.copy2(repo / "docs/ARCHITECTURE.md", root / "docs/ARCHITECTURE.md")
        lock = (directory / "uv.lock").read_bytes()
        assert not (directory / ".venv").exists()
        environment = {
            "PATH": str(Path(uv).parent) + os.pathsep + os.defpath,
            "HOME": str(root / "home"),
            "XDG_CONFIG_HOME": str(root / "config"),
            "UV_CACHE_DIR": str(Path.home() / ".cache/uv"),
            "UV_PYTHON_DOWNLOADS": "never",
        }
        asyncio.run(
            asyncio.wait_for(exchange(directory, config["command"], environment), 120)
        )
        assert (directory / ".venv/bin/python").exists()
        assert (directory / "uv.lock").read_bytes() == lock, (
            "uv run changed the lockfile"
        )
        asyncio.run(
            asyncio.wait_for(
                exchange(
                    directory, config["command"], {**environment, "UV_OFFLINE": "1"}
                ),
                120,
            )
        )
        assert (directory / "uv.lock").read_bytes() == lock, (
            "warm run changed the lockfile"
        )
        python = directory / ".venv/bin/python"
        inventory = [
            str(python),
            "-c",
            "import importlib.metadata, json; "
            "print(json.dumps(sorted((d.metadata['Name'], d.version) "
            "for d in importlib.metadata.distributions())))",
        ]
        packages = subprocess.check_output(inventory, env=environment, timeout=10)
        metadata = directory / "pyproject.toml"
        metadata.write_text(
            metadata.read_text().replace(
                "dependencies = [",
                'dependencies = ["cade-docs-cold-start-nonexistent-dependency==0.0.0", ',
                1,
            )
        )
        assert "cade-docs-cold-start-nonexistent-dependency" in metadata.read_text()
        asyncio.run(
            asyncio.wait_for(
                exchange(
                    directory, config["command"], {**environment, "UV_OFFLINE": "1"}
                ),
                120,
            )
        )
        assert (directory / "uv.lock").read_bytes() == lock, (
            "drift changed the lockfile"
        )
        assert (
            subprocess.check_output(inventory, env=environment, timeout=10) == packages
        )
    print(
        "PASS: cold config command provisioned .venv; initialize, tools/list, search, empty query; lock unchanged"
    )
    print("PASS: warm config command works offline with the provisioned environment")
    print(
        "PASS: offline pyproject drift uses locked environment; lock and package inventory unchanged"
    )


if __name__ == "__main__":
    main()
