"""Focused private-input regressions; no running platform or Docker required."""

import argparse
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from openbao_admin import password_input, run
from openbao_client import (
    BaoError,
    private_create,
    private_read,
    private_write,
    verify_normal_listener,
)
from openbao_recover_operator import journal_open, recover_operator


class PrivateInput(unittest.TestCase):
    def test_initialization_retains_exclusive_descriptor(self) -> None:
        with tempfile.TemporaryDirectory(dir="/tmp/opencode") as directory:
            path = Path(directory) / "init.json"
            target = Path(directory) / "target"
            retained = Path(directory) / "retained-init"
            target.write_text("unchanged")

            def replace(*args: str) -> dict:
                path.rename(retained)
                path.symlink_to(target)
                return {
                    "root_token": "synthetic-root",
                    "unseal_keys_b64": ["synthetic-share"],
                }

            options = argparse.Namespace(
                admin_token_file=None,
                reunseal_only=False,
                resume_bootstrap=False,
                provision_operator=False,
                force_rotate=False,
                password_file=None,
            )
            with (
                patch.dict(os.environ, {"BAO_INIT_FILE": str(path)}),
                patch("openbao_admin.ready", return_value={"initialized": False}),
                patch(
                    "openbao_admin.password_input", return_value="synthetic-password"
                ),
                patch("openbao_admin.Bao.cli", side_effect=replace),
                patch("openbao_admin.unseal", side_effect=BaoError("stop after init")),
                self.assertRaisesRegex(BaoError, "stop after init"),
            ):
                run(options)
            self.assertEqual(target.read_text(), "unchanged")
            self.assertEqual(
                json.loads(private_read(retained)),
                {
                    "root_token": "synthetic-root",
                    "unseal_keys_b64": ["synthetic-share"],
                },
            )

    def test_retained_descriptor_does_not_follow_replacement(self) -> None:
        with tempfile.TemporaryDirectory(dir="/tmp/opencode") as directory:
            path = Path(directory) / "init.json"
            target = Path(directory) / "target"
            target.write_text("unchanged")
            target.chmod(0o644)
            with private_create(path) as stream:
                path.unlink()
                path.symlink_to(target)
                stream.write("synthetic root and shares")
            self.assertEqual(target.read_text(), "unchanged")
            self.assertEqual(target.stat().st_mode & 0o777, 0o644)

    def test_unsafe_parent_rejected_before_server_init(self) -> None:
        with tempfile.TemporaryDirectory(dir="/tmp/opencode") as directory:
            parent = Path(directory) / "unsafe"
            parent.mkdir(mode=0o777)
            parent.chmod(0o777)
            options = argparse.Namespace(
                admin_token_file=None,
                reunseal_only=False,
                resume_bootstrap=False,
                provision_operator=False,
                force_rotate=False,
                password_file=None,
            )
            with (
                patch.dict(os.environ, {"BAO_INIT_FILE": str(parent / "init.json")}),
                patch("openbao_admin.ready", return_value={"initialized": False}),
                patch(
                    "openbao_admin.password_input", return_value="synthetic-password"
                ),
                patch("openbao_admin.Bao.cli") as cli,
                self.assertRaises(BaoError),
            ):
                run(options)
            cli.assert_not_called()
            self.assertFalse((parent / "init.json").exists())

    def test_journal_permissions_and_incomplete_marker(self) -> None:
        with tempfile.TemporaryDirectory(dir="/tmp/opencode") as directory:
            path = Path(directory) / "init.json"
            journal = path.with_name(path.name + ".recovery-pending")
            private_write(journal, '{"state":"generating"}')
            with (
                patch("openbao_recover_operator.recover_root") as generate,
                self.assertRaisesRegex(BaoError, "Unresolved recovery journal"),
            ):
                recover_operator(path, "synthetic-password")
            generate.assert_not_called()
            self.assertEqual(private_read(journal), '{"state":"generating"}')
            journal.chmod(0o644)
            with self.assertRaises(BaoError):
                journal_open(journal)
            journal.unlink()
            journal.symlink_to(path)
            with self.assertRaises(OSError):
                journal_open(journal)

    def test_exact_listener_denials(self) -> None:
        with patch(
            "openbao_client.Bao.read",
            side_effect=[BaoError("denied", 405), BaoError("denied", 403)],
        ) as read:
            verify_normal_listener()
        self.assertEqual(read.call_count, 2)
        self.assertEqual(read.call_args.args, ("sys/generate-root-token/attempt",))
        for status in (None, 500, 403, 404):
            with (
                self.subTest(status=status),
                patch(
                    "openbao_client.Bao.read", side_effect=BaoError("safe", status)
                ) as read,
            ):
                with self.assertRaisesRegex(BaoError, "expected HTTP 405"):
                    verify_normal_listener()
                self.assertEqual(read.call_count, 1)

    def test_damaged_journal_never_starts_quorum(self) -> None:
        with tempfile.TemporaryDirectory(dir="/tmp/opencode") as directory:
            path = Path(directory) / "init.json"
            journal = path.with_name(path.name + ".recovery-pending")
            for value in ("", "{", "[]", '{"state":"revoke","token":""}'):
                journal.write_text(value)
                journal.chmod(0o600)
                with (
                    patch("openbao_recover_operator.recover_root") as generate,
                    self.assertRaises((ValueError, BaoError)),
                ):
                    recover_operator(path, "synthetic-password")
                generate.assert_not_called()
                self.assertEqual(journal.read_text(), value)

    def test_owner_only_and_no_overwrite(self) -> None:
        with tempfile.TemporaryDirectory(dir="/tmp/opencode") as directory:
            path = Path(directory) / "secret"
            private_write(path, "synthetic-password-for-test\n")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(password_input(path), "synthetic-password-for-test")
            with self.assertRaises(FileExistsError):
                private_write(path, "replacement")
            self.assertEqual(private_read(path), "synthetic-password-for-test")
            path.chmod(0o644)
            with self.assertRaises(BaoError):
                private_read(path)

    def test_invalid_passwords(self) -> None:
        with tempfile.TemporaryDirectory(dir="/tmp/opencode") as directory:
            for index, value in enumerate(("", "short", "x" * 73, "x" * 16 + "\ny")):
                with self.subTest(case=index):
                    path = Path(directory) / str(index)
                    private_write(path, value)
                    with self.assertRaises(BaoError):
                        password_input(path)
                    self.assertEqual(private_read(path), value)

    def test_nonregular_input_rejected_without_blocking(self) -> None:
        with tempfile.TemporaryDirectory(dir="/tmp/opencode") as directory:
            path = Path(directory) / "fifo"
            os.mkfifo(path, 0o600)
            with self.assertRaises(BaoError):
                private_read(path)
            link = Path(directory) / "symlink"
            link.symlink_to(path)
            with self.assertRaises(OSError):
                private_read(link)


if __name__ == "__main__":
    unittest.main()
