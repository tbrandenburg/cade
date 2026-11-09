"""Bridge the pinned native harness across SRT without granting network egress."""

import hashlib
import json
import os
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable
from pathlib import Path

CLI = "/usr/local/bin/opencode"


class OwnedProcess(subprocess.Popen[bytes]):
    """Keep the session leader waitable; only stop() may reap this child."""

    def __init__(
        self, command: list[str], *, env: dict[str, str] | None = None
    ) -> None:
        super().__init__(command, env=env, start_new_session=True)

    def poll(self) -> int | None:
        if self.returncode is not None:
            return self.returncode
        status = os.waitid(os.P_PID, self.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
        if status is None:
            return None
        return (
            status.si_status if status.si_code == os.CLD_EXITED else -status.si_status
        )


def loopback_port(url: str) -> int:
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "http" or parsed.hostname != "127.0.0.1" or not parsed.port:
        raise ValueError("native bridge requires an HTTP loopback endpoint")
    return parsed.port


def socket_path(port: int, kind: str) -> str:
    return f"/tmp/cade-omnigent-{os.getuid()}/{kind}-{port}.sock"


def relay_port() -> int | None:
    filename = os.environ.get("OMNIGENT_RELAY_FILE")
    if not filename:
        return None
    data = json.loads(Path(filename).read_text())
    port = loopback_port(data["url"])
    if port not in range(28700, 28716):
        raise ValueError("native relay is outside the pinned Omnigent port pool")
    return port


def fail_closed() -> None:
    """v0.21.0 has no fail-closed option; narrowly fix its generated plugin."""
    filename = os.environ.get("OMNIGENT_RELAY_FILE")
    if not filename:
        raise RuntimeError("native policy relay configuration missing")
    plugin = Path(filename).parent / "omnigent-policy" / "server.js"
    source = plugin.read_text()
    start = source.index("async function evaluate(")
    end = source.index("function resultText(", start)
    evaluate = source[start:end]
    fallback = '{ result: "ALLOW" }'
    expected = "61a32da9c3702997c7555ee9aab0c371d6e0f771e46d859ed787324aa69fc9b8"
    previous = "4432ea74ceb9b6c0ba1f1e108ca2b3361b894e1be86b78af0335b55e404609ba"
    patched = "c9b65acf26528f151b7dbe05bc40fe86c199281f433fa29f4fdbeda1513faef8"
    digest = hashlib.sha256(evaluate.encode()).hexdigest()
    if digest == patched:
        return
    if digest not in (expected, previous):
        raise RuntimeError(
            "pinned Omnigent policy plugin changed; refusing unsafe launch"
        )
    denial = '{ result: "POLICY_ACTION_DENY", reason: "policy relay unavailable" }'
    evaluate = evaluate.replace(fallback, denial)
    evaluate = evaluate.replace(
        "// Unwired (no server/session) or any transport failure allows: fail open.",
        "// CADE: missing configuration or a failed policy transport denies.",
    )
    evaluate = evaluate.replace(
        'body && typeof body === "object"',
        'body && ["POLICY_ACTION_ALLOW", "POLICY_ACTION_DENY"].includes(body.result)',
    )
    evaluate = evaluate.replace(
        '["POLICY_ACTION_ALLOW", "POLICY_ACTION_DENY", "POLICY_ACTION_ASK"]',
        '["POLICY_ACTION_ALLOW", "POLICY_ACTION_DENY"]',
    )
    plugin.write_text(source[:start] + evaluate + source[end:])


def socat(first: str, second: str) -> subprocess.Popen[bytes]:
    return OwnedProcess(["socat", first, second])


def check_bridges(processes: list[subprocess.Popen[bytes]]) -> None:
    if any(process.poll() is not None for process in processes):
        raise RuntimeError("required native bridge process exited")


def wait_listener(
    processes: list[subprocess.Popen[bytes]], address: str | tuple[str, int]
) -> None:
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        check_bridges(processes)
        with socket.socket(
            socket.AF_UNIX if isinstance(address, str) else socket.AF_INET
        ) as connection:
            connection.settimeout(0.2)
            try:
                connection.connect(address)
                return
            except OSError:
                time.sleep(0.1)
    raise RuntimeError("required native bridge listener not ready")


def supervise(
    process: subprocess.Popen[bytes], bridges: list[subprocess.Popen[bytes]]
) -> int:
    while (result := process.poll()) is None:
        check_bridges(bridges)
        time.sleep(0.1)
    check_bridges(bridges)
    return result


def expected_mcp() -> set[str]:
    home = os.environ.get("XDG_CONFIG_HOME")
    if not home:
        raise RuntimeError("generated native config directory missing")
    directory = Path(home) / "opencode"
    config = json.loads((directory / "opencode.json").read_text())
    servers = config.get("mcp", {}).get("servers", {})
    required = {
        name for name, entry in servers.items() if not entry.get("disabled", False)
    }
    if "omnigent" not in required:
        raise RuntimeError("generated native config is missing required omnigent MCP")
    return required


def stop(process: subprocess.Popen[bytes]) -> None:
    if isinstance(process, OwnedProcess) and process.returncode is None:
        # WNOWAIT keeps even an exited leader's PID reserved: no PGID-reuse race.
        process.poll()
        os.killpg(process.pid, signal.SIGTERM)
        deadline = time.monotonic() + 5
        while process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.05)
        # Leader exit does not imply its descendants accepted TERM.
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)
        return
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def wait_location(
    process: subprocess.Popen[bytes],
    port: int,
    *,
    timeout: float = 30,
    bridges: list[subprocess.Popen[bytes]] | None = None,
    publish: Callable[[], None] | None = None,
) -> None:
    """Activate once, expose the authenticated location, then await its MCPs."""
    import base64

    password = os.environ.get(
        "OPENCODE_PASSWORD", os.environ.get("OPENCODE_SERVER_PASSWORD", "")
    )
    headers = {"x-opencode-directory": urllib.parse.quote(os.getcwd(), safe="!~*'()")}
    if password:
        token = base64.b64encode(f"opencode:{password}".encode()).decode()
        headers["Authorization"] = f"Basic {token}"
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/api/model", headers=headers
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    deadline = time.monotonic() + timeout
    expected = expected_mcp()
    failure = "location/MCP not ready"
    active = False
    published = False
    while time.monotonic() < deadline:
        check_bridges(bridges or [])
        if process.poll() is not None:
            raise RuntimeError("native server exited before location readiness")
        try:
            with opener.open(
                request, timeout=min(5, deadline - time.monotonic())
            ) as response:
                body = json.load(response)
                if not active:
                    if response.status != 200 or not isinstance(body, (dict, list)):
                        time.sleep(0.2)
                        continue
                    active = True
                    request = urllib.request.Request(
                        f"http://127.0.0.1:{port}/api/mcp", headers=headers
                    )
                    # MCP connects asynchronously after location activation (OpenCode 2).
                    deadline = time.monotonic() + timeout
                    continue
                required = [item for item in body["data"] if item["name"] in expected]
                if any(item["status"]["status"] == "failed" for item in required):
                    raise RuntimeError("required native MCP failed during startup")
                present = {item["name"] for item in required} == expected
                if present and not published:
                    published = True
                    if publish:
                        publish()
                if present and all(
                    item["status"]["status"] == "connected" for item in required
                ):
                    return
        except urllib.error.HTTPError as error:
            if error.code != 503:
                raise RuntimeError(
                    f"native location readiness rejected: HTTP {error.code}"
                ) from error
            failure = "HTTP 503"
        except (urllib.error.URLError, TimeoutError) as error:
            failure = type(error).__name__
        time.sleep(0.2)
    stage = "required MCP" if active else "location"
    raise RuntimeError(f"native {stage} activation exceeded its deadline: {failure}")


def run(args: list[str], *, inside: bool) -> int:
    if inside:
        parent = os.environ.get("CADE_OMNIGENT_PARENT_NETNS")
        if not parent or parent == os.readlink("/proc/self/ns/net"):
            raise RuntimeError("native inside entry requires a separate SRT namespace")
    if not inside and args == ["--version"]:
        # Omnigent's metadata probe has a 10s budget; never start SRT for it.
        # Only this exact non-agent command is exempt, using the real pinned CLI.
        os.execv(CLI, [CLI, "--version"])
    processes: list[subprocess.Popen[bytes]] = []
    sockets: list[Path] = []
    serve = bool(args) and args[0] == "serve"
    port = None
    for index, arg in enumerate(args):
        if arg == "--port":
            if index + 1 == len(args):
                raise ValueError("missing native server port")
            port = int(args[index + 1])
        if arg.startswith("--port="):
            port = int(arg.split("=", 1)[1])
        if arg == "--server":
            if index + 1 == len(args):
                raise ValueError("missing native server endpoint")
            port = loopback_port(args[index + 1])
    if port is not None and not 1 <= port <= 65535:
        raise ValueError("invalid native server port")
    try:
        relay = relay_port() if serve else None
        if not inside:
            directory = Path(socket_path(1, "server")).parent
            directory.mkdir(mode=0o700, exist_ok=True)
            if directory.is_symlink() or directory.stat().st_uid != os.getuid():
                raise RuntimeError("unsafe native bridge socket directory")
            if serve:
                fail_closed()
                if relay is not None:
                    path = Path(socket_path(relay, "relay"))
                    path.unlink(missing_ok=True)
                    sockets.append(path)
                    processes.append(
                        OwnedProcess(
                            [
                                "/usr/bin/python3",
                                "/opt/cade/omnigent-relay.py",
                                str(relay),
                            ],
                        )
                    )
                    wait_listener(processes, str(path))
            command = ["srt", "/usr/bin/python3", "--", __file__, "--inside", *args]
            environment = {
                **os.environ,
                "CADE_OMNIGENT_PARENT_NETNS": os.readlink("/proc/self/ns/net"),
            }
            process = OwnedProcess(command, env=environment)
            processes.append(process)
            return supervise(process, processes[:-1])
        if relay is not None:
            processes.append(
                socat(
                    f"TCP-LISTEN:{relay},bind=127.0.0.1,fork,reuseaddr",
                    f"UNIX-CONNECT:{socket_path(relay, 'relay')}",
                )
            )
            wait_listener(processes, ("127.0.0.1", relay))
        if not serve and port is not None:
            processes.append(
                socat(
                    f"TCP-LISTEN:{port},bind=127.0.0.1,fork,reuseaddr",
                    f"UNIX-CONNECT:/tmp/opencode-bridge-{port}.sock",
                )
            )
            wait_listener(processes, ("127.0.0.1", port))
        process = OwnedProcess([CLI, *args])
        processes.append(process)
        if serve and port is not None:
            path = Path(f"/tmp/opencode-bridge-{port}.sock")
            bridges = processes[:-1]

            def publish() -> None:
                path.unlink(missing_ok=True)
                sockets.append(path)
                bridge = socat(
                    f"UNIX-LISTEN:{path},fork,mode=600", f"TCP:127.0.0.1:{port}"
                )
                processes.append(bridge)
                bridges.append(bridge)
                wait_listener([bridge], str(path))

            wait_location(process, port, bridges=bridges, publish=publish)
        return supervise(
            process, [bridge for bridge in processes if bridge is not process]
        )
    finally:
        for process in reversed(processes):
            stop(process)
        for path in sockets:
            path.unlink(missing_ok=True)


if __name__ == "__main__":

    def terminate(signum: int, _frame: object) -> None:
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    inside = len(sys.argv) > 1 and sys.argv[1] == "--inside"
    try:
        sys.exit(run(sys.argv[2:] if inside else sys.argv[1:], inside=inside))
    except (OSError, ValueError, RuntimeError) as error:
        detail = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print(f"native bridge startup failed: {detail}", file=sys.stderr)
        sys.exit(1)
