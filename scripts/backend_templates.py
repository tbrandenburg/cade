"""Shared catalog selection, publish variables and read-only Coder inspection."""

import json
import os
from email.message import Message
from pathlib import Path
from typing import BinaryIO
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, Request, build_opener

from backend_config import ConfigError, Connection, Implementation
from backend_config import load_catalog, load_connections

ROOT = Path(__file__).resolve().parents[1]
BUILDS = {
    "docker-workspace": "coder-workspace-build",
    "embedded-linux": "embedded-workspace-build",
    "devcontainer": "devcontainer-workspace-build",
    "agent-workspace": "agent-workspace-build",
}
AZURE_VARIABLES = {
    "subscriptionId": "subscription_id",
    "region": "location",
    "resourceGroup": "resource_group_name",
    "subnetId": "subnet_id",
}


def load_environment() -> None:
    path = ROOT / ".env"
    if not path.is_file():
        return
    for line in path.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if not os.environ.get(key):
            os.environ[key] = value


def selection(
    backend: str | None = None,
) -> tuple[list[Implementation], list[Implementation], dict[str, Connection]]:
    connections = load_connections()
    catalog = load_catalog(ROOT)
    selected = [
        entry
        for entry in catalog
        if entry["backend"] in connections
        and connections[entry["backend"]]["spec"]["enabled"]
    ]
    for name, connection in connections.items():
        if connection["spec"]["enabled"] and not any(
            entry["backend"] == name for entry in catalog
        ):
            raise ConfigError("enabled backend has no supported catalog implementation")
    if backend is not None:
        if backend not in connections:
            raise ConfigError("requested backend has no connection")
        if not connections[backend]["spec"]["enabled"]:
            raise ConfigError("requested backend is disabled")
        selected = [entry for entry in selected if entry["backend"] == backend]
        if not selected:
            raise ConfigError(
                "requested backend has no supported catalog implementation"
            )
    for entry in selected:
        if entry["backend"] == "docker-local" and entry["template"] not in BUILDS:
            raise ConfigError("unknown Docker implementation: no image build mapping")
        if (
            entry["backend"] == "azure-remote-dev-env"
            and entry["template"] != "generic-linux-azure"
        ):
            raise ConfigError(
                "unknown Azure implementation: no publish variable mapping"
            )
    return selected, catalog, connections


def publish_variables(
    entry: Implementation, connections: dict[str, Connection], repo_url: str | None
) -> dict[str, str]:
    if entry["backend"] == "docker-local":
        return {"repo_url": repo_url} if repo_url is not None else {}
    config = connections[entry["backend"]]["spec"]["config"]
    values = {target: config[source] for source, target in AZURE_VARIABLES.items()}
    values["managed_identity_client_id"] = config.get("identity", {}).get(
        "clientId", ""
    )
    return values


class RejectRedirects(HTTPRedirectHandler):
    def redirect_request(
        self,
        req: Request,
        fp: BinaryIO,
        code: int,
        msg: str,
        headers: Message,
        newurl: str,
    ) -> None:
        # Reject before urllib can copy authentication headers to another request.
        raise HTTPError(req.full_url, code, "redirects disabled", headers, fp)


class CoderAPI:
    def __init__(self) -> None:
        self.url = os.environ.get("CODER_URL") or "http://localhost:7080"
        self.token = os.environ.get("CODER_SESSION_TOKEN", "")
        session = Path.home() / ".config/coderv2/session"
        if not self.token and session.is_file():
            self.token = session.read_text().strip()
        if not self.token:
            raise ConfigError(
                "no Coder session token; set CODER_SESSION_TOKEN or run 'coder login'"
            )

    def get(self, path: str) -> list[dict]:
        request = Request(
            self.url.rstrip("/") + "/api/v2/" + path,
            headers={"Coder-Session-Token": self.token},
        )
        try:
            with build_opener(RejectRedirects()).open(request, timeout=15) as response:
                data = json.load(response)
        except (URLError, ValueError, TimeoutError, OSError) as error:
            raise ConfigError(
                "Coder API request failed; check authentication, access and server health"
            ) from error
        if not isinstance(data, list) or not all(
            isinstance(item, dict) for item in data
        ):
            raise ConfigError("Coder API returned an invalid list")
        return data


def check_retirement(
    catalog: list[Implementation],
    connections: dict[str, Connection],
    published: list[dict],
) -> None:
    enabled = {
        name
        for name, connection in connections.items()
        if connection["spec"]["enabled"]
    }
    names = {template.get("name") for template in published}
    unsafe = [
        entry["template"]
        for entry in catalog
        if entry["backend"] not in enabled and entry["template"] in names
    ]
    if unsafe:
        raise ConfigError(
            "RETIREMENT BLOCK: unselected templates remain published: "
            + ", ".join(unsafe)
            + ". Backend disable does not revoke creation access. Manual action: restrict access "
            "using an entitled Coder deployment and verify member creation is denied, or plan "
            "operator-led retirement preserving existing workspaces/data. OSS deprecation/private "
            "CLI success is not proof of enforcement. No server changes were made."
        )
