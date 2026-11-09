#!/usr/bin/env python3
"""Offline CLI for external deployment BackendConnection declarations."""

import argparse
import json
from pathlib import Path
import sys

from backend_config import ConfigError, PROVIDERS, load_connections, resolve


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    validate = commands.add_parser(
        "validate", help="validate without contacting services"
    )
    validate.add_argument("--dir", type=Path, help="override CADE_BACKENDS_DIR")
    selected = commands.add_parser(
        "resolve", help="list selected catalog implementations"
    )
    selected.add_argument("--dir", type=Path, help="override CADE_BACKENDS_DIR")
    selected.add_argument("--format", choices=("json", "text"), default="text")
    selected.add_argument("--backend", help="filter by a known connection name")
    args = parser.parse_args()
    try:
        if args.command == "validate":
            connections = load_connections(args.dir)
            print(f"Valid BackendConnections: {len(connections)}")
            return 0
        if args.backend is not None and args.backend not in PROVIDERS:
            raise ConfigError(
                "unknown backend filter; use docker-local or azure-remote-dev-env"
            )
        entries = resolve(args.dir)
        if args.backend is not None:
            entries = [entry for entry in entries if entry["backend"] == args.backend]
        if args.format == "json":
            print(json.dumps(entries, indent=2))
            return 0
        for entry in entries:
            print(
                "\t".join(
                    entry[key] for key in ("environment", "backend", "template", "path")
                )
            )
        return 0
    except ConfigError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
