#!/usr/bin/env python3
"""Reject unsafe Coder configuration before Compose recreates any service."""

import json
import posixpath
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSION = ROOT / "coder/supported-version.env"
VERSION_KEY = "CADE_CODER_SUPPORTED_VERSION"


def run(args, timeout=30):
    return subprocess.run(
        args, cwd=ROOT, capture_output=True, text=True, timeout=timeout
    )


def config(args, raw=False):
    options = ["--no-env-resolution"] if raw else []
    result = run(["docker", "compose", *args, "config", "--format", "json", *options])
    if result.returncode:
        raise ValueError("could not resolve Compose configuration")
    return json.loads(result.stdout)


def check_existing(project):
    db_id = None
    for name in ("coder", "coder-db"):
        result = run(
            [
                "docker",
                "container",
                "ls",
                "--all",
                "--filter",
                f"name=^/{name}$",
                "--format",
                "{{.ID}}",
            ]
        )
        if result.returncode:
            raise ValueError("could not inspect existing Coder containers")
        ids = result.stdout.splitlines()
        if not ids:
            continue
        if len(ids) != 1:
            raise ValueError(f"cannot uniquely identify existing {name} container")
        labels = run(
            [
                "docker",
                "inspect",
                "--format",
                '{{index .Config.Labels "com.docker.compose.project"}}:{{index .Config.Labels "com.docker.compose.service"}}',
                ids[0],
            ]
        )
        if labels.returncode or labels.stdout.strip() != f"{project}:{name}":
            raise ValueError(
                f"existing {name} container does not belong to Compose project {project}; "
                "select the correct COMPOSE_PROJECT_NAME before proceeding"
            )
        if name == "coder-db":
            db_id = ids[0]
    return db_id


def database_volume(compose):
    mounts = [
        mount
        for mount in compose["services"]["coder-db"].get("volumes", [])
        if posixpath.normpath(mount.get("target", "")) == "/var/lib/postgresql/data"
    ]
    if len(mounts) != 1 or mounts[0].get("type") != "volume":
        raise ValueError("Coder database must have exactly one named data volume")
    volume = compose.get("volumes", {}).get(mounts[0].get("source"), {})
    name = volume.get("name")
    if not isinstance(name, str) or not name:
        raise ValueError("could not resolve the Coder database volume name")
    return name


def check_database_volume(compose, baseline, db_id):
    name = database_volume(compose)
    if db_id is None:
        if name != database_volume(baseline):
            raise ValueError(
                "Coder database volume differs from baseline while coder-db is absent"
            )
        return
    result = run(
        [
            "docker",
            "inspect",
            "--format",
            '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Type}}:{{.Name}}{{println}}{{end}}{{end}}',
            db_id,
        ]
    )
    if result.returncode or result.stdout.strip().splitlines() != [f"volume:{name}"]:
        raise ValueError(
            "existing coder-db data mount does not match the effective named volume"
        )


def main():
    source = VERSION.read_text(encoding="utf-8")
    match = re.fullmatch(r"CADE_CODER_SUPPORTED_VERSION=(v\d+\.\d+\.\d+)\n?", source)
    if not match:
        raise ValueError("invalid coder/supported-version.env")
    version = match.group(1)
    effective = config([])
    project = effective["name"]
    if not isinstance(project, str) or not project:
        raise ValueError("effective Compose project name is missing")
    for name in ("coder", "coder-db"):
        if effective["services"][name].get("container_name") != name:
            raise ValueError(f"effective {name} container name must remain fixed")
    db_id = check_existing(project)
    baseline_config = config(["-p", project, "-f", str(ROOT / "compose.yaml")])
    check_database_volume(effective, baseline_config, db_id)
    coder = effective["services"]["coder"]
    baseline = baseline_config["services"]["coder"]
    raw = config([], raw=True)["services"]["coder"]
    baseline_raw = config(["-p", project, "-f", str(ROOT / "compose.yaml")], raw=True)[
        "services"
    ]["coder"]
    if VERSION_KEY in raw.get("environment", {}) or raw.get(
        "env_file"
    ) != baseline_raw.get("env_file"):
        raise ValueError("Coder supported version environment must not be overridden")
    image = f"ghcr.io/coder/coder:{version}"
    if coder.get("image") != image:
        raise ValueError(f"effective Coder image must be {image}")
    for service in (baseline, coder):
        settings = service.get("environment", {})
        if settings.get(VERSION_KEY) != version:
            raise ValueError(
                "effective Coder supported version differs from the version source"
            )
        if settings.get("CADE_CODER_VERSION") not in (None, "", version):
            raise ValueError("unsupported CODER_VERSION; see README upgrading Coder")
        if settings.get("CODER_OAUTH2_PROVIDER_ENABLE") != "true":
            raise ValueError("Coder OAuth2 provider must be enabled")
        experiments = re.sub(r"\s", "", settings.get("CODER_EXPERIMENTS") or "")
        if "oauth2" in experiments.split(","):
            raise ValueError(
                "remove the retired oauth2 experiment from CODER_EXPERIMENTS"
            )
        if not {"mcp-server-http", "*"}.intersection(experiments.split(",")):
            raise ValueError("CODER_EXPERIMENTS must enable mcp-server-http")
    for key in (
        "entrypoint",
        "command",
        "healthcheck",
        "platform",
        "pull_policy",
        "build",
    ):
        if coder.get(key) != baseline.get(key):
            raise ValueError(f"Coder {key} override would bypass startup checks")
    for mount in coder.get("volumes", []):
        target = posixpath.normpath(mount.get("target", ""))
        if target in ("/", "/opt", "/opt/coder"):
            raise ValueError("Coder binary cannot be shadowed by a mount")

    if run(["docker", "image", "inspect", image]).returncode:
        if run(["docker", "pull", image], timeout=600).returncode:
            raise ValueError("could not obtain the supported Coder image")
    result = run(
        [
            "docker",
            "run",
            "--rm",
            "--network",
            "none",
            "--pull",
            "never",
            "--read-only",
            "--cap-drop",
            "ALL",
            "--security-opt",
            "no-new-privileges",
            "--entrypoint",
            "/opt/coder",
            image,
            "version",
            "--output",
            "json",
        ]
    )
    if result.returncode:
        raise ValueError("could not check Coder image binary version")
    actual = json.loads(result.stdout).get("version", "").split("+", 1)[0]
    if actual != version:
        raise ValueError("Coder image contains an unsupported binary")
    print(f"Coder preflight: {image} and binary verified")


if __name__ == "__main__":
    try:
        main()
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        subprocess.TimeoutExpired,
    ) as error:
        print(f"ERROR: Coder preflight failed: {error}", file=sys.stderr)
        sys.exit(1)
