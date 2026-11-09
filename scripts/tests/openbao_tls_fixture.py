"""Owned, portless OpenBao 2.6.5 test containers; never use platform storage."""

import hashlib
import json
import os
import secrets
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from openbao_client import (
    ROOT,
    Bao,
    BaoError,
    login,
    private_read,
    verify_normal_listener,
)

__all__ = [
    "Instance",
    "command",
    "fingerprint",
    "Bao",
    "BaoError",
    "login",
    "private_read",
    "verify_normal_listener",
]


def command(*args: str) -> str:
    result = subprocess.run(
        args, capture_output=True, text=True, timeout=40, check=False
    )
    if result.returncode:
        raise RuntimeError(f"Test setup command failed: {args[0]} (output withheld)")
    return result.stdout


def fingerprint(path: Path) -> str:
    digest = hashlib.sha256()
    for file in sorted(path.rglob("*")):
        if file.is_file():
            digest.update(str(file.relative_to(path)).encode())
            digest.update(file.read_bytes())
    return digest.hexdigest()


class Instance:
    def __init__(self, directory: Path) -> None:
        self.directory = directory
        self.name = "cade-170-" + secrets.token_hex(6)
        self.init = directory / "init.json"
        self.password = directory / "password"
        self.password.write_text(secrets.token_urlsafe(32))
        self.password.chmod(0o600)
        for folder in ("data", "certs"):
            (directory / folder).mkdir()
        (directory / "data/poisoned-config").write_text(
            'token_helper = "/nonexistent-poisoned-helper"\n'
        )
        command(
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-keyout",
            str(directory / "certs/openbao.key"),
            "-out",
            str(directory / "certs/openbao.crt"),
            "-days",
            "1",
            "-subj",
            "/CN=localhost",
            "-addext",
            "subjectAltName=IP:127.0.0.1",
        )
        self.normal = (ROOT / "governance/openbao/config/openbao.hcl").read_text()
        self.configure(False)

    def configure(self, recovery: bool) -> None:
        content = self.normal.replace(
            'address       = "0.0.0.0:8200"', 'address       = "127.0.0.1:8200"'
        )
        if recovery:
            content = content.replace(
                'listener "tcp" {',
                'listener "tcp" {\n  disable_unauthed_generate_root_endpoints = false',
            )
        (self.directory / "openbao.hcl").write_text(content)

    def select(self) -> None:
        os.environ.update(
            {
                "BAO_CONTAINER": self.name,
                "BAO_INIT_FILE": str(self.init),
                "BAO_ADDR": "https://127.0.0.1:8200",
                "BAO_CACERT": "/openbao/certs/openbao.crt",
                "BAO_ENV_FILE": str(self.directory / "no-platform-env"),
            }
        )

    def start(self) -> None:
        command(
            "docker",
            "run",
            "-d",
            "--name",
            self.name,
            "--network",
            "none",
            "--user",
            f"{os.getuid()}:{os.getgid()}",
            "--cap-drop",
            "ALL",
            "--security-opt",
            "no-new-privileges",
            "--entrypoint",
            "bao",
            "-e",
            "BAO_AGENT_ADDR=http://127.0.0.1:1",
            "-e",
            "VAULT_AGENT_ADDR=http://127.0.0.1:2",
            "-e",
            "BAO_SKIP_VERIFY=true",
            "-e",
            "VAULT_SKIP_VERIFY=true",
            "-e",
            "BAO_DISABLE_REDIRECTS=false",
            "-e",
            "VAULT_DISABLE_REDIRECTS=false",
            "-e",
            "BAO_TOKEN_PATH=/openbao/data/poisoned-token-cache",
            "-e",
            "BAO_TLS_SERVER_NAME=wrong.invalid",
            "-e",
            "BAO_CONFIG_PATH=/openbao/data/poisoned-config",
            "-v",
            f"{self.directory / 'data'}:/openbao/data",
            "-v",
            f"{self.directory / 'certs'}:/openbao/certs:ro",
            "-v",
            f"{self.directory / 'openbao.hcl'}:/openbao/config/test.hcl:ro",
            "openbao/openbao:2.6.5",
            "server",
            "-config=/openbao/config/test.hcl",
        )
        self.select()
        for _ in range(40):
            try:
                status = Bao().status()
                if status["version"] != "2.6.5":
                    raise RuntimeError("Wrong server version")
                return
            except BaoError:
                time.sleep(0.25)
        raise RuntimeError("Disposable TLS server did not start")

    def stop(self) -> None:
        command("docker", "stop", "-t", "5", self.name)
        command("docker", "rm", self.name)

    def invoke(
        self,
        *args: str,
        expected: int = 0,
        stdin: str = "",
        recovery: bool = False,
        reunseal: bool = False,
        revoke_failure: bool = False,
    ) -> str:
        command = (
            ["python3", str(ROOT / "scripts/openbao_recover_operator.py")]
            if recovery
            else [
                "bash",
                str(
                    ROOT
                    / "scripts"
                    / ("openbao-reunseal.sh" if reunseal else "openbao-init.sh")
                ),
            ]
        )
        if revoke_failure:
            command = [
                "python3",
                "-c",
                """import sys
sys.path.insert(0, 'scripts')
from openbao_client import Bao
import openbao_recover_operator as recovery
original = Bao.write
def seal_before_revoke(self, path, payload):
    if path == 'auth/token/revoke-self':
        original(self, 'sys/seal', {})
    return original(self, path, payload)
Bao.write = seal_before_revoke
recovery.recover()
""",
            ]
        result = subprocess.run(
            [*command, *args],
            input=stdin,
            text=True,
            capture_output=True,
            timeout=120,
            check=False,
        )
        output = result.stdout + result.stderr
        sensitive = [self.password.read_text(), stdin.rstrip("\r\n")]
        if self.init.exists() and self.init.stat().st_size:
            init = json.loads(self.init.read_text())
            sensitive.extend([init["root_token"], *init["unseal_keys_b64"]])
        journal = self.init.with_name(self.init.name + ".recovery-pending")
        if journal.exists():
            sensitive.append(json.loads(private_read(journal)).get("token", ""))
        if any(value and value in output for value in sensitive):
            raise RuntimeError("Script leaked secret input; output withheld")
        if result.returncode != expected:
            raise RuntimeError("Bootstrap returned unexpected status: " + output)
        return output

    def initialize(self) -> Bao:
        result = Bao().cli(
            "operator", "init", "-key-shares=5", "-key-threshold=3", "-format=json"
        )
        self.init.write_text(json.dumps(result))
        self.init.chmod(0o600)
        self.invoke()
        return Bao(result["root_token"])
