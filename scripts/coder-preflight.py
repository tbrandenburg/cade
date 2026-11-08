#!/usr/bin/env python3
"""Reject unsafe Coder configuration before Compose recreates any service."""

import json
import posixpath
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSION = ROOT / "coder/supported-version"


def run(args, timeout=30):
    return subprocess.run(
        args, cwd=ROOT, capture_output=True, text=True, timeout=timeout
    )


def config(args):
    result = run(["docker", "compose", *args, "config", "--format", "json"])
    if result.returncode:
        raise ValueError("could not resolve Compose configuration")
    return json.loads(result.stdout)["services"]["coder"]


def main():
    version = VERSION.read_text(encoding="utf-8").strip()
    if not re.fullmatch(r"v\d+\.\d+\.\d+", version):
        raise ValueError("invalid coder/supported-version")
    coder = config([])
    baseline = config(["-f", str(ROOT / "compose.yaml")])
    image = f"ghcr.io/coder/coder:{version}"
    if coder.get("image") != image:
        raise ValueError(f"effective Coder image must be {image}")
    for service in (baseline, coder):
        settings = service.get("environment", {})
        if settings.get("CADE_CODER_VERSION") not in (None, "", version):
            raise ValueError("unsupported CODER_VERSION; see README upgrading Coder")
        experiments = re.sub(r"\s", "", settings.get("CODER_EXPERIMENTS") or "")
        if "oauth2" in experiments.split(","):
            raise ValueError(
                "remove the retired oauth2 experiment from CODER_EXPERIMENTS"
            )
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
    mounts = [
        v
        for v in coder.get("volumes", [])
        if v.get("target") == "/etc/cade/coder-version"
    ]
    if (
        len(mounts) != 1
        or mounts[0].get("source") != str(VERSION)
        or not mounts[0].get("read_only")
    ):
        raise ValueError(
            "Coder supported-version mount must be read-only and unmodified"
        )
    for mount in coder.get("volumes", []):
        target = posixpath.normpath(mount.get("target", ""))
        if target in ("/", "/opt", "/opt/coder", "/etc", "/etc/cade"):
            raise ValueError(
                "Coder binary and version file cannot be shadowed by a mount"
            )

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
