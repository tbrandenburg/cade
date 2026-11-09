"""Validate the product-owned supported-combination catalog, without execution."""

from pathlib import Path
import re
from typing import TypedDict, cast

from backend_config_yaml import ConfigError, read_yaml

PROVIDERS = {"docker-local": "docker", "azure-remote-dev-env": "azure"}


class Implementation(TypedDict):
    environment: str
    backend: str
    template: str
    path: str


def load_catalog(root: Path) -> list[Implementation]:
    """Preserve catalog order; reject ambiguous, unknown or escaping entries."""
    catalog = read_yaml(root / "workspace/catalog.yaml")
    if not isinstance(catalog, dict) or set(catalog) != {"version", "implementations"}:
        raise ConfigError("catalog requires only version and implementations")
    if type(catalog["version"]) is not int or catalog["version"] != 1:
        raise ConfigError("catalog version must be integer 1")
    entries = catalog["implementations"]
    if not isinstance(entries, list):
        raise ConfigError("catalog implementations must be a list")
    pairs: set[tuple[str, str]] = set()
    names: set[str] = set()
    for entry in entries:
        _validate_entry(entry)
        pair = (entry["environment"], entry["backend"])
        if pair in pairs:
            raise ConfigError("duplicate catalog environment/backend pair")
        if entry["template"] in names:
            raise ConfigError("duplicate catalog template name")
        _validate_path(root, entry["path"])
        pairs.add(pair)
        names.add(entry["template"])
    return cast(list[Implementation], entries)


def _validate_entry(entry: object) -> None:
    if not isinstance(entry, dict) or set(entry) != {
        "environment",
        "backend",
        "template",
        "path",
    }:
        raise ConfigError(
            "catalog entry requires environment, backend, template, path only"
        )
    if not all(isinstance(value, str) for value in entry.values()):
        raise ConfigError("catalog entry fields must be strings")
    for field in ("environment", "backend", "template"):
        if len(entry[field]) > 63 or not re.fullmatch(
            r"[a-z][a-z0-9]*(?:-[a-z0-9]+)*", entry[field]
        ):
            raise ConfigError(
                "catalog names must be lowercase hyphenated identifiers (1-63 characters)"
            )
    if entry["backend"] not in PROVIDERS:
        raise ConfigError("catalog references an unknown backend connection")


def _validate_path(root: Path, value: str) -> None:
    path = Path(value)
    if path.is_absolute() or ".." in path.parts:
        raise ConfigError("catalog path must be relative and contained in CADE source")
    try:
        resolved = (root / path).resolve(strict=True)
        main = (resolved / "main.tf").resolve(strict=True)
        if (
            not resolved.is_relative_to(root.resolve())
            or not main.is_relative_to(root.resolve())
            or not resolved.is_dir()
            or not main.is_file()
        ):
            raise ConfigError(
                "catalog path must be an existing contained Coder template directory"
            )
    except (OSError, RuntimeError, ValueError) as error:
        raise ConfigError(
            "catalog path must be an existing contained Coder template directory"
        ) from error
