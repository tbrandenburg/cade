"""Run the documented upgrade commands against isolated synthetic containers."""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def command(path, heading, marker):
    section = path.read_text().split(heading, 1)[1]
    for block in section.split("```bash\n")[1:]:
        code = block.split("\n```", 1)[0]
        if marker in code:
            return code
    raise ValueError(f"runbook command not found: {marker}")


class UpgradeRunbooksTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for directory in ("coder", "bin"):
            (self.root / directory).mkdir()
        for path in ("compose.yaml", "coder/supported-version.env"):
            shutil.copyfile(ROOT / path, self.root / path)
        (self.root / ".env").write_text("")
        self.trace = self.root / "trace"
        self.trace.write_text("")
        docker = self.root / "bin/docker"
        docker.write_text(
            """#!/usr/bin/python3
import os, pathlib, sys
args = sys.argv[1:]
with open(os.environ['TRACE'], 'a') as trace:
    trace.write('docker ' + ' '.join(args) + '\\n')
project = os.environ.get('COMPOSE_PROJECT_NAME', 'devenv-cloud')
stopped = pathlib.Path(os.environ['STOPPED'])
if args and args[0] == 'compose' and 'config' in args:
    os.execv(os.environ['REAL_DOCKER'], [os.environ['REAL_DOCKER'], *args])
if args[:2] == ['compose', 'ps']:
    print(os.environ.get('PS_ID', 'id-coder'))
    sys.exit(0)
if args[:2] == ['compose', 'stop']:
    if not os.environ.get('STOP_NOOP'):
        stopped.touch()
    sys.exit(0)
if args and args[0] == 'inspect':
    template, target = args[2], args[3]
    if target == os.environ.get('MISSING'):
        sys.exit(1)
    name = target.removeprefix('id-')
    if '.Id' in template:
        if name == 'coder-db' and stopped.exists() and os.environ.get('REPLACE_DB'):
            print('id-replacement')
        else:
            print('id-' + name)
    elif 'Labels' in template:
        label = os.environ.get('PROJECT_' + name, project)
        print(label + ':' + name)
    elif '.Mounts' in template:
        print(os.environ.get('MOUNT', 'volume:' + project + '_coder_db_data'))
    elif '.State.Running' in template:
        print('false' if name == 'coder' and stopped.exists() else 'true')
    else:
        sys.exit(2)
    sys.exit(0)
if args and args[0] == 'exec':
    if args[1] == '-i' and os.environ.get('RESTORE_FAILURE'):
        sys.exit(1)
    if args[1] != '-i' and os.environ.get('DUMP_FAILURE'):
        sys.exit(1)
    print('synthetic-dump')
    sys.exit(0)
if args and args[0] in ('stop', 'rm'):
    sys.exit(0)
sys.exit(99)
"""
        )
        docker.chmod(0o755)
        self.env = {
            "PATH": f"{self.root / 'bin'}:/usr/bin:/bin",
            "HOME": str(self.root),
            "TRACE": str(self.trace),
            "STOPPED": str(self.root / "stopped"),
            "REAL_DOCKER": shutil.which("docker"),
        }

    def runbook(self, name, extra=None):
        code = (
            command(ROOT / "README.md", "### Upgrading Coder to 2.38", "backup_dir=")
            if name == "backup"
            else command(
                ROOT / "docs/operations.md",
                "### Migrating from Promtail",
                'docker rm "$id"',
            )
        )
        return subprocess.run(
            ["/bin/bash", "-c", code],
            cwd=self.root,
            env={**self.env, **(extra or {})},
            capture_output=True,
            text=True,
            timeout=30,
        )

    def test_backup_uses_selected_custom_project_and_immutable_database_id(self):
        result = self.runbook("backup", {"COMPOSE_PROJECT_NAME": "chosen-project"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Coder database archive verified", result.stdout)
        calls = self.trace.read_text()
        self.assertIn("docker compose stop coder", calls)
        self.assertIn("docker exec id-coder-db sh -c", calls)
        self.assertIn("docker exec -i id-coder-db pg_restore --list", calls)

    def test_backup_refuses_wrong_project_volume_selection_or_absent_container(self):
        for values in (
            {"PROJECT_coder": "another-project"},
            {"PROJECT_coder-db": "another-project"},
            {"MOUNT": "volume:another-project_coder_db_data"},
            {"MISSING": "coder"},
            {"MISSING": "coder-db"},
            {"PS_ID": "id-other"},
        ):
            with self.subTest(values=values):
                self.trace.write_text("")
                result = self.runbook("backup", values)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("docker compose stop coder", self.trace.read_text())
                self.assertNotIn("docker exec ", self.trace.read_text())

    def test_backup_does_not_dump_after_noop_stop_or_container_replacement(self):
        for values in ({"STOP_NOOP": "1"}, {"REPLACE_DB": "1"}):
            with self.subTest(values=values):
                self.trace.write_text("")
                (self.root / "stopped").unlink(missing_ok=True)
                result = self.runbook("backup", values)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("docker compose stop coder", self.trace.read_text())
                self.assertNotIn("docker exec ", self.trace.read_text())

    def test_backup_does_not_report_success_after_dump_or_archive_failure(self):
        for values in ({"DUMP_FAILURE": "1"}, {"RESTORE_FAILURE": "1"}):
            with self.subTest(values=values):
                self.trace.write_text("")
                (self.root / "stopped").unlink(missing_ok=True)
                result = self.runbook("backup", values)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("docker exec id-coder-db", self.trace.read_text())
                self.assertNotIn("Coder database archive verified", result.stdout)
                if "DUMP_FAILURE" in values:
                    self.assertNotIn("docker exec -i", self.trace.read_text())

    def test_promtail_removal_uses_selected_custom_project(self):
        result = self.runbook("promtail", {"COMPOSE_PROJECT_NAME": "chosen-project"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("docker stop id-promtail", self.trace.read_text())
        self.assertIn("docker rm id-promtail", self.trace.read_text())

    def test_promtail_refuses_wrong_project_or_absent_container(self):
        for values in (
            {"PROJECT_promtail": "another-project"},
            {"MISSING": "promtail"},
        ):
            with self.subTest(values=values):
                self.trace.write_text("")
                result = self.runbook("promtail", values)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("docker stop ", self.trace.read_text())
                self.assertNotIn("docker rm ", self.trace.read_text())


if __name__ == "__main__":
    unittest.main()
