"""Exercise separate authenticated location and asynchronous MCP readiness."""

import subprocess
import threading
import time
import unittest

import test_launch


class Readiness(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = test_launch.NativeLaunch()
        self.fixture.setUp()
        self.process = subprocess.Popen(
            ["python3", "-c", "import time; time.sleep(60)"]
        )

    def tearDown(self) -> None:
        test_launch.launch.stop(self.process)
        self.fixture.tearDown()

    def test_phase_budget_and_single_activation(self) -> None:
        endpoint = test_launch.Endpoint
        endpoint.count = 1
        endpoint.delay = 0.6
        endpoint.docs = "pending"
        publications: list[list[str]] = []
        timer = threading.Timer(0.6, lambda: setattr(endpoint, "docs", "connected"))

        def publish() -> None:
            publications.append(list(endpoint.paths))
            timer.start()

        started = time.monotonic()
        try:
            test_launch.launch.wait_location(
                self.process,
                self.fixture.server.server_port,
                timeout=1,
                publish=publish,
            )
        finally:
            timer.join(timeout=2)
        self.assertGreaterEqual(time.monotonic() - started, 1)
        self.assertEqual(publications, [["/api/model", "/api/mcp"]])
        self.assertEqual(endpoint.paths.count("/api/model"), 1)
        self.assertGreaterEqual(endpoint.paths.count("/api/mcp"), 4)
        self.assertEqual(endpoint.docs, "connected")

    def test_rejection_and_missing_mcp_do_not_publish(self) -> None:
        endpoint = test_launch.Endpoint
        endpoint.status = 401
        publications: list[bool] = []
        with self.assertRaisesRegex(RuntimeError, "HTTP 401"):
            test_launch.launch.wait_location(
                self.process,
                self.fixture.server.server_port,
                timeout=1,
                publish=lambda: publications.append(True),
            )
        self.assertEqual(publications, [])
        endpoint.status = 200
        endpoint.docs = "failed"
        with self.assertRaisesRegex(RuntimeError, "required native MCP failed"):
            test_launch.launch.wait_location(
                self.process,
                self.fixture.server.server_port,
                timeout=1,
                publish=lambda: publications.append(True),
            )
        self.assertEqual(publications, [])
        endpoint.docs = None
        with self.assertRaisesRegex(RuntimeError, "required MCP.*deadline"):
            test_launch.launch.wait_location(
                self.process,
                self.fixture.server.server_port,
                timeout=0.3,
                publish=lambda: publications.append(True),
            )
        self.assertEqual(publications, [])


if __name__ == "__main__":
    unittest.main()
