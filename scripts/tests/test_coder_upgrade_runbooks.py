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
        for directory in ("coder", "bin", "scripts"):
            (self.root / directory).mkdir()
        for path in ("compose.yaml",):
            shutil.copyfile(ROOT / path, self.root / path)
        (self.root / ".env").write_text("")
        self.trace = self.root / "trace"
        self.trace.write_text("")
        docker = self.root / "bin/docker"
        docker.write_text(
            """#!/usr/bin/python3
import os, pathlib, signal, sys
args = sys.argv[1:]
with open(os.environ['TRACE'], 'a') as trace:
    trace.write('docker ' + ' '.join(args) + '\\n')
project = os.environ.get('COMPOSE_PROJECT_NAME', 'devenv-cloud')
stopped = pathlib.Path(os.environ['STOPPED'])
if args and args[0] == 'compose' and 'config' in args:
    os.execv(os.environ['REAL_DOCKER'], [os.environ['REAL_DOCKER'], *args])
if args[:3] == ['compose', 'pull', 'coder']:
    sys.exit(1 if os.environ.get('PULL_FAILURE') else 0)
if args[:2] == ['compose', 'up']:
    with open(os.environ['TRACE'], 'a') as trace:
        trace.write('up orphan policy ' + os.environ.get('COMPOSE_REMOVE_ORPHANS', '') + '\\n')
    if not pathlib.Path(os.environ['STOPPED'] + '-archive-verified').exists():
        sys.exit(98)
    sys.exit(1 if os.environ.get('UP_FAILURE') else 0)
if args[:2] == ['compose', 'ps']:
    print('id-replacement' if stopped.exists() and (os.environ.get('REPLACE_CODER')
          or os.environ.get('REPLACE_SELECTION'))
          else os.environ.get('PS_ID', 'id-coder'))
    sys.exit(0)
if args[:2] == ['compose', 'stop']:
    if os.environ.get('STOP_DELAYED'):
        pathlib.Path(os.environ['STOPPED'] + '-pending').touch()
        sys.exit(1)
    if not os.environ.get('STOP_NOOP'):
        stopped.touch()
    if os.environ.get('STOP_FAILURE'):
        sys.exit(1)
    sys.exit(0)
if args and args[0] == 'inspect':
    template, target = args[2], args[3]
    if target == os.environ.get('MISSING') or (stopped.exists()
            and target == os.environ.get('MISSING_AFTER_STOP')):
        sys.exit(1)
    name = target.removeprefix('id-')
    if '.Id' in template:
        if name == 'coder-db' and stopped.exists() and os.environ.get('REPLACE_DB'):
            print('id-replacement')
        elif target == 'coder' and stopped.exists() and os.environ.get('REPLACE_CODER'):
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
    if os.environ.get('SIGNAL_DURING_DUMP'):
        os.kill(os.getppid(), getattr(signal, os.environ['SIGNAL_DURING_DUMP']))
        sys.exit(1)
    if os.environ.get('REPLACE_DB_DURING_DUMP'):
        pathlib.Path(os.environ['STOPPED'] + '-db-replaced').touch()
        sys.exit(1)
    if args[1] == '-i' and os.environ.get('RESTORE_FAILURE'):
        sys.exit(1)
    if args[1] == '-i':
        if sys.stdin.read() != 'synthetic-dump\\n':
            sys.exit(98)
        pathlib.Path(os.environ['STOPPED'] + '-archive-verified').touch()
        sys.exit(0)
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
        make = self.root / "bin/make"
        make.write_text(
            """#!/usr/bin/python3
import os, pathlib, sys
with open(os.environ['TRACE'], 'a') as trace:
    trace.write('make ' + ' '.join(sys.argv[1:]) + '\\n')
if sys.argv[1:] != ['coder-preflight']:
    sys.exit(99)
count = pathlib.Path(os.environ['TRACE']).read_text().count('make coder-preflight\\n')
if count == 2:
    if not pathlib.Path(os.environ['STOPPED'] + '-archive-verified').exists():
        sys.exit(98)
    sys.exit(1 if os.environ.get('SECOND_PREFLIGHT_FAILURE') else 0)
sys.exit(1 if os.environ.get('PREFLIGHT_FAILURE') else 0)
"""
        )
        make.chmod(0o755)
        (self.root / "scripts/wait-for-coder.sh").write_text(
            """#!/bin/bash
printf 'wait-for-coder\\n' >>"$TRACE"
if [ "${HEALTH_FAILURE:-}" = 1 ]; then exit 1; fi
"""
        )
        self.env = {
            "PATH": f"{self.root / 'bin'}:/usr/bin:/bin",
            "HOME": str(self.root),
            "TRACE": str(self.trace),
            "STOPPED": str(self.root / "stopped"),
            "REAL_DOCKER": shutil.which("docker"),
        }

    def runbook(self, name, extra=None):
        if name == "backup":
            (self.root / "stopped-archive-verified").unlink(missing_ok=True)
            code = command(
                ROOT / "README.md", "### Upgrading Coder to 2.38", "backup_dir="
            )
        else:
            code = command(
                ROOT / "docs/operations.md",
                "### Migrating from Promtail",
                'docker rm "$id"',
            )
        return subprocess.run(
            ["/bin/bash", "-c", code],
            cwd=self.root,
            env={**self.env, **(extra or {})},
            capture_output=True,
            text=True,
            timeout=30,
        )

    def test_preparation_precedes_successful_backup(self):
        result = self.runbook("backup", {"COMPOSE_REMOVE_ORPHANS": "1"})
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.trace.read_text()
        self.assertLess(
            calls.index("docker compose pull coder"),
            calls.index("make coder-preflight"),
        )
        self.assertLess(
            calls.index("make coder-preflight"),
            calls.index("docker compose stop coder"),
        )
        self.assertIn("Coder database archive verified", result.stdout)
        self.assertEqual(calls.count("make coder-preflight"), 2)
        self.assertLess(
            calls.index("docker exec -i id-coder-db pg_restore --list"),
            calls.rindex("make coder-preflight"),
        )
        self.assertLess(
            calls.rindex("make coder-preflight"),
            calls.index("docker compose up -d --no-deps coder"),
        )
        self.assertIn("up orphan policy 0", calls)
        self.assertIn("wait-for-coder", calls)
        self.assertTrue((self.root / "stopped").exists())

    def test_preparation_failure_never_stops_coder(self):
        for values in ({"PULL_FAILURE": "1"}, {"PREFLIGHT_FAILURE": "1"}):
            with self.subTest(values=values):
                self.trace.write_text("")
                result = self.runbook("backup", values)
                calls = self.trace.read_text()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("docker compose pull coder", calls)
                self.assertEqual(
                    "make coder-preflight" in calls, "PREFLIGHT_FAILURE" in values
                )
                self.assertNotIn("docker compose stop coder", calls)
                self.assertNotIn("docker exec ", calls)
                self.assertFalse((self.root / "stopped").exists())
                self.assert_no_recovery(calls)

    def assert_no_recovery(self, calls):
        for operation in (
            "docker start ",
            "docker compose start ",
            "docker compose up ",
            "docker run ",
            "docker rm ",
        ):
            self.assertNotIn(operation, calls)

    def assert_no_old_restart(self, calls):
        self.assertNotIn("docker start ", calls)
        self.assertNotIn("docker compose start ", calls)
        self.assertNotIn("docker rm ", calls)

    def assert_recovery_warning(self, result):
        self.assertIn("Coder state may still be changing", result.stderr)
        self.assertIn("Wait for any in-flight stop", result.stderr)
        self.assertIn("database ID id-coder-db", result.stderr)
        self.assertIn("project devenv-cloud", result.stderr)
        self.assertIn("database volume devenv-cloud_coder_db_data", result.stderr)
        self.assertIn("migration schema before any manual restart", result.stderr)
        self.assertIn("No restart or recreation was attempted", result.stderr)
        self.assert_no_recovery(self.trace.read_text())
        self.assertEqual(self.trace.read_text().count("make coder-preflight"), 1)

    def test_backup_uses_selected_custom_project_and_immutable_database_id(self):
        result = self.runbook("backup", {"COMPOSE_PROJECT_NAME": "chosen-project"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Coder database archive verified", result.stdout)
        calls = self.trace.read_text()
        self.assertIn("docker compose stop coder", calls)
        self.assertIn("docker exec id-coder-db sh -c", calls)
        self.assertIn("docker exec -i id-coder-db pg_restore --list", calls)
        self.assert_no_old_restart(calls)
        self.assertIn("docker compose up -d --no-deps coder", calls)
        self.assertTrue((self.root / "stopped").exists())

    def test_failure_after_verified_backup_warns_and_never_restarts_old_coder(self):
        for values in (
            {"SECOND_PREFLIGHT_FAILURE": "1"},
            {"UP_FAILURE": "1"},
            {"HEALTH_FAILURE": "1"},
        ):
            with self.subTest(values=values):
                self.trace.write_text("")
                (self.root / "stopped").unlink(missing_ok=True)
                result = self.runbook("backup", values)
                calls = self.trace.read_text()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls.count("make coder-preflight"), 2)
                path = result.stdout.split("Coder database archive verified: ", 1)[
                    1
                ].splitlines()[0]
                self.assertTrue(Path(path).is_file())
                self.assertIn(f"Verified backup: {path}", result.stderr)
                self.assertIn("migration schema before recovery", result.stderr)
                self.assertIn("database ID id-coder-db", result.stderr)
                self.assertIn(
                    "No automatic rollback or restart of old Coder", result.stderr
                )
                self.assert_no_old_restart(calls)
                self.assertEqual(
                    "docker compose up -d --no-deps coder" in calls,
                    "SECOND_PREFLIGHT_FAILURE" not in values,
                )
                self.assertEqual("wait-for-coder" in calls, "HEALTH_FAILURE" in values)

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
                self.assert_no_recovery(self.trace.read_text())
                self.assertEqual(
                    self.trace.read_text().count("make coder-preflight"), 1
                )

    def test_backup_does_not_dump_after_noop_stop_or_container_replacement(self):
        for values in ({"STOP_NOOP": "1"}, {"REPLACE_DB": "1"}):
            with self.subTest(values=values):
                self.trace.write_text("")
                (self.root / "stopped").unlink(missing_ok=True)
                result = self.runbook("backup", values)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("docker compose stop coder", self.trace.read_text())
                self.assertNotIn("docker exec ", self.trace.read_text())
                self.assert_recovery_warning(result)
                self.assertEqual(
                    (self.root / "stopped").exists(), "REPLACE_DB" in values
                )

    def test_backup_does_not_report_success_after_dump_or_archive_failure(self):
        for values in ({"DUMP_FAILURE": "1"}, {"RESTORE_FAILURE": "1"}):
            with self.subTest(values=values):
                self.trace.write_text("")
                (self.root / "stopped").unlink(missing_ok=True)
                result = self.runbook("backup", values)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("docker exec id-coder-db", self.trace.read_text())
                self.assertNotIn("Coder database archive verified", result.stdout)
                self.assert_recovery_warning(result)
                self.assertTrue((self.root / "stopped").exists())
                if "DUMP_FAILURE" in values:
                    self.assertNotIn("docker exec -i", self.trace.read_text())

    def test_backup_warns_when_stop_fails_after_stopping(self):
        result = self.runbook("backup", {"STOP_FAILURE": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assert_recovery_warning(result)
        self.assertNotIn("docker exec ", self.trace.read_text())
        self.assertTrue((self.root / "stopped").exists())

    def test_backup_warns_when_failed_stop_may_finish_later(self):
        result = self.runbook("backup", {"STOP_DELAYED": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assert_recovery_warning(result)
        self.assertTrue((self.root / "stopped-pending").exists())
        self.assertFalse((self.root / "stopped").exists())
        self.assertNotIn("docker exec ", self.trace.read_text())
        (self.root / "stopped").touch()
        self.assertTrue((self.root / "stopped").exists())
        self.assert_no_recovery(self.trace.read_text())

    def test_backup_does_not_restart_when_database_changes_during_dump(self):
        result = self.runbook("backup", {"REPLACE_DB_DURING_DUMP": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.root / "stopped-db-replaced").exists())
        self.assertTrue((self.root / "stopped").exists())
        self.assertIn("docker exec id-coder-db", self.trace.read_text())
        self.assert_recovery_warning(result)

    def test_backup_warns_if_coder_or_database_identity_changes(self):
        for values in (
            {"REPLACE_CODER": "1"},
            {"REPLACE_DB": "1"},
            {"MISSING_AFTER_STOP": "id-coder"},
        ):
            with self.subTest(values=values):
                self.trace.write_text("")
                (self.root / "stopped").unlink(missing_ok=True)
                result = self.runbook("backup", values)
                self.assertNotEqual(result.returncode, 0)
                self.assert_recovery_warning(result)
                self.assertNotIn("docker exec ", self.trace.read_text())
                self.assertTrue((self.root / "stopped").exists())

    def test_backup_warns_on_signal_during_dump(self):
        for sig in ("SIGTERM", "SIGHUP"):
            with self.subTest(signal=sig):
                self.trace.write_text("")
                (self.root / "stopped").unlink(missing_ok=True)
                result = self.runbook("backup", {"SIGNAL_DURING_DUMP": sig})
                self.assertNotEqual(result.returncode, 0)
                self.assert_recovery_warning(result)
                self.assertNotIn("Coder database archive verified", result.stdout)
                self.assertTrue((self.root / "stopped").exists())

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
