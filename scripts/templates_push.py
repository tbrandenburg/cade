"""Publish selected implementations through existing Make builds and Coder CLI."""

import argparse
import os
import shlex
import subprocess
import sys

from backend_templates import BUILDS, ROOT, CoderAPI, ConfigError
from backend_templates import (
    check_retirement,
    load_environment,
    publish_variables,
    selection,
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend")
    parser.add_argument("--repo-url", required=True)
    args = parser.parse_args()
    try:
        load_environment()
        selected, catalog, connections = selection(args.backend)
        api = CoderAPI()
        check_retirement(catalog, connections, api.get("templates"))
        builds = list(
            dict.fromkeys(
                BUILDS[entry["template"]]
                for entry in selected
                if entry["backend"] == "docker-local"
            )
        )
        if builds:
            subprocess.run(
                [*shlex.split(os.environ.get("MAKE", "make")), *builds],
                cwd=ROOT,
                check=True,
                timeout=1800,
            )
        for entry in selected:
            command = [
                "coder",
                "templates",
                "push",
                entry["template"],
                "-d",
                entry["path"],
            ]
            for name, value in publish_variables(
                entry, connections, args.repo_url
            ).items():
                command.extend(["--variable", f"{name}={value}"])
            command.append("--yes")
            # Do not echo provider output: it may contain sensitive Terraform values.
            result = subprocess.run(command, cwd=ROOT, capture_output=True, timeout=600)
            if result.returncode:
                raise ConfigError(
                    f"template push failed: {entry['template']}; inspect Coder job logs securely"
                )
            print(f"PUSHED {entry['template']}")
        print(f"Published {len(selected)} selected template(s).")
        return 0
    except (ConfigError, OSError, subprocess.SubprocessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
