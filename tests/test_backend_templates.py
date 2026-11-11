"""Exercise authenticated publishing clients against real loopback HTTP servers."""

from fnmatch import fnmatchcase
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
TOKEN = "synthetic-redirect-test-token"
FAILURE = (
    "FAIL: Coder API request failed; check authentication, access and server health\n"
)


class CoderAPITest(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory(prefix="cade-api-redirect-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        shutil.copytree(
            ROOT / "scripts",
            self.root / "scripts",
            ignore=shutil.ignore_patterns("__pycache__"),
        )
        shutil.copytree(ROOT / "workspace", self.root / "workspace")
        catalog = yaml.safe_load((self.root / "workspace/catalog.yaml").read_text())
        for entry in catalog["implementations"]:
            target = self.root / entry["path"]
            target.mkdir(parents=True)
            for name in ("main.tf", "variables.tf"):
                shutil.copy(ROOT / entry["path"] / name, target / name)
        connections = self.root / "connections"
        connections.mkdir()
        self.env = {
            "HOME": str(self.root),
            "CADE_BACKENDS_DIR": str(connections),
            "CODER_SESSION_TOKEN": TOKEN,
            "NO_PROXY": "*",
        }

    def server(
        self, status: int = 200, location: str = ""
    ) -> tuple[str, list[tuple[str, bool]]]:
        requests: list[tuple[str, bool]] = []

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                requests.append(
                    (self.path, self.headers.get("Coder-Session-Token") == TOKEN)
                )
                self.send_response(status if self.path == "/api/v2/templates" else 200)
                if location:
                    self.send_header("Location", location)
                self.end_headers()
                self.wfile.write(b"[]" if status == 200 else TOKEN.encode())

            def log_message(self, format: str, *args: object) -> None:
                return

        server = HTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()

        def stop() -> None:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

        self.addCleanup(stop)
        return f"http://127.0.0.1:{server.server_port}", requests

    def run_client(self, url: str, script: str) -> subprocess.CompletedProcess[str]:
        arguments = (
            ["--repo-url", "https://example.invalid/repo.git"]
            if script == "templates_push.py"
            else []
        )
        return subprocess.run(
            [sys.executable, str(self.root / "scripts" / script), *arguments],
            cwd=self.root,
            env={**self.env, "CODER_URL": url},
            text=True,
            capture_output=True,
            timeout=15,
            check=False,
        )

    def assert_failure(self, result: subprocess.CompletedProcess[str]) -> None:
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr, FAILURE)
        self.assertEqual(result.stdout, "")
        self.assertNotIn(TOKEN, result.stdout + result.stderr)

    def test_cross_origin_redirect_never_requests_destination(self) -> None:
        destination, received = self.server()
        for status in (301, 302, 303, 307, 308):
            source, sent = self.server(status, f"{destination}/target?{TOKEN}")
            for script in ("templates_push.py", "template_vars.py"):
                with self.subTest(status=status, script=script):
                    self.assert_failure(self.run_client(source, script))
                    self.assertEqual(received, [])
            self.assertEqual(sent, [("/api/v2/templates", True)] * 2)

    def test_same_origin_redirect_never_requests_destination(self) -> None:
        for status in (301, 302, 303, 307, 308):
            source, sent = self.server(status, f"/target?{TOKEN}")
            for script in ("templates_push.py", "template_vars.py"):
                with self.subTest(status=status, script=script):
                    self.assert_failure(self.run_client(source, script))
            self.assertEqual(sent, [("/api/v2/templates", True)] * 2)

    def test_direct_authenticated_success(self) -> None:
        source, sent = self.server()
        for script in ("templates_push.py", "template_vars.py"):
            with self.subTest(script=script):
                result = self.run_client(source, script)
                self.assertEqual(result.returncode, 0)
                self.assertIn("0 selected template(s)", result.stdout)
                self.assertEqual(result.stderr, "")
                self.assertNotIn(TOKEN, result.stdout)
        self.assertEqual(sent, [("/api/v2/templates", True)] * 2)

    def test_authentication_errors_remain_sanitized(self) -> None:
        for status in (401, 403):
            source, sent = self.server(status)
            for script in ("templates_push.py", "template_vars.py"):
                with self.subTest(status=status, script=script):
                    self.assert_failure(self.run_client(source, script))
            self.assertEqual(sent, [("/api/v2/templates", True)] * 2)


class BackendWorkflowTest(unittest.TestCase):
    def test_backend_paths_trigger_both_events_but_omnigent_tests_do_not(self) -> None:
        workflow = yaml.load(
            (ROOT / ".github/workflows/backends-check.yml").read_text(),
            Loader=yaml.BaseLoader,
        )
        included = (
            "workspace/backend-connection.schema.json",
            "workspace/catalog.yaml",
            "coder/templates/generic-linux-azure/main.tf",
            "coder/templates/generic-linux-azure/mount-home.sh",
            "scripts/doctor_azure.py",
            "scripts/doctor-azure.sh",
            "scripts/backend_templates.py",
            "scripts/templates_push.py",
            "scripts/template_vars.py",
            "scripts/verify-template-vars.sh",
            "scripts/requirements-backends.txt",
            "scripts/requirements-template-publishing.txt",
            "tests/test_template_vars.py",
            "tests/test_templates_push.py",
            "tests/fixtures/backends/azure-enabled.yaml",
            "tests/fixtures/doctor-azure/enabled.yaml",
            "Makefile",
            ".github/workflows/backends-check.yml",
        )
        excluded = ("tests/test_omnigent.py", "tests/coder-omnigent-launch.py")
        self.assertEqual(
            workflow["on"]["pull_request"]["paths"], workflow["on"]["push"]["paths"]
        )
        for event in ("pull_request", "push"):
            paths = workflow["on"][event]["paths"]
            for name in included:
                with self.subTest(event=event, name=name):
                    self.assertTrue((ROOT / name).is_file())
                    self.assertTrue(any(fnmatchcase(name, path) for path in paths))
            for name in excluded:
                with self.subTest(event=event, name=name):
                    self.assertFalse(any(fnmatchcase(name, path) for path in paths))
