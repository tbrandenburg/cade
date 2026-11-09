"""Exercise the real offline CLI against a disposable two-repository layout."""

import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests/fixtures/doctor-azure/enabled.yaml"
SENTINEL = "SYNTHETIC-SECRET-NOT-FOR-OUTPUT"


class DoctorAzureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.infra = self.root / "infrastructure"
        self.infra.mkdir()
        (self.infra / "review.txt").write_text(
            "Platform-owned infrastructure; do not mutate\n"
        )
        self.deployment = self.root / "cade-deployment/backends"
        self.deployment.mkdir(parents=True)
        self.config = self.deployment / "azure-remote-dev-env.yaml"
        self.document = yaml.safe_load(FIXTURE.read_text())
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.marker = self.root / "unexpected-cloud-command"
        for name in ("az", "terraform", "coder", "docker", "curl", "wget"):
            executable = self.bin / name
            executable.write_text(
                f"#!/bin/sh\nprintf invoked > '{self.marker}'\nexit 99\n"
            )
            executable.chmod(0o755)

    def run_doctor(
        self, *arguments: str, payload: str | None = None
    ) -> subprocess.CompletedProcess[str]:
        self.config.write_text(
            json.dumps(self.document) if payload is None else payload
        )
        before = {
            path: path.read_bytes() for path in self.root.rglob("*") if path.is_file()
        }
        result = subprocess.run(
            ["/bin/bash", str(ROOT / "scripts/doctor-azure.sh"), *arguments],
            cwd=self.root,
            env={
                "PATH": f"{self.bin}:{Path(sys.executable).parent}:/usr/bin:/bin",
                "HOME": str(self.root),
                "CADE_BACKENDS_DIR": str(self.root / "ignored-missing-directory"),
                "PYTHONDONTWRITEBYTECODE": "1",
            },
            capture_output=True,
            text=True,
            timeout=10,
        )
        after = {
            path: path.read_bytes() for path in self.root.rglob("*") if path.is_file()
        }
        self.assertEqual(before, after, "doctor must not mutate either repository")
        self.assertFalse(
            self.marker.exists(), "offline doctor invoked a cloud/runtime CLI"
        )
        self.assertNotIn(SENTINEL, result.stdout + result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        return result

    def check(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return self.run_doctor("--offline", "--config", str(self.config), *arguments)

    def test_external_two_repo_rehearsal_and_cross_rg_subnet(self) -> None:
        result = self.check("--profile", "Small")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("enabled: syntax/reference checks passed", result.stdout)
        self.assertIn("Live Azure checks NOT TESTED", result.stdout)
        self.assertEqual(result.stderr, "")

    def test_disabled_placeholders(self) -> None:
        self.document = yaml.safe_load(
            (ROOT / "workspace/examples/azure-remote-dev-env.yaml").read_text()
        )
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("disabled: placeholders permitted", result.stdout)
        self.assertIn("NOT TESTED", result.stdout)

    def test_enabled_invalid_fields(self) -> None:
        changes = (
            ("subscriptionId", "<subscription-id>", "subscriptionId"),
            ("subscriptionId", "99999999-2222-3333-4444-555555555555", "must match"),
            ("subnetId", "/not/a/subnet", "subnetId"),
            ("region", "Sweden Central", "region"),
            ("resourceGroup", "invalid/rg", "resourceGroup"),
            (
                "identity",
                {"method": "managedIdentity", "clientId": "not-uuid"},
                "clientId",
            ),
            ("password", SENTINEL, "unknown fields"),
            ("profile", "Small", "unknown fields"),
        )
        original = copy.deepcopy(self.document)
        for field, value, diagnostic in changes:
            with self.subTest(field=field, diagnostic=diagnostic):
                self.document = copy.deepcopy(original)
                self.document["spec"]["config"][field] = value
                result = self.check()
                self.assertEqual(result.returncode, 1)
                self.assertIn(diagnostic, result.stderr)
                self.assertEqual(result.stdout, "")

    def test_missing_resource_group(self) -> None:
        del self.document["spec"]["config"]["resourceGroup"]
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("required fields", result.stderr)
        self.assertIn("resourceGroup", result.stderr)

    def test_nested_secret_rejected_when_disabled(self) -> None:
        self.document["spec"]["enabled"] = False
        self.document["spec"]["config"]["identity"]["clientSecret"] = SENTINEL
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("identity: unknown fields", result.stderr)

    def test_malformed_yaml_sanitized(self) -> None:
        result = self.run_doctor(
            "--offline", "--config", str(self.config), payload=f"password: [{SENTINEL}"
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("check permissions and YAML syntax", result.stderr)

    def test_profile_allowlist_even_when_disabled(self) -> None:
        self.document["spec"]["enabled"] = False
        for profile in ("Medium", "Large", "Unknown", SENTINEL):
            with self.subTest(profile=profile):
                result = self.check("--profile", profile)
                self.assertEqual(result.returncode, 1)
                self.assertIn("only --profile Small is approved", result.stderr)
                self.assertEqual(result.stdout, "")

    def test_missing_path_directory_and_dangling_link(self) -> None:
        dangling = self.root / "dangling.yaml"
        dangling.symlink_to(self.root / "nonexistent-target")
        for path in (self.root / "absent.yaml", self.deployment, dangling):
            with self.subTest(kind=path.name):
                result = self.run_doctor("--offline", "--config", str(path))
                self.assertEqual(result.returncode, 1)
                self.assertIn("ERROR:", result.stderr)
                self.assertEqual(result.stdout, "")

    def test_non_azure_connection(self) -> None:
        self.document = yaml.safe_load(
            (ROOT / "workspace/examples/docker-local.yaml").read_text()
        )
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("select an azure-remote-dev-env Azure declaration", result.stderr)

    def test_required_offline_mode_and_sanitized_argument_errors(self) -> None:
        for arguments in (
            ("--config", str(self.config)),
            ("--offline", "--config", str(self.config), "--password", SENTINEL),
            ("--offline", "--config"),
        ):
            result = self.run_doctor(*arguments)
            self.assertEqual(result.returncode, 2)
            self.assertIn(
                "use --offline --config FILE [--profile Small]", result.stderr
            )
            self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
