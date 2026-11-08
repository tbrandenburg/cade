"""Exercise make up and real Compose config with a synthetic Docker daemon."""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class PreflightTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for directory in ("coder", "scripts", "bin"):
            (self.root / directory).mkdir()
        for path in (
            "compose.yaml",
            "Makefile",
            "coder/supported-version",
            "scripts/coder-preflight.py",
            "scripts/wait-for-coder.sh",
        ):
            shutil.copyfile(ROOT / path, self.root / path)
        self.trace = self.root / "trace"
        self.trace.write_text("")
        docker = self.root / "bin/docker"
        docker.write_text(
            """#!/usr/bin/python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ['TRACE'], 'a') as trace:
    trace.write('docker ' + ' '.join(args) + '\\n')
if args and args[0] == 'compose' and 'config' in args:
    os.execv(os.environ['REAL_DOCKER'], [os.environ['REAL_DOCKER'], *args])
if args[:2] == ['image', 'inspect'] or args[:2] == ['buildx', 'build']:
    sys.exit(0)
if args and args[0] == 'run':
    print(json.dumps({'version': os.environ.get('BINARY_VERSION', 'v2.38.6+test')}))
    sys.exit(0)
if args[:2] == ['compose', 'up']:
    sys.exit(int(os.environ.get('UP_FAILURE', '0')))
if args[:2] == ['compose', 'ps']:
    print('synthetic-id')
    sys.exit(0)
if args and args[0] == 'inspect':
    print(os.environ.get('CODER_STATE', 'running healthy'))
    sys.exit(0)
sys.exit(99)
"""
        )
        docker.chmod(0o755)
        bash = self.root / "bin/bash"
        bash.write_text(
            """#!/bin/sh
printf 'bash %s\\n' "$*" >> "$TRACE"
if [ "$1" = scripts/wait-for-coder.sh ]; then
  exec /bin/bash "$@"
fi
exit 0
"""
        )
        bash.chmod(0o755)
        self.env = {
            "PATH": f"{self.root / 'bin'}:/usr/bin:/bin",
            "HOME": str(self.root),
            "TRACE": str(self.trace),
            "REAL_DOCKER": shutil.which("docker"),
        }

    def run_make(self, settings="", override="", extra=None, arguments=()):
        (self.root / ".env").write_text(settings)
        if override:
            (self.root / "override.yaml").write_text(override)
            self.env["COMPOSE_FILE"] = "compose.yaml:override.yaml"
        return subprocess.run(
            ["make", "up", *arguments],
            cwd=self.root,
            env={**self.env, **(extra or {})},
            capture_output=True,
            text=True,
            timeout=30,
        )

    def test_old_env_and_retired_experiment_stop_before_up(self):
        for settings, message in (
            (
                "CODER_VERSION=v2.36.4\nCODER_EXPERIMENTS=oauth2,mcp-server-http\n",
                "unsupported CODER_VERSION",
            ),
            ("CODER_EXPERIMENTS=mcp-server-http,oauth2\n", "retired oauth2"),
        ):
            with self.subTest(settings=settings):
                self.trace.write_text("")
                result = self.run_make(settings)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertNotIn("compose up", self.trace.read_text())

    def test_effective_image_and_command_overrides_stop_before_up(self):
        for override in (
            "services:\n  coder:\n    image: ghcr.io/coder/coder:v2.36.4\n",
            'services:\n  coder:\n    entrypoint: ["/opt/coder", "server"]\n',
            "services:\n  coder:\n    pull_policy: always\n",
            "services:\n  coder:\n    volumes:\n      - /tmp:/opt/coder:ro\n",
        ):
            with self.subTest(override=override):
                self.trace.write_text("")
                result = self.run_make(override=override)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Coder preflight failed", result.stderr)
                self.assertNotIn("compose up", self.trace.read_text())

    def test_binary_mismatch_stops_before_up(self):
        result = self.run_make(extra={"BINARY_VERSION": "v2.36.4+test"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported binary", result.stderr)
        self.assertNotIn("compose up", self.trace.read_text())

    def test_pin_drift_stops_before_up(self):
        (self.root / "coder/supported-version").write_text("v2.39.0\n")
        result = self.run_make()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("effective Coder image must be", result.stderr)
        self.assertNotIn("compose up", self.trace.read_text())

    def test_custom_make_compose_command_stops_before_up(self):
        result = self.run_make(arguments=("COMPOSE=docker compose -f override.yaml",))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("custom COMPOSE is not supported", result.stderr)
        self.assertNotIn("compose up", self.trace.read_text())

    def test_unhealthy_coder_fails_make_before_bootstrap(self):
        for state in ("running unhealthy", "exited none", "running none"):
            with self.subTest(state=state):
                self.trace.write_text("")
                result = self.run_make(extra={"CODER_STATE": state})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Coder startup failed", result.stderr)
                self.assertIn("compose up -d", self.trace.read_text())
                self.assertNotIn("scripts/ai-bootstrap.sh", self.trace.read_text())

    def test_compose_start_failure_fails_make_before_bootstrap(self):
        result = self.run_make(extra={"UP_FAILURE": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("compose up -d", self.trace.read_text())
        self.assertNotIn("scripts/wait-for-coder.sh", self.trace.read_text())
        self.assertNotIn("scripts/ai-bootstrap.sh", self.trace.read_text())

    def test_healthy_coder_allows_startup(self):
        result = self.run_make()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Coder is healthy", result.stdout)
        self.assertIn("scripts/ai-bootstrap.sh", self.trace.read_text())


if __name__ == "__main__":
    unittest.main()
