import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("shellular-watchdog.py")
SPEC = importlib.util.spec_from_file_location("shellular_watchdog", SCRIPT)
watchdog = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(watchdog)


class ShellularWatchdogTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.runtime = self.root / "runtime"
        self.home = self.root / "home"
        self.proc = self.root / "proc"
        self.runtime.mkdir()
        self.home.mkdir()
        self.proc.mkdir()
        paths = watchdog.runtime_paths(self.runtime)
        self.expected_entry = str(paths["entry"])

    def tearDown(self):
        self.tmp.cleanup()

    def record(self, state, pid=0):
        return json.dumps({"name": "shellular", "status": state, "pid": pid,
                           "execpath": self.expected_entry})

    def result(self, stdout="", returncode=0):
        return subprocess.CompletedProcess([], returncode, stdout, "")

    def test_online_is_a_noop_and_status_file_is_safe(self):
        calls = []
        (self.proc / "321").mkdir()
        (self.proc / "321" / "exe").touch()

        def run(argv, **kwargs):
            calls.append((argv, kwargs))
            return self.result(self.record("online", 321))

        outcome = watchdog.run_watchdog(self.runtime, self.home, self.proc, run)
        self.assertEqual(outcome, {"result": "running", "action": "none", "reason": ""})
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], [str(watchdog.runtime_paths(self.runtime)["status"])])
        self.assertEqual(set(calls[0][1]["env"]), {"HOME", "PM2_HOME", "PATH"})
        status = json.loads((self.runtime / "var" / "watchdog-status.json").read_text())
        self.assertEqual(status["result"], "running")
        self.assertEqual(os.stat(self.runtime / "var" / "watchdog-status.json").st_mode & 0o777, 0o600)

    def test_down_manager_starts_once_and_confirms_online(self):
        calls = []
        statuses = [self.record("not_found"), self.record("online", 654)]

        def run(argv, **kwargs):
            calls.append((argv, kwargs))
            if argv[0] == str(watchdog.runtime_paths(self.runtime)["status"]):
                body = statuses.pop(0)
                if '"online"' in body:
                    (self.proc / "654").mkdir(exist_ok=True)
                    (self.proc / "654" / "exe").touch()
                return self.result(body)
            return self.result()

        outcome = watchdog.run_watchdog(self.runtime, self.home, self.proc, run)
        self.assertEqual(outcome, {"result": "started", "action": "start", "reason": ""})
        self.assertEqual(len(calls), 3)
        self.assertEqual(calls[1][0], [str(watchdog.runtime_paths(self.runtime)["wrapper"]), "--no-qr"])
        self.assertIs(calls[1][1]["stdout"], subprocess.DEVNULL)
        self.assertIs(calls[1][1]["stderr"], subprocess.DEVNULL)

    def test_online_record_race_requires_second_confirmed_missing_pid_before_start(self):
        calls = []
        statuses = [self.record("online", 123), self.record("process_missing", 123),
                    self.record("online", 654)]

        def run(argv, **kwargs):
            calls.append((argv, kwargs))
            if argv[0] == str(watchdog.runtime_paths(self.runtime)["status"]):
                body = statuses.pop(0)
                if '"online"' in body and '654' in body:
                    (self.proc / "654").mkdir(exist_ok=True)
                    (self.proc / "654" / "exe").touch()
                return self.result(body)
            return self.result()

        outcome = watchdog.run_watchdog(self.runtime, self.home, self.proc, run)
        self.assertEqual(outcome, {"result": "started", "action": "start", "reason": ""})
        self.assertEqual(len(calls), 4)
        self.assertEqual(calls[2][0], [str(watchdog.runtime_paths(self.runtime)["wrapper"]), "--no-qr"])

    def test_manager_timeout_reports_error_without_starting_or_killing(self):
        calls = []

        def run(argv, **kwargs):
            calls.append(argv)
            raise subprocess.TimeoutExpired(argv, kwargs["timeout"])

        outcome = watchdog.run_watchdog(self.runtime, self.home, self.proc, run)
        self.assertEqual(outcome, {"result": "error", "action": "none", "reason": "status_timeout"})
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0], [str(watchdog.runtime_paths(self.runtime)["status"])])

    def test_manager_down_but_pid_present_fails_closed(self):
        (self.proc / "123").mkdir()
        calls = []

        def run(argv, **kwargs):
            calls.append(argv)
            return self.result(self.record("stopped", 123))

        outcome = watchdog.run_watchdog(self.runtime, self.home, self.proc, run)
        self.assertEqual(outcome, {"result": "error", "action": "none", "reason": "process_alive_while_manager_down"})
        self.assertEqual(len(calls), 1)

    def test_bad_manager_identity_does_not_start(self):
        calls = []

        def run(argv, **kwargs):
            calls.append(argv)
            return self.result(json.dumps({"name": "other", "status": "not_found", "pid": 0,
                                           "execpath": self.expected_entry}))

        outcome = watchdog.run_watchdog(self.runtime, self.home, self.proc, run)
        self.assertEqual(outcome["reason"], "identity_mismatch")
        self.assertEqual(len(calls), 1)

    def test_start_timeout_is_reported_without_exposing_child_output(self):
        calls = []

        def run(argv, **kwargs):
            calls.append((argv, kwargs))
            if argv[0] == str(watchdog.runtime_paths(self.runtime)["status"]):
                return self.result(self.record("not_found"))
            raise subprocess.TimeoutExpired(argv, kwargs["timeout"], output="private-output")

        outcome = watchdog.run_watchdog(self.runtime, self.home, self.proc, run)
        self.assertEqual(outcome, {"result": "error", "action": "start", "reason": "start_timeout"})
        self.assertEqual(len(calls), 2)
        self.assertIs(calls[1][1]["stdout"], subprocess.DEVNULL)
        self.assertIs(calls[1][1]["stderr"], subprocess.DEVNULL)


if __name__ == "__main__":
    unittest.main()
