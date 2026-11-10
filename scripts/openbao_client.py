"""Small verified-TLS bao CLI transport. Secrets use docker exec stdin only."""

import json
import os
import re
import stat
import subprocess
from pathlib import Path
from typing import TextIO

ROOT = Path(__file__).resolve().parents[1]
OPERATOR = "cade-operator"
POLICY = "devenv-cloud-rotate"


class BaoError(RuntimeError):
    """Safe diagnostic: never includes subprocess output or request payloads."""

    def __init__(self, message: str, status: int | None = None) -> None:
        super().__init__(message)
        self.status = status


def private_read(path: Path) -> str:
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    with os.fdopen(descriptor) as stream:
        info = os.fstat(stream.fileno())
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_mode & 0o077
            or info.st_uid != os.getuid()
        ):
            raise BaoError(
                "Secret input must be a regular owner-only file (chmod 600)."
            )
        return stream.read().rstrip("\r\n")


def private_parent(path: Path) -> int:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    info = os.fstat(parent)
    if info.st_uid != os.getuid() or info.st_mode & 0o022:
        os.close(parent)
        raise BaoError(
            "Private output parent must be owned and not group/world writable."
        )
    return parent


def private_create(path: Path) -> TextIO:
    """Keep the exclusive descriptor open across irreversible server mutations."""
    parent = private_parent(path)
    try:
        descriptor = os.open(
            path.name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=parent,
        )
        os.fsync(parent)
    finally:
        os.close(parent)
    return os.fdopen(descriptor, "w")


def private_write(path: Path, text: str) -> None:
    with private_create(path) as stream:
        stream.write(text)
        stream.flush()
        os.fsync(stream.fileno())


class Bao:
    def __init__(self, token: str = "") -> None:
        self.token = token

    def cli(self, *args: str, payload: str = "", sealed: bool = False) -> dict:
        address = os.environ.get("BAO_ADDR", "https://127.0.0.1:8200")
        if not address.startswith("https://"):
            raise BaoError("BAO_ADDR must use verified HTTPS.")
        command = [
            "docker",
            "exec",
            "-i",
            os.environ.get("BAO_CONTAINER", "openbao"),
            "env",
            "-i",
            "PATH=/bin:/usr/bin",
            "HOME=/nonexistent-cade-private-home",
            f"BAO_ADDR={address}",
            "BAO_CACERT=" + os.environ.get("BAO_CACERT", "/openbao/certs/openbao.crt"),
            "BAO_CLIENT_TIMEOUT=15s",
            "BAO_DISABLE_REDIRECTS=true",
            "BAO_MAX_RETRIES=0",
            "BAO_TOKEN_PATH=/dev/null",
            "BAO_CONFIG_PATH=/dev/null",
            "sh",
            "-c",
            'IFS= read -r BAO_TOKEN; export BAO_TOKEN; exec bao "$@"',
            "bao-private",
            *args,
        ]
        try:
            result = subprocess.run(
                command,
                input=self.token + "\n" + payload,
                text=True,
                capture_output=True,
                timeout=25,
                check=False,
            )
        except subprocess.TimeoutExpired as error:
            raise BaoError(
                "OpenBao request timed out; inspect state before retrying."
            ) from error
        if result.returncode not in ((0, 2) if sealed else (0,)):
            code = re.search(r"Code:\s+(\d{3})", result.stderr)
            raise BaoError(
                "OpenBao request failed; check TLS, permissions, and credentials.",
                status=int(code.group(1)) if code else None,
            )
        return json.loads(result.stdout) if result.stdout.strip() else {}

    def read(self, path: str) -> dict:
        return self.cli("read", "-format=json", path)

    def write(self, path: str, payload: dict) -> dict:
        return self.cli("write", "-format=json", path, "-", payload=json.dumps(payload))

    def status(self) -> dict:
        return self.cli("status", "-format=json", sealed=True)


def verify_normal_listener() -> None:
    for endpoint, expected in (
        ("sys/generate-root/attempt", 405),
        ("sys/generate-root-token/attempt", 403),
    ):
        try:
            Bao().read(endpoint)
        except BaoError as error:
            if error.status == expected:
                continue
            status = (
                str(error.status)
                if error.status is not None
                else "transport/TLS failure"
            )
            raise BaoError(
                f"Normal listener {endpoint}: expected HTTP {expected}, got {status}."
            ) from error
        raise BaoError(f"Normal listener {endpoint}: unexpectedly accepted request.")


def login(password: str) -> Bao:
    auth = Bao().write(f"auth/userpass/login/{OPERATOR}", {"password": password})[
        "auth"
    ]
    if (
        set(auth["policies"]) != {POLICY}
        # bao write's CLI Auth serialization omits token_type in 2.6.5.
        or not auth["client_token"].startswith(("hvb.", "b."))
        or auth["renewable"]
        or not 0 < auth["lease_duration"] <= 300
    ):
        raise BaoError(
            "Operator login has unexpected policy or session lifetime; root retained."
        )
    return Bao(auth["client_token"])


def provision(admin: Bao, password: str) -> None:
    mounts = admin.read("sys/mounts")["data"]
    if "secret/" not in mounts:
        admin.write("sys/mounts/secret", {"type": "kv", "options": {"version": "2"}})
    elif (
        mounts["secret/"]["type"] != "kv"
        or mounts["secret/"]["options"].get("version") != "2"
    ):
        raise BaoError("Existing secret/ mount is not KV v2; refusing to replace it.")
    auth = admin.read("sys/auth")["data"]
    for mount in ("userpass", "approle"):
        if f"{mount}/" not in auth:
            admin.write(f"sys/auth/{mount}", {"type": mount})
        elif auth[f"{mount}/"]["type"] != mount:
            raise BaoError("Existing auth mount has unexpected type; root retained.")
    for name, capabilities in (
        ("devenv-cloud-read", '"read"'),
        (POLICY, '"read", "create", "update"'),
    ):
        policy = (
            'path "secret/data/devenv-cloud/*" { capabilities = ['
            + capabilities
            + "] }"
        )
        admin.write(f"sys/policies/acl/{name}", {"policy": policy})
    admin.write(
        f"auth/userpass/users/{OPERATOR}",
        {
            "password": password,
            "token_policies": [POLICY],
            "token_no_default_policy": True,
            "token_type": "batch",
            "token_ttl": "5m",
            "token_max_ttl": "5m",
            "token_explicit_max_ttl": "5m",
        },
    )
    login(password)
