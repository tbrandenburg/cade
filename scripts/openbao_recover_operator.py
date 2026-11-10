"""One-time operator recovery on an explicitly isolated DISPOSABLE storage copy."""

import argparse
import base64
import fcntl
import json
import os
import stat
import subprocess
import sys
from pathlib import Path
from typing import TextIO

from openbao_admin import password_input, unseal
from openbao_client import Bao, BaoError, private_parent, private_read, provision


def journal_open(path: Path) -> TextIO:
    parent = private_parent(path)
    try:
        flags = os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK
        try:
            descriptor = os.open(
                path.name, flags | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=parent
            )
            created = True
        except FileExistsError:
            descriptor = os.open(path.name, flags, dir_fd=parent)
            created = False
        os.fsync(parent)
    finally:
        os.close(parent)
    stream = os.fdopen(descriptor, "r+")
    info = os.fstat(descriptor)
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_mode & 0o077
        or info.st_uid != os.getuid()
        or info.st_nlink != 1
    ):
        stream.close()
        raise BaoError("Recovery journal must be an owned, owner-only regular file.")
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        stream.close()
        raise BaoError("Another recovery owns the private cleanup journal.") from None
    if created:
        journal_save(stream, {"state": "clean"})
        stream.seek(0)
    return stream


def journal_save(stream: TextIO, record: dict) -> None:
    stream.seek(0)
    json.dump(record, stream)
    stream.truncate()
    stream.flush()
    os.fsync(stream.fileno())


def revoke_verified(root: Bao) -> None:
    try:
        root.read("sys/mounts")
    except BaoError as error:
        if error.status == 403 and not Bao().status()["sealed"]:
            return
        raise BaoError("Could not verify pending recovery-root state.") from error
    root.write("auth/token/revoke-self", {})
    try:
        root.read("sys/mounts")
    except BaoError as error:
        if error.status == 403 and not Bao().status()["sealed"]:
            return
        raise BaoError("Could not verify temporary-root revocation.") from error
    raise BaoError("Temporary root remains usable; keep recovery isolated.")


def recover_root(bao: Bao, path: Path) -> Bao:
    attempt = bao.write("sys/generate-root/attempt", {})["data"]
    init = json.loads(private_read(path))
    for share in init["unseal_keys_b64"]:
        response = bao.write(
            "sys/generate-root/update", {"nonce": attempt["nonce"], "key": share}
        )["data"]
        if response["complete"]:
            break
    if not response["complete"]:
        raise BaoError(
            "Matching quorum not reached; preserve original storage and shares."
        )
    # OpenBao 2.6.5 roottoken.DecodeToken uses unpadded RawStdEncoding.
    value = response["encoded_token"]
    encoded = base64.b64decode(value + "=" * (-len(value) % 4), validate=True)
    otp = attempt["otp"].encode()
    return Bao(bytes(a ^ b for a, b in zip(encoded, otp, strict=True)).decode())


def recover_operator(path: Path, password: str) -> None:
    # Persist a fail-closed marker BEFORE quorum: a lost final response must never
    # allow a retry to silently forget a root whose cleanup handle is unknown.
    with journal_open(path.with_name(path.name + ".recovery-pending")) as journal:
        text = journal.read()
        pending = json.loads(text)
        if pending == {"state": "clean"}:
            pass
        elif (
            isinstance(pending, dict)
            and set(pending) == {"state", "token"}
            and pending["state"] == "revoke"
            and isinstance(pending["token"], str)
            and pending["token"]
        ):
            revoke_verified(Bao(pending["token"]))
        else:
            raise BaoError(
                "Unresolved recovery journal: preserve isolation and storage; "
                "reconcile generated root accessors before any cutover."
            )
        journal_save(journal, {"state": "generating"})
        root = recover_root(Bao(), path)
        journal_save(journal, {"state": "revoke", "token": root.token})
        try:
            provision(root, password)
        finally:
            revoke_verified(root)
            journal_save(journal, {"state": "clean"})
    print("Operator fresh login verified; temporary recovery root revoked.")


def recover() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--password-file", type=Path, help="owner-only file, or - for stdin"
    )
    options = parser.parse_args()
    if os.environ.get("BAO_RECOVERY_DISPOSABLE_COPY") != "yes":
        raise BaoError(
            "Confirm stopped disposable storage copy: BAO_RECOVERY_DISPOSABLE_COPY=yes."
        )
    container = os.environ.get("BAO_CONTAINER", "")
    if not container or container == "openbao":
        raise BaoError(
            "Set BAO_CONTAINER to the uniquely named disposable recovery container."
        )
    result = subprocess.run(
        ["docker", "inspect", container],
        text=True,
        capture_output=True,
        timeout=15,
        check=True,
    )
    instance = json.loads(result.stdout)[0]
    if (
        instance["HostConfig"]["NetworkMode"] != "none"
        or set(instance["NetworkSettings"]["Networks"]) != {"none"}
        or instance["HostConfig"].get("PortBindings")
        or instance["HostConfig"]["Privileged"]
        or instance["Config"].get("User", "").split(":")[0] in ("", "0", "root")
    ):
        raise BaoError(
            "Recovery requires non-root, unprivileged --network none "
            "with no published ports."
        )
    path = Path(os.environ["BAO_INIT_FILE"])
    password = password_input(options.password_file)
    bao = Bao()
    unseal(bao, path)
    recover_operator(path, password)


if __name__ == "__main__":
    try:
        recover()
    except (
        BaoError,
        OSError,
        ValueError,
        KeyError,
        subprocess.SubprocessError,
    ) as error:
        print(
            "ERROR: isolated recovery incomplete; preserve original storage, "
            "retain the private .recovery-pending journal; "
            "no cutover until cleanup verifies.",
            file=sys.stderr,
        )
        print(
            str(error) if isinstance(error, BaoError) else type(error).__name__,
            file=sys.stderr,
        )
        sys.exit(1)
