"""Seed fresh homes or upgrade only CADE's unchanged model-only seed."""

import json
import sys
from pathlib import Path


def seed(docs: dict[str, object]) -> None:
    directory = Path.home() / ".config/opencode"
    path = directory / "opencode.jsonc"
    stock = {
        "$schema": "https://opencode.ai/config.json",
        "model": "opencode/big-pickle",
    }
    if path.exists():
        try:
            current = json.loads(path.read_text())
        except ValueError:
            return  # Customized JSONC is intentionally operator-managed.
        if current != stock or not docs:
            return
    elif (directory / "opencode.json").exists():
        return
    directory.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({**stock, "mcp": {"servers": docs}}, indent=2) + "\n")


if __name__ == "__main__":
    seed(json.loads(sys.argv[1]))
