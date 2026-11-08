"""Exercise make up and real Compose config with a synthetic Docker daemon."""

import importlib.util
import json
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
            "coder/supported-version.env",
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
if args[:2] == ['container', 'ls']:
    if os.environ.get('LIST_FAILURE'):
        sys.exit(1)
    name = 'coder-db' if 'name=^/coder-db$' in args else 'coder'
    if os.environ.get('PROJECT_' + name):
        print('id-' + name)
    sys.exit(0)
if args and args[0] == 'inspect' and 'Labels' in args[2]:
    if os.environ.get('LABEL_FAILURE'):
        sys.exit(1)
    name = args[-1].removeprefix('id-')
    print(os.environ['PROJECT_' + name] + ':' + os.environ.get('SERVICE_' + name, name))
    sys.exit(0)
if args and args[0] == 'inspect' and '.HostConfig.Mounts' in args[2]:
    project = os.environ.get('PROJECT_coder-db', 'devenv-cloud')
    source = os.environ.get('DB_MOUNT', 'volume:' + project + '_coder_db_data').removeprefix('volume:')
    default = [{'Type': 'volume', 'Source': source, 'Target': '/var/lib/postgresql/data',
                'VolumeOptions': {'Subpath': os.environ.get('HOST_SUBPATH', '')}}]
    print(os.environ.get('HOST_MOUNTS_JSON', json.dumps(default)))
    print(os.environ.get('HOST_BINDS_JSON', 'null'))
    sys.exit(0)
if args and args[0] == 'inspect' and '.Config.Env' in args[2]:
    if os.environ.get('PGDATA_FAILURE'):
        sys.exit(1)
    if not os.environ.get('NO_PGDATA'):
        print('PGDATA=' + os.environ.get('ACTUAL_PGDATA', '/var/lib/postgresql/data'))
        if os.environ.get('DUP_PGDATA'):
            print('PGDATA=/var/lib/postgresql/data')
    print()
    sys.exit(0)
if args and args[0] == 'inspect' and '.Mounts' in args[2]:
    if os.environ.get('MOUNT_FAILURE'):
        sys.exit(1)
    project = os.environ.get('PROJECT_coder-db', 'devenv-cloud')
    print(os.environ.get('DB_MOUNT', 'volume:' + project + '_coder_db_data') + '\\n')
    sys.exit(0)
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
            ("CODER_EXPERIMENTS=other\n", "must enable mcp-server-http"),
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
            "services:\n  coder:\n    environment:\n      CADE_CODER_SUPPORTED_VERSION: v2.36.4\n",
            "services:\n  coder:\n    environment:\n      CADE_CODER_SUPPORTED_VERSION: v2.38.6\n",
            "services:\n  coder:\n    environment:\n      CODER_OAUTH2_PROVIDER_ENABLE: 'false'\n",
            "services:\n  coder:\n    container_name: alternate-coder\n",
            "services:\n  coder-db:\n    container_name: alternate-db\n",
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

    def test_existing_containers_must_match_effective_compose_project(self):
        for values in (
            {"PROJECT_coder": "another-project"},
            {"PROJECT_coder-db": "another-project"},
            {"PROJECT_coder": "devenv-cloud", "SERVICE_coder": "other"},
            {"PROJECT_coder": "devenv-cloud", "LABEL_FAILURE": "1"},
            {"LIST_FAILURE": "1"},
        ):
            with self.subTest(values=values):
                self.trace.write_text("")
                result = self.run_make(extra=values)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Coder preflight failed", result.stderr)
                self.assertNotIn("compose up", self.trace.read_text())
                self.assertNotIn("docker image inspect", self.trace.read_text())

    def test_absent_or_matching_containers_allow_preflight(self):
        for values in (
            {},
            {"PROJECT_coder": "devenv-cloud"},
            {"PROJECT_coder-db": "devenv-cloud"},
            {
                "COMPOSE_PROJECT_NAME": "chosen-project",
                "PROJECT_coder": "chosen-project",
                "PROJECT_coder-db": "chosen-project",
            },
        ):
            with self.subTest(values=values):
                self.trace.write_text("")
                result = self.run_make(extra=values)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("compose up -d", self.trace.read_text())

    def test_database_volume_overrides_rejected_with_existing_or_absent_db(self):
        for override in (
            "volumes:\n  coder_db_data:\n    name: different-volume\n",
            "services:\n  coder-db:\n    volumes:\n      - other:/var/lib/postgresql/data\nvolumes:\n  other: {}\n",
        ):
            for existing in (
                {},
                {"PROJECT_coder-db": "devenv-cloud"},
                {"COMPOSE_PROJECT_NAME": "chosen-project"},
                {
                    "COMPOSE_PROJECT_NAME": "chosen-project",
                    "PROJECT_coder-db": "chosen-project",
                },
            ):
                with self.subTest(override=override, existing=existing):
                    self.trace.write_text("")
                    result = self.run_make(override=override, extra=existing)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Coder preflight failed", result.stderr)
                    self.assertNotIn("docker image inspect", self.trace.read_text())
                    self.assertNotIn("compose up", self.trace.read_text())

    def test_existing_database_mount_must_match_exactly(self):
        for mount in (
            "volume:other-data",
            "",
            "bind:",
            "volume:devenv-cloud_coder_db_data\nvolume:devenv-cloud_coder_db_data",
        ):
            with self.subTest(mount=mount):
                self.trace.write_text("")
                result = self.run_make(
                    extra={"PROJECT_coder-db": "devenv-cloud", "DB_MOUNT": mount}
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("data mount does not match", result.stderr)
                self.assertNotIn("compose up", self.trace.read_text())
        result = self.run_make(
            extra={"PROJECT_coder-db": "devenv-cloud", "MOUNT_FAILURE": "1"}
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("data mount does not match", result.stderr)

    def test_missing_or_nonvolume_effective_mount_is_rejected(self):
        for override in (
            "services:\n  coder-db:\n    volumes: !reset []\n",
            "services:\n  coder-db:\n    volumes:\n      - /tmp:/var/lib/postgresql/data\n",
        ):
            with self.subTest(override=override):
                self.trace.write_text("")
                result = self.run_make(override=override)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("exactly one named data volume", result.stderr)
                self.assertNotIn("compose up", self.trace.read_text())

    def test_pgdata_and_volume_subpath_overrides_stop_parallel_up(self):
        for override in (
            "services:\n  coder-db:\n    environment:\n      PGDATA: /var/lib/postgresql/data/newcluster\n",
            "services:\n  coder-db:\n    environment:\n      PGDATA: ''\n",
            "services:\n  coder-db:\n    volumes:\n      - type: volume\n        source: coder_db_data\n        target: /var/lib/postgresql/data\n        volume:\n          subpath: newcluster\n",
        ):
            for existing in (
                {},
                {"PROJECT_coder-db": "devenv-cloud"},
                {"COMPOSE_PROJECT_NAME": "chosen-project"},
                {
                    "COMPOSE_PROJECT_NAME": "chosen-project",
                    "PROJECT_coder-db": "chosen-project",
                },
            ):
                with self.subTest(override=override, existing=existing):
                    self.trace.write_text("")
                    result = self.run_make(
                        override=override, extra=existing, arguments=("-j3",)
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Coder preflight failed", result.stderr)
                    self.assertNotIn("docker buildx build", self.trace.read_text())
                    self.assertNotIn("compose up", self.trace.read_text())

    def test_existing_database_pgdata_must_be_unambiguous_and_match(self):
        for settings in (
            {"ACTUAL_PGDATA": "/var/lib/postgresql/data/newcluster"},
            {"NO_PGDATA": "1"},
            {"DUP_PGDATA": "1"},
            {"PGDATA_FAILURE": "1"},
        ):
            with self.subTest(settings=settings):
                self.trace.write_text("")
                result = self.run_make(
                    extra={"PROJECT_coder-db": "devenv-cloud", **settings},
                    arguments=("-j3",),
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("existing coder-db PGDATA", result.stderr)
                self.assertNotIn("docker buildx build", self.trace.read_text())
                self.assertNotIn("compose up", self.trace.read_text())

    def test_existing_database_mount_declarations_must_prove_volume_root(self):
        path = "/var/lib/postgresql/data"
        entry = {
            "Type": "volume",
            "Source": "devenv-cloud_coder_db_data",
            "Target": path,
        }
        for settings in (
            {"HOST_SUBPATH": "newcluster"},
            {"HOST_MOUNTS_JSON": "null", "HOST_BINDS_JSON": "null"},
            {"HOST_MOUNTS_JSON": json.dumps([entry, entry])},
            {"HOST_MOUNTS_JSON": "not-json"},
            {"HOST_MOUNTS_JSON": "[null]"},
            {"HOST_MOUNTS_JSON": json.dumps([{**entry, "Source": "different"}])},
        ):
            with self.subTest(settings=settings):
                self.trace.write_text("")
                result = self.run_make(
                    extra={"PROJECT_coder-db": "devenv-cloud", **settings},
                    arguments=("-j3",),
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Coder preflight failed", result.stderr)
                self.assertNotIn("docker buildx build", self.trace.read_text())
                self.assertNotIn("compose up", self.trace.read_text())

    def test_database_default_and_legacy_root_mount_work_for_selected_project(self):
        for project in ("devenv-cloud", "chosen-project"):
            for binds in (
                None,
                json.dumps([f"{project}_coder_db_data:/var/lib/postgresql/data:rw"]),
            ):
                with self.subTest(project=project, binds=binds):
                    self.trace.write_text("")
                    extra = {
                        "COMPOSE_PROJECT_NAME": project,
                        "PROJECT_coder-db": project,
                    }
                    if binds is not None:
                        extra.update(
                            {"HOST_MOUNTS_JSON": "null", "HOST_BINDS_JSON": binds}
                        )
                    result = self.run_make(extra=extra, arguments=("-j3",))
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("compose up -d", self.trace.read_text())

    def test_database_image_override_is_rejected_before_parallel_builds(self):
        result = self.run_make(
            override="services:\n  coder-db:\n    image: postgres:18-alpine\n",
            arguments=("-j3",),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("database image must match", result.stderr)
        self.assertNotIn("docker buildx build", self.trace.read_text())
        self.assertNotIn("compose up", self.trace.read_text())

    def test_database_launch_override_cannot_change_data_directory(self):
        for override in (
            'services:\n  coder-db:\n    command: ["postgres", "-D", "/var/lib/postgresql/data/newcluster"]\n',
            'services:\n  coder-db:\n    entrypoint: ["/bin/sh", "-c", "exit 0"]\n',
            "services:\n  coder-db:\n    build: .\n",
        ):
            with self.subTest(override=override):
                self.trace.write_text("")
                result = self.run_make(override=override, arguments=("-j3",))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("must match the baseline", result.stderr)
                self.assertNotIn("docker buildx build", self.trace.read_text())
                self.assertNotIn("compose up", self.trace.read_text())

    def test_explicit_postgres_17_default_pgdata_is_allowed(self):
        result = self.run_make(
            override="services:\n  coder-db:\n    environment:\n      PGDATA: /var/lib/postgresql/data\n",
            extra={
                "COMPOSE_PROJECT_NAME": "chosen-project",
                "PROJECT_coder-db": "chosen-project",
            },
            arguments=("-j3",),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("compose up -d", self.trace.read_text())

    def test_resolver_rejects_ambiguous_effective_mounts(self):
        result = subprocess.run(
            [self.env["REAL_DOCKER"], "compose", "config", "--format", "json"],
            cwd=self.root,
            env=self.env,
            capture_output=True,
            text=True,
            check=True,
            timeout=20,
        )
        compose = json.loads(result.stdout)
        spec = importlib.util.spec_from_file_location(
            "coder_preflight", ROOT / "scripts/coder-preflight.py"
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertEqual(module.database_volume(compose), "devenv-cloud_coder_db_data")
        compose["services"]["coder-db"]["volumes"].append(
            {
                "type": "volume",
                "source": "coder_db_data",
                "target": "/var/lib/postgresql/data/",
            }
        )
        with self.assertRaisesRegex(ValueError, "exactly one named data volume"):
            module.database_volume(compose)

    def test_existing_custom_database_volume_is_allowed_when_it_matches(self):
        result = self.run_make(
            override="volumes:\n  coder_db_data:\n    name: existing-custom-volume\n",
            extra={
                "PROJECT_coder-db": "devenv-cloud",
                "DB_MOUNT": "volume:existing-custom-volume",
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("compose up -d", self.trace.read_text())

    def test_absent_database_baseline_uses_effective_compose_project(self):
        for override, extra in (
            ("name: chosen-project\n", {}),
            ("", {"COMPOSE_PROJECT_NAME": "chosen-project"}),
        ):
            with self.subTest(override=override, extra=extra):
                self.trace.write_text("")
                self.env.pop("COMPOSE_FILE", None)
                result = self.run_make(override=override, extra=extra)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("compose up -d", self.trace.read_text())

    def test_parallel_up_waits_for_preflight_before_builds(self):
        result = self.run_make(settings="CODER_VERSION=v2.36.4\n", arguments=("-j3",))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported CODER_VERSION", result.stderr)
        self.assertNotIn("docker buildx build", self.trace.read_text())
        self.assertNotIn("compose up", self.trace.read_text())
        self.trace.write_text("")
        result = self.run_make(arguments=("-j3",))
        self.assertEqual(result.returncode, 0, result.stderr)
        trace = self.trace.read_text()
        self.assertEqual(trace.count("docker buildx build"), 2)
        self.assertLess(trace.index("docker run"), trace.index("docker buildx build"))

    def test_standalone_build_targets_do_not_require_preflight(self):
        result = subprocess.run(
            ["make", "-j3", "temporal-worker-build", "lab-sim-build"],
            cwd=self.root,
            env=self.env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.trace.read_text().count("docker buildx build"), 2)
        self.assertNotIn("container ls", self.trace.read_text())

    def test_preflight_failure_does_not_print_environment_secrets(self):
        result = self.run_make(
            settings="CODER_VERSION=v2.36.4\nCODER_PG_PASSWORD=synthetic-secret\n"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported CODER_VERSION", result.stderr)
        self.assertNotIn("synthetic-secret", result.stdout + result.stderr)
        self.assertNotIn("compose up", self.trace.read_text())

    def test_additional_service_env_file_is_rejected(self):
        (self.root / "extra.env").write_text("CADE_CODER_SUPPORTED_VERSION=v2.38.6\n")
        result = self.run_make(
            override="services:\n  coder:\n    env_file: [extra.env]\n"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "supported version environment must not be overridden", result.stderr
        )
        self.assertNotIn("compose up", self.trace.read_text())

    def test_pin_drift_stops_before_up(self):
        (self.root / "coder/supported-version.env").write_text(
            "CADE_CODER_SUPPORTED_VERSION=v2.39.0\n"
        )
        result = self.run_make()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("effective Coder image must be", result.stderr)
        self.assertNotIn("compose up", self.trace.read_text())

    def test_invalid_or_missing_version_source_stops_before_up(self):
        path = self.root / "coder/supported-version.env"
        for contents in ("", "CADE_CODER_SUPPORTED_VERSION=${SOME_VAR}\n", None):
            with self.subTest(contents=contents):
                self.trace.write_text("")
                if contents is None:
                    path.unlink()
                else:
                    path.write_text(contents)
                result = self.run_make()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Coder preflight failed", result.stderr)
                self.assertNotIn("compose up", self.trace.read_text())

    def test_project_and_shell_env_do_not_override_supported_version(self):
        result = self.run_make(
            settings="CADE_CODER_SUPPORTED_VERSION=v2.36.4\n",
            extra={"CADE_CODER_SUPPORTED_VERSION": "v9.0.0"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Coder is healthy", result.stdout)

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
