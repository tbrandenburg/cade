#!/usr/bin/env python3
"""Reject unsafe Coder configuration before Compose recreates any service."""

import json
import posixpath
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IMAGE_KEY = "CADE_CODER_IMAGE"
DB_PATH = "/var/lib/postgresql/data"


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
    service = compose["services"]["coder-db"]
    if any(service.get(key) for key in ("tmpfs", "secrets", "configs", "volumes_from")):
        raise ValueError("Coder database cannot have additional mounts")
    mounts = service.get("volumes", []) or []
    if (
        len(mounts) != 1
        or mounts[0].get("type") != "volume"
        or posixpath.normpath(mounts[0].get("target", "")) != DB_PATH
    ):
        raise ValueError("Coder database must have exactly one named data volume")
    options = mounts[0].get("volume")
    if options is None:
        options = {}
    if not isinstance(options, dict) or options.get("subpath") not in (None, ""):
        raise ValueError("Coder database volume subpath is not supported")
    volume = compose.get("volumes", {}).get(mounts[0].get("source"), {})
    name = volume.get("name")
    if not isinstance(name, str) or not name:
        raise ValueError("could not resolve the Coder database volume name")
    return name


def check_database_volume(compose, baseline, db_id):
    name = database_volume(compose)
    baseline_name = database_volume(baseline)
    mount = compose["services"]["coder-db"]["volumes"][0]
    original = baseline["services"]["coder-db"]["volumes"][0]
    if {key: value for key, value in mount.items() if key != "source"} != {
        key: value for key, value in original.items() if key != "source"
    }:
        raise ValueError("Coder database mount options must match the baseline")
    if db_id is None:
        if name != baseline_name:
            raise ValueError(
                "Coder database volume differs from baseline while coder-db is absent"
            )
        return
    result = run(
        [
            "docker",
            "inspect",
            "--format",
            "{{range .Mounts}}{{.Destination}} {{.Type}}:{{.Name}}{{println}}{{end}}",
            db_id,
        ]
    )
    if result.returncode or result.stdout.strip().splitlines() != [
        f"{DB_PATH} volume:{name}"
    ]:
        raise ValueError(
            "existing coder-db data mount does not match the effective named volume"
        )
    result = run(
        [
            "docker",
            "inspect",
            "--format",
            "{{json .HostConfig.Mounts}}\n{{json .HostConfig.Binds}}\n{{json .HostConfig.Tmpfs}}",
            db_id,
        ]
    )
    lines = result.stdout.strip().splitlines()
    if result.returncode or len(lines) != 3:
        raise ValueError("could not verify existing coder-db mount configuration")
    mounts = json.loads(lines[0])
    binds = json.loads(lines[1])
    tmpfs = json.loads(lines[2])
    mounts = [] if mounts is None else mounts
    binds = [] if binds is None else binds
    tmpfs = {} if tmpfs is None else tmpfs
    if (
        not isinstance(mounts, list)
        or not isinstance(binds, list)
        or any(not isinstance(mount, dict) for mount in mounts)
        or any(not isinstance(bind, str) for bind in binds)
        or not isinstance(tmpfs, dict)
        or tmpfs
        or len(mounts) + len(binds) != 1
    ):
        raise ValueError("could not verify existing coder-db mount configuration")
    declarations = [
        m for m in mounts if posixpath.normpath(m.get("Target", "")) == DB_PATH
    ]
    for bind in binds:
        parts = bind.split(":")
        if len(parts) >= 2 and posixpath.normpath(parts[1]) == DB_PATH:
            declarations.append({"Type": "volume", "Source": parts[0]})
    if len(declarations) != 1:
        raise ValueError("cannot uniquely verify existing coder-db data mount")
    mount = declarations[0]
    options = mount.get("VolumeOptions")
    if options is None:
        options = {}
    if (
        mount.get("Type") != "volume"
        or mount.get("Source") != name
        or not isinstance(options, dict)
        or options.get("Subpath") not in (None, "")
    ):
        raise ValueError("existing coder-db data mount is not the volume root")


def check_database_pgdata(compose, baseline, db_id):
    current = compose["services"]["coder-db"]
    original = baseline["services"]["coder-db"]
    for key in ("image", "entrypoint", "command", "build", "platform", "pull_policy"):
        if current.get(key) != original.get(key):
            raise ValueError(f"Coder database {key} must match the baseline")
    expected = original.get("environment", {}).get("PGDATA", DB_PATH)
    effective = current.get("environment", {}).get("PGDATA", DB_PATH)
    if not isinstance(expected, str) or not expected or effective != expected:
        raise ValueError("Coder database PGDATA must match the baseline")
    if db_id is None:
        return
    result = run(
        [
            "docker",
            "inspect",
            "--format",
            '{{range .Config.Env}}{{if eq (index (split . "=") 0) "PGDATA"}}{{println .}}{{end}}{{end}}',
            db_id,
        ]
    )
    if result.returncode or result.stdout.strip().splitlines() != [
        f"PGDATA={expected}"
    ]:
        raise ValueError("existing coder-db PGDATA is missing, ambiguous or mismatched")


def main():
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
    check_database_pgdata(effective, baseline_config, db_id)
    coder = effective["services"]["coder"]
    baseline = baseline_config["services"]["coder"]
    raw = config([], raw=True)["services"]["coder"]
    baseline_raw = config(["-p", project, "-f", str(ROOT / "compose.yaml")], raw=True)[
        "services"
    ]["coder"]
    image = baseline.get("image")
    match = re.fullmatch(r"ghcr\.io/coder/coder:(v\d+\.\d+\.\d+)", image or "")
    if not match:
        raise ValueError("invalid baseline Coder image")
    version = match.group(1)
    if raw.get("environment", {}).get(IMAGE_KEY) != baseline_raw.get(
        "environment", {}
    ).get(IMAGE_KEY) or raw.get("env_file") != baseline_raw.get("env_file"):
        raise ValueError("Coder supported image environment must not be overridden")
    if coder.get("image") != image:
        raise ValueError(f"effective Coder image must be {image}")
    for service in (baseline, coder):
        settings = service.get("environment", {})
        if settings.get(IMAGE_KEY) != image:
            raise ValueError("effective Coder guard does not match the baseline image")
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
