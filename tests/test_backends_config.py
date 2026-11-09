"""Exercise the offline contract against fixture files and the real CLI."""

import copy
import importlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml
from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
backend = importlib.import_module("backend_config")

FIXTURES = ROOT / "tests/fixtures/backends"
EXAMPLES = ROOT / "workspace/examples"


class BackendConfigTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="cade-backends-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name) / "cade-deployment/backends"
        self.directory.mkdir(parents=True, mode=0o700)

    def fixture(self, name: str = "azure-enabled.yaml") -> dict:
        return yaml.safe_load((FIXTURES / name).read_text())

    def docker(self) -> dict:
        return yaml.safe_load((EXAMPLES / "docker-local.yaml").read_text())

    def write(self, declaration: dict, name: str = "connection.yaml") -> Path:
        path = self.directory / name
        path.write_text(yaml.safe_dump(declaration))
        return path

    def cli(
        self, *args: str, directory: bool = True, **env: str
    ) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(ROOT / "scripts/backends-config.py"), *args]
            + (["--dir", str(self.directory)] if directory else []),
            cwd=self.directory.parent,
            env={"PATH": os.environ["PATH"], **env},
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )

    def test_examples_from_external_private_directory(self) -> None:
        for path in EXAMPLES.glob("*.yaml"):
            shutil.copy(path, self.directory)
        declarations = backend.load_connections(self.directory)
        self.assertEqual(list(declarations), ["azure-remote-dev-env", "docker-local"])
        self.assertFalse(declarations["azure-remote-dev-env"]["spec"]["enabled"])
        self.assertEqual(declarations["docker-local"], self.docker())
        result = self.cli("validate")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "Valid BackendConnections: 2")

    def test_schema_is_valid_and_rejects_enabled_placeholders(self) -> None:
        schema = json.loads(
            (ROOT / "workspace/backend-connection.schema.json").read_text()
        )
        Draft202012Validator.check_schema(schema)
        declaration = yaml.safe_load(
            (EXAMPLES / "azure-remote-dev-env.yaml").read_text()
        )
        self.assertTrue(Draft202012Validator(schema).is_valid(declaration))
        declaration["spec"]["enabled"] = True
        self.assertFalse(Draft202012Validator(schema).is_valid(declaration))
        self.write(declaration)
        result = self.cli("validate")
        self.assertEqual(result.returncode, 1)
        self.assertIn("spec.config.subscriptionId", result.stderr)
        self.assertNotIn("<subscription-id>", result.stderr)

    def test_schema_version_types_names_provider_and_typo_rejected(self) -> None:
        changes = [
            (("apiVersion",), "cade.dev/v99"),
            (("kind",), "Template"),
            (("metadata", "name"), "docker-typo"),
            (("metadata", "name"), "azure-remote-dev-env"),
            (("spec", "provider"), "unknown"),
            (("spec", "enabled"), "true"),
            (("spec", "config", "endpoint"), "https://user:secret@example.invalid"),
            (("spec", "config", "subscriptionID"), "typo"),
            (("spec", "config", "profile"), "Small"),
        ]
        for keys, value in changes:
            with self.subTest(keys=keys):
                declaration = self.docker()
                parent = declaration
                for key in keys[:-1]:
                    parent = parent[key]
                parent[keys[-1]] = value
                with self.assertRaises(backend.ConfigError) as caught:
                    backend.validate_connection(declaration)
                self.assertIn("schema", str(caught.exception))
                self.assertNotIn(str(value), str(caught.exception))

    def test_secret_keys_rejected_without_value_disclosure(self) -> None:
        for key in (
            "password",
            "clientSecret",
            "token",
            "credentials",
            "template",
            "path",
        ):
            with self.subTest(key=key):
                declaration = self.fixture()
                declaration["spec"]["config"][key] = "sensitive-sentinel"
                self.write(declaration)
                result = self.cli("validate")
                self.assertEqual(result.returncode, 1)
                self.assertIn("unknown fields", result.stderr)
                self.assertNotIn("sensitive-sentinel", result.stdout + result.stderr)
        declaration = self.fixture()
        declaration["spec"]["config"]["identity"]["clientSecret"] = "nested-secret"
        with self.assertRaises(backend.ConfigError) as caught:
            backend.validate_connection(declaration)
        self.assertNotIn("nested-secret", str(caught.exception))
        self.assertIn("identity", str(caught.exception))

    def test_enabled_azure_required_ids_identity_and_correspondence(self) -> None:
        declaration = self.fixture()
        self.assertEqual(backend.validate_connection(declaration), declaration)
        self.assertIsNone(backend.validate_azure_config(declaration["spec"]["config"]))
        for key in (
            "subscriptionId",
            "region",
            "resourceGroup",
            "subnetId",
            "identity",
        ):
            with self.subTest(missing=key):
                missing = copy.deepcopy(declaration)
                del missing["spec"]["config"][key]
                with self.assertRaises(backend.ConfigError) as caught:
                    backend.validate_connection(missing)
                self.assertIn("required", str(caught.exception))
        for key, value in (
            ("subscriptionId", "<subscription-id>"),
            ("subnetId", "/subscriptions/not-a-subnet"),
            ("region", "<region>"),
            ("resourceGroup", "invalid/group"),
            ("identity", {"method": "clientSecret"}),
            ("identity", {"method": "managedIdentity", "clientId": "<client-id>"}),
        ):
            with self.subTest(field=key):
                invalid = copy.deepcopy(declaration)
                invalid["spec"]["config"][key] = value
                with self.assertRaises(backend.ConfigError) as caught:
                    backend.validate_connection(invalid)
                self.assertIn("schema", str(caught.exception))
        for key, value in (
            ("subscriptionId", "99999999-2222-3333-4444-555555555555"),
            ("resourceGroup", "other-group"),
        ):
            with self.subTest(mismatch=key):
                invalid = copy.deepcopy(declaration)
                invalid["spec"]["config"][key] = value
                with self.assertRaises(backend.ConfigError) as caught:
                    backend.validate_azure_config(invalid["spec"]["config"])
                self.assertIn(f"must match {key}", str(caught.exception))

    def test_user_assigned_identity_and_case_insensitive_ids(self) -> None:
        declaration = self.fixture()
        config = declaration["spec"]["config"]
        config["identity"]["clientId"] = "abcdefab-2222-3333-4444-555555555555"
        config["subnetId"] = config["subnetId"].upper()
        self.assertEqual(backend.validate_connection(declaration), declaration)
        self.assertEqual(config["identity"]["method"], "managedIdentity")

    def test_enabled_azure_rejects_trailing_whitespace(self) -> None:
        for field in (
            "subscriptionId",
            "region",
            "resourceGroup",
            "subnetId",
            "clientId",
        ):
            with self.subTest(field=field):
                declaration = self.fixture()
                config = declaration["spec"]["config"]
                target = config["identity"] if field == "clientId" else config
                target[field] = (
                    target.get(field, "abcdefab-2222-3333-4444-555555555555") + "\n"
                )
                with self.assertRaises(backend.ConfigError) as caught:
                    backend.validate_connection(declaration)
                self.assertIn("schema", str(caught.exception))
                self.assertNotIn("abcdefab-2222", str(caught.exception))

    def test_duplicate_names_and_duplicate_yaml_keys_fail(self) -> None:
        self.write(self.docker())
        self.write(self.docker(), "second.yml")
        result = self.cli("validate")
        self.assertEqual(result.returncode, 1)
        self.assertIn("duplicate BackendConnection name", result.stderr)
        for path in self.directory.iterdir():
            path.unlink()
        shutil.copy(FIXTURES / "duplicate-key.yaml", self.directory)
        result = self.cli("validate")
        self.assertEqual(result.returncode, 1)
        self.assertIn("duplicate YAML key", result.stderr)

    def test_malformed_unsafe_deep_and_recursive_yaml_are_value_free(self) -> None:
        for text in (
            "secret-sentinel: [\n",
            "!!python/object/apply:os.system ['secret-sentinel']",
            "a: !!int secret-sentinel",
            "a: !!timestamp secret-sentinel",
            "a: !!bool secret-sentinel",
            "a: " + "9" * 5000,
            "a: &a {b: *a}",
            "a: &a {b: 1}\nb: {<<: *a}",
            "{[complex, key]: secret-sentinel}",
            "a: " + "[" * 25 + "0" + "]" * 25,
            "a: 1\n---\na: 2",
            "a" * 65537,
            "",
        ):
            with self.subTest(text=text[:30]):
                (self.directory / "bad.yaml").write_text(text)
                result = self.cli("validate")
                self.assertEqual(result.returncode, 1)
                self.assertNotIn("secret-sentinel", result.stdout + result.stderr)
                self.assertNotIn("Traceback", result.stderr)

    def test_missing_empty_unreadable_directory_and_file(self) -> None:
        self.assertEqual(backend.load_connections(self.directory), {})
        self.assertEqual(
            list(backend.load_connections(self.directory / "missing")), ["docker-local"]
        )
        path = self.write(self.docker())
        for target in (path, self.directory):
            with self.subTest(target=target.name):
                previous = target.stat().st_mode
                target.chmod(0)
                try:
                    with self.assertRaises(backend.ConfigError) as caught:
                        backend.load_connections(self.directory)
                    self.assertIn("readable", str(caught.exception))
                finally:
                    target.chmod(previous)
        with self.assertRaises(backend.ConfigError) as caught:
            backend.load_connections(path)
        self.assertIn("directory", str(caught.exception))

    def test_env_selection_and_explicit_override(self) -> None:
        result = self.cli(
            "validate", directory=False, CADE_BACKENDS_DIR=str(self.directory)
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("BackendConnections: 0", result.stdout)
        result = self.cli("validate", CADE_BACKENDS_DIR=str(self.directory / "missing"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("BackendConnections: 0", result.stdout)

    def test_exact_four_catalog_mappings_and_legacy_explicit_resolution(self) -> None:
        expected = [
            ("generic-linux", "docker-workspace"),
            ("embedded-linux", "embedded-linux"),
            ("devcontainer", "devcontainer"),
            ("ai-agent", "agent-workspace"),
        ]
        catalog = backend.load_catalog()
        self.assertEqual(
            [(entry["environment"], entry["template"]) for entry in catalog], expected
        )
        self.assertEqual([entry["backend"] for entry in catalog], ["docker-local"] * 4)
        self.assertEqual(
            [entry["path"] for entry in catalog],
            ["coder/templates/" + name for _, name in expected],
        )
        missing = self.directory / "absent"
        self.assertEqual(backend.resolve(missing), catalog)
        self.write(self.docker())
        self.assertEqual(backend.resolve(self.directory), catalog)
        result = self.cli("resolve", "--format", "json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), catalog)

    def test_disabled_omitted_empty_and_azure_only_selection(self) -> None:
        self.assertEqual(backend.resolve(self.directory), [])
        docker = self.docker()
        docker["spec"]["enabled"] = False
        path = self.write(docker)
        self.assertEqual(backend.resolve(self.directory), [])
        path.unlink()
        shutil.copy(EXAMPLES / "azure-remote-dev-env.yaml", self.directory)
        self.assertEqual(backend.resolve(self.directory), [])
        self.write(self.fixture())
        # Replace the disabled declaration rather than introducing a duplicate name.
        (self.directory / "azure-remote-dev-env.yaml").unlink()
        result = self.cli("resolve", "--format", "json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [])

    def test_cli_backend_filter_and_value_free_unknown_filter(self) -> None:
        self.write(self.docker())
        result = self.cli(
            "resolve", "--backend", "azure-remote-dev-env", "--format", "json"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [])
        result = self.cli("resolve", "--backend", "docker-local")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(result.stdout.splitlines()), 4)
        self.assertTrue(
            result.stdout.startswith("generic-linux\tdocker-local\tdocker-workspace\t")
        )
        result = self.cli("resolve", "--backend", "sensitive-sentinel")
        self.assertEqual(result.returncode, 1)
        self.assertIn("unknown backend filter", result.stderr)
        self.assertNotIn("sensitive-sentinel", result.stderr)

    def test_invalid_catalogs_fail_before_selection(self) -> None:
        root = Path(self.temp.name) / "catalog-source"
        (root / "workspace").mkdir(parents=True)
        catalog = yaml.safe_load((ROOT / "workspace/catalog.yaml").read_text())
        for entry in catalog["implementations"]:
            target = root / entry["path"]
            target.mkdir(parents=True)
            shutil.copy(ROOT / entry["path"] / "main.tf", target)
        variants = []
        for key, value in (
            ("version", 2),
            ("version", True),
            ("implementations", {}),
            ("typo", "hidden"),
        ):
            invalid = copy.deepcopy(catalog)
            invalid[key] = value
            variants.append(invalid)
        for field, value in (
            ("backend", "unknown-backend"),
            ("environment", "Bad Name"),
            ("template", "-unsafe"),
            ("path", "../outside"),
            ("path", str(ROOT / "coder/templates/docker-workspace")),
            ("path", "missing"),
            ("path", "workspace/catalog.yaml"),
            ("extra", "hidden"),
        ):
            invalid = copy.deepcopy(catalog)
            invalid["implementations"][0][field] = value
            variants.append(invalid)
        pair = copy.deepcopy(catalog)
        pair["implementations"][1]["environment"] = "generic-linux"
        variants.append(pair)
        name = copy.deepcopy(catalog)
        name["implementations"][1]["template"] = "docker-workspace"
        variants.append(name)
        (root / "escape").symlink_to(
            ROOT / "coder/templates/docker-workspace", target_is_directory=True
        )
        escape = copy.deepcopy(catalog)
        escape["implementations"][0]["path"] = "escape"
        variants.append(escape)
        for index, invalid in enumerate(variants):
            with self.subTest(case=index):
                (root / "workspace/catalog.yaml").write_text(yaml.safe_dump(invalid))
                with self.assertRaises(backend.ConfigError) as caught:
                    backend.resolve(self.directory, root)
                self.assertIn("catalog", str(caught.exception))
                self.assertNotIn("hidden", str(caught.exception))

    def test_invalid_files_never_trigger_legacy_fallback(self) -> None:
        broken = self.directory / "broken.yaml"
        broken.symlink_to(self.directory / "absent.yaml")
        with self.assertRaises(backend.ConfigError) as caught:
            backend.resolve(self.directory)
        self.assertIn("cannot read", str(caught.exception))
        broken.unlink()
        self.directory.rmdir()
        self.directory.symlink_to(
            self.directory.parent / "missing", target_is_directory=True
        )
        with self.assertRaises(backend.ConfigError) as caught:
            backend.resolve(self.directory)
        self.assertIn("cannot read", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
