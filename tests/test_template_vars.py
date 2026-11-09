#!/usr/bin/env python3
"""Exercise the real Make target and verifier against an isolated Coder API fixture."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


ROOT = Path(__file__).resolve().parents[1]
DEFAULTS = {
    "docker-workspace": {
        "docker_socket": "",
        "workspace_image": "cade/coder-workspace:latest",
        "temporal_ui_public_url": "http://localhost:8088",
        "nodered_icon": "https://cdn.simpleicons.org/nodered",
        "omnigent_server_url": "http://omnigent-server:8000",
        "omnigent_public_url": "http://localhost:8000",
        "omnigent_sandbox_mode": "srt",
    },
    "embedded-linux": {
        "docker_socket": "",
        "workspace_image": "cade/embedded-linux-workspace:latest",
    },
    "devcontainer": {
        "docker_socket": "",
        "repo_url": "",
        "bootstrap_image": "cade/devcontainer-bootstrap:latest",
        "default_devcontainer_image": "mcr.microsoft.com/devcontainers/base:ubuntu",
    },
    "agent-workspace": {
        "docker_socket": "",
        "workspace_image": "cade/agent-workspace:latest",
        "omnigent_server_url": "http://omnigent-server:8000",
        "omnigent_public_url": "http://localhost:8000",
        "omnigent_sandbox_mode": "srt",
    },
}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get("Coder-Session-Token") != "fixture-token":
            self.send_error(401)
            return
        if self.server.fail and (
            self.server.fail == "all" or self.server.fail in self.path
        ):
            self.send_error(500)
            return
        if self.path == "/api/v2/templates":
            data = [
                {"name": name, "active_version_id": name} for name in self.server.values
            ]
        elif self.path.startswith("/api/v2/templateversions/") and self.path.endswith(
            "/variables"
        ):
            name = self.path.split("/")[4]
            if name not in self.server.values:
                self.send_error(404)
                return
            data = [
                {"name": key, "value": value}
                for key, value in self.server.values[name].items()
            ]
        else:
            self.send_error(404)
            return
        payload = json.dumps(data).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format, *args):
        pass


class TemplateVarsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cade-template-vars-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        (self.root / "coder").mkdir()
        shutil.copy(ROOT / "Makefile", self.root / "Makefile")
        shutil.copy(ROOT / "scripts/verify-template-vars.sh", self.root / "scripts")
        for name in DEFAULTS:
            target = self.root / "coder/templates" / name
            target.mkdir(parents=True)
            shutil.copy(ROOT / "coder/templates" / name / "variables.tf", target)
        # Port 0 atomically checks and reserves an unused loopback port before serving.
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.values = {name: values.copy() for name, values in DEFAULTS.items()}
        self.server.fail = ""
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)
        self.env = {
            "PATH": os.environ["PATH"],
            "HOME": str(self.root),
            "CODER_URL": f"http://127.0.0.1:{self.server.server_port}",
            "CODER_SESSION_TOKEN": "fixture-token",
        }

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)

    def run_command(self, *args, env=None):
        return subprocess.run(
            args,
            cwd=self.root,
            env=env or self.env,
            text=True,
            capture_output=True,
            timeout=15,
            check=False,
        )

    def test_coder_url_precedence_and_fallback(self):
        fixture = self.env["CODER_URL"]
        fallback = "http://localhost:7080"
        binpath = self.root / "bin"
        binpath.mkdir()
        curl = binpath / "curl"
        # Record the selected URL while keeping fallback traffic off the real stack.
        curl.write_text(
            "#!/usr/bin/env bash\n"
            'printf "%s\\n" "${@: -1}" >> "$CURL_URL_LOG"\n'
            'exec "$REAL_CURL" --connect-to "$CURL_CONNECT_TO" "$@"\n',
            encoding="utf-8",
        )
        curl.chmod(0o755)
        scenarios = [
            (f"CODER_URL={fixture}\n", None, fixture),
            (f"CODER_URL={fixture}\n", "", fixture),
            ("CODER_URL=http://unused.invalid\n", fixture, fixture),
            ("CODER_URL=\n", None, fallback),
            ("CODER_URL=\n", "", fallback),
            ("# No URL setting\n", None, fallback),
            (None, None, fallback),
            (None, "", fallback),
        ]
        for contents, exported, expected in scenarios:
            with self.subTest(file=contents, environment=exported):
                envfile = self.root / ".env"
                if contents is None:
                    envfile.unlink(missing_ok=True)
                else:
                    envfile.write_text(contents, encoding="utf-8")
                env = self.env.copy()
                env.pop("CODER_URL")
                if exported is not None:
                    env["CODER_URL"] = exported
                log = self.root / "curl-urls"
                log.unlink(missing_ok=True)
                env.update(
                    PATH=f"{binpath}:{env['PATH']}",
                    REAL_CURL=shutil.which("curl"),
                    CURL_CONNECT_TO=f"localhost:7080:127.0.0.1:{self.server.server_port}",
                    CURL_URL_LOG=str(log),
                )
                result = self.run_command(
                    "bash", "scripts/verify-template-vars.sh", env=env
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("PASS  repo_url", result.stdout)
                self.assertEqual(
                    log.read_text(encoding="utf-8").splitlines(),
                    [
                        f"{expected}/api/v2/{path}"
                        for name in DEFAULTS
                        for path in (
                            "templates",
                            f"templateversions/{name}/variables",
                        )
                    ],
                )

    def test_slug_precedence_and_push_recipe(self):
        scenarios = [
            (None, None, None, "tbrandenburg/cade"),
            ("file/project", None, None, "file/project"),
            ("file/project", "env/project", None, "env/project"),
            ("file/project", "env/project", "cli/project", "cli/project"),
            ("", None, None, "tbrandenburg/cade"),
        ]
        for file_slug, env_slug, cli_slug, expected in scenarios:
            with self.subTest(
                file=file_slug, environment=env_slug, command_line=cli_slug
            ):
                envfile = self.root / ".env"
                if file_slug is None:
                    envfile.unlink(missing_ok=True)
                else:
                    envfile.write_text(f"REPO_SLUG={file_slug}\n", encoding="utf-8")
                env = self.env.copy()
                if env_slug is not None:
                    env["REPO_SLUG"] = env_slug
                url = f"https://github.com/{expected}.git"
                self.server.values["devcontainer"]["repo_url"] = url
                cli = [f"REPO_SLUG={cli_slug}"] if cli_slug is not None else []
                result = self.run_command(
                    "make", "templates-verify-vars", *cli, env=env
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("PASS  repo_url", result.stdout)
                push = self.run_command(
                    "make",
                    "-n",
                    "-o",
                    "embedded-workspace-build",
                    "-o",
                    "devcontainer-workspace-build",
                    "-o",
                    "agent-workspace-build",
                    "templates-push",
                    *cli,
                    env=env,
                )
                self.assertEqual(push.returncode, 0, push.stderr)
                self.assertEqual(push.stdout.count(f"repo_url={url}"), 4, push.stdout)

    def test_mismatch_and_unrelated_drift(self):
        expected = "https://github.com/tbrandenburg/cade.git"
        for value in ("", "https://github.com/other/project.git"):
            with self.subTest(value=value):
                self.server.values["devcontainer"]["repo_url"] = value
                result = self.run_command("make", "templates-verify-vars")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"expected publish value='{expected}'", result.stdout)
        self.server.values["devcontainer"]["repo_url"] = expected
        self.server.values["embedded-linux"]["workspace_image"] = "wrong"
        result = self.run_command("make", "templates-verify-vars")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DRIFT workspace_image", result.stdout)
        self.assertIn("PASS  repo_url", result.stdout)
        self.server.values["embedded-linux"]["workspace_image"] = DEFAULTS[
            "embedded-linux"
        ]["workspace_image"]
        self.server.values["devcontainer"]["bootstrap_image"] = "wrong"
        result = self.run_command("make", "templates-verify-vars")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DRIFT bootstrap_image", result.stdout)

    def test_standalone_blank_default(self):
        result = self.run_command("bash", "scripts/verify-template-vars.sh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS  repo_url", result.stdout)
        self.server.values["devcontainer"]["repo_url"] = (
            "https://github.com/example/fork.git"
        )
        result = self.run_command("bash", "scripts/verify-template-vars.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(".tf default=''", result.stdout)

    def test_missing_and_error_inputs(self):
        result = self.run_command(
            "bash", "scripts/verify-template-vars.sh", "--expected-repo-url", ""
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("Usage:", result.stderr)
        result = self.run_command(
            "bash", "scripts/verify-template-vars.sh", "--expected-repo-url"
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("Usage:", result.stderr)
        del self.server.values["devcontainer"]["repo_url"]
        result = self.run_command("make", "templates-verify-vars")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DRIFT repo_url: missing", result.stdout)
        del self.server.values["devcontainer"]
        result = self.run_command("make", "templates-verify-vars")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not resolve active_version_id", result.stdout)
        self.server.fail = "all"
        result = self.run_command("make", "templates-verify-vars")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Error", result.stderr)
        self.server.values["devcontainer"] = DEFAULTS["devcontainer"].copy()
        self.server.fail = "/variables"
        result = self.run_command("make", "templates-verify-vars")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Error", result.stderr)
        env = self.env.copy()
        del env["CODER_SESSION_TOKEN"]
        result = self.run_command("bash", "scripts/verify-template-vars.sh", env=env)
        self.assertEqual(result.returncode, 0)
        self.assertIn("SKIP: no Coder session token", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
