"""Run in the pinned workspace image; use real native plugin source and HTTP."""

import ctypes
import hashlib
import http.client
import importlib.util
import json
import os
import select
import signal
import socket
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import ClassVar

from omnigent.harnesses.opencode_native.bridge import write_opencode_policy_plugin
from omnigent.harnesses.opencode_native.provider import maybe_merge_user_provider_config
from omnigent.onboarding.opencode_auth import OpenCodeAuthSummary

spec = importlib.util.spec_from_file_location("launch", "/opt/cade/omnigent-launch.py")
launch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launch)
spec = importlib.util.spec_from_file_location("relay", "/opt/cade/omnigent-relay.py")
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)


class Endpoint(BaseHTTPRequestHandler):
    status = 200
    count = 0
    directory = ""
    verdict: ClassVar[dict[str, str]] = {"result": "POLICY_ACTION_ALLOW"}
    mcp = "connected"
    docs: ClassVar[str | None] = "connected"
    delay = 0.0
    paths: ClassVar[list[str]] = []

    def do_GET(self) -> None:
        type(self).paths.append(self.path)
        if self.path == "/api/model":
            time.sleep(self.delay)
        type(self).count += 1
        type(self).directory = self.headers.get("x-opencode-directory")
        self.send_response(
            503 if self.count == 1 and self.status == 200 else self.status
        )
        self.end_headers()
        body = (
            {
                "data": [{"name": "omnigent", "status": {"status": self.mcp}}]
                + (
                    [{"name": "devenv-docs", "status": {"status": self.docs}}]
                    if self.docs
                    else []
                )
            }
            if self.path == "/api/mcp"
            else []
        )
        self.wfile.write(json.dumps(body).encode())

    def do_POST(self) -> None:
        type(self).count += 1
        self.rfile.read(int(self.headers["Content-Length"]))
        self.send_response(self.status)
        self.end_headers()
        self.wfile.write(json.dumps(self.verdict).encode())

    def log_message(self, *_args: object) -> None:
        return


class NativeLaunch(unittest.TestCase):
    def setUp(self) -> None:
        self.environment = dict(os.environ)
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        os.environ["OMNIGENT_RELAY_FILE"] = str(self.root / "tool_relay.json")
        os.environ["OMNIGENT_POLICY_URL"] = "http://127.0.0.1:1"
        os.environ["OMNIGENT_SESSION_ID"] = "disposable-policy-test"
        os.environ["XDG_CONFIG_HOME"] = str(self.root / "xdg")
        self.config = self.root / "xdg/opencode/opencode.json"
        self.config.parent.mkdir(parents=True)
        self.config.write_text(
            json.dumps({"mcp": {"servers": {"omnigent": {}, "devenv-docs": {}}}})
        )
        self.server = HTTPServer(("127.0.0.1", 0), Endpoint)
        Endpoint.count = 0
        Endpoint.status = 200
        Endpoint.verdict = {"result": "POLICY_ACTION_ALLOW"}
        Endpoint.mcp = "connected"
        Endpoint.docs = "connected"
        Endpoint.delay = 0.0
        Endpoint.paths = []
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        self.temp.cleanup()
        os.environ.clear()
        os.environ.update(self.environment)

    def plugin_call(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "node",
                "--input-type=module",
                "-e",
                """
const plugin = (await import(process.argv[1])).default;
const hooks = {};
await plugin.setup({session:{hook:async (_, f)=>{hooks.prompt=f}},tool:{hook:async (_,f)=>{hooks.tool=f}}});
let blocked = false;
try { await hooks.prompt({prompt:{text:'disposable'}}) } catch { blocked = true }
const result = {status:'completed', tool:'read', result:{content:'disposable output'}};
await hooks.tool(result);
console.log(JSON.stringify({blocked, output:result.result.content}));
""",
                str(self.root / "omnigent-policy/server.js"),
            ],
            capture_output=True,
            text=True,
            timeout=15,
            check=True,
        )

    def test_generated_policy_transport_and_failures(self) -> None:
        write_opencode_policy_plugin(self.root)
        launch.fail_closed()
        plugin = self.root / "omnigent-policy/server.js"
        corrected = plugin.read_text()
        launch.fail_closed()
        self.assertEqual(plugin.read_text(), corrected)
        self.assertNotIn('return { result: "ALLOW" }', corrected)
        relay = self.root / "tool_relay.json"
        relay.write_text(
            json.dumps(
                {
                    "url": f"http://127.0.0.1:{self.server.server_port}",
                    "token": "synthetic",
                }
            )
        )
        allowed = json.loads(self.plugin_call().stdout)
        self.assertFalse(allowed["blocked"])
        self.assertEqual(allowed["output"], "disposable output")
        Endpoint.verdict = {"result": "POLICY_ACTION_DENY", "reason": "test denial"}
        denied = json.loads(self.plugin_call().stdout)
        self.assertTrue(denied["blocked"])
        self.assertIn("withheld", denied["output"])
        self.assertIn("test denial", denied["output"])
        Endpoint.verdict = {"result": "POLICY_ACTION_ASK", "reason": "needs approval"}
        unresolved = json.loads(self.plugin_call().stdout)
        self.assertTrue(unresolved["blocked"])
        self.assertIn("withheld", unresolved["output"])
        self.assertNotIn("disposable output", unresolved["output"])
        Endpoint.status = 503
        unavailable = json.loads(self.plugin_call().stdout)
        self.assertTrue(unavailable["blocked"])
        self.assertIn("policy relay unavailable", unavailable["output"])
        Endpoint.status = 200
        Endpoint.verdict = {}
        malformed = json.loads(self.plugin_call().stdout)
        self.assertTrue(malformed["blocked"])
        self.assertIn("withheld", malformed["output"])
        relay.write_text(
            json.dumps({"url": "http://127.0.0.1:1", "token": "synthetic"})
        )
        disconnected = json.loads(self.plugin_call().stdout)
        self.assertTrue(disconnected["blocked"])
        self.assertIn("withheld", disconnected["output"])
        self.assertEqual(Endpoint.count, 10)

    def test_previous_policy_correction_upgrades_idempotently(self) -> None:
        write_opencode_policy_plugin(self.root)
        plugin = self.root / "omnigent-policy/server.js"
        # Reconstruct the exact deployed correction, not the current implementation.
        previous = (
            plugin.read_text()
            .replace(
                '{ result: "ALLOW" }',
                '{ result: "POLICY_ACTION_DENY", reason: "policy relay unavailable" }',
            )
            .replace(
                "// Unwired (no server/session) or any transport failure allows: fail open.",
                "// CADE: missing configuration or a failed policy transport denies.",
            )
            .replace(
                'body && typeof body === "object"',
                'body && ["POLICY_ACTION_ALLOW", "POLICY_ACTION_DENY", "POLICY_ACTION_ASK"].includes(body.result)',
            )
        )
        evaluate = previous[
            previous.index("async function evaluate(") : previous.index(
                "function resultText("
            )
        ]
        self.assertEqual(
            hashlib.sha256(evaluate.encode()).hexdigest(),
            "4432ea74ceb9b6c0ba1f1e108ca2b3361b894e1be86b78af0335b55e404609ba",
        )
        plugin.write_text(previous)
        launch.fail_closed()
        corrected = plugin.read_text()
        self.assertNotEqual(corrected, previous)
        launch.fail_closed()
        self.assertEqual(plugin.read_text(), corrected)
        changed = corrected.replace(
            'reason: "policy relay unavailable"', 'reason: "changed"', 1
        )
        plugin.write_text(changed)
        with self.assertRaisesRegex(RuntimeError, "refusing unsafe launch"):
            launch.fail_closed()
        self.assertEqual(plugin.read_text(), changed)
        plugin.write_text(corrected)
        (self.root / "tool_relay.json").write_text(
            json.dumps(
                {
                    "url": f"http://127.0.0.1:{self.server.server_port}",
                    "token": "synthetic",
                }
            )
        )
        Endpoint.verdict = {"result": "POLICY_ACTION_ASK"}
        unresolved = json.loads(self.plugin_call().stdout)
        self.assertTrue(unresolved["blocked"])
        self.assertIn("withheld", unresolved["output"])
        Endpoint.verdict = {"result": "POLICY_ACTION_ALLOW"}
        allowed = json.loads(self.plugin_call().stdout)
        self.assertFalse(allowed["blocked"])
        self.assertEqual(allowed["output"], "disposable output")

    def test_unsafe_launch_rejected(self) -> None:
        os.environ.pop("CADE_OMNIGENT_PARENT_NETNS", None)
        with self.assertRaisesRegex(RuntimeError, "separate SRT namespace"):
            launch.run(["--version"], inside=True)
        os.environ["CADE_OMNIGENT_PARENT_NETNS"] = os.readlink("/proc/self/ns/net")
        with self.assertRaisesRegex(RuntimeError, "separate SRT namespace"):
            launch.run(["--version"], inside=True)
        for args in (["serve", "--port"], ["--server"]):
            with self.assertRaisesRegex(ValueError, "missing native server"):
                launch.run(args, inside=False)
        del os.environ["OMNIGENT_RELAY_FILE"]
        with self.assertRaisesRegex(RuntimeError, "configuration missing"):
            launch.fail_closed()
        os.environ["OMNIGENT_RELAY_FILE"] = str(self.root / "tool_relay.json")
        write_opencode_policy_plugin(self.root)
        plugin = self.root / "omnigent-policy/server.js"
        original = plugin.read_text()
        plugin.write_text(
            original.replace('return { result: "ALLOW" }', "return {}", 1)
        )
        with self.assertRaisesRegex(RuntimeError, "refusing unsafe launch"):
            launch.fail_closed()
        self.assertNotIn("policy relay unavailable", plugin.read_text())
        for url in (
            "http://example.com:28700",
            "https://127.0.0.1:28700",
            "http://127.0.0.1:65536",
        ):
            with self.assertRaises(ValueError):
                launch.loopback_port(url)

    def test_scoped_unix_relay(self) -> None:
        path = str(self.root / "relay.sock")
        server = relay.Relay(path, self.server.server_port)
        thread = threading.Thread(target=server.serve_forever)
        thread.start()

        def call(route: str, body: dict[str, object]) -> tuple[int, dict[str, object]]:
            connection = http.client.HTTPConnection("localhost", timeout=2)
            connection.sock = socket.socket(socket.AF_UNIX)
            connection.sock.settimeout(2)
            connection.sock.connect(path)
            try:
                connection.request(
                    "POST",
                    route,
                    json.dumps(body),
                    {"Content-Type": "application/json"},
                )
                response = connection.getresponse()
                return response.status, json.loads(response.read())
            finally:
                connection.close()

        try:
            for name in (
                "sys_os_shell",
                "sys_os_write",
                "sys_terminal_launch",
                "sys_call_async",
                "sys_session_create",
                None,
                ["sys_os_shell"],
            ):
                status, result = call("/tool", {"name": name, "arguments": {}})
                self.assertEqual(status, 200)
                self.assertTrue(result["isError"])
            self.assertEqual(Endpoint.count, 0)
            status, result = call("/tool", {"name": "list_comments", "arguments": {}})
            self.assertEqual(status, 200)
            self.assertEqual(result["result"], "POLICY_ACTION_ALLOW")
            self.assertEqual(Endpoint.count, 1)
            Endpoint.status = 503
            status, result = call("/policies/evaluate", {"event": {}})
            self.assertEqual(status, 200)
            self.assertEqual(result["result"], "POLICY_ACTION_DENY")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

    def test_location_readiness_and_rejection(self) -> None:
        process = subprocess.Popen(["python3", "-c", "import time; time.sleep(60)"])
        try:
            launch.wait_location(process, self.server.server_port, timeout=2)
            self.assertEqual(Endpoint.count, 3)
            self.assertEqual(urllib.parse.unquote(Endpoint.directory), os.getcwd())
            Endpoint.docs = None
            with self.assertRaisesRegex(RuntimeError, "deadline"):
                launch.wait_location(process, self.server.server_port, timeout=0.3)
            Endpoint.docs = "failed"
            with self.assertRaisesRegex(RuntimeError, "required native MCP failed"):
                launch.wait_location(process, self.server.server_port, timeout=2)
            self.config.write_text(json.dumps({"mcp": {"servers": {"omnigent": {}}}}))
            Endpoint.docs = None
            launch.wait_location(process, self.server.server_port, timeout=2)
            self.assertEqual(launch.expected_mcp(), {"omnigent"})
            Endpoint.mcp = "failed"
            with self.assertRaisesRegex(RuntimeError, "required native MCP failed"):
                launch.wait_location(process, self.server.server_port, timeout=2)
            Endpoint.status = 401
            with self.assertRaisesRegex(RuntimeError, "HTTP 401"):
                launch.wait_location(process, self.server.server_port, timeout=2)
            Endpoint.status = 503
            with self.assertRaisesRegex(RuntimeError, "deadline"):
                launch.wait_location(process, self.server.server_port, timeout=0.3)
            self.assertGreaterEqual(Endpoint.count, 7)
        finally:
            launch.stop(process)
        self.assertIsNotNone(process.returncode)

    def test_stock_seed_and_custom_preservation(self) -> None:
        os.environ["HOME"] = str(self.root / "home")
        os.environ.pop("XDG_CONFIG_HOME", None)
        directory = Path.home() / ".config/opencode"
        directory.mkdir(parents=True)
        path = directory / "opencode.jsonc"
        docs = {"devenv-docs": {"type": "local", "command": ["python3"], "cwd": "/tmp"}}
        stock = '{\n  "$schema": "https://opencode.ai/config.json",\n  "model": "opencode/big-pickle"\n}\n'
        for initial in (None, stock):
            path.unlink(missing_ok=True)
            if initial:
                path.write_text(initial)
            subprocess.run(
                ["python3", "/opt/cade/omnigent-seed.py", json.dumps(docs)],
                check=True,
                timeout=5,
            )
            merged = maybe_merge_user_provider_config(
                {"mcp": {"servers": {"omnigent": {"type": "local"}}}}
            )
            self.assertEqual(set(merged["mcp"]["servers"]), {"omnigent", "devenv-docs"})
            self.assertEqual(merged["model"], "opencode/big-pickle")
        for custom in (
            stock.replace("big-pickle", "custom"),
            "// customized\n" + stock,
            stock.replace(
                '"model":',
                '"providers": {"private": {"settings": {"apiKey": "synthetic"}}}, "model":',
            ),
        ):
            path.write_text(custom)
            subprocess.run(
                ["python3", "/opt/cade/omnigent-seed.py", json.dumps(docs)],
                check=True,
                timeout=5,
            )
            self.assertEqual(path.read_text(), custom)
            self.assertNotIn("devenv-docs", path.read_text())
        path.write_text(stock)
        subprocess.run(
            ["python3", "/opt/cade/omnigent-seed.py", "{}"], check=True, timeout=5
        )
        self.assertEqual(path.read_text(), stock)

    def test_bridge_listener_and_poststart_death(self) -> None:
        path = str(self.root / "listener.sock")
        server = launch.socat(f"UNIX-LISTEN:{path},fork", "EXEC:cat")
        owner = subprocess.Popen(["python3", "-c", "import time; time.sleep(60)"])
        try:
            launch.wait_listener([server], path)
            self.assertTrue(Path(path).is_socket())
            launch.stop(server)
            with self.assertRaisesRegex(RuntimeError, "bridge process exited"):
                launch.supervise(owner, [server])
        finally:
            launch.stop(owner)
            launch.stop(server)
        self.assertIsNotNone(owner.returncode)
        failed = launch.socat(
            f"UNIX-LISTEN:{self.root}/missing/listener.sock", "EXEC:cat"
        )
        try:
            with self.assertRaisesRegex(RuntimeError, "bridge process exited"):
                launch.wait_listener([failed], str(self.root / "missing/listener.sock"))
        finally:
            launch.stop(failed)
        self.assertNotEqual(failed.returncode, 0)

    def test_group_cleanup_ownership_and_exited_leaders(self) -> None:
        # Adopt orphan descendants so this real-process regression reaps its children.
        libc = ctypes.CDLL(None, use_errno=True)
        previous = ctypes.c_int()
        self.assertEqual(libc.prctl(37, ctypes.byref(previous), 0, 0, 0), 0)
        self.assertEqual(libc.prctl(36, 1, 0, 0, 0), 0)
        try:
            for owned, exited, stubborn in (
                (True, False, False),
                (True, True, False),
                (True, False, True),
                (False, False, False),
            ):
                with self.subTest(owned=owned, leader_exited=exited, stubborn=stubborn):
                    child = None
                    reaped = False
                    marker = self.root / f"child-{owned}-{exited}-{stubborn}"
                    command = [
                        "python3",
                        "-c",
                        "import os,signal,time\n"
                        "from pathlib import Path\n"
                        f"if {stubborn!r}: signal.signal(signal.SIGTERM,signal.SIG_IGN)\n"
                        "child=os.fork()\n"
                        "if child == 0:\n"
                        f" signal.signal(signal.SIGTERM,signal.SIG_IGN if {owned!r} else signal.SIG_DFL)\n"
                        f" marker=Path({str(marker)!r})\n"
                        " marker.with_suffix('.ready').write_text(str(os.getpid()))\n"
                        " marker.with_suffix('.ready').rename(marker)\n"
                        " while True: time.sleep(1)\n"
                        f"if {exited!r}: raise SystemExit(0)\n"
                        "while True: time.sleep(1)\n",
                    ]
                    process = (
                        launch.OwnedProcess(command)
                        if owned
                        else subprocess.Popen(command, start_new_session=True)
                    )
                    try:
                        deadline = time.monotonic() + 5
                        while not marker.exists() and time.monotonic() < deadline:
                            time.sleep(0.01)
                        self.assertTrue(marker.exists())
                        child = int(marker.read_text())
                        self.assertEqual(os.getpgid(child), process.pid)
                        if exited:
                            while (
                                process.poll() is None and time.monotonic() < deadline
                            ):
                                time.sleep(0.01)
                            self.assertEqual(process.poll(), 0)
                            self.assertEqual(launch.supervise(process, []), 0)
                            # The leader has not been reaped or made reusable.
                            self.assertIsNone(process.returncode)
                        started = time.monotonic()
                        launch.stop(process)
                        self.assertLess(time.monotonic() - started, 6)
                        self.assertIsNotNone(process.returncode)
                        self.assertEqual(
                            process.returncode,
                            0
                            if exited
                            else -signal.SIGKILL
                            if stubborn
                            else -signal.SIGTERM,
                        )
                        if not owned:
                            os.kill(child, 0)
                            self.assertNotEqual(
                                Path(f"/proc/{child}/stat").read_text().split()[2], "Z"
                            )
                            continue
                        deadline = time.monotonic() + 2
                        status = (0, 0)
                        while status[0] == 0 and time.monotonic() < deadline:
                            status = os.waitpid(child, os.WNOHANG)
                            time.sleep(0.01)
                        reaped = status[0] == child
                        self.assertEqual(status[0], child)
                        self.assertTrue(os.WIFSIGNALED(status[1]))
                        self.assertEqual(os.WTERMSIG(status[1]), signal.SIGKILL)
                        # A repeated stop must not signal a reused ID.
                        launch.stop(process)
                    finally:
                        # Independent cleanup must work even when stop() is the failure.
                        if process.returncode is None:
                            process.kill()
                        process.wait(timeout=5)
                        if marker.exists() and child is None:
                            child = int(marker.read_text())
                        if child is not None and not reaped:
                            status = os.waitpid(child, os.WNOHANG)
                            if status[0] == 0:
                                os.kill(child, signal.SIGKILL)
                                os.waitpid(child, 0)
        finally:
            self.assertEqual(libc.prctl(36, previous.value, 0, 0, 0), 0)

    def test_relay_death_terminates_owning_launch(self) -> None:
        driver = self.root / "driver.py"
        driver.write_text("""import importlib.util,os,subprocess,sys
from pathlib import Path
spec=importlib.util.spec_from_file_location("launch","/opt/cade/omnigent-launch.py")
launch=importlib.util.module_from_spec(spec); spec.loader.exec_module(launch)
path=Path(launch.socket_path(28700,"relay")); path.parent.mkdir(mode=0o700,exist_ok=True)
relay=subprocess.Popen(["python3","/opt/cade/omnigent-relay.py","28700"])
owner=subprocess.Popen(["python3","-c","import time; time.sleep(60)"])
try:
 launch.wait_listener([relay],str(path))
 print(owner.pid,relay.pid,flush=True)
 launch.supervise(owner,[relay])
finally:
 launch.stop(owner); launch.stop(relay)
""")
        driver_process = subprocess.Popen(
            ["python3", str(driver)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            self.assertTrue(select.select([driver_process.stdout], [], [], 5)[0])
            owner, relay = map(int, driver_process.stdout.readline().split())
            os.kill(relay, signal.SIGTERM)
            _, error = driver_process.communicate(timeout=10)
            self.assertNotEqual(driver_process.returncode, 0)
            self.assertIn("required native bridge process exited", error)
            with self.assertRaises(ProcessLookupError):
                os.kill(owner, 0)
        finally:
            launch.stop(driver_process)

    def test_free_model_needs_no_dummy_credential(self) -> None:
        summary = OpenCodeAuthSummary(
            installed=True, stored_providers=(), env_providers=()
        )
        self.assertTrue(summary.ready)
        self.assertFalse(summary.has_provider)

    def test_exact_version_probe_uses_real_pinned_cli(self) -> None:
        result = subprocess.run(
            ["python3", "/opt/cade/omnigent-launch.py", "--version"],
            check=True,
            capture_output=True,
            text=True,
            timeout=7,
        )
        self.assertEqual(result.stdout.strip(), "opencode v2.0.32")
        self.assertEqual(result.stderr, "")
        with self.assertRaisesRegex(ValueError, "missing native server"):
            launch.run(["--version", "--server"], inside=False)

    def test_provisioning_failure_stops_startup(self) -> None:
        for template in ("docker", "agent"):
            source = Path(f"/tmp/{template}.tf").read_text()
            start = source.index("docs_mcp='{}'")
            end = source.index("fi\n", start) + 3
            block = source[start:end].replace("${local.workspace_dir}", str(self.root))
            directory = self.root / "mcp/docs-server"
            directory.mkdir(parents=True, exist_ok=True)
            failed = subprocess.run(
                ["sh", "-ec", block + "\necho HOST_START_MUST_NOT_RUN"],
                check=False,
                capture_output=True,
                text=True,
                timeout=15,
            )
            self.assertNotEqual(failed.returncode, 0)
            self.assertNotIn("HOST_START_MUST_NOT_RUN", failed.stdout)
            directory.rmdir()
            blank = subprocess.run(
                ["sh", "-ec", block + '\nprintf "%s" "$docs_mcp"'],
                capture_output=True,
                text=True,
                timeout=15,
                check=True,
            )
            self.assertEqual(json.loads(blank.stdout), {})
            self.assertEqual(blank.stderr, "")

    def test_requested_registration_failure_stops_startup(self) -> None:
        for template in ("docker", "agent"):
            source = Path(f"/tmp/{template}.tf").read_text()
            start = source.index('if [ -n "$${OMNIGENT_ADMIN_PASSWORD}" ]')
            end = source.index(
                "OMNIGENT_LOGIN_PY\n", source.index('print(f"omnigent:', start)
            ) + len("OMNIGENT_LOGIN_PY\n")
            login = (
                source[start:end].replace("$${", "${") + "\necho LOGIN_CONTINUED\nfi"
            )
            environment = {
                **os.environ,
                "OMNIGENT_ADMIN_PASSWORD": "synthetic",
                "OMNIGENT_ADMIN_USERNAME": "synthetic",
                "OMNIGENT_SERVER_URL": f"http://127.0.0.1:{self.server.server_port}",
            }
            Endpoint.status = 503
            failed = subprocess.run(
                ["sh", "-ec", login],
                check=False,
                env=environment,
                capture_output=True,
                text=True,
                timeout=15,
            )
            self.assertNotEqual(failed.returncode, 0)
            self.assertNotIn("LOGIN_CONTINUED", failed.stdout)
            environment["OMNIGENT_ADMIN_PASSWORD"] = ""
            skipped = subprocess.run(
                ["sh", "-ec", login],
                env=environment,
                capture_output=True,
                text=True,
                check=True,
                timeout=5,
            )
            self.assertEqual(skipped.stdout, "")
            self.assertEqual(skipped.stderr, "")
            line = next(
                line.strip()
                for line in source.splitlines()
                if 'omnigent host "$${OMNIGENT_SERVER_URL}" --background' in line
            )
            # This subprocess fixture targets the shell's failure propagation, not native E2E.
            failed = subprocess.run(
                [
                    "sh",
                    "-ec",
                    "omnigent() { return 23; }; "
                    + line.replace("$${", "${").replace(
                        "/tmp/omnigent-host.log", str(self.root / "host.log")
                    )
                    + "\necho HOST_CONTINUED",
                ],
                check=False,
                env=environment,
                capture_output=True,
                text=True,
                timeout=5,
            )
            self.assertEqual(failed.returncode, 23)
            self.assertNotIn("HOST_CONTINUED", failed.stdout)


if __name__ == "__main__":
    unittest.main()
