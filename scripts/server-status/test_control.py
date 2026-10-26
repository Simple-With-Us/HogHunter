import importlib.util
import json
import os
from pathlib import Path
import pwd
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('control', Path(__file__).with_name('control.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def write_process(root, pid, comm, start_time, ppid=1, ticks=0):
    """A /proc-shaped fixture for one process."""
    path = root / str(pid)
    path.mkdir(parents=True, exist_ok=True)
    tail = ['S', str(ppid)] + ['0'] * 9 + [str(ticks), str(ticks)] + ['0'] * 6 + [str(start_time)] + ['0'] * 20
    (path / 'stat').write_text(f'{pid} ({comm}) ' + ' '.join(tail))
    (path / 'comm').write_text(comm)
    # A user process has an executable; a kernel thread does not.
    (path / 'exe').write_text('/usr/bin/fixture')
    return path


class ControlTests(unittest.TestCase):
    """The owner allowlist is the account this test runs as, so the tests
    describe the same rules on any machine and under any user."""

    @property
    def owners(self):
        return module.ALLOWED_OWNERS + (pwd.getpwuid(os.getuid()).pw_name,)

    def test_a_kernel_thread_is_never_offered(self):
        """Kernel threads have no executable and cannot be signalled."""
        with tempfile.TemporaryDirectory() as directory:
            proc = Path(directory)
            path = write_process(proc, 30, 'kworker/0:0H-kblockd', start_time=1)
            (path / 'exe').unlink()
            rows = module.list_targets(proc=proc, owners=self.owners)
            self.assertNotIn(30, [row['pid'] for row in rows['processes']])
            outcome = module.stop_process(30, 1, proc=proc, kill=lambda *a: None,
                                         ancestors=set(), container_lookup=lambda pid: None,
                                         owners=self.owners)
            self.assertFalse(outcome['ok'])
            self.assertIn('kernel thread', outcome['reason'])

    def test_pid_one_is_never_signalled(self):
        outcome = module.stop_process(1, 0)
        self.assertFalse(outcome['ok'])
        self.assertIn('pid 1', outcome['reason'])

    def test_a_recycled_pid_is_refused(self):
        """The pid is the same; the process behind it is not."""
        with tempfile.TemporaryDirectory() as directory:
            proc = Path(directory)
            write_process(proc, 4242, 'next-server', start_time=999)
            outcome = module.stop_process(4242, 111, proc=proc, kill=lambda *a: None,
                                         ancestors=set(), container_lookup=lambda pid: None,
                                         owners=self.owners)
            self.assertFalse(outcome['ok'])
            self.assertIn('changed since', outcome['reason'])

    def test_a_matching_process_is_asked_to_stop(self):
        with tempfile.TemporaryDirectory() as directory:
            proc = Path(directory)
            write_process(proc, 4242, 'next-server', start_time=999)
            seen = []
            outcome = module.stop_process(4242, 999, proc=proc, kill=lambda pid, sig: seen.append((pid, sig)),
                                         ancestors=set(), container_lookup=lambda pid: None,
                                         owners=self.owners)
            self.assertTrue(outcome['ok'], outcome)
            self.assertEqual(seen[0][0], 4242)
            self.assertEqual(seen[0][1], module.signal.SIGTERM)

    def test_force_kills_instead_of_asking(self):
        with tempfile.TemporaryDirectory() as directory:
            proc = Path(directory)
            write_process(proc, 4242, 'next-server', start_time=999)
            seen = []
            module.stop_process(4242, 999, force=True, proc=proc, kill=lambda pid, sig: seen.append(sig),
                                ancestors=set(), container_lookup=lambda pid: None,
                                owners=self.owners)
            self.assertEqual(seen[0], module.signal.SIGKILL)

    def test_infrastructure_is_never_stopped(self):
        with tempfile.TemporaryDirectory() as directory:
            proc = Path(directory)
            write_process(proc, 5, 'dockerd', start_time=1)
            outcome = module.stop_process(5, 1, proc=proc, kill=lambda *a: None,
                                         ancestors=set(), container_lookup=lambda pid: None,
                                         owners=self.owners)
            self.assertFalse(outcome['ok'])
            self.assertIn('keeps the host running', outcome['reason'])

    def test_the_callers_own_session_is_never_stopped(self):
        with tempfile.TemporaryDirectory() as directory:
            proc = Path(directory)
            write_process(proc, 7, 'bash', start_time=1)
            outcome = module.stop_process(7, 1, proc=proc, kill=lambda *a: None,
                                         ancestors={7}, container_lookup=lambda pid: None)
            self.assertFalse(outcome['ok'])
            self.assertIn('this session', outcome['reason'])

    def test_the_listing_names_the_identity_the_action_needs(self):
        with tempfile.TemporaryDirectory() as directory:
            proc = Path(directory)
            write_process(proc, 42, 'next-server', start_time=555)
            write_process(proc, 43, 'dockerd', start_time=556)
            rows = module.list_targets(proc=proc, owners=self.owners)
            pids = {row['pid'] for row in rows['processes']}
            self.assertIn(42, pids)
            self.assertNotIn(43, pids)  # Infrastructure is not offered.
            row = next(row for row in rows['processes'] if row['pid'] == 42)
            self.assertEqual(row['start_time'], 555)

    def test_coolify_workloads_are_listed_with_the_name_the_owner_knows(self):
        def run(args, **kwargs):
            if args[1] == 'ps':
                return subprocess.CompletedProcess(args, 0, 'abc\n', '')
            if args[1] == 'inspect':
                return subprocess.CompletedProcess(args, 0, json.dumps([{
                    'Name': '/yagelvqux9e8l1kztif7bf2o',
                    'Config': {'Labels': {'coolify.name': 'yagelvqux9e8l1kztif7bf2o',
                                          'coolify.projectName': 'fleet-infra',
                                          'coolify.resourceName': 'um-appworker'}},
                    'State': {'Status': 'running'}}]), '')
            return subprocess.CompletedProcess(args, 1, '', '')
        rows = module.coolify_containers(run=run)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['name'], 'fleet-infra / um-appworker')
        self.assertEqual(rows[0]['status'], 'running')

    def test_an_unknown_workload_is_refused(self):
        outcome = module.container_action('not-a-container', 'stop', run=lambda *a, **k: subprocess.CompletedProcess(a, 1, '', ''))
        self.assertFalse(outcome['ok'])

    def test_container_action_matches_the_display_name(self):
        """The Mac names the workload by the display name it was shown."""
        stopped = []

        def run(args, **kwargs):
            if args[1] == 'ps':
                return subprocess.CompletedProcess(args, 0, 'abc123\n', '')
            if args[1] == 'inspect':
                return subprocess.CompletedProcess(args, 0, json.dumps([{
                    'Name': '/yagelvqux9e8l1kztif7bf2o',
                    'Config': {'Labels': {'coolify.name': 'yagelvqux9e8l1kztif7bf2o',
                                          'coolify.projectName': 'fleet-infra',
                                          'coolify.resourceName': 'um-appworker'}},
                    'State': {'Status': 'running'}}]), '')
            if args[1] == 'stop':
                stopped.append(list(args))
                return subprocess.CompletedProcess(args, 0, 'yagelvqux9e8l1kztif7bf2o\n', '')
            return subprocess.CompletedProcess(args, 1, '', '')
        outcome = module.container_action('fleet-infra / um-appworker', 'stop', run=run)
        self.assertTrue(outcome['ok'], outcome)
        # Docker is told the container name, never the display label.
        self.assertEqual(stopped, [['docker', 'stop', 'yagelvqux9e8l1kztif7bf2o']])
        self.assertEqual(outcome['container'], 'yagelvqux9e8l1kztif7bf2o')

    def test_main_stop_process_passes_container_identities(self):
        """main() looks the identities up, so a containerized process is not
        held to the host's ownership and infrastructure guards."""
        import io
        import contextlib
        with tempfile.TemporaryDirectory() as directory:
            proc = Path(directory)
            path = write_process(proc, 4242, 'next-server', start_time=999)
            # Belongs to a container, so the host's ownership guard does not
            # apply no matter which account runs this test.
            (path / 'cgroup').write_text('0::/docker/abc\n')
            real_stop = module.stop_process
            real_identities = module.container_identities
            real_audit = module.AUDIT_LOG
            seen = {}

            def recording_stop(pid, start_time, force=False, **kwargs):
                seen['identities'] = kwargs.get('identities')
                return real_stop(pid, start_time, force=force, proc=proc,
                                 kill=lambda *a: None, ancestors=set(),
                                 identities=kwargs.get('identities'))

            module.stop_process = recording_stop
            module.container_identities = lambda run=subprocess.run: {'abc': 'box'}
            module.AUDIT_LOG = Path(directory) / 'audit.log'
            try:
                buffer = io.StringIO()
                with contextlib.redirect_stdout(buffer):
                    code = module.main(['stop-process', '--pid', '4242',
                                        '--start-time', '999', '--confirm'])
            finally:
                module.stop_process = real_stop
                module.container_identities = real_identities
                module.AUDIT_LOG = real_audit
            self.assertEqual(code, 0, buffer.getvalue())
            self.assertEqual(seen.get('identities'), {'abc': 'box'})
            self.assertIn('"ok": true', buffer.getvalue())

    def test_the_audit_log_names_what_was_done(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'audit.log'
            original = module.AUDIT_LOG
            module.AUDIT_LOG = log
            try:
                module.audit('stop-process', 'pid=42', 'ok')
            finally:
                module.AUDIT_LOG = original
            text = log.read_text()
            self.assertIn('command=stop-process', text)
            self.assertIn('target=pid=42', text)
            self.assertIn('outcome=ok', text)

    def test_a_command_without_confirmation_is_refused(self):
        import io
        import contextlib
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = module.main(['stop-process', '--pid', '42', '--start-time', '1'])
        self.assertEqual(code, 2)
        self.assertIn('confirm', buffer.getvalue())


if __name__ == '__main__':
    unittest.main()
