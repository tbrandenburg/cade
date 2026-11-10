"""CADE's single-user OpenBao bootstrap and routine rotation entry point."""

import argparse
import getpass
import json
import os
import secrets
import sys
import time
from pathlib import Path

from openbao_client import (
    ROOT,
    Bao,
    BaoError,
    login,
    private_create,
    private_read,
    provision,
)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument(
        "--force-rotate",
        action="store_true",
    )
    modes.add_argument("--resume-bootstrap", action="store_true")
    modes.add_argument("--provision-operator", action="store_true")
    modes.add_argument("--reunseal-only", action="store_true")
    parser.add_argument(
        "--password-file", type=Path, help="owner-only file, or - for stdin"
    )
    parser.add_argument(
        "--admin-token-file",
        type=Path,
        help="existing administrator; provisioning only",
    )
    options = parser.parse_args()
    if not (
        options.resume_bootstrap or options.provision_operator or options.reunseal_only
    ):
        options.force_rotate = (
            options.force_rotate or os.environ.get("FORCE_ROTATE") == "1"
        )
    return options


def password_input(path: Path | None) -> str:
    if path == Path("-"):
        password = sys.stdin.readline().rstrip("\r\n")
    elif path:
        password = private_read(path)
    elif sys.stdin.isatty():
        password = getpass.getpass(
            "OpenBao cade-operator password (save in password manager): "
        )
    else:
        raise BaoError(
            "Operator password required: --password-file FILE (chmod 600), "
            "or --password-file - via stdin."
        )
    if not 16 <= len(password.encode()) <= 72 or "\n" in password or "\r" in password:
        raise BaoError("Operator password must be a single line of 16-72 UTF-8 bytes.")
    return password


def unseal(bao: Bao, path: Path) -> None:
    status = bao.status()
    if not status["initialized"]:
        raise BaoError("OpenBao not initialized; run governance-bootstrap first.")
    if not status["sealed"]:
        return
    init = json.loads(private_read(path))
    for key in init["unseal_keys_b64"]:
        result = bao.write("sys/unseal", {"key": key})["data"]
        if not result["sealed"]:
            return
    raise BaoError("OpenBao remains sealed; restore matching unseal shares.")


def ready(bao: Bao, wait: bool) -> dict:
    # make up invokes re-unseal while the listener may still be starting.
    for attempt in range(20):
        try:
            return bao.status()
        except BaoError:
            if not wait or attempt == 19:
                raise
            time.sleep(2)
    raise BaoError("OpenBao listener did not become ready.")


def rotate(bao: Bao) -> None:
    records = {
        "coder-db": {"password": secrets.token_urlsafe(24)},
        "temporal-db": {"password": secrets.token_urlsafe(24)},
        "lab-sim": {
            "tokens": (
                f"agent-a:{secrets.token_urlsafe(24)},"
                f"agent-b:{secrets.token_urlsafe(24)}"
            )
        },
    }
    # Preserve the existing optional integrations, but never export .env wholesale.
    environment = dict(os.environ)
    envfile = Path(os.environ.get("BAO_ENV_FILE", str(ROOT / ".env")))
    if envfile.exists():
        for line in envfile.read_text().splitlines():
            if line.strip() and not line.lstrip().startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                environment.setdefault(key.strip(), value)
    if environment.get("CODER_WORKSPACE_API_TOKEN"):
        records["coder-temporal-svc"] = {
            "token": environment["CODER_WORKSPACE_API_TOKEN"],
            "owner": environment.get("CODER_WORKSPACE_OWNER", "temporal-svc"),
        }
    if environment.get("OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD"):
        records["omnigent/host-account"] = {
            "url": "http://omnigent-server:8000",
            "username": "admin",
            "password": environment["OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD"],
        }
    for name, data in records.items():
        path = f"secret/data/devenv-cloud/{name}"
        bao.write(path, {"data": data})
        if bao.read(path)["data"]["data"] != data:
            raise BaoError(
                "Credential verification failed; rotation may be partial, "
                "inspect stored versions."
            )
        print(
            f"Verified credential record: secret/devenv-cloud/{name} (value withheld)"
        )
    print(
        "Stored values changed only in OpenBao; reconcile affected consumers "
        "privately before restarting them."
    )


def run(options: argparse.Namespace) -> None:
    path = Path(
        os.environ.get(
            "BAO_INIT_FILE", str(ROOT / "governance/openbao/unseal/init.json")
        )
    )
    bao = Bao()
    if options.admin_token_file and not options.provision_operator:
        raise BaoError("--admin-token-file is only accepted with --provision-operator.")
    status = ready(bao, options.reunseal_only)
    fresh = not status["initialized"]
    active = (
        fresh
        or options.resume_bootstrap
        or options.provision_operator
        or options.force_rotate
    )
    password = (
        password_input(options.password_file)
        if active and not options.reunseal_only
        else ""
    )
    if fresh:
        if (
            options.reunseal_only
            or options.provision_operator
            or options.force_rotate
            or options.resume_bootstrap
        ):
            raise BaoError("Initialize with an ordinary bootstrap invocation first.")
        # Refuse to overwrite any saved shares, including after an interrupted init.
        if path.exists():
            raise BaoError(
                "Init file exists for an uninitialized server; inspect state, "
                "do not overwrite shares."
            )
        # Open the private destination before initializing the server. A bad
        # path/permission must not strand a freshly initialized server's shares.
        with private_create(path) as stream:
            init = bao.cli(
                "operator", "init", "-key-shares=5", "-key-threshold=3", "-format=json"
            )
            json.dump(init, stream)
            stream.flush()
            os.fsync(stream.fileno())
        print(
            "Initialized; private init file saved. "
            "Separate shares from storage backups."
        )
    unseal(bao, path)
    if not active or options.reunseal_only:
        print("OpenBao unsealed; no provisioning or rotation requested.")
        return
    if options.provision_operator:
        if not options.admin_token_file:
            raise BaoError("Provisioning requires --admin-token-file FILE (chmod 600).")
        provision(Bao(private_read(options.admin_token_file)), password)
        print(
            "Operator provisioned and fresh login verified; "
            "administrator token not revoked by this mode."
        )
        return
    if options.force_rotate:
        rotate(login(password))
        return
    admin = Bao(json.loads(private_read(path))["root_token"])
    try:
        provision(admin, password)
        rotate(login(password))
    except BaoError as error:
        raise BaoError(
            "Bootstrap incomplete; root was NOT revoked. Fix the cause and retry "
            "--resume-bootstrap with the saved init file and password. " + str(error)
        ) from error
    admin.write("auth/token/revoke-self", {})
    print(
        "Bootstrap verified; initial root revoked. "
        "Routine rotation uses a fresh operator login."
    )


def main() -> int:
    options = arguments()
    try:
        run(options)
    except (BaoError, OSError, ValueError, KeyError) as error:
        # Never print arbitrary exception strings: parsers/OS errors may contain input.
        if options.reunseal_only:
            print(
                "SKIP: OpenBao unseal unavailable; "
                "run governance-bootstrap to diagnose.",
                file=sys.stderr,
            )
            return 0
        message = (
            str(error)
            if isinstance(error, BaoError)
            else "Invalid or unavailable private input/server response; "
            "inspect state before retrying."
        )
        print("ERROR: " + message, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
