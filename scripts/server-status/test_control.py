import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import pwd
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('control', Path(__file__).with_name('control.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
BOOT = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
CID = 'a' * 64
STARTED = '2026-11-03T00:00:00Z'


def write_process(root, pid=4242, name='worker', start_time=999, cgroup='0::/user.slice/session-1.scope', ppid=1):
    path = root / str(pid)
    path.mkdir(parents=True, exist_ok=True)
    tail = ['S', str(ppid)] + ['0'] * 9 + ['10', '5'] + ['0'] * 3 + ['0', '2', '0', str(start_time)] + ['0'] * 20
    (path / 'stat').write_text(f'{pid} ({name}) ' + ' '.join(tail))
    (path / 'comm').write_text(name)
    (path / 'cgroup').write_text(cgroup)
    (path / 'status').write_text('VmRSS: 32 kB\nVmSwap: 12 kB\n')
    if not (path / 'exe').is_symlink():
        (path / 'exe').symlink_to('/usr/bin/' + name)
    return path


class ControlTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.proc = Path(self.temp.name).resolve() / 'proc'
        (self.proc / 'sys/kernel/random').mkdir(parents=True)
        (self.proc / 'sys/kernel/random/boot_id').write_text(BOOT)
        write_process(self.proc)
        self.owners = module.ALLOWED_OWNERS + (pwd.getpwuid(os.getuid()).pw_name,)
        self.sent = []
        self.priority = 3
        self.closed = []

    def action(self, action='quit', **overrides):
        kwargs = dict(proc=self.proc, ancestors=set(), containers=[], owners=self.owners,
                      pidfd_open=lambda pid, flags: 55,
                      send=lambda fd, sig, *_: self.sent.append((fd, sig)), close=self.closed.append,
                      state_dir=self.proc.parent / 'state',
                      getpriority=lambda *_: self.priority,
                      setpriority=lambda _, pid, value: setattr(self, 'priority', value))
        kwargs.update(overrides)
        return module.process_action(action, 4242, 999, BOOT, **kwargs)

    def row(self, **changes):
        row = dict(id=CID, container='worker-box', name='worker-box', display_name='example / worker',
                   project='example', resource='worker', service=None, type='application', status='running',
                   started_at=STARTED, protection_reason=None)
        row.update(changes)
        return row

    def test_real_harmless_owned_runner_success_and_nonzero(self):
        result = module.bounded_run([sys.executable, '-c', "print('bounded')"], timeout=2)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, 'bounded\n')
        result = module.bounded_run([sys.executable, '-c', "import sys; print('failed'); sys.exit(7)"], timeout=2)
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout, 'failed\n')

    def test_real_harmless_owned_runner_timeout_and_output_limit(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            module.bounded_run([sys.executable, '-c', 'import time; time.sleep(3)'], timeout=0.1)
        with self.assertRaises(ValueError):
            module.bounded_run([sys.executable, '-c', "print('x' * 10000)"], timeout=2, max_output=1024)

    def test_quit_force_and_priority_use_identity(self):
        self.assertTrue(self.action()['ok'])
        self.assertTrue(self.action('force-quit')['ok'])
        self.assertEqual(self.sent, [(55, signal.SIGTERM), (55, signal.SIGKILL)])
        self.assertEqual(self.closed, [55, 55])
        self.assertTrue(self.action('tame')['ok'])
        self.assertEqual(self.priority, 19)
        self.assertTrue(self.action('untame')['ok'])
        self.assertEqual(self.priority, 3)

    def test_pid_reuse_reboot_and_missing_identity_refused(self):
        for pid, start, boot in [(1, 1, BOOT), (4242, 1000, BOOT), (4242, 999, 'old-boot'),
                                 (4242, 0, BOOT), (4242, 999, None), (True, 999, BOOT)]:
            result = module.process_action('quit', pid, start, boot, proc=self.proc,
                                           owners=self.owners, ancestors=set(), containers=[])
            self.assertFalse(result['ok'])
        self.assertEqual(self.sent, [])

    def test_pidfd_revalidation_prevents_signal_after_recycle(self):
        def open_pidfd(*_):
            write_process(self.proc, start_time=1001)
            return 55
        self.assertFalse(self.action(pidfd_open=open_pidfd)['ok'])
        self.assertEqual(self.sent, [])
        self.assertEqual(self.closed, [55])

    def test_host_infrastructure_and_named_interpreted_services_protected(self):
        for name, group in [('dockerd', '0::/system.slice/docker.service'),
                            ('python3', '0::/system.slice/operator.service\n'),
                            ('node', '0::/system.slice/claude-remote-control.service'),
                            ('sqlite3', '0::/user.slice/session-1.scope')]:
            path = self.proc / '4242'
            (path / 'exe').unlink()
            write_process(self.proc, name=name, cgroup=group)
            for action in ('quit', 'force-quit', 'tame', 'untame'):
                self.assertFalse(self.action(action)['ok'], (name, action))
        self.assertEqual(self.sent, [])

    def test_self_ancestor_unknown_owner_and_unreadable_identity_refused(self):
        self.assertFalse(self.action(ancestors={4242})['ok'])
        self.assertFalse(self.action(owners=())['ok'])
        (self.proc / '4242/cgroup').unlink()
        self.assertFalse(self.action()['ok'])

    def test_container_membership_never_exempts_infrastructure(self):
        (self.proc / '4242/cgroup').write_text('0::/system.slice/docker-' + CID + '.scope')
        self.assertFalse(self.action(containers=None, allow_workload=True)['ok'])
        self.assertFalse(self.action(containers=[])['ok'])
        row = self.row()
        self.assertFalse(self.action(containers=[row])['ok'])
        self.assertTrue(self.action(containers=[row], allow_workload=True)['ok'])
        row['protection_reason'] = 'protected infrastructure'
        self.assertFalse(self.action(containers=[row], allow_workload=True)['ok'])

    def test_untame_preserves_external_priority_and_requires_own_saved_identity(self):
        self.assertFalse(self.action('untame')['ok'])
        self.assertTrue(self.action('tame')['ok'])
        self.priority = 7
        self.assertFalse(self.action('untame')['ok'])
        self.assertEqual(self.priority, 7)

    def test_priority_state_symlink_is_refused(self):
        state = self.proc.parent / 'state'
        state.symlink_to(self.proc)
        self.assertFalse(self.action('tame')['ok'])
        self.assertEqual(self.priority, 3)

    def test_sample_has_bounded_counters_without_attach_or_secret_fields(self):
        times = iter([0, 3])
        result = self.action('sample', sleep=lambda seconds: self.assertEqual(seconds, 3),
                             monotonic=lambda: next(times))
        self.assertTrue(result['ok'], result)
        sample = result['sample']
        self.assertEqual(sample['duration_seconds'], 3)
        self.assertEqual(sample['memory_after']['swap_bytes'], 12 * 1024)
        self.assertEqual(self.sent, [])
        self.assertNotIn('argv', json.dumps(result))
        self.assertNotIn('environment', json.dumps(result))

    def test_sample_rechecks_identity_after_window(self):
        times = iter([0, 3])
        result = self.action('sample', sleep=lambda _: write_process(self.proc, start_time=1001),
                             monotonic=lambda: next(times))
        self.assertFalse(result['ok'])

    def test_docker_inventory_requests_only_allowlisted_metadata(self):
        seen = []
        row = self.row()
        def run(args, **_):
            seen.append(args)
            return subprocess.CompletedProcess(args, 0, CID + '\n' if 'ps' in args else json.dumps(row), '')
        rows = module.coolify_containers(run)
        self.assertEqual(rows[0]['id'], CID)
        template = seen[1][seen[1].index('--format') + 1]
        self.assertNotIn('Config.Env', template)
        self.assertNotIn('Config.Cmd', template)
        self.assertNotIn('.Args', template)
        self.assertNotIn('json .}}', template)

    def test_unknown_docker_inventory_and_non_coolify_containers_refused(self):
        self.assertIsNone(module.coolify_containers(lambda a, **_: subprocess.CompletedProcess(a, 1, '', '')))
        def run(args, **_):
            return subprocess.CompletedProcess(args, 0, CID if 'ps' in args else json.dumps(self.row(name=None)), '')
        self.assertEqual(module.coolify_containers(run), [])

    def test_container_requires_full_identity_and_rechecks_start(self):
        commands = []
        def run(args, **_):
            commands.append(args)
            return subprocess.CompletedProcess(args, 0, '', '')
        with patch.object(module, 'coolify_containers', return_value=[self.row()]):
            for cid, started in [(None, STARTED), (CID, 'stale')]:
                self.assertFalse(module.container_action('worker-box', 'stop', cid, started, run)['ok'])
            self.assertTrue(module.container_action('worker-box', 'restart', CID, STARTED, run)['ok'])
        self.assertEqual(commands, [module.DOCKER + ['restart', '--time', '10', CID]])

    def test_container_infrastructure_unknown_verb_and_name_changes_refused(self):
        protected = self.row(protection_reason='protected')
        for action, name in [('delete', 'worker-box'), ('stop', 'different'), ('stop', 'worker-box')]:
            with patch.object(module, 'coolify_containers', return_value=[protected]):
                result = module.container_action(name, action, CID, STARTED, lambda *a, **_: self.fail('mutation ran'))
            self.assertFalse(result['ok'])
        for name in ('coolify-db', 'operator-listener-server', 'qdrant-production', 'postgres-main'):
            self.assertIsNotNone(module.protected_container(self.row(container=name)))

    def test_audit_json_escapes_newlines_and_is_private(self):
        path = self.proc.parent / 'audit'
        module.audit('quit', 'name\nforged', {'ok': True}, path)
        self.assertEqual(len(path.read_text().splitlines()), 1)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads(path.read_text())['target'], 'name\nforged')

    def test_main_serializes_and_requires_root_and_confirmation(self):
        calls = []
        argv = ['tame-process', '--pid', '4242', '--start-time', '999', '--boot-id', BOOT]
        for root, confirm in [(False, True), (True, False)]:
            with contextlib.redirect_stdout(io.StringIO()):
                code = module.main(argv + (['--confirm'] if confirm else []), proc=self.proc,
                                   run=lambda *a, **_: self.fail('probe before authorization'),
                                   require_root=lambda: root)
            self.assertEqual(code, 1)
        lock = self.proc.parent / 'control.lock'
        with module.action_lock(lock):
            with contextlib.redirect_stdout(io.StringIO()):
                code = module.main(argv + ['--confirm'], proc=self.proc, lock_path=lock, require_root=lambda: True,
                                   run=lambda *a, **_: self.fail('probe before lock'), audit_fn=lambda *args: calls.append(args))
            self.assertEqual(code, 1)
        self.assertEqual(calls, [])

    def test_starting_audit_failure_prevents_mutation(self):
        with contextlib.redirect_stdout(io.StringIO()):
            code = module.main(['tame-process', '--pid', '4242', '--start-time', '999', '--boot-id', BOOT, '--confirm'],
                               proc=self.proc, lock_path=self.proc.parent / 'control.lock', require_root=lambda: True,
                               audit_fn=lambda *_: (_ for _ in ()).throw(OSError()),
                               process_fn=lambda *a, **_: self.fail('mutation before audit'),
                               run=lambda *a, **_: self.fail('probe before audit'))
        self.assertEqual(code, 1)


if __name__ == '__main__':
    unittest.main()
