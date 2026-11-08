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
    return json.loads(result.stdout)["services"]["coder"]


def main():
    source = VERSION.read_text(encoding="utf-8")
    match = re.fullmatch(r"CADE_CODER_SUPPORTED_VERSION=(v\d+\.\d+\.\d+)\n?", source)
    if not match:
        raise ValueError("invalid coder/supported-version.env")
    version = match.group(1)
    coder = config([])
    baseline = config(["-f", str(ROOT / "compose.yaml")])
    raw = config([], raw=True)
    baseline_raw = config(["-f", str(ROOT / "compose.yaml")], raw=True)
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
