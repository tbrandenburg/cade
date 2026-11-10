#!/usr/bin/env python3
"""Executable opt-in real Docker TLS/recovery drill: python3 this_file.py."""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from openbao_redirect_e2e import OpenBaoRedirectTLS
from openbao_tls_fixture import (
    Bao,
    BaoError,
    Instance,
    command,
    fingerprint,
    login,
    private_read,
    verify_normal_listener,
)


class OpenBaoTLS(unittest.TestCase):
    def denied(
        self,
        bao: Bao,
        path: str,
        payload: dict | None = None,
        statuses: tuple[int, ...] = (403,),
    ) -> None:
        with self.assertRaises(BaoError) as caught:
            if payload is None:
                bao.read(path)
            if payload is not None:
                bao.write(path, payload)
        self.assertIn(caught.exception.status, statuses)

    def test_bootstrap(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="cade-170-", dir="/tmp/opencode"
        ) as temporary:
            instance = Instance(Path(temporary))
            try:
                instance.start()
                os.environ["BAO_CACERT"] = "/missing-test-ca.pem"
                with self.assertRaises(BaoError):
                    Bao().status()
                instance.select()
                os.environ["BAO_ADDR"] = "https://localhost:8200"
                with self.assertRaises(BaoError):
                    Bao().status()
                instance.select()
                self.assertIn("password required", instance.invoke(expected=1))
                self.assertFalse(Bao().status()["initialized"])
                instance.password.chmod(0o644)
                self.assertIn(
                    "owner-only",
                    instance.invoke(
                        "--password-file", str(instance.password), expected=1
                    ),
                )
                instance.password.chmod(0o600)
                unsafe = instance.directory / "unsafe-output"
                unsafe.mkdir(mode=0o777)
                unsafe.chmod(0o777)
                os.environ["BAO_INIT_FILE"] = str(unsafe / "init.json")
                self.assertIn(
                    "not group/world writable",
                    instance.invoke(
                        "--password-file", str(instance.password), expected=1
                    ),
                )
                self.assertFalse(Bao().status()["initialized"])
                self.assertFalse((unsafe / "init.json").exists())
                instance.select()
                instance.invoke("--password-file", str(instance.password))
                root = Bao(json.loads(private_read(instance.init))["root_token"])
                self.denied(root, "sys/mounts")
                operator = login(private_read(instance.password))
                self.exercise_operator(operator)
                self.rotation_checks(instance, operator)
                self.assertEqual(instance.init.stat().st_mode & 0o777, 0o600)
                print(
                    "PASS bootstrap, root revocation, TLS, scoped writes, "
                    "rotation/unseal"
                )
            finally:
                instance.stop()

    def exercise_operator(self, operator: Bao) -> None:
        path = "secret/data/devenv-cloud/test"
        operator.write(path, {"data": {"value": "first"}})
        operator.write(path, {"data": {"value": "second"}})
        result = operator.read(path)["data"]
        self.assertEqual(result["data"], {"value": "second"})
        self.assertEqual(result["metadata"]["version"], 2)
        self.denied(operator, "secret/data/outside/test", {"data": {"value": "no"}})
        self.denied(operator, "sys/mounts")
        self.denied(operator, "auth/token/create", {"policies": ["root"]})
        verify_normal_listener()

    def rotation_checks(self, instance: Instance, operator: Bao) -> None:
        path = "secret/data/devenv-cloud/coder-db"
        before = operator.read(path)["data"]
        instance.invoke("--force-rotate", expected=1)
        instance.invoke(
            "--force-rotate",
            "--password-file",
            "-",
            stdin="incorrect-password-for-test\n",
            expected=1,
        )
        self.assertTrue(
            before == operator.read(path)["data"], "failed rotation changed data"
        )
        command("docker", "restart", "-t", "5", instance.name)
        instance.invoke(reunseal=True)
        self.assertTrue(before == operator.read(path)["data"], "unseal changed data")
        instance.invoke(
            "--force-rotate",
            "--password-file",
            "-",
            stdin=private_read(instance.password) + "\n",
        )
        after = login(private_read(instance.password)).read(path)["data"]
        self.assertTrue(before["data"] != after["data"], "rotation did not change data")
        self.assertEqual(
            after["metadata"]["version"], before["metadata"]["version"] + 1
        )

    def test_resume_and_recovery(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="cade-170-", dir="/tmp/opencode"
        ) as temporary:
            instance = Instance(Path(temporary))
            try:
                instance.start()
                root = instance.initialize()
                (instance.directory / "data/poisoned-token-cache").write_text(
                    root.token
                )
                self.denied(Bao(), "sys/mounts")
                self.failed_provision(instance, root)
                root = self.failed_login(instance, root)
                self.readonly(root)
                # Simulate the legacy locked-out installation: no usable operator.
                root.cli("delete", "-format=json", "auth/userpass/users/cade-operator")
                root.write("auth/token/revoke-self", {})
                self.denied(root, "sys/mounts")
                instance.stop()
                original = fingerprint(instance.directory / "data")
                copy = Path(temporary) / "copy"
                shutil.copytree(instance.directory / "data", copy)
                shutil.move(
                    instance.directory / "data", instance.directory / "original"
                )
                shutil.move(copy, instance.directory / "data")
                instance.configure(True)
                instance.start()
                self.recover_copy(instance)
                instance.stop()
                instance.configure(False)
                instance.start()
                instance.invoke()
                self.exercise_operator(login(private_read(instance.password)))
                self.assertEqual(original, fingerprint(instance.directory / "original"))
                print(
                    "PASS failed provisioning/login resume, read-only denial, "
                    "copied-storage recovery"
                )
            finally:
                instance.stop()

    def failed_provision(self, instance: Instance, root: Bao) -> None:
        init = json.loads(private_read(instance.init))
        restricted = root.write("auth/token/create", {"policies": ["default"]})
        init["root_token"] = restricted["auth"]["client_token"]
        instance.init.write_text(json.dumps(init))
        output = instance.invoke(
            "--resume-bootstrap", "--password-file", str(instance.password), expected=1
        )
        self.assertIn("root was NOT revoked", output)
        self.assertIn("sys/", root.read("sys/mounts")["data"])
        init["root_token"] = root.token
        instance.init.write_text(json.dumps(init))
        root.write("sys/auth/userpass", {"type": "userpass"})
        # Provision with a valid administrator through the supported entry point.
        admin_file = instance.directory / "admin-token"
        admin_file.write_text(root.token)
        admin_file.chmod(0o600)
        instance.invoke(
            "--provision-operator",
            "--admin-token-file",
            str(admin_file),
            "--password-file",
            str(instance.password),
        )

    def failed_login(self, instance: Instance, root: Bao) -> Bao:
        for _ in range(6):
            self.denied(
                Bao(),
                "auth/userpass/login/cade-operator",
                {"password": "wrong"},
                statuses=(400, 403),
            )
        output = instance.invoke(
            "--resume-bootstrap", "--password-file", str(instance.password), expected=1
        )
        self.assertIn("root was NOT revoked", output)
        self.assertEqual(root.read("sys/locked-users")["data"]["total"], 1)
        accessor = root.read("sys/auth")["data"]["userpass/"]["accessor"]
        root.write(f"sys/locked-users/{accessor}/unlock/cade-operator", {})
        self.assertEqual(root.read("sys/locked-users")["data"]["total"], 0)
        alternate = Bao(
            root.write(
                "auth/token/create-orphan",
                {
                    "policies": ["root"],
                    "ttl": "5m",
                },
            )["auth"]["client_token"]
        )
        instance.invoke("--resume-bootstrap", "--password-file", str(instance.password))
        self.denied(root, "sys/mounts")
        return alternate

    def readonly(self, root: Bao) -> None:
        # This method is called only while the fixture's root is valid.
        token = root.write(
            "auth/token/create",
            {
                "policies": ["devenv-cloud-read"],
                "ttl": "5m",
                "no_default_policy": True,
            },
        )["auth"]["client_token"]
        reader = Bao(token)
        self.assertIn("data", reader.read("secret/data/devenv-cloud/coder-db"))
        self.denied(
            reader, "secret/data/devenv-cloud/coder-db", {"data": {"value": "no"}}
        )

    def recover_copy(self, instance: Instance) -> None:
        self.assertIn(
            "recovery incomplete",
            instance.invoke(
                "--password-file", str(instance.password), expected=1, recovery=True
            ),
        )
        os.environ["BAO_RECOVERY_DISPOSABLE_COPY"] = "yes"
        try:
            self.failed_revoke(instance)
            output = instance.invoke(
                "--password-file", str(instance.password), recovery=True
            )
        finally:
            os.environ.pop("BAO_RECOVERY_DISPOSABLE_COPY", None)
        self.assertIn("temporary recovery root revoked", output)
        self.assertFalse(Bao().status()["sealed"])

    def failed_revoke(self, instance: Instance) -> None:
        # Seal the real server immediately before the final revoke; no canned errors.
        instance.invoke(
            "--password-file",
            str(instance.password),
            recovery=True,
            expected=1,
            revoke_failure=True,
        )
        journal = instance.init.with_name(instance.init.name + ".recovery-pending")
        pending = json.loads(private_read(journal))
        self.assertEqual(pending["state"], "revoke")
        self.assertEqual(journal.stat().st_mode & 0o777, 0o600)
        self.assertTrue(Bao().status()["sealed"])
        instance.invoke()
        self.assertFalse(Bao().status()["sealed"])
        root = Bao(pending["token"])
        self.assertIn("sys/", root.read("sys/mounts")["data"])
        instance.invoke("--password-file", str(instance.password), recovery=True)
        self.denied(root, "sys/mounts")
        self.assertEqual(json.loads(private_read(journal)), {"state": "clean"})
        print(
            "PASS failed recovery revoke retained privately; "
            "retry invalidated original root"
        )


if __name__ == "__main__":
    # Check listeners without binding or disturbing any existing service.
    subprocess.run(["ss", "-ltn"], capture_output=True, timeout=10, check=True)
    os.environ.pop("FORCE_ROTATE", None)
    os.environ.pop("BAO_RECOVERY_DISPOSABLE_COPY", None)
    os.environ.pop("CODER_WORKSPACE_API_TOKEN", None)
    os.environ.pop("OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD", None)
    suite = unittest.TestSuite(
        unittest.defaultTestLoader.loadTestsFromTestCase(case)
        for case in (OpenBaoTLS, OpenBaoRedirectTLS)
    )
    result = unittest.TextTestRunner().run(suite)
    raise SystemExit(not result.wasSuccessful())
