"""Exercise the bootstrap entrypoint against a Coder 2.38-shaped HTTP fixture."""

import json
import os
import subprocess
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MODELS = "/api/v2/organizations/default/chats/models"
PROVIDERS = "/api/v2/ai/providers"


class CoderFixture(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.server.requests.append(("GET", self.path))
        if self.path == "/api/v2/buildinfo":
            return self.reply(200, {"version": "v2.38.6"})
        if self.path == PROVIDERS:
            return self.reply(200, self.server.providers)
        if self.path == MODELS:
            return self.reply(
                self.server.model_status,
                self.server.model_response
                if self.server.model_response is not None
                else {"models": self.server.models},
            )
        return self.reply(404, {"message": "unknown route"})

    def do_POST(self):
        self.server.requests.append(("POST", self.path))
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == PROVIDERS:
            provider = {
                **body,
                "id": "provider-1",
                "api_keys": [{"masked": "test...1234"}],
            }
            self.server.providers.append(provider)
            return self.reply(201, provider)
        if self.path == MODELS:
            model = {
                **body,
                "id": f"model-{len(self.server.models) + 1}",
                "is_default": not self.server.models,
            }
            self.server.models.append(model)
            return self.reply(201, model)
        return self.reply(404, {"message": "unknown route"})

    def do_PATCH(self):
        self.server.requests.append(("PATCH", self.path))
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        for model in self.server.models:
            if self.path == f"{MODELS}/{model['id']}":
                if body.get("is_default"):
                    for current in self.server.models:
                        current["is_default"] = False
                model.update(body)
                return self.reply(200, model)
        return self.reply(404, {"message": "unknown route"})


class BootstrapTest(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), CoderFixture)
        self.server.requests = []
        self.server.providers = []
        self.server.models = []
        self.server.model_response = None
        self.server.model_status = 200
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.thread.join()
        self.server.server_close()

    def bootstrap(self, key="test-secret-1234"):
        env = {
            "PATH": os.defpath,
            "CODER_URL": f"http://127.0.0.1:{self.server.server_port}",
            "CODER_SESSION_TOKEN": "synthetic-token",
            "OPENAI_API_KEY": key,
        }
        return subprocess.run(
            ["python3", str(ROOT / "scripts/ai_bootstrap.py")],
            env=env,
            text=True,
            capture_output=True,
            timeout=15,
            check=True,
        ).stdout

    def test_create_idempotence_and_drift(self):
        first = self.bootstrap()
        self.assertIn("Default model: set to 'openai/gpt-5.6-luna'", first)
        self.assertEqual(len(self.server.models), 7)
        self.assertEqual(
            [m["model"] for m in self.server.models if m["is_default"]],
            ["gpt-5.6-luna"],
        )
        self.server.requests.clear()
        second = self.bootstrap()
        self.assertIn("Provider 'openai': unchanged", second)
        self.assertFalse([r for r in self.server.requests if r[0] != "GET"])
        self.server.models[0]["context_limit"] = 1
        self.server.requests.clear()
        third = self.bootstrap()
        self.assertIn("Model 'openai/gpt-4o-mini': updated", third)
        self.assertEqual(self.server.models[0]["context_limit"], 128000)
        self.assertEqual(
            [r for r in self.server.requests if r[0] != "GET"],
            [("PATCH", f"{MODELS}/model-1")],
        )

    def test_invalid_model_response_never_writes_models(self):
        self.server.model_response = {"models": "not-a-list"}
        output = self.bootstrap()
        self.assertIn("could not list model-configs", output)
        self.assertFalse(self.server.models)
        self.assertFalse(
            [
                r
                for r in self.server.requests
                if r[0] != "GET" and r[1].startswith(MODELS)
            ]
        )

    def test_api_error_never_writes_models(self):
        self.server.model_status = 500
        output = self.bootstrap()
        self.assertIn("status 500", output)
        self.assertFalse(self.server.models)
        self.assertFalse(
            [
                r
                for r in self.server.requests
                if r[0] != "GET" and r[1].startswith(MODELS)
            ]
        )

    def test_missing_provider_key_does_not_change_default(self):
        self.server.models.append(
            {
                "id": "other",
                "model": "gpt-5.6-luna",
                "ai_provider_id": "other-provider",
                "is_default": True,
            }
        )
        output = self.bootstrap(key="")
        self.assertIn("OPENAI_API_KEY is not set/resolvable", output)
        self.assertIn("no provider id for default", output)
        self.assertTrue(self.server.models[0]["is_default"])
        self.assertFalse([r for r in self.server.requests if r[0] != "GET"])

    def test_default_matches_provider_as_well_as_model_name(self):
        self.server.models.append(
            {
                "id": "other",
                "model": "gpt-5.6-luna",
                "ai_provider_id": "other-provider",
                "is_default": True,
            }
        )
        output = self.bootstrap()
        self.assertIn("Default model: set to 'openai/gpt-5.6-luna'", output)
        defaults = [m for m in self.server.models if m["is_default"]]
        self.assertEqual(len(defaults), 1)
        self.assertEqual(defaults[0]["ai_provider_id"], "provider-1")
        self.assertFalse(self.server.models[0]["is_default"])


if __name__ == "__main__":
    unittest.main()
