"""Exercise real dispatch/Make recipes against isolated CLI and HTTP fixtures."""

import json
import sys

import yaml

from test_template_vars import DEFAULTS, TemplateFixture

AZURE = {
    "subscription_id": "11111111-1111-4111-8111-111111111111",
    "location": "swedencentral",
    "resource_group_name": "rg-cade-workspaces",
    "subnet_id": "/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-network/providers/Microsoft.Network/virtualNetworks/vnet/subnets/workspaces",
    "managed_identity_client_id": "",
}


class TemplatesPushTest(TemplateFixture):
    def setUp(self):
        super().setUp()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "calls.jsonl"
        stub = (
            f"#!{sys.executable}\n"
            "import json, os, pathlib, sys\n"
            "name = pathlib.Path(sys.argv[0]).name\n"
            "with open(os.environ['CALL_LOG'], 'a') as log:\n"
            " log.write(json.dumps([name, *sys.argv[1:]]) + '\\n')\n"
            "if name == 'git' and os.environ.get('DIRTY'): print(' M coder/Dockerfile')\n"
            "if name == 'coder' and os.environ.get('FAIL_PUSH') == sys.argv[3]:\n"
            " print('synthetic-secret-must-not-escape'); sys.exit(1)\n"
        )
        for name in ("coder", "docker", "git"):
            path = self.bin / name
            path.write_text(stub)
            path.chmod(0o755)
        self.env.update(PATH=f"{self.bin}:{self.env['PATH']}", CALL_LOG=str(self.log))
        self.server.values = {}

    def calls(self, name):
        return [call[1:] for call in self.records() if call[0] == name]

    def records(self):
        return (
            [json.loads(line) for line in self.log.read_text().splitlines()]
            if self.log.exists()
            else []
        )

    def connections(self, docker=True, azure=False):
        directory = self.root / "deployment/backends"
        directory.mkdir(parents=True, exist_ok=True)
        docker_doc = yaml.safe_load(
            (self.root / "workspace/examples/docker-local.yaml").read_text()
        )
        docker_doc["spec"]["enabled"] = docker
        azure_doc = yaml.safe_load(
            (self.root / "workspace/examples/azure-remote-dev-env.yaml").read_text()
        )
        azure_doc["spec"]["enabled"] = azure
        azure_doc["spec"]["config"] = {
            "subscriptionId": AZURE["subscription_id"],
            "region": AZURE["location"],
            "resourceGroup": AZURE["resource_group_name"],
            "subnetId": AZURE["subnet_id"],
            "identity": {"method": "managedIdentity"},
        }
        (directory / "docker.yaml").write_text(yaml.safe_dump(docker_doc))
        (directory / "azure.yaml").write_text(yaml.safe_dump(azure_doc))
        self.env["CADE_BACKENDS_DIR"] = str(directory)

    def azure_catalog(self):
        catalog = self.root / "workspace/catalog.yaml"
        document = yaml.safe_load(catalog.read_text())
        document["implementations"].append(
            {
                "environment": "generic-linux",
                "backend": "azure-remote-dev-env",
                "template": "generic-linux-azure",
                "path": "coder/templates/generic-linux-azure",
            }
        )
        catalog.write_text(yaml.safe_dump(document, sort_keys=False))
        path = self.root / "coder/templates/generic-linux-azure"
        path.mkdir()
        (path / "main.tf").write_text("")
        (path / "variables.tf").write_text(
            "\n".join(f'variable "{key}" {{ type = string }}' for key in AZURE)
        )

    def test_legacy_and_explicit_keep_build_and_push_order(self):
        for explicit in (False, True):
            with self.subTest(explicit=explicit):
                if explicit:
                    self.connections()
                self.log.unlink(missing_ok=True)
                result = self.run_command(
                    "make", "templates-push", "REPO_SLUG=fixture/project"
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(
                    self.calls("coder"),
                    [
                        [
                            "templates",
                            "push",
                            name,
                            "-d",
                            f"coder/templates/{name}",
                            "--variable",
                            "repo_url=https://github.com/fixture/project.git",
                            "--yes",
                        ]
                        for name in DEFAULTS
                    ],
                )
                self.assertEqual(
                    [call[call.index("-t") + 1] for call in self.calls("docker")],
                    [
                        "cade/coder-workspace:latest",
                        "cade/embedded-linux-workspace:latest",
                        "cade/devcontainer-bootstrap:latest",
                        "cade/agent-workspace:latest",
                    ],
                )
                self.assertEqual(
                    self.calls("git"),
                    [
                        [
                            "status",
                            "--porcelain",
                            "--",
                            "examples",
                            "coder",
                            "Makefile",
                        ],
                        [
                            "status",
                            "--porcelain",
                            "--",
                            "examples",
                            "coder",
                            "Makefile",
                        ],
                    ],
                )

    def test_disabled_azure_and_both_enabled(self):
        self.azure_catalog()
        self.connections(azure=False)
        result = self.run_command("make", "templates-push")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls("coder")), 4)
        self.log.unlink()
        self.connections(azure=True)
        result = self.run_command("make", "templates-push")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            [call[2] for call in self.calls("coder")],
            [*DEFAULTS, "generic-linux-azure"],
        )
        self.assertEqual(len(self.calls("docker")), 4)

    def test_explicit_docker_target_and_repo_slug_precedence(self):
        self.connections()
        (self.root / ".env").write_text("REPO_SLUG=file/project\n")
        for exported, command_line, expected in (
            ({}, (), "file/project"),
            ({"REPO_SLUG": "env/project"}, (), "env/project"),
            ({"REPO_SLUG": "env/project"}, ("REPO_SLUG=cli/project",), "cli/project"),
        ):
            with self.subTest(expected=expected):
                self.log.unlink(missing_ok=True)
                result = self.run_command(
                    "make",
                    "backend-templates-push",
                    "BACKEND=docker-local",
                    *command_line,
                    env={**self.env, **exported},
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(self.calls("coder")), 4)
                for command in self.calls("coder"):
                    self.assertIn(
                        f"repo_url=https://github.com/{expected}.git", command
                    )

    def test_user_assigned_identity_and_login_session_fallback(self):
        self.azure_catalog()
        self.connections(docker=False, azure=True)
        path = self.root / "deployment/backends/azure.yaml"
        document = yaml.safe_load(path.read_text())
        client = "22222222-2222-4222-8222-222222222222"
        document["spec"]["config"]["identity"]["clientId"] = client
        path.write_text(yaml.safe_dump(document))
        session = self.root / ".config/coderv2/session"
        session.parent.mkdir(parents=True)
        session.write_text("fixture-token")
        env = self.env.copy()
        del env["CODER_SESSION_TOKEN"]
        result = self.run_command("make", "templates-push", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"managed_identity_client_id={client}", self.calls("coder")[0])
        self.assertEqual(self.calls("docker"), [])
        self.assertNotIn("fixture-token", result.stdout + result.stderr)

    def test_azure_only_and_targeted_use_connection_variables_without_builds(self):
        self.azure_catalog()
        for docker in (False, True):
            with self.subTest(docker=docker):
                self.connections(docker=docker, azure=True)
                self.log.unlink(missing_ok=True)
                result = self.run_command(
                    "make", "backend-templates-push", "BACKEND=azure-remote-dev-env"
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                command = self.calls("coder")
                self.assertEqual(len(command), 1)
                self.assertEqual(
                    command[0][:5],
                    [
                        "templates",
                        "push",
                        "generic-linux-azure",
                        "-d",
                        "coder/templates/generic-linux-azure",
                    ],
                )
                self.assertEqual(
                    command[0][5:-1],
                    [
                        arg
                        for key, value in AZURE.items()
                        for arg in ("--variable", f"{key}={value}")
                    ],
                )
                self.assertEqual(self.calls("docker"), [])
                self.assertEqual(self.calls("git"), [])

    def test_target_auth_push_and_dirty_errors_stop_mutation(self):
        for args, changes, message in (
            (("backend-templates-push",), {}, "BACKEND is required"),
            (("backend-templates-push", "BACKEND=unknown"), {}, "no connection"),
            (
                ("templates-push",),
                {"CODER_SESSION_TOKEN": ""},
                "no Coder session token",
            ),
            (
                ("templates-push",),
                {"CODER_SESSION_TOKEN": "invalid"},
                "Coder API request failed",
            ),
            (("templates-push",), {"DIRTY": "1"}, "uncommitted changes"),
            (
                ("templates-push",),
                {"FAIL_PUSH": "embedded-linux"},
                "template push failed",
            ),
        ):
            with self.subTest(args=args, changes=changes):
                self.log.unlink(missing_ok=True)
                result = self.run_command("make", *args, env={**self.env, **changes})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stdout + result.stderr)
                self.assertNotIn("synthetic-secret", result.stdout + result.stderr)
                self.assertLessEqual(len(self.calls("coder")), 2)

    def test_disabled_and_unsupported_target(self):
        self.connections(docker=False, azure=False)
        result = self.run_command(
            "make", "backend-templates-push", "BACKEND=docker-local"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("disabled", result.stderr)
        self.connections(docker=False, azure=True)
        for args in (
            ("templates-push",),
            ("backend-templates-push", "BACKEND=azure-remote-dev-env"),
        ):
            result = self.run_command("make", *args)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("no supported", result.stderr)
            self.assertEqual(self.records(), [])

    def test_invalid_catalog_fails_before_build_or_push(self):
        path = self.root / "workspace/catalog.yaml"
        original = yaml.safe_load(path.read_text())
        for change, message in (
            ({"template": "unknown"}, "unknown Docker implementation"),
            ({"backend": "unknown"}, "unknown backend"),
            ({"path": "../escape"}, "contained"),
            ({"path": "coder/templates/missing"}, "existing contained"),
            ({"template": "embedded-linux"}, "duplicate catalog template"),
        ):
            with self.subTest(change=change):
                document = json.loads(json.dumps(original))
                document["implementations"][0].update(change)
                path.write_text(yaml.safe_dump(document))
                result = self.run_command("make", "templates-push")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertEqual(self.records(), [])

    def test_disabled_published_blocks_even_if_marked_deprecated(self):
        self.azure_catalog()
        self.connections(azure=False)
        self.server.values = {"generic-linux-azure": {}}
        for target in ("templates-push", "templates-verify-vars"):
            result = self.run_command("make", target)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("RETIREMENT BLOCK", result.stderr)
            self.assertIn("Manual action", result.stderr)
            self.assertIn("No server changes", result.stderr)
            self.assertEqual(self.records(), [])

    def test_no_selected_templates_is_explicit_and_never_builds(self):
        self.connections(docker=False, azure=False)
        for target in ("templates-push", "templates-verify-vars"):
            result = self.run_command("make", target)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("0 selected template(s)", result.stdout)
            self.assertEqual(self.records(), [])

    def test_duplicate_pair_and_wrong_connection_provider(self):
        catalog = self.root / "workspace/catalog.yaml"
        original = yaml.safe_load(catalog.read_text())
        document = json.loads(json.dumps(original))
        document["implementations"][1]["environment"] = "generic-linux"
        catalog.write_text(yaml.safe_dump(document))
        result = self.run_command("make", "templates-push")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate catalog environment/backend", result.stderr)
        catalog.write_text(yaml.safe_dump(original))
        self.connections()
        path = self.root / "deployment/backends/docker.yaml"
        document = yaml.safe_load(path.read_text())
        document["spec"]["provider"] = "azure"
        path.write_text(yaml.safe_dump(document))
        result = self.run_command("make", "templates-push")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("schema", result.stderr)
        self.assertEqual(self.records(), [])

    def test_azure_required_defaults_nonstring_and_missing_variables(self):
        self.azure_catalog()
        self.connections(docker=False, azure=True)
        path = self.root / "coder/templates/generic-linux-azure/variables.tf"
        with path.open("a") as stream:
            stream.write(
                '\nvariable "enabled" { default = true }\nvariable "count" { default = 2 }\nvariable "tags" { default = { owner = "platform" } }\n'
            )
        self.server.values = {
            "generic-linux-azure": {
                **AZURE,
                "enabled": "true",
                "count": "2",
                "tags": '{"owner":"platform"}',
            }
        }
        result = self.run_command("make", "templates-verify-vars")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS  subscription_id", result.stdout)
        del self.server.values["generic-linux-azure"]["subscription_id"]
        result = self.run_command("make", "templates-verify-vars")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DRIFT subscription_id: missing", result.stdout)
        self.server.values["generic-linux-azure"]["subscription_id"] = AZURE[
            "subscription_id"
        ]
        self.server.values["generic-linux-azure"]["location"] = "wrong"
        result = self.run_command("make", "templates-verify-vars")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DRIFT location", result.stdout)
        path.unlink()
        result = self.run_command("make", "templates-verify-vars")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("variables.tf not found", result.stderr)
        path.write_text("")
        result = self.run_command("make", "templates-verify-vars")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1 selected template(s)", result.stdout)


if __name__ == "__main__":
    import unittest

    unittest.main(verbosity=2)
