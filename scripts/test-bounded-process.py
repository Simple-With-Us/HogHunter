#!/usr/bin/env python3
"""Synthetic process trees only; no GUI or app capture is launched."""
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

SUPERVISOR = Path(__file__).with_name('bounded-process.py')


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

    def test_timeout_kills_term_resistant_process(self):
        result, elapsed = self.invoke('import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)', timeout=0.2)
        self.assertEqual(result.returncode, 124)
        self.assertLess(elapsed, 2)

    def test_sigterm_reports_128_plus_signal_and_cleans_up(self):
        # The Actions runner cancels a step by signalling the process group, so
        # the supervisor must report 128+signum rather than dying on a traceback.
        process = subprocess.Popen([sys.executable, str(SUPERVISOR), '--timeout', '30', '--grace', '0.1',
                                    '--', sys.executable, '-c', 'import time; time.sleep(60)'],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        time.sleep(1)
        process.send_signal(signal.SIGTERM)
        _, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 128 + signal.SIGTERM)
        self.assertIn(f'exit status: {128 + signal.SIGTERM}', stderr)

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
