"""Read-only BackendConnection validation. No subprocess, network or cloud calls."""

import json
import os
from pathlib import Path
from typing import TypedDict, cast

from jsonschema import Draft202012Validator

import backend_catalog
from backend_config_yaml import ConfigError, read_yaml

ROOT = Path(__file__).resolve().parents[1]
PROVIDERS = backend_catalog.PROVIDERS
Implementation = backend_catalog.Implementation


class Identity(TypedDict, total=False):
    method: str
    clientId: str


class ProviderConfig(TypedDict, total=False):
    endpoint: str
    subscriptionId: str
    region: str
    resourceGroup: str
    subnetId: str
    identity: Identity


class ConnectionSpec(TypedDict):
    provider: str
    enabled: bool
    config: ProviderConfig


class Metadata(TypedDict):
    name: str


class Connection(TypedDict):
    apiVersion: str
    kind: str
    metadata: Metadata
    spec: ConnectionSpec


def _schema() -> dict:
    try:
        return json.loads(
            (ROOT / "workspace/backend-connection.schema.json").read_text()
        )
    except (OSError, ValueError) as error:
        raise ConfigError("cannot read the CADE BackendConnection schema") from error


def _validate(document: object, schema: dict) -> None:
    error = next(Draft202012Validator(schema).iter_errors(document), None)
    if error is None:
        return
    # Library error messages include input values; only emit schema-controlled details.
    location = ".".join(str(part) for part in error.absolute_path) or "document"
    detail = f"violates {error.validator}"
    if error.validator == "additionalProperties":
        detail = "unknown fields; credentials and template paths are forbidden"
    if error.validator == "required":
        detail = "required fields: " + ", ".join(error.validator_value)
    raise ConfigError(f"{location}: {detail}; check BackendConnection schema")


def validate_azure_config(config: ProviderConfig) -> None:
    """Validate enabled Azure IDs and same-subscription/resource-group subnet ownership.

    Reusable by doctor/preflight. This checks syntax/correspondence, not Azure access.
    """
    schema = _schema()
    _validate(config, {"$ref": "#/$defs/azureEnabled", "$defs": schema["$defs"]})
    segments = config["subnetId"].split("/")
    if segments[2].lower() != config["subscriptionId"].lower():
        raise ConfigError("subnetId must match subscriptionId")
    if segments[4].lower() != config["resourceGroup"].lower():
        raise ConfigError("subnetId must match resourceGroup")


def validate_connection(document: object) -> Connection:
    """Return the original declaration after strict schema and semantic validation."""
    _validate(document, _schema())
    connection = cast(Connection, document)
    spec = connection["spec"]
    if spec["provider"] == "azure" and spec["enabled"]:
        validate_azure_config(spec["config"])
    return connection


def connection_directory(directory: Path | None = None) -> Path | None:
    """Explicit directory overrides CADE_BACKENDS_DIR; unset/empty means legacy."""
    if directory is not None:
        return directory
    value = os.environ.get("CADE_BACKENDS_DIR")
    return Path(value) if value else None


def load_connections(directory: Path | None = None) -> dict[str, Connection]:
    """Load sorted *.yaml/*.yml; missing directory synthesizes legacy docker-local.

    An existing empty directory intentionally returns {}. Invalid/unreadable inputs
    raise ConfigError, never silently re-enable Docker.
    """
    selected = connection_directory(directory)
    try:
        if selected is None:
            return _legacy()
        selected.lstat()
    except FileNotFoundError:
        return _legacy()
    except OSError as error:
        raise ConfigError("cannot inspect backend directory") from error
    try:
        mode = selected.stat().st_mode
        if (
            not selected.is_dir()
            or not mode & 0o444
            or not mode & 0o111
            or not os.access(selected, os.R_OK | os.X_OK)
        ):
            raise ConfigError("backend directory must be readable and searchable")
        paths = sorted(p for p in selected.iterdir() if p.suffix in {".yaml", ".yml"})
        connections: dict[str, Connection] = {}
        for path in paths:
            connection = validate_connection(read_yaml(path))
            name = connection["metadata"]["name"]
            if name in connections:
                raise ConfigError("duplicate BackendConnection name")
            connections[name] = connection
        return connections
    except OSError as error:
        raise ConfigError("cannot read backend directory") from error


def _legacy() -> dict[str, Connection]:
    connection = validate_connection(
        read_yaml(ROOT / "workspace/examples/docker-local.yaml")
    )
    return {"docker-local": connection}


def load_catalog(root: Path = ROOT) -> list[Implementation]:
    """Return validated original catalog entries in source order."""
    return backend_catalog.load_catalog(root)


def resolve(directory: Path | None = None, root: Path = ROOT) -> list[Implementation]:
    """Select catalog entries for enabled declared connections; never execute them."""
    connections = load_connections(directory)
    catalog = load_catalog(root)
    return [
        entry
        for entry in catalog
        if entry["backend"] in connections
        and connections[entry["backend"]]["spec"]["enabled"]
    ]
