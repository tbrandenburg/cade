"""Verify selected templates against HCL defaults and explicit publish overrides."""

import argparse
import json
from pathlib import Path
import sys

import hcl2

from backend_templates import ROOT, CoderAPI, ConfigError, check_retirement
from backend_templates import load_environment, publish_variables, selection
from backend_config import Connection, Implementation


def variables(path: Path) -> dict[str, dict[str, object]]:
    if not path.is_file():
        raise ConfigError(
            "variables.tf not found; use an explicit empty file for a template without variables"
        )
    try:
        with path.open() as stream:
            document = hcl2.load(stream)
        return {
            name: body
            for block in document.get("variable", [])
            for name, body in block.items()
        }
    except Exception as error:
        raise ConfigError("cannot parse variables.tf as HCL") from error


def equal(actual: object, expected: object) -> bool:
    if isinstance(expected, str):
        return actual == expected
    try:
        return json.dumps(
            json.loads(actual) if isinstance(actual, str) else actual, sort_keys=True
        ) == json.dumps(expected, sort_keys=True)
    except ValueError:
        return False


def verify(
    entry: Implementation,
    connections: dict[str, Connection],
    api: CoderAPI,
    published: list[dict],
    repo_url: str | None,
) -> bool:
    name = entry["template"]
    declarations = variables(ROOT / entry["path"] / "variables.tf")
    matches = [item for item in published if item.get("name") == name]
    if len(matches) != 1 or not matches[0].get("active_version_id"):
        raise ConfigError(
            f"could not resolve active_version_id for template '{name}' (is it pushed and unique?)"
        )
    live = api.get(f"templateversions/{matches[0]['active_version_id']}/variables")
    values = {item["name"]: item for item in live if isinstance(item.get("name"), str)}
    if len(values) != len(live) or any("value" not in item for item in live):
        raise ConfigError(
            "Coder variables response contains missing values or missing/duplicate names"
        )
    overrides = publish_variables(entry, connections, repo_url)
    # Legacy Docker templates receive repo_url even where it is not declared.
    expected = {
        key: overrides[key] if key in overrides else body.get("default")
        for key, body in declarations.items()
    }
    failed = False
    print(f"=== {name} ===")
    for key, value in expected.items():
        item = values.get(key)
        if item is None:
            print(f"  DRIFT {key}: missing from live variables")
            failed = True
            continue
        if item.get("sensitive") or declarations[key].get("sensitive"):
            raise ConfigError(
                f"cannot verify sensitive variable {key}; manual secure verification required"
            )
        if key not in overrides and "default" not in declarations[key]:
            raise ConfigError(f"required variable {key} has no known expected value")
        if equal(item.get("value"), value):
            print(f"  PASS  {key}")
            continue
        label = "expected publish value" if key in overrides else ".tf default"
        print(f"  DRIFT {key}: {label}={value!r}; live value differs (redacted)")
        failed = True
    return failed


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, usage="%(prog)s [--expected-repo-url URL]"
    )
    parser.add_argument("--expected-repo-url")
    args = parser.parse_args()
    if args.expected_repo_url == "":
        parser.error("Usage: URL must not be empty")
    try:
        load_environment()
        selected, catalog, connections = selection()
        api = CoderAPI()
        published = api.get("templates")
        check_retirement(catalog, connections, published)
        failures = [
            verify(entry, connections, api, published, args.expected_repo_url)
            for entry in selected
        ]
        if any(failures):
            raise ConfigError(
                "template-variable drift; repush with explicit --variable '<name>=<expected-value>'"
            )
        print(f"PASS: {len(selected)} selected template(s) match expected variables.")
        return 0
    except (ConfigError, OSError, KeyError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
