#!/usr/bin/env python3
"""Synthetic process trees only; no GUI or app capture is launched."""
from pathlib import Path
import importlib.util
import os
import selectors
import signal
import subprocess
import sys
import tempfile
import time
import types
import unittest
from unittest import mock

SUPERVISOR = Path(__file__).with_name('bounded-process.py')
SPEC = importlib.util.spec_from_file_location('bounded_capture', SUPERVISOR)
CAPTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CAPTURE)


class BoundedProcessTests(unittest.TestCase):
    def invoke(self, source, timeout=2):
        started = time.monotonic()
        result = subprocess.run([sys.executable, str(SUPERVISOR), '--timeout', str(timeout),
                                 '--grace', '0.1', '--', sys.executable, '-c', source],
                                capture_output=True, text=True, timeout=5)
        return result, time.monotonic() - started

    def test_quick_completion_does_not_wait_for_deadline(self):
        result, elapsed = self.invoke('raise SystemExit(7)', timeout=20)
        self.assertEqual(result.returncode, 7)
        self.assertLess(elapsed, 2)
        self.assertIn('exit status: 7', result.stderr)

    def test_leader_remains_unreaped_until_group_cleanup(self):
        original_signal = CAPTURE.signal_group
        observed = []

        def inspect_leader(group, signum):
            if not observed:
                event = os.waitid(os.P_PID, group, os.WEXITED | os.WNOHANG | os.WNOWAIT)
                self.assertIsNotNone(event)
                self.assertEqual(event.si_pid, group)
                observed.append(group)
            return original_signal(group, signum)

        with mock.patch.object(CAPTURE, 'signal_group', side_effect=inspect_leader):
            self.assertEqual(CAPTURE.run([sys.executable, '-c', 'raise SystemExit(7)'], 2, 0), 7)
        self.assertEqual(len(observed), 1)

    def test_cleanup_timeout_cannot_report_success(self):
        process = mock.Mock(pid=999999, args=['synthetic'])
        process.wait.side_effect = subprocess.TimeoutExpired('synthetic', 5)
        with mock.patch.object(CAPTURE.subprocess, 'Popen', return_value=process), \
             mock.patch.object(CAPTURE, 'wait_unreaped', return_value=0), \
             mock.patch.object(CAPTURE, 'signal_group', return_value=False):
            with self.assertRaises(subprocess.TimeoutExpired):
                CAPTURE.run(['synthetic'], 1, 0)
        process.kill.assert_called_once()

    def test_cleanup_escalates_before_reaping_with_a_bounded_grace(self):
        # A fake clock catches omitted/delayed escalation without making loaded
        # hosts satisfy a two-second scheduling assumption in the real fixtures.
        for group_accepts_term in (True, False):
            with self.subTest(group_accepts_term=group_accepts_term):
                process = mock.Mock(pid=999999, args=['synthetic'])
                elapsed = 0.0

                def sleep(duration):
                    nonlocal elapsed
                    elapsed += duration

                events = mock.Mock()
                # Bind the fakes to the supervisor's own globals: patching the
                # shared stdlib time/subprocess modules would install this test's
                # fake clock and Popen process-wide for anything else running.
                fake_time = types.SimpleNamespace(monotonic=lambda: elapsed, sleep=sleep)
                fake_subprocess = types.SimpleNamespace(
                    Popen=mock.Mock(return_value=process),
                    TimeoutExpired=subprocess.TimeoutExpired)
                with mock.patch.object(CAPTURE, 'subprocess', fake_subprocess), \
                     mock.patch.object(CAPTURE, 'time', fake_time), \
                     mock.patch.object(CAPTURE, 'wait_unreaped', return_value=0), \
                     mock.patch.object(CAPTURE, 'signal_group',
                                       return_value=group_accepts_term) as group_signal:
                    events.attach_mock(group_signal, 'group_signal')
                    events.attach_mock(process.kill, 'kill')
                    events.attach_mock(process.wait, 'wait')
                    self.assertEqual(CAPTURE.run(['synthetic'], 1, 0.1), 0)
                # A group that refuses SIGTERM skips the grace block entirely, so
                # assert each branch exactly: a regression that always waits the
                # grace window must not stay green behind a <= bound.
                if group_accepts_term:
                    self.assertAlmostEqual(elapsed, 0.1)
                else:
                    self.assertEqual(elapsed, 0.0)
                self.assertEqual(events.mock_calls[0], mock.call.group_signal(999999, signal.SIGTERM))
                self.assertEqual(events.mock_calls[-3:], [
                    mock.call.group_signal(999999, signal.SIGKILL),
                    mock.call.kill(), mock.call.wait(timeout=5)])

    def test_cleanup_timeout_preserves_cancellation(self):
        process = mock.Mock(pid=999999, args=['synthetic'])
        process.wait.side_effect = subprocess.TimeoutExpired('synthetic', 5)

        def cancelled_spawn(*_args, **_kwargs):
            signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)
            return process

        with mock.patch.object(CAPTURE.subprocess, 'Popen', side_effect=cancelled_spawn), \
             mock.patch.object(CAPTURE, 'signal_group', return_value=False), \
             mock.patch.object(sys, 'argv', ['bounded-process.py', '--timeout', '1', 'synthetic']), \
             mock.patch.object(CAPTURE.sys, 'stderr') as stderr:
            self.assertEqual(CAPTURE.main(), 128 + signal.SIGTERM)
        messages = ''.join(str(call.args[0]) for call in stderr.write.call_args_list)
        self.assertIn('did not exit after group cleanup', messages)
        self.assertIn('exit status: 143', messages)

    def test_cancellation_during_spawn_keeps_child_owned(self):
        original_popen = subprocess.Popen
        children = []

        def cancel_after_creation(*args, **kwargs):
            handler = signal.getsignal(signal.SIGTERM)
            self.assertTrue(callable(handler), 'handler must precede child creation')
            child = original_popen(*args, **kwargs)
            children.append(child)
            handler(signal.SIGTERM, None)
            return child

        try:
            with mock.patch.object(CAPTURE.subprocess, 'Popen', side_effect=cancel_after_creation):
                result = CAPTURE.run([sys.executable, '-c', 'import time; time.sleep(60)'], 2, 0)
            self.assertEqual(result, 128 + signal.SIGTERM)
            self.assertIsNotNone(children[0].returncode)
        finally:
            for child in children:
                if child.poll() is None:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait(timeout=2)

    def test_cancellation_after_observation_or_during_grace_is_retained(self):
        for arrival in ('after observation', 'during grace'):
            with self.subTest(arrival=arrival):
                process = mock.Mock(pid=999999, args=['synthetic'])
                previous = {signum: signal.getsignal(signum)
                            for signum in (signal.SIGTERM, signal.SIGINT)}

                def cancel():
                    handler = signal.getsignal(signal.SIGTERM)
                    self.assertTrue(callable(handler), 'cleanup must keep recording cancellation')
                    handler(signal.SIGTERM, None)

                def observe(*_args):
                    if arrival == 'after observation':
                        cancel()
                    return 0

                def cleanup_signal(_group, signum):
                    if signum == 0 and arrival == 'during grace':
                        cancel()
                    return signum == signal.SIGTERM

                with mock.patch.object(CAPTURE.subprocess, 'Popen', return_value=process), \
                     mock.patch.object(CAPTURE, 'wait_unreaped', side_effect=observe), \
                     mock.patch.object(CAPTURE, 'signal_group', side_effect=cleanup_signal) as cleanup:
                    self.assertEqual(CAPTURE.run(['synthetic'], 1, 1), 143)
                self.assertIn(mock.call(process.pid, signal.SIGKILL), cleanup.call_args_list)
                process.wait.assert_called_once_with(timeout=5)
                for signum, handler in previous.items():
                    self.assertEqual(signal.getsignal(signum), handler)

    def test_deadline_then_cancellation_during_failed_cleanup_reports_cancellation(self):
        process = mock.Mock(pid=999999, args=['synthetic'])
        process.wait.side_effect = subprocess.TimeoutExpired('synthetic', 5)

        def cleanup_signal(_group, signum):
            if signum == signal.SIGTERM:
                handler = signal.getsignal(signal.SIGTERM)
                self.assertTrue(callable(handler))
                handler(signal.SIGTERM, None)
            return False

        with mock.patch.object(CAPTURE.subprocess, 'Popen', return_value=process), \
             mock.patch.object(CAPTURE, 'wait_unreaped',
                               side_effect=subprocess.TimeoutExpired('synthetic', 1)), \
             mock.patch.object(CAPTURE, 'signal_group', side_effect=cleanup_signal), \
             mock.patch.object(sys, 'argv', ['bounded-process.py', '--timeout', '1', 'synthetic']), \
             mock.patch.object(CAPTURE.sys, 'stderr') as stderr:
            self.assertEqual(CAPTURE.main(), 143)
        messages = ''.join(str(call.args[0]) for call in stderr.write.call_args_list)
        self.assertIn('exceeded its deadline', messages)
        self.assertIn('did not exit after group cleanup', messages)
        self.assertIn('cancelled by signal 15', messages)
        self.assertIn('exit status: 143', messages)

    def test_timeout_kills_term_resistant_process(self):
        result, elapsed = self.invoke('import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)', timeout=0.2)
        self.assertEqual(result.returncode, 124)
        self.assertLess(elapsed, 2)

    def test_sigterm_reports_128_plus_signal_and_cleans_up(self):
        # The Actions runner cancels a step by signalling the process group, so
        # the supervisor must report 128+signum rather than dying on a traceback.
        with tempfile.TemporaryDirectory() as directory:
            child_pidfile = Path(directory) / 'child.pid'
            child = ('import os,pathlib,time; '
                     f'pathlib.Path({str(child_pidfile)!r}).write_text(str(os.getpid())); '
                     'time.sleep(60)')
            process = subprocess.Popen([sys.executable, str(SUPERVISOR), '--timeout', '30', '--grace', '0.1',
                                        '--', sys.executable, '-c', child],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                       start_new_session=True)
            try:
                self.wait_for_readiness(process)
                process.send_signal(signal.SIGTERM)
                _, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 128 + signal.SIGTERM)
                self.assertIn(f'exit status: {128 + signal.SIGTERM}', stderr)
            except BaseException:
                self.cleanup_fixture(process, child_pidfile)
                raise

    def cleanup_fixture(self, process, child_pidfile):
        """Bound failure cleanup without replacing the test's original error."""
        try:
            # Let the supervisor clean its separate capture session, even when
            # readiness failed before the child's pidfile was written.
            if process.returncode is None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except OSError:
                    pass
            try:
                process.communicate(timeout=2)
                return
            except (OSError, ValueError, subprocess.TimeoutExpired):
                pass
            # A wedged supervisor must not leave either session holding pipes.
            try:
                os.killpg(int(child_pidfile.read_text()), signal.SIGKILL)
            except (OSError, ValueError):
                pass
            if process.returncode is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except OSError:
                    pass
            try:
                process.communicate(timeout=2)
            except (OSError, ValueError, subprocess.TimeoutExpired):
                pass
        finally:
            for pipe in (process.stdout, process.stderr):
                if pipe is not None:
                    try:
                        pipe.close()
                    except (OSError, ValueError):
                        pass

    def test_fixture_failure_cleanup_kills_groups_and_closes_pipes(self):
        process = mock.Mock(pid=999998, returncode=None)
        process.communicate.side_effect = subprocess.TimeoutExpired('synthetic', 2)
        with tempfile.TemporaryDirectory() as directory:
            pidfile = Path(directory) / 'child.pid'
            pidfile.write_text('999999')
            with mock.patch.object(os, 'killpg') as killpg:
                with self.assertRaisesRegex(AssertionError, 'original readiness failure'):
                    try:
                        raise AssertionError('original readiness failure')
                    except AssertionError:
                        self.cleanup_fixture(process, pidfile)
                        raise
            self.assertEqual(killpg.call_args_list, [mock.call(999998, signal.SIGTERM),
                             mock.call(999999, signal.SIGKILL), mock.call(999998, signal.SIGKILL)])
        self.assertEqual(process.communicate.call_count, 2)
        process.stdout.close.assert_called_once()
        process.stderr.close.assert_called_once()

    def wait_for_readiness(self, process):
        """Block until the supervisor has installed its signal handlers.

        A fixed sleep cannot prove that: under scheduling delay the SIGTERM would
        arrive mid-install, take the default action, and crash the supervisor.
        """
        deadline = time.monotonic() + 10
        ready_marker = b'Supervisor ready.'
        pending = bytearray()
        with selectors.DefaultSelector() as selector:
            selector.register(process.stderr, selectors.EVENT_READ)
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    self.fail('supervisor never reported readiness')
                chunk = os.read(process.stderr.fileno(), 4096)
                if not chunk:
                    process.poll()
                    self.fail(f'supervisor exited {process.returncode} before becoming ready')
                pending.extend(chunk)
                if ready_marker in pending:
                    return

    def test_successful_parent_does_not_leave_orphan_holding_output(self):
        with tempfile.TemporaryDirectory() as directory:
            pidfile = Path(directory) / 'child.pid'
            child = ('import os,signal,time,pathlib; '
                     'signal.signal(signal.SIGTERM,signal.SIG_IGN); '
                     f'pathlib.Path({str(pidfile)!r}).write_text(str(os.getpid())); time.sleep(60)')
            parent = (f'import subprocess,sys,time,pathlib; subprocess.Popen([sys.executable,"-c",{child!r}]); '
                      f'p=pathlib.Path({str(pidfile)!r}); '
                      '\nwhile not p.exists(): time.sleep(0.01)\n')
            result, elapsed = self.invoke(parent)
            self.assertEqual(result.returncode, 0)
            self.assertLess(elapsed, 2)
            pid = int(pidfile.read_text())
            # A killed orphan can briefly remain a zombie awaiting its adopter.
            status = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='], capture_output=True, text=True)
            self.assertTrue(not status.stdout.strip() or status.stdout.strip().startswith('Z'))


if __name__ == '__main__':
    unittest.main()
