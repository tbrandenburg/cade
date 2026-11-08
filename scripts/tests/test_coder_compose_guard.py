"""Exercise the Compose-resolved Coder entrypoint without starting containers."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class CoderComposeGuardTest(unittest.TestCase):
    def run_entrypoint(self, settings, overrides=None, stub_server=False):
        with tempfile.TemporaryDirectory() as directory:
            env_file = Path(directory) / ".env"
            env_file.write_text(settings, encoding="utf-8")
            env = {"PATH": os.defpath, "HOME": directory, **(overrides or {})}
            config = subprocess.run(
                [
                    "docker",
                    "compose",
                    "--env-file",
                    str(env_file),
                    "-f",
                    str(ROOT / "compose.yaml"),
                    "config",
                    "--format",
                    "json",
                ],
                cwd=ROOT,
                env=env,
                capture_output=True,
                text=True,
                check=True,
                timeout=20,
            )
            coder = json.loads(config.stdout)["services"]["coder"]
            self.assertEqual(coder["image"], "ghcr.io/coder/coder:v2.38.6")
            self.assertEqual(coder["entrypoint"], ["/bin/sh", "-c"])
            # `compose config` escapes literal dollars for Compose re-input;
            # the container receives single dollars instead.
            command = coder["command"][0].replace("$$", "$")
            # Rejection tests run the original command; success tests replace
            # only the final exec because no real Coder server may be started.
            stub = (
                'printf "started:%s:%s:%s:%s\\n" /opt/coder server '
                '"${CODER_EXTERNAL_AUTH_0_ID-unset}" '
                '"${CODER_EXTERNAL_AUTH_0_CLIENT_ID-unset}"'
            )
            self.assertEqual(command.count("exec /opt/coder server"), 1)
            if stub_server:
                command = command.replace("exec /opt/coder server", stub)
            return subprocess.run(
                ["/bin/sh", "-c", command],
                env={"PATH": os.defpath, **coder["environment"]},
                capture_output=True,
                text=True,
                timeout=10,
            )

    def test_old_env_rejects_version_before_start(self):
        result = self.run_entrypoint(
            "CODER_VERSION=v2.36.4\nCODER_EXPERIMENTS=oauth2,mcp-server-http\n"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported CODER_VERSION", result.stderr)
        self.assertNotIn("started:", result.stdout)

    def test_retired_experiment_rejected_after_version_migration(self):
        for experiments in ("oauth2,mcp-server-http", "mcp-server-http, oauth2 "):
            with self.subTest(experiments=experiments):
                result = self.run_entrypoint(f"CODER_EXPERIMENTS={experiments}\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("retired oauth2 experiment", result.stderr)
                self.assertNotIn("started:", result.stdout)

    def test_shell_override_rejected_even_with_safe_env_file(self):
        result = self.run_entrypoint(
            "CODER_VERSION=v2.38.6\n", {"CODER_VERSION": "v9.0.0"}
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported CODER_VERSION", result.stderr)
        self.assertNotIn("started:", result.stdout)

    def test_default_and_supported_env_reach_server(self):
        for settings in (
            "",
            "CODER_VERSION=v2.38.6\nCODER_EXPERIMENTS=mcp-server-http,oauth2-other\n",
        ):
            with self.subTest(settings=settings):
                result = self.run_entrypoint(settings, stub_server=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("started:/opt/coder:server:unset:unset", result.stdout)

    def test_github_auth_still_exported(self):
        result = self.run_entrypoint(
            "GITHUB_OAUTH_CLIENT_ID=synthetic-client\n"
            "GITHUB_OAUTH_CLIENT_SECRET=synthetic-secret\n",
            stub_server=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "started:/opt/coder:server:github:synthetic-client", result.stdout
        )


if __name__ == "__main__":
    unittest.main()
