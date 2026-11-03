#!/usr/bin/env python3
"""Hermetic: every root/command/active-file probe is replaced; no SSH or Docker."""
import importlib.util
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("server_maintain", HERE / "maintain.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
sys.path.insert(0, str(HERE.parent))
from vacuum.engine import VacuumEngine, parse_server_maintenance_result
from vacuum.models import StepStatus


class MaintenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        (self.root / "run").mkdir()
        self.commands = []
        self.pressure = {"free_bytes": 10 * 1024**3, "total_bytes": 100 * 1024**3, "used_percent": 90}
        self.now = 2000000000
        self.tool = m.Maintenance(root=self.root, runner=self.runner, disk=lambda: dict(self.pressure),
                                  active_files=lambda: set(), clock=lambda: self.now, audit=lambda _: None)
        self.tool.process_start = lambda pid: 1234

    def runner(self, argv):
        self.commands.append(argv)
        return 0, ""

    def cache(self, name="old.deb"):
        directory = self.root / "var/cache/apt/archives"
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "lock").touch()
        path = directory / name
        path.write_bytes(b"cache")
        return path

    def test_healthy_does_not_inventory_run_or_lock(self):
        self.pressure.update(free_bytes=60 * 1024**3, used_percent=40)
        self.tool.files = lambda _: self.fail("healthy path scanned filesystem")
        result = self.tool.execute()
        self.assertEqual(result["status"], "skipped")
        self.assertEqual(list((self.root / "run").iterdir()), [])
        self.assertEqual(self.commands, [])

    def test_dry_run_has_no_lock_or_deletion(self):
        p = self.cache()
        result = self.tool.execute("run", ["package-cache"], dry_run=True)
        self.assertEqual(result["status"], "planned")
        self.assertTrue(p.exists())
        self.assertEqual(list((self.root / "run").iterdir()), [])

    def test_confirmation_and_duplicate_unknown_strategy_refused(self):
        for strategies, confirm in [(["package-cache"], False), (["x"], True), (["package-cache"] * 2, True)]:
            self.assertEqual(self.tool.execute("run", strategies, confirm)["status"], "failed")
        self.assertEqual(list((self.root / "run").iterdir()), [])

    def test_run_measures_removed_files_without_claiming_host_delta(self):
        p = self.cache()
        result = self.tool.execute("run", ["package-cache"], True)
        self.assertFalse(p.exists())
        self.assertEqual(result["removed_file_bytes"], 5)
        self.assertEqual(result["reclaimed_bytes"], 0)
        self.assertEqual(result["status"], "ran")
        self.assertTrue(result["lock"]["released"])
        self.assertFalse(self.tool.lock.exists())

    def test_active_symlink_hardlink_recent_and_keep_are_preserved(self):
        p = self.cache()
        s = p.stat()
        self.tool.active_files = lambda: {(s.st_dev, s.st_ino)}
        self.assertEqual(self.tool.execute("run", ["package-cache"], True)["status"], "skipped")
        self.assertTrue(p.exists())
        self.tool.active_files = lambda: set()
        os.link(p, p.with_name("hard.deb"))
        p.with_name("symlink.deb").symlink_to(p)
        self.assertEqual(self.tool.files("package-cache"), [])
        p.with_name("hard.deb").unlink()
        self.tool.clock = lambda: 0
        self.assertEqual(self.tool.files("package-cache"), [])
        self.tool.clock = lambda: self.now
        p.with_name(".JANITOR-KEEP").touch()
        self.assertEqual(self.tool.files("package-cache"), [])

    def test_changed_file_and_unknown_active_inventory_fail_closed(self):
        p = self.cache()
        candidates = self.tool.files("package-cache")
        p.write_text("changed")
        self.assertEqual(self.tool.remove_files("package-cache", candidates), 0)
        self.tool.active_files = lambda: (_ for _ in ()).throw(PermissionError())
        self.assertEqual(self.tool.execute("run", ["package-cache"], True)["status"], "failed")
        self.assertTrue(p.exists())

    def test_only_rotated_non_audit_logs_are_eligible(self):
        directory = self.root / "var/log/fleet-backup"
        directory.mkdir(parents=True)
        for name in ["backup.log", "backup.log.1.gz", "audit.log.1.gz", "auth.log.1.gz", "security.log.1.gz", "data.db.tmp"]:
            (directory / name).touch()
        self.assertEqual([name for name, _ in self.tool.files("rotated-logs")], ["backup.log.1.gz"])

    def test_unknown_legacy_or_live_lock_is_preserved(self):
        self.tool.lock.mkdir()
        self.assertEqual(self.tool.execute()["status"], "partial")
        self.assertTrue(self.tool.lock.exists())
        self.tool.lock.rmdir()
        self.assertTrue(self.tool.acquire_lock())
        self.assertEqual(self.tool.execute()["status"], "skipped")
        self.assertTrue(self.tool.lock.exists())

    def test_guard_contention_is_known_busy_and_skips_without_work(self):
        guard = os.open(self.tool.lock.with_suffix('.guard'), os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(guard, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.tool.execute()
        finally:
            os.close(guard)
        self.assertEqual(result['status'], 'skipped')
        self.assertIn('busy', result['reason'])
        self.assertFalse(self.tool.lock.exists())

    def test_reused_pid_recovery_requires_known_owner_and_no_dispatch(self):
        self.assertTrue(self.tool.acquire_lock())
        prior = self.tool.owner.copy()
        self.tool.process_start = lambda _: prior['start_ticks'] + 1
        self.assertTrue(self.tool.acquire_lock())
        self.assertNotEqual(self.tool.owner['nonce'], prior['nonce'])
        (self.tool.lock / 'dispatch.json').write_text('{}')
        self.tool.process_start = lambda _: prior['start_ticks'] + 2
        self.assertFalse(self.tool.acquire_lock())
        self.assertEqual(self.tool.lock_state, 'unknown')
        result = self.tool.execute()
        self.assertEqual(result['status'], 'partial')
        self.assertIn('requires inspection', result['reason'])

    def test_unreadable_live_start_is_not_recovery_evidence_or_benign_busy(self):
        self.assertTrue(self.tool.acquire_lock())
        owner = (self.tool.lock / 'owner.json').read_bytes()
        self.tool.process_start = lambda _: (_ for _ in ()).throw(PermissionError())
        result = self.tool.execute()
        self.assertEqual(result['status'], 'partial')
        self.assertEqual((self.tool.lock / 'owner.json').read_bytes(), owner)
        self.assertIn('requires inspection', result['reason'])

    def test_malformed_process_stat_raises_value_error_and_execute_returns_json(self):
        directory = self.root / 'proc' / str(os.getpid())
        directory.mkdir(parents=True)
        for text in ('truncated', f'{os.getpid()} (with ) parentheses) S 1',
                     f'{os.getpid()} (worker) ' + ' '.join(['S'] + ['0'] * 19)):
            (directory / 'stat').write_text(text)
            with self.assertRaises(ValueError):
                m.Maintenance.process_start(self.tool, os.getpid())
        self.tool.process_start = lambda pid: m.Maintenance.process_start(self.tool, pid)
        result = self.tool.execute('run', ['package-cache'], True)
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(json.loads(json.dumps(result))['schema_version'], 1)

    def test_image_json_preserves_pipe_labels_and_revalidates_only_each_identity(self):
        identities = ['sha256:' + letter * 64 for letter in ('a', 'b', 'c')]
        calls = []
        def runner(argv):
            calls.append(argv)
            if 'ls' in argv:
                return 0, '\n'.join(identities)
            if 'inspect' in argv:
                template = argv[argv.index('--format') + 1]
                self.assertIn('"created":', template)
                self.assertNotIn('Config.Env', template)
                return 0, json.dumps(dict(created='2020-01-01T00:00:00Z', tags=[], labels={'description': 'valid|label'}))
            self.assertIn('rm', argv)
            self.assertTrue((self.tool.lock / 'dispatch.json').exists())
            return 0, ''
        self.tool.runner = runner
        result = self.tool.execute('run', ['docker-images'], True)
        self.assertEqual(result['status'], 'ran')
        self.assertEqual(result['strategies'][0]['attempted_count'], 3)
        self.assertEqual(sum('ls' in a for a in calls), 1)
        self.assertEqual(sum('inspect' in a for a in calls), 2 * len(identities))
        self.assertEqual(sum('rm' in a for a in calls), len(identities))

    def test_image_tag_or_keep_change_during_single_identity_recheck_prevents_removal(self):
        identity = 'sha256:' + 'a' * 64
        for tags, labels in [(['current:tag'], {}), ([], {'JANITOR-KEEP': 'yes'})]:
            with self.subTest(tags=tags, labels=labels):
                inspects = []
                def runner(argv):
                    if 'ls' in argv:
                        return 0, identity
                    self.assertIn('inspect', argv, 'changed image was removed')
                    inspects.append(argv[-1])
                    return 0, json.dumps(dict(created='2020-01-01T00:00:00Z',
                        tags=[] if len(inspects) == 1 else tags, labels={} if len(inspects) == 1 else labels))
                self.tool.runner = runner
                result = self.tool.execute('run', ['docker-images'], True)
                self.assertEqual(result['status'], 'skipped')
                self.assertEqual(inspects, [identity, identity])
    def test_known_dead_lock_recovery_and_owner_mismatch(self):
        self.assertTrue(self.tool.acquire_lock())
        with patch.object(m.os, "kill", side_effect=ProcessLookupError):
            self.assertTrue(self.tool.acquire_lock())
        owner = self.tool.owner.copy()
        self.tool.owner["nonce"] = "0" * 32
        with self.assertRaises(OSError):
            self.tool.release_lock()
        self.tool.owner = owner
        self.tool.release_lock()

    def test_dispatch_record_precedes_runner_and_only_success_clears_it(self):
        self.assertTrue(self.tool.acquire_lock())
        marker = self.tool.lock / 'dispatch.json'
        def runner(argv):
            record = json.loads(marker.read_text())
            self.assertEqual(record['owner'], self.tool.owner)
            self.assertEqual(record['strategy'], 'docker-build-cache')
            self.assertEqual(record['identity'], 'cache-record')
            self.assertEqual(marker.stat().st_mode & 0o777, 0o600)
            contender = m.Maintenance(root=self.root)
            with patch.object(m.os, 'kill', side_effect=ProcessLookupError):
                self.assertFalse(contender.acquire_lock())
            return 0, 'completed'
        self.tool.runner = runner
        self.assertEqual(self.tool.mutation(['harmless-injected-command'], 'docker-build-cache', 'cache-record'),
                         (0, 'completed'))
        self.assertFalse(marker.exists())
        self.tool.release_lock()

    def test_nonzero_or_exception_retains_dispatch_and_refuses_dead_owner_recovery(self):
        for failure in (False, True):
            with self.subTest(exception=failure):
                self.assertTrue(self.tool.acquire_lock())
                def runner(_):
                    if failure:
                        raise OSError('transport failed')
                    return 1, ''
                self.tool.runner = runner
                with self.assertRaises(m.StopWork):
                    self.tool.mutation(['harmless-injected-command'], 'docker-build-cache', 'cache-record')
                self.assertTrue((self.tool.lock / 'dispatch.json').exists())
                with self.assertRaises(OSError):
                    self.tool.release_lock()
                with patch.object(m.os, 'kill', side_effect=ProcessLookupError):
                    self.assertFalse(self.tool.acquire_lock())
                # Test fixture retirement only; production requires operator review.
                (self.tool.lock / 'dispatch.json').unlink()
                self.tool.release_lock()

    def test_execute_wraps_each_external_mutation_and_clears_confirmed_dispatch(self):
        self.tool.docker_candidates = lambda _: ['first-record', 'second-record']
        self.tool.verify_local_builder = lambda: None
        records = []
        def runner(_):
            records.append(json.loads((self.tool.lock / 'dispatch.json').read_text())['identity'])
            return 0, ''
        self.tool.runner = runner
        result = self.tool.execute('run', ['docker-build-cache'], True)
        self.assertEqual(records, ['first-record', 'second-record'])
        self.assertEqual(result['status'], 'ran')
        self.assertEqual(result['strategies'][0]['attempted_count'], 2)
        self.assertTrue(result['lock']['released'])

    def test_uncertain_dispatch_stops_before_later_cleanup_and_retains_lock(self):
        cache = self.cache()
        self.tool.docker_candidates = lambda _: ['cache-record']
        self.tool.verify_local_builder = lambda: None
        self.tool.runner = lambda _: (1, '')
        result = self.tool.execute('run', ['docker-build-cache', 'package-cache'], True)
        self.assertEqual(result['status'], 'partial')
        self.assertFalse(result['lock']['released'])
        self.assertTrue(cache.exists())
        self.assertTrue((self.tool.lock / 'dispatch.json').exists())
        with patch.object(m.os, 'kill', side_effect=ProcessLookupError):
            self.assertFalse(self.tool.acquire_lock())

    def test_sigkill_parent_leaves_detached_harmless_child_and_unrecoverable_dispatch(self):
        child_file = self.root / 'owned-child-pid'
        fixture = '''
import importlib.util, os, pathlib, signal, subprocess, sys
spec = importlib.util.spec_from_file_location('fixture_maintain', sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
tool = m.Maintenance(root=pathlib.Path(sys.argv[2]))
tool.process_start = lambda _: 1234
assert tool.acquire_lock()
def runner(_):
    child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(20)'],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    pathlib.Path(sys.argv[3]).write_text(str(child.pid))
    os.kill(os.getpid(), signal.SIGKILL)
tool.runner = runner
tool.mutation(['harmless-injected-command'], 'docker-build-cache', 'cache-record')
'''
        try:
            result = subprocess.run([sys.executable, '-c', fixture, str(HERE / 'maintain.py'),
                                     str(self.root), str(child_file)], capture_output=True, timeout=5)
            self.assertEqual(result.returncode, -signal.SIGKILL, result.stderr)
            os.kill(int(child_file.read_text()), 0)
            self.assertTrue((self.tool.lock / 'dispatch.json').exists())
            # The real recorded owner is dead; its detached child is still alive.
            self.assertFalse(self.tool.acquire_lock())
            self.assertTrue((self.tool.lock / 'owner.json').exists())
        finally:
            if child_file.exists():
                try:
                    os.kill(int(child_file.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_scheduled_does_not_opt_into_image_removal(self):
        self.tool.execute()
        self.assertFalse(any("image" in x for x in self.commands))

    def test_cache_eligibility_is_age_unused_immutable_private_regular(self):
        base = dict(ID="abcdefghijklm", LastUsedAt="2020-01-01T00:00:00Z", Reclaimable=True,
                    Mutable=False, Shared=False, Type="regular")
        records = [base] + [dict(base, **changes) for changes in [dict(Mutable=True), dict(Shared=True),
                   dict(Reclaimable=False), dict(Type="exec.cachemount"), dict(LastUsedAt="2035-01-01T00:00:00Z")]]
        self.tool.runner = lambda argv: (0, "Driver: docker\nEndpoint: default\n" if argv[-1] == "inspect" else "\n".join(map(json.dumps, records)))
        self.assertEqual(self.tool.docker_candidates("docker-build-cache"), [base["ID"]])

    def test_remote_or_unknown_builder_refuses_without_prune(self):
        for output in ["Driver: docker-container\nEndpoint: default\n", "Driver: docker\nEndpoint: ssh://remote.example\n", "unrecognized"]:
            self.tool.runner = lambda _: (0, output)
            with self.assertRaises(ValueError):
                self.tool.docker_candidates("docker-build-cache")

    def test_no_candidates_means_no_prune_and_failure_not_ran(self):
        self.tool.runner = lambda _: (1, "unsupported")
        result = self.tool.execute("run", ["docker-build-cache"], True)
        self.assertEqual(result["status"], "failed")
        self.assertTrue(result["lock"]["released"])

    def test_cancel_and_budget_release_own_lock(self):
        self.tool.files = lambda _: (_ for _ in ()).throw(m.StopWork("cancelled"))
        self.tool.cancelled = True
        result = self.tool.execute("run", ["package-cache"], True)
        self.assertEqual(result["status"], "cancelled")
        self.assertFalse(self.tool.lock.exists())

    def test_output_limit_and_timeout_kill_child(self):
        tool = m.Maintenance(root=self.root, budget=0.2)
        with self.assertRaises(m.StopWork):
            tool.command([sys.executable, "-c", "import time; time.sleep(3)"])
        tool = m.Maintenance(root=self.root)
        with self.assertRaises(m.StopWork):
            tool.command([sys.executable, "-c", "import sys; sys.stdout.write('x'*2000000)"])

    def test_readonly_inventory_timeout_reaps_child_and_releases_lock(self):
        self.tool.deadline = time.monotonic() + 0.3
        self.tool.docker_candidates = lambda _: self.tool.command(
            [sys.executable, '-c', 'import time; time.sleep(20)'])
        children, popen = [], subprocess.Popen
        def launch(*args, **kwargs):
            child = popen(*args, **kwargs)
            children.append(child)
            return child
        with patch.object(m.subprocess, 'Popen', side_effect=launch):
            result = self.tool.execute('run', ['docker-build-cache'], True)
        self.assertEqual(len(children), 1)
        self.assertEqual(children[0].returncode, -signal.SIGKILL)
        self.assertTrue(children[0].stdout.closed)
        self.assertEqual(result['status'], 'partial')
        self.assertTrue(result['lock']['released'])
        self.assertFalse(self.tool.uncertain_child)
        self.assertFalse(self.tool.lock.exists())

    def test_mutating_timeout_reaps_cli_but_keeps_daemon_dispatch_lock(self):
        self.tool.deadline = time.monotonic() + 0.3
        self.tool.docker_candidates = lambda _: ['cache-record']
        self.tool.verify_local_builder = lambda: None
        self.tool.runner = lambda _: self.tool.command(
            [sys.executable, '-c', 'import time; time.sleep(20)'])
        children, popen = [], subprocess.Popen
        def launch(*args, **kwargs):
            child = popen(*args, **kwargs)
            children.append(child)
            return child
        with patch.object(m.subprocess, 'Popen', side_effect=launch):
            result = self.tool.execute('run', ['docker-build-cache'], True)
        self.assertEqual(len(children), 1)
        self.assertEqual(children[0].returncode, -signal.SIGKILL)
        self.assertTrue(children[0].stdout.closed)
        self.assertEqual(result['status'], 'partial')
        self.assertFalse(result['lock']['released'])
        self.assertFalse(self.tool.uncertain_child)
        self.assertTrue((self.tool.lock / 'dispatch.json').exists())
        with patch.object(m.os, 'kill', side_effect=ProcessLookupError):
            self.assertFalse(self.tool.acquire_lock())

    def test_audit_failure_prevents_deletion_and_uncertain_child_retains_lock(self):
        path = self.cache()
        self.tool.audit = lambda _: (_ for _ in ()).throw(PermissionError())
        result = self.tool.execute("run", ["package-cache"], True)
        self.assertTrue(path.exists())
        self.assertIn(result["status"], ("partial", "failed"))
        self.assertFalse(self.tool.lock.exists())
        self.tool.audit = lambda _: None
        self.tool.uncertain_child = True
        result = self.tool.execute("run", ["package-cache"], True)
        self.assertFalse(result["lock"]["released"])
        self.assertTrue(self.tool.lock.exists())
        with patch.object(m.os, "kill", side_effect=ProcessLookupError):
            self.assertFalse(self.tool.acquire_lock())

    def test_partial_file_failure_keeps_successful_unlink_evidence(self):
        first = self.cache("first.deb")
        second = self.cache("second.deb")
        unlink = m.os.unlink
        removed = []
        def fail_second(path, *args, **kwargs):
            if kwargs.get('dir_fd') is not None:
                if removed:
                    raise PermissionError()
                removed.append(path)
            return unlink(path, *args, **kwargs)
        with patch.object(m.os, 'unlink', side_effect=fail_second):
            result = self.tool.execute("run", ["package-cache"], True)
        self.assertEqual(result['status'], 'partial')
        self.assertEqual(result['strategies'][0]['removed_count'], 1)
        self.assertEqual(result['removed_file_bytes'], 5)
        self.assertNotEqual(first.exists(), second.exists())

    def test_deployment_plan_is_read_only_and_symlinks_refused(self):
        spec = importlib.util.spec_from_file_location("server_deploy", HERE / "deploy.py")
        deploy = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(deploy)
        legacy = self.root / "etc/cron.daily/coolify-auto-maintenance"
        legacy.parent.mkdir(parents=True)
        legacy.write_text("#!/bin/sh\nexit 0\n")
        before = sorted(str(p.relative_to(self.root)) for p in self.root.rglob("*"))
        plan = deploy.deploy(self.root)
        self.assertFalse(plan["apply"])
        self.assertEqual(before, sorted(str(p.relative_to(self.root)) for p in self.root.rglob("*")))
        legacy.unlink()
        legacy.symlink_to(self.root / "missing")
        with self.assertRaises(ValueError):
            deploy.deploy(self.root)


class CallerTests(unittest.TestCase):
    setUp = MaintenanceTests.setUp
    runner = MaintenanceTests.runner
    def response(self, status="skipped"):
        r = self.tool.execute()
        r["mode"], r["status"] = "scheduled", status
        return r

    def engine(self):
        obj = object.__new__(VacuumEngine)
        obj.cfg = {"coolify_ssh_host": "server.example"}
        obj._step_freed = 0
        return obj

    def test_invalid_shapes_and_fake_booleans_are_refused(self):
        valid = self.response()
        for key, value in [("schema_version", True), ("reclaimed_bytes", True), ("candidate_count", False),
                           ("duration_seconds", float("nan")), ("strategies", [{}]), ("dry_run", 0)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                parse_server_maintenance_result(json.dumps(dict(valid, **{key: value})))
        for raw in ["", "permission denied", "[]", "null", '{"schema_version":1,"schema_version":1}', json.dumps(valid) + "noise"]:
            with self.assertRaises((ValueError, TypeError)):
                parse_server_maintenance_result(raw)

    def test_duplicate_unknown_strategy_and_fabricated_success_refused(self):
        valid = self.response()
        item = dict(id="package-cache", status="ran", candidate_count=1, removed_count=1, attempted_count=0)
        for strategies in [[item, item], [dict(item, id="unknown")]]:
            with self.assertRaises(ValueError):
                parse_server_maintenance_result(json.dumps(dict(valid, strategies=strategies)))
        with self.assertRaises(ValueError):
            parse_server_maintenance_result(json.dumps(dict(valid, status="ran")))

    def test_caller_honors_skip_failure_timeout_and_missing_install(self):
        obj = self.engine()
        for code, raw, expected in [(0, json.dumps(self.response()), StepStatus.SKIPPED),
                                    (1, json.dumps(self.response("failed")), StepStatus.FAILED),
                                    (0, "malformed", StepStatus.FAILED), (127, "", StepStatus.FAILED)]:
            with patch("vacuum.engine.work.run_process", return_value=subprocess.CompletedProcess([], code, raw, "")):
                self.assertEqual(obj._coolify_remote()[2], expected)
        with patch("vacuum.engine.work.run_process", side_effect=subprocess.TimeoutExpired("ssh", 110)):
            self.assertEqual(obj._coolify_remote()[2], StepStatus.FAILED)

    def test_empty_ssh_and_remote_command_failures_have_distinct_safe_reasons(self):
        obj = self.engine()
        for code, stdout, expected in [(255, b'', 'SSH connection or authentication failed'),
                                       (1, ' \n', 'verify installation and sudo access'),
                                       (0, '', 'invalid result')]:
            with self.subTest(code=code), patch('vacuum.engine.work.run_process',
                    return_value=subprocess.CompletedProcess([], code, stdout, 'private diagnostic')):
                _, reason, status = obj._coolify_remote()
                self.assertEqual(status, StepStatus.FAILED)
                self.assertIn(expected, reason)
                self.assertNotIn('private diagnostic', reason)


if __name__ == "__main__":
    unittest.main()
