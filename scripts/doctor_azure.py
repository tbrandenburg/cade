"""Offline Azure onboarding checks using the shared BackendConnection contract."""

import argparse
from pathlib import Path
import sys

try:
    from backend_config import validate_connection
    from backend_config_yaml import ConfigError, read_yaml
except ModuleNotFoundError:
    sys.exit(
        "ERROR: install scripts/requirements-backends.txt in an isolated venv "
        "and activate it before running the doctor"
    )


class Parser(argparse.ArgumentParser):
    """Keep unexpected CLI values, including accidental secrets, out of diagnostics."""

    def error(self, message: str) -> None:
        self.print_usage(sys.stderr)
        self.exit(2, "ERROR: use --offline --config FILE [--profile Small]\n")


def main() -> int:
    parser = Parser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--offline", action="store_true", required=True)
    parser.add_argument("--config", type=Path, required=True, metavar="FILE")
    parser.add_argument("--profile", default="Small", metavar="Small")
    arguments = parser.parse_args()
    try:
        if arguments.profile != "Small":
            raise ConfigError("only --profile Small is approved; Medium/Large need B3")
        connection = validate_connection(read_yaml(arguments.config))
        if connection["spec"]["provider"] != "azure":
            raise ConfigError("select an azure-remote-dev-env Azure declaration")
    except ConfigError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    state = (
        "enabled: syntax/reference checks passed"
        if connection["spec"]["enabled"]
        else "disabled: placeholders permitted; not selected for publishing"
    )
    print(f"Offline Azure declaration valid ({state}); profile Small")
    print("Live Azure checks NOT TESTED; no cloud access or resource changes performed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
