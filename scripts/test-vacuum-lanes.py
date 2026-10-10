#!/usr/bin/env python3
"""Linux-runnable tests for the Robotic Vacuum lane doctor integration.

Covers vacuum/lanes.py (report gates, the Vacuum's own re-check, dependency folders), vacuum/janitor.py
(retire with git worktree remove, never force), the engine steps that use them, and the --dry-run CLI.
Everything runs in temp directories with fake doctor output and real throwaway git repos.  Nothing here
touches the real home directory, the real lane doctor, or any real checkout.

CI runs scripts/test-robotic-vacuum.py, which loads this file; it also runs standalone.
"""
from __future__ import annotations

import atexit
import contextlib
import dataclasses
import datetime as dt
import importlib.util
import io
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path
from unittest.mock import patch

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

# --------------------------------------------------------------------------- hermetic process
#
# GitHub's Ubuntu runner has no global git identity and no ~/.gitconfig, a Mac usually has both, and a test that
# commits without its own identity passes on one and fails on the other.  Nothing below may lean on the machine:
# every git call gets the identity from git_identity_env, HOME is an empty folder, and no banner can be posted.
# scripts/test-robotic-vacuum.py carries the same block, because either file can be the one that is run.

NO_NOTIFY = "HOGHUNTER_NO_NOTIFY"
# Variables that would point a test at the owner's real setup or at the wrong repository.
AMBIENT_ENV = (
    "FLEET_APPS_JSON",
    "HOGHUNTER_LANE_DOCTOR_COMMAND",
    "JANITOR_MAX_LOAD",
    "XDG_CONFIG_HOME",
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_COMMON_DIR",
    "GIT_OBJECT_DIRECTORY",
)


def git_identity_env(global_config: str = os.devnull) -> dict:
    """The four identity variables plus a global config that holds nothing (or the file given), so a git
    command behaves the same on a Mac with a ~/.gitconfig and on a runner with none."""
    return {
        "GIT_CONFIG_GLOBAL": global_config,
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_AUTHOR_NAME": "Vacuum Test",
        "GIT_AUTHOR_EMAIL": "vacuum-test@example.invalid",
        "GIT_COMMITTER_NAME": "Vacuum Test",
        "GIT_COMMITTER_EMAIL": "vacuum-test@example.invalid",
        "GIT_TERMINAL_PROMPT": "0",
    }


def isolate_process_environment() -> str:
    """Point HOME at an empty folder, drop ambient settings, pin the git identity, and switch notifications
    off for every process this run starts.  Returns the fake HOME.  Runs once, at import."""
    home = tempfile.mkdtemp(prefix="hhtest-home-")
    atexit.register(shutil.rmtree, home, True)
    for name in AMBIENT_ENV:
        os.environ.pop(name, None)
    os.environ.update(git_identity_env())
    os.environ["HOME"] = home
    os.environ[NO_NOTIFY] = "1"
    return home


FAKE_HOME = isolate_process_environment()

from vacuum import alerts  # noqa: E402
from vacuum import lanes  # noqa: E402
from vacuum.config import default_keep_worktree_regex, load_config, step_enabled, steps_for_trigger  # noqa: E402
from vacuum.engine import VacuumEngine  # noqa: E402
from vacuum.janitor import apply_retire_worktrees, plan_retire_worktrees, retire_worktrees  # noqa: E402
from vacuum.models import StepStatus, TriggerKind  # noqa: E402


def install_notify_leak_guard() -> None:
    """Make notify_macos raise unless a test patches it.  The environment switch already stops a real banner;
    this makes the call itself a failure, so a test that reaches a notification by accident cannot pass.  A
    test that expects one patches vacuum.alerts.notify_macos for its own duration."""
    real = getattr(alerts.notify_macos, "real", alerts.notify_macos)

    def guard(title, body):
        raise AssertionError(f"notify_macos({title!r}, ...) was called by a test that did not expect a notification")

    guard.real = real  # type: ignore[attr-defined]
    alerts.notify_macos = guard


def real_notify_macos():
    """The real function, for the tests of notify_macos itself."""
    return getattr(alerts.notify_macos, "real", alerts.notify_macos)


install_notify_leak_guard()

NEVER = re.compile(r"(?!)")
SHA_A = "a" * 40
REPO_SLUG = "Simple-With-Us/HogHunter"


# --------------------------------------------------------------------------- fixtures


class Runner:
    """Process runner for the code under test.  git and du are real; pgrep and lsof are scripted."""

    def __init__(self, pgrep_rc: int = 1, lsof_paths=None, lsof_rc: int = 0, fail_remove=()):
        self.pgrep_rc = pgrep_rc
        self.lsof_paths = ["/"] if lsof_paths is None else list(lsof_paths)
        self.lsof_rc = lsof_rc
        self.fail_remove = set(fail_remove)
        self.calls: list = []

    def __call__(self, argv, **kwargs):
        self.calls.append(list(argv))
        exe = argv[0]
        if exe == "pgrep":
            return subprocess.CompletedProcess(argv, self.pgrep_rc, "", "")
        if exe == "lsof":
            out = "".join(f"p1\nfcwd\nn{p}\n" for p in self.lsof_paths)
            return subprocess.CompletedProcess(argv, self.lsof_rc, out, "")
        if "worktree" in argv and "remove" in argv and argv[-1] in self.fail_remove:
            return subprocess.CompletedProcess(argv, 1, "", "fatal: refused by test")
        return subprocess.run(argv, **kwargs)

    def removals(self) -> list:
        return [c for c in self.calls if "worktree" in c and "remove" in c]


class Sandbox:
    """A fake home with one full clone under ~/Code and helpers to cut lanes from it.

    Remote-tracking refs are written with update-ref instead of a real push: same effect on `--remotes`,
    far fewer processes.  Pass a TestCase (per-test) or a TestCase class (per-class, read-only tests)."""

    def __init__(self, owner) -> None:
        cleanup = owner.addCleanup if isinstance(owner, unittest.TestCase) else owner.addClassCleanup
        root = tempfile.mkdtemp(prefix="hhlanes-")
        cleanup(shutil.rmtree, root, True)
        self.root = Path(os.path.realpath(root))
        self.home = self.root / "home"
        self.lanes_root = self.home / "apps" / "lanes" / "hoghunter"
        self.lanes_root.mkdir(parents=True)
        (self.root / "gitconfig").write_text("", encoding="utf-8")
        patcher = patch.dict(os.environ, git_identity_env(str(self.root / "gitconfig")))
        patcher.start()
        cleanup(patcher.stop)
        self.main = self.home / "Code" / "HogHunter"
        self.main.mkdir(parents=True)
        self.git(self.main, "init", "-q", "-b", "main")
        self.exclude = self.main / ".git" / "info" / "exclude"
        self.exclude.parent.mkdir(parents=True, exist_ok=True)
        self.exclude.write_text(".env\ndata/\nnode_modules/\ndist/\n", encoding="utf-8")
        (self.main / "README.md").write_text("fixture\n", encoding="utf-8")
        self.git(self.main, "add", "README.md")
        self.git(self.main, "commit", "-q", "-m", "base")
        self.git(self.main, "update-ref", "refs/remotes/origin/main", "HEAD")

    def git(self, cwd, *args: str) -> str:
        res = subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True)
        if res.returncode != 0:
            raise AssertionError(f"git {' '.join(args)} failed: {res.stderr}")
        return res.stdout.strip()

    def ignore(self, *patterns: str) -> None:
        """Add patterns to the main repository's info/exclude, which every lane shares."""
        with open(self.exclude, "a", encoding="utf-8") as handle:
            handle.write("".join(p + "\n" for p in patterns))

    def push(self, lane) -> None:
        """Make the lane's current HEAD count as pushed: what `git push` does to the remote-tracking ref."""
        name = self.branch(lane)
        self.git(lane, "update-ref", f"refs/remotes/origin/{name}", "HEAD")

    def commit(self, lane, name: str = "more.txt") -> None:
        (Path(lane) / name).write_text("more\n", encoding="utf-8")
        self.git(lane, "add", name)
        self.git(lane, "commit", "-q", "-m", f"add {name}")

    def lane(self, name: str = "claude-lane", branch: str | None = None, push: bool = True, commit: bool = True) -> Path:
        branch = branch or f"claude/{name}"
        path = self.lanes_root / name
        self.git(self.main, "worktree", "add", "-q", "-b", branch, str(path))
        if commit:
            self.git(path, "commit", "-q", "--allow-empty", "-m", "lane work")
        if push:
            self.push(path)
        return path

    def head(self, path) -> str:
        return self.git(path, "rev-parse", "HEAD")

    def branch(self, path) -> str:
        return self.git(path, "symbolic-ref", "--short", "HEAD")

    def row(self, lane, **over) -> dict:
        path = lane
        row = {
            "path": str(path),
            "realpath": str(path),
            "kind": "LINKED-WORKTREE",
            "location_class": "LANE_NESTED",
            "owner_repo": REPO_SLUG,
            "tool_cache": False,
            "branch": over["branch"] if "branch" in over else self.branch(path),
            "head_sha": self.head(path),
            "lane_age_days": 12.0,
            "idle_days": 9.0,
            "dirty_tracked": 0,
            "dirty_untracked": 0,
            "unpushed": 0,
            "pr_state": "MERGED",
            "pr_number": 7,
            "registered": True,
            "cwd_procs": [],
            "active": False,
            "janitor_keep": False,
            "safety": "SAFE-TO-REMOVE",
            "read_errors": [],
        }
        row.update(over)
        return row

    def report(self, rows, candidates=None, now: float | None = None, **top) -> dict:
        now = time.time() if now is None else now
        rep = {
            "schema": 2,
            "generated_at": dt.datetime.fromtimestamp(now - 60, dt.timezone.utc).isoformat(),
            "host": "fixture",
            "layout_mode": "nested",
            "home": str(self.home),
            "lsof": "ok",
            "gh": "ok",
            "gh_repos": {REPO_SLUG: "ok"},
            "warnings": [],
            "checkouts": list(rows),
            "anomalies": [],
            "summary": {},
            "cleaner_candidates": [r["realpath"] for r in rows] if candidates is None else list(candidates),
        }
        rep.update(top)
        return rep

    def cfg(self, **lane_over) -> dict:
        cfg = load_config(home=self.home)
        cfg["housekeeper_lock"] = str(self.root / "lock")
        cfg["data_dir"] = str(self.root / "data")
        cfg["keep_worktree_regex"] = r"(?!)"
        cfg["lanes"] = dict(cfg["lanes"], doctor_command=[sys.executable, "fake-doctor"], **lane_over)
        return cfg

    def settings(self, **lane_over) -> "lanes.LaneSettings":
        """Settings read from a config whose `lanes` block carries lane_over (numeric keys there are ignored)."""
        return lanes.lane_settings(self.cfg(**lane_over), self.home, env={})

    def ctx(self, runner=None, keep=NEVER, clock=time.time, **lane_over) -> "lanes.LaneContext":
        return lanes.LaneContext(self.home, keep, self.settings(**lane_over), runner or Runner(), clock)


class PgrepPassthrough(Runner):
    """Like Runner, but pgrep is the real binary, so a test can prove what a real process search matches."""

    def __call__(self, argv, **kwargs):
        if argv[0] == "pgrep":
            self.calls.append(list(argv))
            return subprocess.run(argv, **kwargs)
        return super().__call__(argv, **kwargs)


def backdate(root, seconds: float) -> None:
    """Set the mtime of root and everything under it (symlinks not followed) to `seconds` ago."""
    old = time.time() - seconds
    for dirpath, dirnames, filenames in os.walk(root):
        for name in dirnames + filenames:
            os.utime(os.path.join(dirpath, name), (old, old), follow_symlinks=False)
    os.utime(root, (old, old), follow_symlinks=False)


def nested_clone(folder: Path) -> Path:
    """A git repository with one commit that exists nowhere else, the way pip install -e git+... leaves one."""
    folder.mkdir(parents=True)
    env = dict(os.environ, **git_identity_env())  # the commit must not lean on a global identity
    for args in (("init", "-q", "-b", "main"), ("add", "work.py"), ("commit", "-q", "-m", "local only")):
        if args[0] == "add":
            (folder / "work.py").write_text("local only\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(folder), *args], check=True, capture_output=True, env=env)
    return folder


def doctor_returning(report, rc: int = 0, text: str | None = None):
    payload = json.dumps(report) if text is None else text

    def run(argv, timeout):
        return subprocess.CompletedProcess(argv, rc, payload, "")

    return run


def refused_reason(scan, path) -> str:
    for item in scan.refused:
        if item["path"] == str(path):
            return item["reason"]
    return ""


# --------------------------------------------------------------------------- report gates (fail closed)


class TestReportGates(unittest.TestCase):
    """Anything missing, stale, malformed or partial means nothing is removable, with a reason for the log."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.sb = Sandbox(cls)
        cls.lane = cls.sb.lane()

    def setUp(self) -> None:
        self.row = self.sb.row(self.lane)

    def scan(self, report, rc: int = 0, text: str | None = None, clock=time.time, **lane_over):
        settings = self.sb.settings(**lane_over)
        rep = lanes.load_report(settings, self.sb.home, doctor_returning(report, rc, text), clock)
        return rep, lanes.removable_lanes(rep, self.sb.ctx(clock=clock, **lane_over))

    def assert_nothing(self, scan, needle: str) -> None:
        self.assertFalse(scan.ok)
        self.assertEqual(scan.choices, [])
        self.assertIn(needle, scan.reason)

    def test_good_report_yields_the_lane(self) -> None:
        _rep, scan = self.scan(self.sb.report([self.row]))
        self.assertTrue(scan.ok, scan.reason)
        self.assertEqual([c.path for c in scan.choices], [str(self.lane)])

    def test_stale_report_yields_nothing(self) -> None:
        old = time.time() - 3600
        _rep, scan = self.scan(self.sb.report([self.row], now=old))
        self.assert_nothing(scan, "stale")

    def test_age_limit_is_configurable_but_report_just_inside_passes(self) -> None:
        _rep, scan = self.scan(self.sb.report([self.row], now=time.time() - 800))
        self.assertTrue(scan.ok, scan.reason)

    def test_missing_doctor_command_yields_nothing(self) -> None:
        cfg = self.sb.cfg()
        cfg["lanes"]["doctor_command"] = ["~/apps/lane", "ls", "--json"]  # nothing installed in the fake home
        settings = lanes.lane_settings(cfg, self.sb.home, env={})
        self.assertEqual(settings.command[0], str(self.sb.home / "apps" / "lane"))
        rep = lanes.load_report(settings, self.sb.home, doctor_returning(self.sb.report([self.row])))
        self.assertFalse(rep.ok)
        self.assertIn("missing", rep.reason)
        self.assertEqual(lanes.removable_lanes(rep, self.sb.ctx()).choices, [])

    def test_doctor_runner_that_cannot_start_yields_nothing(self) -> None:
        def broken(argv, timeout):
            raise FileNotFoundError("no such tool")

        rep = lanes.load_report(self.sb.settings(), self.sb.home, broken)
        self.assertFalse(rep.ok)
        self.assertIn("could not run", rep.reason)

    def test_nonzero_exit_yields_nothing(self) -> None:
        rep, scan = self.scan(self.sb.report([self.row]), rc=3)
        self.assertFalse(rep.ok)
        self.assert_nothing(scan, "exited 3")

    def test_invalid_json_yields_nothing(self) -> None:
        _rep, scan = self.scan({}, text="not json at all")
        self.assert_nothing(scan, "not valid JSON")

    def test_non_object_json_yields_nothing(self) -> None:
        _rep, scan = self.scan({}, text="[1, 2, 3]")
        self.assert_nothing(scan, "not a JSON object")

    def test_gh_not_ok_yields_nothing(self) -> None:
        for status in ("failed", "partial", "skipped"):
            _rep, scan = self.scan(self.sb.report([self.row], gh=status))
            self.assert_nothing(scan, "gh status")

    def test_gh_repo_not_ok_refuses_that_candidate(self) -> None:
        _rep, scan = self.scan(self.sb.report([self.row], gh_repos={REPO_SLUG: "failed"}))
        self.assertTrue(scan.ok)
        self.assertEqual(scan.choices, [])
        self.assertIn("gh lookup", refused_reason(scan, self.lane))

    def test_missing_gh_repos_refuses_that_candidate(self) -> None:
        report = self.sb.report([self.row])
        del report["gh_repos"]
        _rep, scan = self.scan(report)
        self.assertEqual(scan.choices, [])
        self.assertIn("gh lookup", refused_reason(scan, self.lane))

    def test_schema_one_yields_nothing(self) -> None:
        _rep, scan = self.scan(self.sb.report([self.row], schema=1))
        self.assert_nothing(scan, "schema 1")

    def test_missing_or_bad_schema_yields_nothing(self) -> None:
        for bad in (None, "2", True):
            _rep, scan = self.scan(self.sb.report([self.row], schema=bad))
            self.assertFalse(scan.ok)
            self.assertEqual(scan.choices, [])

    def test_min_schema_cannot_be_configured_below_two(self) -> None:
        _rep, scan = self.scan(self.sb.report([self.row], schema=1), min_schema=1)
        self.assert_nothing(scan, "schema 1")

    def test_future_dated_report_yields_nothing(self) -> None:
        _rep, scan = self.scan(self.sb.report([self.row], now=time.time() + 900))
        self.assert_nothing(scan, "future")

    def test_small_clock_skew_is_tolerated(self) -> None:
        _rep, scan = self.scan(self.sb.report([self.row], now=time.time() + 60 + 240))
        self.assertTrue(scan.ok, scan.reason)

    def test_missing_unparseable_or_naive_generated_at_yields_nothing(self) -> None:
        for bad in (None, "", "yesterday", "2026-10-08T05:09:34"):
            report = self.sb.report([self.row])
            if bad is None:
                del report["generated_at"]
            else:
                report["generated_at"] = bad
            _rep, scan = self.scan(report)
            self.assert_nothing(scan, "generated_at")

    def test_zulu_timestamps_parse(self) -> None:
        report = self.sb.report([self.row])
        report["generated_at"] = dt.datetime.fromtimestamp(time.time() - 30, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        _rep, scan = self.scan(report)
        self.assertTrue(scan.ok, scan.reason)

    def test_lsof_not_ok_yields_nothing(self) -> None:
        _rep, scan = self.scan(self.sb.report([self.row], lsof="unavailable"))
        self.assert_nothing(scan, "lsof")

    def test_report_for_another_home_yields_nothing(self) -> None:
        _rep, scan = self.scan(self.sb.report([self.row], home="/Users/somebody-else"))
        self.assert_nothing(scan, "different home")

    def test_candidate_not_in_checkouts_is_refused(self) -> None:
        ghost = str(self.sb.lanes_root / "ghost")
        _rep, scan = self.scan(self.sb.report([self.row], candidates=[ghost]))
        self.assertTrue(scan.ok)
        self.assertEqual(scan.choices, [])
        self.assertIn("not found in checkouts", refused_reason(scan, ghost))

    def test_missing_candidate_list_yields_nothing(self) -> None:
        report = self.sb.report([self.row])
        del report["cleaner_candidates"]
        _rep, scan = self.scan(report)
        self.assert_nothing(scan, "cleaner_candidates")

    def test_real_script_timeout_is_killed_and_yields_nothing(self) -> None:
        script = self.sb.root / "slow-doctor.py"
        script.write_text("import time\ntime.sleep(30)\n", encoding="utf-8")
        cfg = self.sb.cfg()
        cfg["lanes"]["doctor_command"] = [sys.executable, str(script)]
        # The timeout is a code constant; a test shortens it on the settings object, never through config.
        settings = dataclasses.replace(lanes.lane_settings(cfg, self.sb.home, env={}), timeout_seconds=1)
        started = time.time()
        rep = lanes.load_report(settings, self.sb.home)
        self.assertLess(time.time() - started, 15)
        self.assertFalse(rep.ok)
        self.assertIn("timed out", rep.reason)

    def test_real_script_through_env_override_is_accepted(self) -> None:
        report_path = self.sb.root / "report.json"
        report_path.write_text(json.dumps(self.sb.report([self.row])), encoding="utf-8")
        script = self.sb.root / "fake-doctor.py"
        script.write_text(
            textwrap.dedent(
                """
                import datetime, json, sys
                data = json.load(open(sys.argv[1]))
                data["generated_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
                print(json.dumps(data))
                """
            ),
            encoding="utf-8",
        )
        env = {lanes.DOCTOR_ENV_VAR: f"{sys.executable} {script} {report_path}"}
        settings = lanes.lane_settings(self.sb.cfg(), self.sb.home, env=env)
        rep = lanes.load_report(settings, self.sb.home)
        self.assertTrue(rep.ok, rep.reason)
        scan = lanes.removable_lanes(rep, self.sb.ctx())
        self.assertEqual([c.path for c in scan.choices], [str(self.lane)])


class TestSettings(unittest.TestCase):
    CONSTANTS = (900.0, 300.0, 2, 7.0, 24.0)

    @staticmethod
    def limits(settings) -> tuple:
        return (
            settings.max_report_age_seconds,
            settings.timeout_seconds,
            settings.min_schema,
            settings.retire_min_days,
            settings.deps_min_hours,
        )

    def test_defaults(self) -> None:
        settings = lanes.lane_settings({}, Path("/home/example"), env={})
        self.assertEqual(settings.command, ("/home/example/apps/lane", "ls", "--json"))
        self.assertEqual(self.limits(settings), self.CONSTANTS)

    def test_config_cannot_move_any_limit_in_either_direction(self) -> None:
        # Review finding: max_report_age_seconds 1e9 used to make a saved report count as fresh forever.
        for block in (
            {"max_report_age_seconds": 1e9, "timeout_seconds": 1e9},
            {"min_schema": 1, "retire_min_days": 1, "dependency_min_idle_hours": 2, "timeout_seconds": "bad"},
            {"min_schema": 3, "retire_min_days": 14, "dependency_min_idle_hours": 48, "max_report_age_seconds": 60},
            {"max_report_age_seconds": float("inf"), "timeout_seconds": -1, "min_schema": None},
        ):
            settings = lanes.lane_settings({"lanes": dict(block, doctor_command=["/bin/doctor"])}, Path("/h"), env={})
            self.assertEqual(self.limits(settings), self.CONSTANTS, block)
            self.assertEqual(settings.command, ("/bin/doctor",))

    def test_shipped_config_numbers_have_no_effect(self) -> None:
        cfg = load_config(path=Path("/nonexistent/config.json"), home=Path("/h"))
        self.assertEqual(self.limits(lanes.lane_settings(cfg, Path("/h"), env={})), self.CONSTANTS)

    def test_a_stale_report_stays_stale_whatever_the_config_says(self) -> None:
        sb = Sandbox(self)
        lane = sb.lane()
        cfg = sb.cfg(max_report_age_seconds=1e9)
        report = sb.report([sb.row(lane)], now=time.time() - 86400)
        rep = lanes.load_report(lanes.lane_settings(cfg, sb.home, env={}), sb.home, doctor_returning(report))
        self.assertFalse(rep.ok)
        self.assertIn("stale", rep.reason)

    def test_env_override_wins_and_is_split_without_a_shell(self) -> None:
        settings = lanes.lane_settings({}, Path("/h"), env={lanes.DOCTOR_ENV_VAR: "/bin/echo 'two words' ~/x; rm -rf /"})
        self.assertEqual(settings.command, ("/bin/echo", "two words", "/h/x;", "rm", "-rf", "/"))

    def test_garbage_command_means_no_command(self) -> None:
        for bad in (None, 5, [1, 2], [""], []):
            settings = lanes.lane_settings({"lanes": {"doctor_command": bad}}, Path("/h"), env={})
            self.assertEqual(settings.command, ())
        rep = lanes.load_report(lanes.lane_settings({"lanes": {"doctor_command": []}}, Path("/h"), env={}), Path("/h"))
        self.assertFalse(rep.ok)


# --------------------------------------------------------------------------- the Vacuum's own re-check


class TestRecheck(unittest.TestCase):
    def setUp(self) -> None:
        self.sb = Sandbox(self)
        self.lane = self.sb.lane("claude-ok")

    def removable(self, rows=None, runner=None, keep=NEVER, **report_over):
        rows = rows if rows is not None else [self.sb.row(self.lane)]
        report = lanes.validate_report(self.sb.report(rows, **report_over), self.sb.settings(), self.sb.home)
        self.assertTrue(report.ok, report.reason)
        return lanes.removable_lanes(report, self.sb.ctx(runner=runner, keep=keep))

    def assert_blocked(self, scan, needle: str, path=None) -> None:
        self.assertEqual(scan.choices, [])
        self.assertIn(needle, refused_reason(scan, path or self.lane))

    def test_nested_lane_is_accepted_and_carries_size_and_command(self) -> None:
        runner = Runner()
        scan = self.removable(runner=runner)
        self.assertEqual(len(scan.choices), 1, scan.refused)
        choice = scan.choices[0]
        self.assertGreater(choice.size_bytes or 0, 0)
        self.assertEqual(choice.command, ["git", "-C", str(self.sb.main), "worktree", "remove", str(self.lane)])
        self.assertIn("PR MERGED #7", choice.reasons)

    def test_ignored_env_file_blocks(self) -> None:
        (self.lane / ".env").write_text("LOCAL_ONLY=1\n", encoding="utf-8")
        self.assert_blocked(self.removable(), "ignored local state")

    def test_ignored_database_file_blocks(self) -> None:
        (self.lane / "data").mkdir()
        (self.lane / "data" / "app.db").write_bytes(b"sqlite")
        self.assert_blocked(self.removable(), "ignored local state: data/")

    def test_ignored_data_dir_blocks_even_beside_regenerable_dirs(self) -> None:
        (self.lane / "node_modules").mkdir()
        (self.lane / "node_modules" / "pkg.js").write_text("x\n", encoding="utf-8")
        (self.lane / "data").mkdir()
        (self.lane / "data" / "keep.txt").write_text("x\n", encoding="utf-8")
        self.assert_blocked(self.removable(), "data/")

    def test_regenerable_ignored_dirs_do_not_block(self) -> None:
        (self.lane / "node_modules").mkdir()
        (self.lane / "node_modules" / "pkg.js").write_text("x\n", encoding="utf-8")
        (self.lane / "dist").mkdir()
        (self.lane / "dist" / "out.js").write_text("x\n", encoding="utf-8")
        scan = self.removable()
        self.assertEqual(len(scan.choices), 1, scan.refused)

    def test_untracked_file_blocks(self) -> None:
        (self.lane / "notes.txt").write_text("scratch\n", encoding="utf-8")
        self.assert_blocked(self.removable(), "untracked files: notes.txt")

    def test_untracked_regenerable_dir_still_blocks_removal(self) -> None:
        (self.lane / ".next").mkdir()
        (self.lane / ".next" / "cache").write_text("x\n", encoding="utf-8")
        self.assert_blocked(self.removable(), "untracked")

    def test_tracked_change_blocks(self) -> None:
        (self.lane / "README.md").write_text("changed\n", encoding="utf-8")
        self.assert_blocked(self.removable(), "tracked changes")

    def test_unpushed_commit_on_a_detached_head_blocks(self) -> None:
        self.sb.commit(self.lane)
        self.sb.git(self.lane, "checkout", "-q", "--detach")
        # The report is built AFTER the commit, so its head sha matches: only the unpushed rule can refuse.
        # On a detached HEAD no branch ref keeps the commit once the lane is gone.
        row = self.sb.row(self.lane, branch=None)
        self.assert_blocked(self.removable([row]), "unpushed commits: 1 on a detached HEAD")

    def test_unpushed_commit_without_merged_evidence_blocks(self) -> None:
        # The report gate already demands MERGED or CLOSED; the live rule refuses on its own as well.
        self.sb.commit(self.lane)
        why = lanes.recheck_for_removal(str(self.lane), self.sb.row(self.lane, pr_state="OPEN"), self.sb.ctx())[1]
        self.assertEqual(why, "unpushed commits: 1")

    def test_unpushed_commits_on_the_reported_branch_are_accepted_with_a_note(self) -> None:
        # A squash-merged lane whose remote branch was pruned: the doctor's MERGED PR covers this head.
        self.sb.commit(self.lane)
        scan = self.removable()
        self.assertEqual(len(scan.choices), 1, scan.refused)
        self.assertIn(f"1 unpushed, kept by branch {self.sb.branch(self.lane)} and PR #7 head", scan.choices[0].reasons)
        self.assertNotIn("0 unpushed", scan.choices[0].reasons)

    def test_pushed_lane_says_zero_unpushed(self) -> None:
        self.assertIn("0 unpushed", self.removable().choices[0].reasons)

    def test_branch_name_reused_with_a_different_head_sha_is_refused(self) -> None:
        # Squash-merge, delete the branch, reuse the name: the doctor's PR evidence is for the OLD head sha.
        stale = self.sb.row(self.lane, head_sha=SHA_A)
        self.assert_blocked(self.removable([stale]), "HEAD moved since the doctor report")

    def test_new_pushed_commit_after_the_report_is_refused(self) -> None:
        row = self.sb.row(self.lane)
        self.sb.commit(self.lane, "later.txt")
        self.sb.push(self.lane)
        self.assert_blocked(self.removable([row]), "HEAD moved")

    def test_branch_switched_after_the_report_is_refused(self) -> None:
        row = self.sb.row(self.lane)
        self.sb.git(self.lane, "checkout", "-q", "-b", "claude/other")
        self.sb.push(self.lane)
        self.assert_blocked(self.removable([row]), "branch changed")

    def test_keep_marker_on_disk_blocks(self) -> None:
        (self.lane / ".janitor-keep").write_text("", encoding="utf-8")
        scan = self.removable()
        self.assertEqual(scan.choices, [])
        # Either gate may fire first (a marker is also an untracked file); the marker must name itself.
        self.assertIn("keep marker", refused_reason(scan, self.lane))

    def test_keep_marker_in_report_blocks(self) -> None:
        self.assert_blocked(self.removable([self.sb.row(self.lane, janitor_keep=True)]), "keep marker")

    def test_keep_regex_blocks(self) -> None:
        keep = re.compile(re.escape(str(self.sb.lanes_root)) + r"/claude-ok$")
        self.assert_blocked(self.removable(keep=keep), "keep list")

    def test_full_clone_is_not_a_linked_worktree(self) -> None:
        clone = self.sb.home / "apps" / "lanes" / "hoghunter" / "claude-clone"
        self.sb.git(self.sb.root, "clone", "-q", str(self.sb.main), str(clone))
        row = self.sb.row(clone, kind="FULL-CLONE", branch="main")
        self.assert_blocked(self.removable([row]), "not a linked worktree", clone)
        # A report that wrongly calls it a linked worktree is caught by the Vacuum's own look at .git.
        lie = self.sb.row(clone, branch="main")
        self.assert_blocked(self.removable([lie]), "not a linked worktree (.git is not a file)", clone)

    def test_unregistered_lane_is_refused(self) -> None:
        row = self.sb.row(self.lane, registered=False)
        self.assert_blocked(self.removable([row]), "not registered")

    def test_locations_that_are_not_lanes_are_refused_even_when_listed(self) -> None:
        for klass in ("FORBIDDEN_TMP", "FORBIDDEN_CODE_TOPLEVEL", "UNSANCTIONED", "INTEGRATION_TREE", "SOMETHING_NEW", None):
            scan = self.removable([self.sb.row(self.lane, location_class=klass)])
            self.assertEqual(scan.choices, [], klass)
            self.assertIn("not a lane location", refused_reason(scan, self.lane))
        self.assertTrue(self.lane.exists())

    def test_every_lane_like_class_is_accepted(self) -> None:
        for klass in ("LANE_NESTED", "LANE_FLAT_LEGACY", "LANE_FLAT", "REVIEW", "MANAGED"):
            scan = self.removable([self.sb.row(self.lane, location_class=klass)])
            self.assertEqual(len(scan.choices), 1, (klass, scan.refused))

    def test_path_outside_home_is_refused_even_with_a_lane_class(self) -> None:
        outside = Path(os.path.realpath(tempfile.mkdtemp(prefix="hhoutside-")))
        self.addCleanup(shutil.rmtree, str(outside), True)
        path = outside / "claude-out"
        self.sb.git(self.sb.main, "worktree", "add", "-q", "-b", "claude/out", str(path))
        scan = self.removable([self.sb.row(path)])
        self.assertEqual(scan.choices, [])
        self.assertIn("outside the home directory", refused_reason(scan, path))

    def test_symlinked_path_is_refused(self) -> None:
        link = self.sb.lanes_root / "linked"
        link.symlink_to(self.lane)
        row = self.sb.row(self.lane, realpath=str(link), path=str(link))
        scan = self.removable([row])
        self.assertEqual(scan.choices, [])
        self.assertIn("resolves somewhere else", refused_reason(scan, link))

    def test_dirty_report_facts_refuse(self) -> None:
        for over, needle in (
            ({"cwd_procs": [123]}, "process is using"),
            ({"cwd_procs": None}, "process is using"),
            ({"active": True}, "process is using"),
            ({"safety": "NEEDS-REVIEW"}, "safety"),
            ({"pr_state": "OPEN"}, "no merged-PR evidence"),
            ({"pr_state": "NONE"}, "no merged-PR evidence"),
            ({"pr_state": "BEYOND-MERGED"}, "no merged-PR evidence"),
            ({"idle_days": 3.0}, "idle_days"),
            ({"lane_age_days": 3.0}, "lane_age_days"),
            ({"idle_days": None}, "idle_days"),
            ({"read_errors": ["status: timeout"]}, "could not read"),
            ({"tool_cache": True}, "tool cache"),
            ({"head_sha": None}, "head sha"),
            ({"owner_repo": ""}, "owner repository"),
        ):
            scan = self.removable([self.sb.row(self.lane, **over)])
            self.assertEqual(scan.choices, [], over)
            self.assertIn(needle, refused_reason(scan, self.lane), over)

    def test_fresh_clean_zero_ahead_lane_is_not_safe(self) -> None:
        # A new lane that is clean and fully pushed, with no merged PR: the doctor would not list it, and
        # even if a report did, the Vacuum refuses without merged-PR evidence and the age floor.
        row = self.sb.row(self.lane, pr_state="NONE", lane_age_days=0.2, idle_days=0.1, safety="NEEDS-REVIEW")
        scan = self.removable([row])
        self.assertEqual(scan.choices, [])

    def test_process_in_the_lane_blocks(self) -> None:
        scan = self.removable(runner=Runner(lsof_paths=["/", str(self.lane / "src")]))
        self.assert_blocked(scan, "working directory")

    def test_lsof_failure_blocks_everything(self) -> None:
        for runner in (Runner(lsof_rc=2), Runner(lsof_paths=[], lsof_rc=0)):
            scan = self.removable(runner=runner)
            self.assert_blocked(scan, "process check failed")

    def test_pgrep_error_blocks(self) -> None:
        for rc in (2, 3):
            self.assert_blocked(self.removable(runner=Runner(pgrep_rc=rc)), "treated as busy")

    def test_pgrep_match_blocks(self) -> None:
        self.assert_blocked(self.removable(runner=Runner(pgrep_rc=0)), "running process")

    def test_branch_checked_out_in_another_worktree_blocks(self) -> None:
        other = self.sb.root / "second-copy"
        self.sb.git(self.sb.main, "worktree", "add", "-q", "--force", str(other), self.sb.branch(self.lane))
        self.assert_blocked(self.removable(), "also checked out")

    def test_locked_worktree_blocks(self) -> None:
        self.sb.git(self.sb.main, "worktree", "lock", str(self.lane))
        self.assert_blocked(self.removable(), "locked")

    def test_status_that_cannot_be_read_blocks(self) -> None:
        class BrokenStatus(Runner):
            def __call__(self, argv, **kwargs):
                if "status" in argv:
                    return subprocess.CompletedProcess(argv, 128, "", "fatal")
                return super().__call__(argv, **kwargs)

        self.assert_blocked(self.removable(runner=BrokenStatus()), "status")

    def test_timeout_in_any_git_call_blocks(self) -> None:
        class Slow(Runner):
            def __call__(self, argv, **kwargs):
                if "rev-list" in argv:
                    raise subprocess.TimeoutExpired(argv, 1)
                return super().__call__(argv, **kwargs)

        self.assert_blocked(self.removable(runner=Slow()), "timed out")

    def test_duplicate_candidates_are_planned_once(self) -> None:
        row = self.sb.row(self.lane)
        scan = self.removable([row], candidates=[row["realpath"], row["realpath"]])
        self.assertEqual(len(scan.choices), 1)


# --------------------------------------------------------------------------- removal (janitor)


class TestRetire(unittest.TestCase):
    def setUp(self) -> None:
        self.sb = Sandbox(self)
        self.cfg = self.sb.cfg()

    def doctor(self, rows, **top):
        return doctor_returning(self.sb.report(rows, **top))

    def retire(self, rows, runner=None, dry_run=False, **top):
        runner = runner or Runner()
        outcome = retire_worktrees(
            self.cfg,
            self.sb.home,
            runner,
            dry_run=dry_run,
            doctor_runner=self.doctor(rows, **top),
            data_dir=Path(self.cfg["data_dir"]),
        )
        return outcome, runner

    def test_nested_lane_is_removed_with_git_worktree_remove_and_never_force(self) -> None:
        lane = self.sb.lane("claude-nested")
        (lane / "node_modules").mkdir()
        (lane / "node_modules" / "pkg.js").write_text("x\n", encoding="utf-8")
        outcome, runner = self.retire([self.sb.row(lane)])
        self.assertEqual(outcome.retired, 1, outcome.detail)
        self.assertFalse(lane.exists())
        self.assertNotIn(str(lane), self.sb.git(self.sb.main, "worktree", "list", "--porcelain"))
        self.assertEqual(runner.removals(), [["git", "-C", str(self.sb.main), "worktree", "remove", str(lane)]])
        for argv in runner.calls:
            if argv[0] != "git":
                continue
            self.assertNotIn("--force", argv)
            self.assertNotIn("-f", argv)
            self.assertFalse(any(part.startswith("-") and not part.startswith("--") and "f" in part[1:] for part in argv), argv)
        self.assertGreater(outcome.bytes_freed, 0)
        self.assertIn(shlex.join(["git", "-C", str(self.sb.main), "worktree", "remove", str(lane)]), outcome.detail)

    def test_lane_with_unpushed_commits_on_its_merged_branch_is_removed_and_the_branch_keeps_them(self) -> None:
        lane = self.sb.lane("claude-squashed")
        self.sb.commit(lane)  # not under any remote ref, like a squash-merged branch whose remote ref was pruned
        head, branch = self.sb.head(lane), self.sb.branch(lane)
        outcome, runner = self.retire([self.sb.row(lane)])
        self.assertEqual(outcome.retired, 1, outcome.detail)
        self.assertFalse(lane.exists())
        self.assertEqual(runner.removals(), [["git", "-C", str(self.sb.main), "worktree", "remove", str(lane)]])
        # The proof the commits survive: the branch ref still names the removed lane's HEAD.
        self.assertEqual(self.sb.git(self.sb.main, "rev-parse", f"refs/heads/{branch}"), head)
        entry = json.loads((Path(self.cfg["data_dir"]) / lanes.ACTION_LOG_NAME).read_text(encoding="utf-8").splitlines()[-1])
        self.assertIn(f"1 unpushed, kept by branch {branch} and PR #7 head", entry["reasons"])

    def test_action_log_records_size_and_exact_command(self) -> None:
        lane = self.sb.lane("claude-logged")
        self.retire([self.sb.row(lane)])
        lines = (Path(self.cfg["data_dir"]) / lanes.ACTION_LOG_NAME).read_text(encoding="utf-8").splitlines()
        entry = json.loads(lines[-1])
        self.assertEqual(entry["action"], "retired")
        self.assertEqual(entry["path"], str(lane))
        self.assertGreater(entry["size_bytes"], 0)
        self.assertEqual(entry["command"], shlex.join(["git", "-C", str(self.sb.main), "worktree", "remove", str(lane)]))
        self.assertEqual(entry["step_id"], "janitor_worktree_retire")

    def test_dry_run_removes_nothing_and_prints_a_plan(self) -> None:
        lane = self.sb.lane("claude-dry")
        outcome, runner = self.retire([self.sb.row(lane)], dry_run=True)
        self.assertTrue(lane.exists())
        self.assertEqual(outcome.retired, 0)
        self.assertEqual(runner.removals(), [])
        self.assertFalse((Path(self.cfg["data_dir"]) / lanes.ACTION_LOG_NAME).exists())
        self.assertEqual([a["action"] for a in outcome.actions], ["would-retire"])
        action = outcome.actions[0]
        self.assertEqual(action["path"], str(lane))
        self.assertGreater(action["size_bytes"], 0)
        self.assertIn("worktree remove", action["command"])
        self.assertNotIn("--force", action["command"])
        self.assertIn("would-retire", outcome.detail)

    def test_plan_function_never_removes_and_reports_refusals(self) -> None:
        good = self.sb.lane("claude-good")
        bad = self.sb.lane("claude-bad")
        (bad / ".env").write_text("LOCAL_ONLY=1\n", encoding="utf-8")
        plan = plan_retire_worktrees(
            self.cfg, self.sb.home, Runner(), doctor_runner=self.doctor([self.sb.row(good), self.sb.row(bad)]), dry_run=True
        )
        self.assertTrue(plan.ok)
        self.assertTrue(plan.dry_run)
        self.assertEqual([c.path for c in plan.choices], [str(good)])
        self.assertEqual([r["path"] for r in plan.refused], [str(bad)])
        self.assertTrue(good.exists() and bad.exists())
        self.assertEqual(json.loads(json.dumps(plan.as_dict()))["candidates"][0]["path"], str(good))

    def test_failed_removal_is_logged_and_the_run_carries_on(self) -> None:
        first = self.sb.lane("claude-first")
        second = self.sb.lane("claude-second")
        runner = Runner(fail_remove={str(first)})
        outcome, _ = self.retire([self.sb.row(first), self.sb.row(second)], runner=runner)
        self.assertEqual(outcome.retired, 1, outcome.detail)
        self.assertTrue(first.exists())
        self.assertFalse(second.exists())
        self.assertIn(f"failed {first}", outcome.detail)
        self.assertEqual([a["action"] for a in outcome.actions], ["failed", "retired"])

    def test_lane_that_became_dirty_after_planning_is_skipped(self) -> None:
        lane = self.sb.lane("claude-late")
        plan = plan_retire_worktrees(self.cfg, self.sb.home, Runner(), doctor_runner=self.doctor([self.sb.row(lane)]))
        self.assertEqual(len(plan.choices), 1)
        (lane / ".env").write_text("LOCAL_ONLY=1\n", encoding="utf-8")
        runner = Runner()
        outcome = apply_retire_worktrees(plan, self.cfg, self.sb.home, runner, data_dir=Path(self.cfg["data_dir"]))
        self.assertEqual(outcome.retired, 0)
        self.assertTrue(lane.exists())
        self.assertEqual(runner.removals(), [])
        self.assertIn("skipped", outcome.detail)
        self.assertIn("ignored local state", outcome.detail)

    def test_unusable_doctor_removes_nothing(self) -> None:
        lane = self.sb.lane("claude-nodoc")
        outcome, runner = self.retire([self.sb.row(lane)], schema=1)
        self.assertEqual(outcome.retired, 0)
        self.assertTrue(lane.exists())
        self.assertEqual(runner.removals(), [])
        self.assertIn("lane doctor unusable", outcome.detail)

    def test_retirement_can_be_switched_off(self) -> None:
        lane = self.sb.lane("claude-off")
        self.cfg["janitor"]["reap_worktrees"] = False
        outcome, runner = self.retire([self.sb.row(lane)])
        self.assertEqual(outcome.detail, "worktree retirement disabled")
        self.assertTrue(lane.exists())

    def test_long_detail_never_cuts_a_note_in_half(self) -> None:
        from vacuum import janitor

        first = "retired /a (1.0 MB) via " + "x" * 700
        notes = [first] + [f"retired /lane-{i} (1.0 MB) via git worktree remove /lane-{i}" for i in range(40)]
        text = janitor._clip(notes)
        self.assertTrue(text.startswith(first))
        self.assertIn("more, see " + lanes.ACTION_LOG_NAME, text)
        self.assertLess(len(text), len(first) + 100)
        self.assertEqual(janitor._clip(["a", "b", "c"]), "a; b; c")

    def test_force_is_refused_by_the_argv_builder(self) -> None:
        for bad in (["git", "worktree", "remove", "--force", "x"], ["git", "worktree", "remove", "-f", "x"], ["git", "-fC", "x"]):
            with self.assertRaises(ValueError):
                lanes.assert_no_force(bad)
        self.assertEqual(
            lanes.removal_argv("/r", "/r/lane"), ["git", "-C", "/r", "worktree", "remove", "/r/lane"]
        )

    def test_invalid_keep_regex_raises_for_the_engine_to_record(self) -> None:
        self.cfg["keep_worktree_regex"] = "[invalid"
        with self.assertRaises(re.error):
            plan_retire_worktrees(self.cfg, self.sb.home, Runner(), doctor_runner=self.doctor([]))


# --------------------------------------------------------------------------- status parsing


class TestParseStatus(unittest.TestCase):
    def parse(self, *entries: str):
        return lanes.parse_status("\0".join(entries) + "\0")

    def test_regenerable_ignored_dirs(self) -> None:
        scan = self.parse("!! node_modules/", "!! packages/web/.next/", "!! .pytest_cache/", "!! DerivedData/")
        self.assertEqual(scan.removal_blocker(), "")
        self.assertEqual(scan.regen_ignored, ["node_modules", "packages/web/.next", ".pytest_cache", "DerivedData"])

    def test_anything_else_blocks(self) -> None:
        # "!! foo.pyc" used to be on this list; the doctor calls *.pyc regenerable, so it no longer blocks
        # removal (see test_removal_only_entries).  "!! build" with no slash is a FILE or a link, not a folder.
        for entry in (
            "!! .env",
            "!! data/",
            "!! build",
            "!! app.db",
            "!! secrets/",
            "!! ../x/",
            "!! /abs/dist/",
            "!! ../x.pyc",
            "!! .DS_Store/",
            "!! venv-data/",
            "!! build/app.db",
        ):
            self.assertNotEqual(self.parse(entry).removal_blocker(), "", entry)

    def test_removal_only_entries(self) -> None:
        entries = (
            "!! .DS_Store",
            "!! pkg/.DS_Store",
            "!! mod.pyc",
            "!! tsconfig.tsbuildinfo",
            "!! .build/",
            "!! venv/",
            "!! .mypy_cache/",
            "!! .ruff_cache/",
            "!! dist-electron/",
        )
        scan = self.parse(*entries)
        self.assertEqual(scan.removal_blocker(), "")
        self.assertEqual(scan.removal_only_dirs, [".build", "venv", ".mypy_cache", ".ruff_cache", "dist-electron"])
        self.assertEqual(scan.removal_only_files, [".DS_Store", "pkg/.DS_Store", "mod.pyc", "tsconfig.tsbuildinfo"])
        # Never deletable by the dependency step.
        self.assertEqual(scan.regen_ignored, [])
        self.assertEqual(scan.removal_walk_dirs(), [".build", "venv", ".mypy_cache", ".ruff_cache", "dist-electron"])

    def test_link_candidates_pass_only_when_verified(self) -> None:
        scan = self.parse("!! node_modules", "!! build")
        self.assertEqual(scan.link_candidates, ["node_modules", "build"])
        self.assertIn("node_modules", scan.removal_blocker())
        self.assertIn("build", scan.removal_blocker(["node_modules"]))
        self.assertEqual(scan.removal_blocker(["node_modules", "build"]), "")

    def test_untracked_and_tracked_changes_block(self) -> None:
        self.assertIn("untracked", self.parse("?? notes.txt").removal_blocker())
        self.assertIn("tracked changes", self.parse(" M README.md").removal_blocker())
        self.assertIn("tracked changes", self.parse("A  new.txt").removal_blocker())
        self.assertIn("tracked changes", self.parse("UU conflict.txt").removal_blocker())

    def test_rename_consumes_its_origin_path(self) -> None:
        scan = self.parse("R  new.txt", "old.txt", "!! node_modules/")
        self.assertEqual(len(scan.tracked_dirty), 1)
        self.assertEqual(scan.regen_ignored, ["node_modules"])

    def test_garbage_blocks(self) -> None:
        self.assertNotEqual(self.parse("x").removal_blocker(), "")

    def test_untracked_dependency_folders_are_deletable_only_for_the_narrow_list(self) -> None:
        scan = self.parse("?? node_modules/", "?? dist/", "?? build/")
        self.assertEqual(scan.regen_untracked, ["node_modules"])
        self.assertEqual(scan.regen_ignored, [])


# --------------------------------------------------------------------------- what git hides (review findings)


class TestNestedRepositories(unittest.TestCase):
    """A clone inside an ignored folder (.venv/src/<pkg> from pip install -e git+..., or one under build/) shows in
    git status only as `!! .venv/`, and git worktree remove or rmtree would take its local-only commits."""

    FOLDERS = (".venv/src/mypkg", "build/vendor-clone")

    def setUp(self) -> None:
        self.sb = Sandbox(self)
        self.sb.ignore(".venv/", "build/", ".build/")
        self.cfg = self.sb.cfg()

    def test_retire_refuses_a_lane_with_a_nested_clone_in_an_ignored_folder(self) -> None:
        for folder in self.FOLDERS:
            lane = self.sb.lane("claude-nest-" + folder.split("/")[0].strip("."))
            nested = nested_clone(lane / folder)
            self.assertEqual(self.sb.git(lane, "status", "--porcelain", "--ignored"), "!! " + folder.split("/")[0] + "/")
            runner = Runner()
            doctor = doctor_returning(self.sb.report([self.sb.row(lane)]))
            plan = plan_retire_worktrees(self.cfg, self.sb.home, runner, doctor_runner=doctor)
            self.assertEqual(plan.choices, [], folder)
            self.assertIn("nested git repository", refused_reason(plan, lane), folder)
            outcome = retire_worktrees(self.cfg, self.sb.home, runner, doctor_runner=doctor)
            self.assertEqual(outcome.retired, 0, folder)
            self.assertEqual(runner.removals(), [], folder)
            self.assertTrue((nested / ".git").is_dir(), folder)

    def test_swiftpm_checkouts_keep_a_lane(self) -> None:
        lane = self.sb.lane("claude-spm")
        nested_clone(lane / ".build" / "checkouts" / "swift-argument-parser")
        plan = plan_retire_worktrees(
            self.cfg, self.sb.home, Runner(), doctor_runner=doctor_returning(self.sb.report([self.sb.row(lane)]))
        )
        self.assertIn("nested git repository", refused_reason(plan, lane))

    def test_another_reported_checkout_inside_the_lane_refuses(self) -> None:
        lane = self.sb.lane("claude-outer")
        inner = lane / "build" / "inner"
        nested_clone(inner)
        rows = [self.sb.row(lane), {"path": str(inner), "realpath": str(inner), "kind": "FULL-CLONE"}]
        report = lanes.validate_report(self.sb.report(rows, candidates=[str(lane)]), self.sb.settings(), self.sb.home)
        scan = lanes.removable_lanes(report, self.sb.ctx())
        self.assertEqual(scan.choices, [])
        self.assertIn("another checkout lives inside it", refused_reason(scan, lane))

    def test_dependency_step_keeps_a_folder_holding_a_nested_clone(self) -> None:
        lane = self.sb.lane("claude-nest-deps")
        nested = [nested_clone(lane / folder) for folder in self.FOLDERS]
        (lane / "node_modules").mkdir()
        (lane / "node_modules" / "pkg.js").write_text("x\n", encoding="utf-8")
        now = time.time() + 3 * 86400
        row = self.sb.row(lane, pr_state="NONE", safety="NEEDS-REVIEW", idle_days=2.0, lane_age_days=2.0)
        report = self.sb.report([row], now=now, candidates=[])

        def engine() -> VacuumEngine:
            return VacuumEngine(self.cfg, self.sb.home, runner=Runner(), doctor_runner=doctor_returning(report), clock=lambda: now)

        dry = engine()
        dry._pressure_apps_deps(dry_run=True)
        refusals = {a["path"]: a["reason"] for a in dry.plan if a["action"] == "refused"}
        for folder in (".venv", "build"):
            self.assertIn("nested git repository", refusals.get(str(lane / folder), ""), (folder, dry.plan))
        self.assertEqual([a["path"] for a in dry.plan if a["action"] == "would-remove-folder"], [str(lane / "node_modules")])

        _freed, reason, status = engine()._pressure_apps_deps(dry_run=False)
        self.assertEqual(status, StepStatus.RAN, reason)
        self.assertFalse((lane / "node_modules").exists())
        for clone in nested:
            self.assertTrue((clone / ".git").is_dir(), clone)
            self.assertTrue((clone / "work.py").exists(), clone)


class TestNestedRepoWalker(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(os.path.realpath(tempfile.mkdtemp(prefix="hhwalk-")))
        self.addCleanup(shutil.rmtree, str(self.root), True)

    def test_a_gitfile_or_git_folder_anywhere_below_refuses(self) -> None:
        (self.root / "a" / "b").mkdir(parents=True)
        self.assertEqual(lanes.nested_repo_blocker(str(self.root)), "")
        (self.root / "a" / "b" / ".git").write_text("gitdir: /elsewhere\n", encoding="utf-8")
        self.assertIn("nested git repository", lanes.nested_repo_blocker(str(self.root)))

    def test_symlinks_are_not_followed(self) -> None:
        outside = nested_clone(self.root / "outside")
        inside = self.root / "inside"
        inside.mkdir()
        (inside / "link").symlink_to(outside)
        self.assertEqual(lanes.nested_repo_blocker(str(inside)), "")
        self.assertEqual(lanes.nested_repo_blocker(str(inside / "link")), "")  # a link itself is removed, not entered

    def test_the_cap_refuses(self) -> None:
        for i in range(5):
            (self.root / f"f{i}").write_text("x", encoding="utf-8")
        self.assertIn("more than 3 entries", lanes.nested_repo_blocker(str(self.root), cap=3))
        self.assertEqual(lanes.nested_repo_blocker(str(self.root), cap=10), "")

    def test_missing_folder_has_nothing_to_hide(self) -> None:
        self.assertEqual(lanes.nested_repo_blocker(str(self.root / "gone")), "")

    @unittest.skipIf(hasattr(os, "geteuid") and os.geteuid() == 0, "root reads any folder")
    def test_unreadable_folder_refuses_and_is_never_called_idle(self) -> None:
        locked = self.root / "locked"
        locked.mkdir()
        (locked / "x").write_text("x", encoding="utf-8")
        backdate(self.root, 86400)
        os.chmod(locked, 0)
        self.addCleanup(os.chmod, locked, 0o755)
        self.assertIn("cannot read", lanes.nested_repo_blocker(str(self.root)))
        # The idle check used to skip unreadable folders silently and call the tree idle.
        self.assertTrue(lanes.recently_modified(str(self.root), 3600))
        os.chmod(locked, 0o755)
        self.assertFalse(lanes.recently_modified(str(self.root), 3600))


class TestHiddenIndexFlags(unittest.TestCase):
    """A tracked file marked --skip-worktree or --assume-unchanged can hold edits that git status never shows."""

    def test_hidden_edits_block_removal(self) -> None:
        for flag, tag in (("--skip-worktree", "S"), ("--assume-unchanged", "h")):
            with self.subTest(flag=flag):
                sb = Sandbox(self)
                cfg = sb.cfg()
                lane = sb.lane("claude-hidden")
                (lane / "settings.json").write_text('{"theme": "light"}\n', encoding="utf-8")
                sb.git(lane, "add", "settings.json")
                sb.git(lane, "commit", "-q", "-m", "template")
                sb.push(lane)
                sb.git(lane, "update-index", flag, "settings.json")
                (lane / "settings.json").write_text('{"theme": "dark"}\n', encoding="utf-8")
                self.assertEqual(sb.git(lane, "status", "--porcelain", "--ignored"), "")
                doctor = doctor_returning(sb.report([sb.row(lane)]))
                plan = plan_retire_worktrees(cfg, sb.home, Runner(), doctor_runner=doctor)
                self.assertIn("index flags", refused_reason(plan, lane))
                self.assertIn(f"{tag} settings.json", refused_reason(plan, lane))
                runner = Runner()
                outcome = retire_worktrees(cfg, sb.home, runner, doctor_runner=doctor)
                self.assertEqual((outcome.retired, runner.removals()), (0, []))
                self.assertIn("dark", (lane / "settings.json").read_text(encoding="utf-8"))


class TestProcessPathMatching(unittest.TestCase):
    """pgrep -f takes an extended regular expression, so a lane path with + ( ) $ ? [ { | did not match itself."""

    ODD = ("/h/a+b", "/h/v(2)", "/h/x$y", "/h/q?m", "/h/s[1]", "/h/c{2}", "/h/p|q", "/h/d.e", "/h/^h", "/h/back\\slash", "/h/b]r}")

    def test_escaped_pattern_matches_only_the_literal_path(self) -> None:
        for text in self.ODD:
            pattern = lanes.ere_escape(text)
            self.assertTrue(re.fullmatch(pattern, text), text)
            self.assertIsNone(re.fullmatch(pattern, text + "x"), text)

    def test_control_characters_read_as_busy_without_running_pgrep(self) -> None:
        runner = Runner()
        busy, reason = lanes.path_process_state(runner, "/h/new\nline")
        self.assertTrue(busy)
        self.assertIn("control characters", reason)
        self.assertEqual(runner.calls, [])

    @unittest.skipUnless(shutil.which("pgrep"), "pgrep not installed")
    def test_a_process_naming_a_file_in_an_oddly_named_lane_blocks_removal(self) -> None:
        sb = Sandbox(self)
        for name in ("claude-a+b", "claude-v(2)", "claude-plain"):
            lane = sb.lane(name)
            # cwd elsewhere, so only the command-line search can see it (lsof is scripted to "/").
            proc = subprocess.Popen(
                [sys.executable, "-c", "import time; time.sleep(120)", str(lane / "server.log")],
                cwd="/",
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            self.addCleanup(proc.wait)
            self.addCleanup(proc.kill)
            report = lanes.validate_report(sb.report([sb.row(lane)]), sb.settings(), sb.home)
            runner = PgrepPassthrough()
            scan = lanes.removable_lanes(report, sb.ctx(runner=runner))
            self.assertEqual(scan.choices, [], name)
            self.assertIn("running process mentions this path", refused_reason(scan, lane), name)
            proc.kill()
            proc.wait()
            scan = lanes.removable_lanes(report, sb.ctx(runner=PgrepPassthrough()))
            self.assertEqual([c.path for c in scan.choices], [str(lane)], (name, scan.refused))


class TestDoctorAgreement(unittest.TestCase):
    """The doctor calls more ignored entries regenerable than the dependency step may delete.  Those must not
    block removal (git worktree remove takes them), and the dependency step must still leave them alone."""

    def setUp(self) -> None:
        self.sb = Sandbox(self)
        self.sb.ignore(".DS_Store", ".build/", "venv/", ".mypy_cache/", ".ruff_cache/", "*.pyc", "*.tsbuildinfo", "dist-*/")
        self.cfg = self.sb.cfg()

    def plan(self, lane):
        return plan_retire_worktrees(
            self.cfg, self.sb.home, Runner(), doctor_runner=doctor_returning(self.sb.report([self.sb.row(lane)]))
        )

    def fill(self, lane: Path) -> None:
        (lane / ".DS_Store").write_bytes(b"\0")
        (lane / "mod.pyc").write_bytes(b"\0")
        (lane / "tsconfig.tsbuildinfo").write_text("{}\n", encoding="utf-8")
        for folder in (".build/debug", "venv/lib", ".mypy_cache", ".ruff_cache", "dist-electron"):
            (lane / folder).mkdir(parents=True)
            (lane / folder / "blob").write_text("x\n", encoding="utf-8")

    def test_doctor_regenerable_entries_do_not_block_removal(self) -> None:
        lane = self.sb.lane("claude-regen")
        self.fill(lane)
        plan = self.plan(lane)
        self.assertEqual([c.path for c in plan.choices], [str(lane)], plan.refused)
        outcome = apply_retire_worktrees(plan, self.cfg, self.sb.home, Runner())
        self.assertEqual(outcome.retired, 1, outcome.detail)
        self.assertFalse(lane.exists())

    def test_node_modules_symlink_does_not_block_and_its_target_survives(self) -> None:
        self.sb.ignore("node_modules")  # without the slash, so git ignores the link as well as a folder
        shared = self.sb.root / "shared-node-modules"
        shared.mkdir()
        (shared / "keep.js").write_text("x\n", encoding="utf-8")
        lane = self.sb.lane("claude-link")
        (lane / "node_modules").symlink_to(shared)
        plan = self.plan(lane)
        self.assertEqual(len(plan.choices), 1, plan.refused)
        self.assertEqual(apply_retire_worktrees(plan, self.cfg, self.sb.home, Runner()).retired, 1)
        self.assertTrue((shared / "keep.js").exists())

    def test_an_ignored_plain_file_named_like_a_folder_still_blocks(self) -> None:
        self.sb.ignore("build")
        lane = self.sb.lane("claude-buildfile")
        (lane / "build").write_text("a hand-built binary\n", encoding="utf-8")
        self.assertIn("ignored local state: build", refused_reason(self.plan(lane), lane))

    def test_dependency_step_never_deletes_the_removal_only_entries(self) -> None:
        lane = self.sb.lane("claude-regen-deps")
        self.fill(lane)
        (lane / "node_modules").mkdir()
        (lane / "node_modules" / "pkg.js").write_text("x\n", encoding="utf-8")
        now = time.time() + 3 * 86400
        row = self.sb.row(lane, pr_state="NONE", safety="NEEDS-REVIEW", idle_days=2.0, lane_age_days=2.0)
        engine = VacuumEngine(
            self.cfg,
            self.sb.home,
            runner=Runner(),
            doctor_runner=doctor_returning(self.sb.report([row], now=now, candidates=[])),
            clock=lambda: now,
        )
        _freed, reason, status = engine._pressure_apps_deps(dry_run=False)
        self.assertEqual(status, StepStatus.RAN, reason)
        self.assertFalse((lane / "node_modules").exists())
        for name in (".DS_Store", "mod.pyc", "tsconfig.tsbuildinfo", ".build", "venv", ".mypy_cache", ".ruff_cache", "dist-electron"):
            self.assertTrue((lane / name).exists(), name)


class TestHarnessWorktrees(unittest.TestCase):
    """The dependency step leaves harness-managed worktrees alone, and nothing touches ~/.grok/worktrees."""

    def setUp(self) -> None:
        self.sb = Sandbox(self)
        self.cfg = self.sb.cfg()
        self.now = time.time() + 3 * 86400

    def worktree(self, rel: str) -> Path:
        path = self.sb.home / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        self.sb.git(self.sb.main, "worktree", "add", "-q", "-b", "harness/" + path.name, str(path))
        self.sb.git(path, "commit", "-q", "--allow-empty", "-m", "work")
        self.sb.push(path)
        (path / "node_modules" / "pkg").mkdir(parents=True)
        (path / "node_modules" / "pkg" / "i.js").write_text("x\n", encoding="utf-8")
        return path

    def deps(self, row, dry_run: bool) -> VacuumEngine:
        engine = VacuumEngine(
            self.cfg,
            self.sb.home,
            runner=Runner(),
            doctor_runner=doctor_returning(self.sb.report([row], now=self.now, candidates=[])),
            clock=lambda: self.now,
        )
        engine._pressure_apps_deps(dry_run=dry_run)
        return engine

    def deps_row(self, path: Path, klass: str) -> dict:
        return self.sb.row(path, location_class=klass, pr_state="NONE", safety="NEEDS-REVIEW", idle_days=2.0, lane_age_days=2.0)

    def test_managed_worktrees_are_left_to_their_harness(self) -> None:
        for rel in (".grok/worktrees/session-1", ".codex/worktrees/abc"):
            path = self.worktree(rel)
            row = self.deps_row(path, "MANAGED")
            self.assertEqual([a for a in self.deps(row, True).plan if a["action"] == "would-remove-folder"], [], rel)
            self.deps(row, False)
            self.assertTrue((path / "node_modules" / "pkg" / "i.js").exists(), rel)

    def test_never_touch_folders_refuse_even_with_a_lane_class(self) -> None:
        path = self.worktree(".grok/worktrees/session-2")
        row = self.deps_row(path, "LANE_NESTED")
        refusals = [a["reason"] for a in self.deps(row, True).plan if a["action"] == "refused"]
        self.assertTrue(any("~/.grok/worktrees" in r for r in refusals), refusals)
        self.deps(row, False)
        self.assertTrue((path / "node_modules" / "pkg" / "i.js").exists())
        plan = plan_retire_worktrees(
            self.cfg, self.sb.home, Runner(), doctor_runner=doctor_returning(self.sb.report([self.sb.row(path)]))
        )
        self.assertIn("~/.grok/worktrees", refused_reason(plan, path))


# --------------------------------------------------------------------------- engine steps


def only_step(cfg: dict, step_id: str) -> None:
    for sid in list(cfg["steps"]):
        cfg["steps"][sid] = {"enabled": sid == step_id}


class TestEngineProcessChecks(unittest.TestCase):
    """pgrep and lsof failures read as busy: the step is skipped, with the reason."""

    def engine(self, runner):
        return VacuumEngine(load_config(home=Path(tempfile.gettempdir())), Path(tempfile.gettempdir()), runner=runner)

    def test_pgrep_exit_codes(self) -> None:
        self.assertFalse(self.engine(Runner(pgrep_rc=1))._install_running("npm install"))
        self.assertTrue(self.engine(Runner(pgrep_rc=0))._install_running("npm install"))
        for rc in (2, 3, 127):
            engine = self.engine(Runner(pgrep_rc=rc))
            self.assertTrue(engine._install_running("npm install"), rc)
            self.assertTrue(engine._pgrep_f("/some/path"), rc)
            self.assertIn("treated as busy", engine._busy_reason)

    def test_pgrep_that_cannot_run_is_busy(self) -> None:
        def boom(argv, **kwargs):
            raise FileNotFoundError("pgrep")

        def slow(argv, **kwargs):
            raise subprocess.TimeoutExpired(argv, 3)

        for runner in (boom, slow):
            engine = self.engine(runner)
            self.assertTrue(engine._install_running("npm install"))
            self.assertTrue(engine._pgrep_f("/some/path"))
            self.assertIn("treated as busy", engine._busy_reason)

    def test_install_steps_skip_when_pgrep_errors(self) -> None:
        engine = self.engine(Runner(pgrep_rc=2))
        with patch("vacuum.engine.shutil.which", return_value="/usr/bin/true"), patch(
            "vacuum.engine.subprocess.run"
        ) as ran:
            for step in (engine._npm_cache, engine._pnpm_store, engine._brew_cleanup):
                freed, reason, status = step()
                self.assertEqual(status, StepStatus.SKIPPED)
                self.assertIn("pgrep exited 2", reason)
                self.assertEqual(freed, 0)
        ran.assert_not_called()

    def test_install_steps_run_when_pgrep_is_clear(self) -> None:
        engine = self.engine(Runner(pgrep_rc=1))
        with patch("vacuum.engine.shutil.which", return_value="/usr/bin/true"), patch(
            "vacuum.engine.subprocess.run"
        ) as ran, patch("vacuum.engine.shutil.rmtree"):
            _freed, _reason, status = engine._pnpm_store()
        self.assertEqual(status, StepStatus.RAN)
        ran.assert_called()

    def test_install_step_reports_a_real_match_plainly(self) -> None:
        engine = self.engine(Runner(pgrep_rc=0))
        with patch("vacuum.engine.shutil.which", return_value="/usr/bin/true"):
            _freed, reason, status = engine._npm_cache()
        self.assertEqual((status, reason), (StepStatus.SKIPPED, "npm install in progress"))


class OnlyMatching(Runner):
    """pgrep reports a match only when its pattern contains `needle`."""

    def __init__(self, needle: str) -> None:
        super().__init__()
        self.needle = needle

    def __call__(self, argv, **kwargs):
        if argv[0] == "pgrep":
            self.calls.append(list(argv))
            return subprocess.CompletedProcess(argv, 0 if self.needle in argv[-1] else 1, "", "")
        return super().__call__(argv, **kwargs)


class TestLegacyFullSteps(unittest.TestCase):
    """The older `full` steps follow config/reclaim-policy.json: no Xcode cleanup while a build runs, idle gates
    per folder, never `simctl delete unavailable` (it deletes CoreSimulator/Devices), and brew --prune=all."""

    def setUp(self) -> None:
        td = tempfile.mkdtemp(prefix="hhlegacy-")
        self.addCleanup(shutil.rmtree, td, True)
        self.home = Path(os.path.realpath(td))
        self.cfg = load_config(path=self.home / "none.json", home=self.home)
        self.dd = self.home / "Library/Developer/Xcode/DerivedData"
        self.ds = self.home / "Library/Developer/Xcode/iOS DeviceSupport"

    def engine(self, runner=None) -> VacuumEngine:
        return VacuumEngine(self.cfg, self.home, runner=runner or Runner())

    @staticmethod
    def folder(root: Path, name: str, age_seconds: float) -> Path:
        path = root / name
        (path / "sub").mkdir(parents=True)
        (path / "sub" / "x.bin").write_bytes(b"1" * 100)
        if age_seconds:
            backdate(path, age_seconds)
        return path

    def test_derived_data_keeps_a_project_written_recently_and_clears_an_idle_one(self) -> None:
        live = self.folder(self.dd, "Live-abc", 0)
        idle = self.folder(self.dd, "Idle-def", 3 * 3600)
        freed, reason, status = self.engine()._xcode_derived_data()
        self.assertEqual(status, StepStatus.RAN, reason)
        self.assertTrue(live.exists())
        self.assertFalse(idle.exists())
        self.assertEqual(freed, 100)
        self.assertIn("cleared 1 DerivedData project folder, kept 1", reason)

    def test_derived_data_is_left_alone_while_a_build_runs_or_the_check_fails(self) -> None:
        idle = self.folder(self.dd, "Idle-def", 3 * 3600)
        for runner, needle in (
            (OnlyMatching("xcodebuild"), "xcodebuild is running"),
            (OnlyMatching("clang"), "clang is running"),
            (OnlyMatching("swift-frontend"), "swift-frontend is running"),
            (Runner(pgrep_rc=2), "treated as busy"),
        ):
            freed, reason, status = self.engine(runner)._xcode_derived_data()
            self.assertEqual((freed, status), (0, StepStatus.SKIPPED), needle)
            self.assertIn(needle, reason)
            self.assertTrue(idle.exists(), needle)

    def test_derived_data_keeps_marked_and_linked_folders(self) -> None:
        kept = self.folder(self.dd, "Kept", 0)
        (kept / ".janitor-keep").write_text("", encoding="utf-8")
        backdate(kept, 3 * 3600)
        outside = self.folder(self.home, "outside", 3 * 3600)
        (self.dd / "Link").symlink_to(outside)
        self.engine()._xcode_derived_data()
        self.assertTrue(kept.exists())
        self.assertTrue((outside / "sub" / "x.bin").exists())
        self.assertTrue((self.dd / "Link").is_symlink())

    def test_device_support_is_off_by_default_and_keeps_versions_used_within_seven_days(self) -> None:
        self.assertFalse(step_enabled(self.cfg, "xcode_device_support"))
        self.assertNotIn("xcode_device_support", steps_for_trigger(self.cfg, "full"))
        recent = self.folder(self.ds, "18.0 (22A3354)", 2 * 86400)
        old = self.folder(self.ds, "17.5 (21F79)", 8 * 86400)
        _freed, reason, status = self.engine()._xcode_device_support()
        self.assertEqual(status, StepStatus.RAN, reason)
        self.assertTrue(recent.exists())
        self.assertFalse(old.exists())

    def test_simctl_delete_unavailable_never_deletes(self) -> None:
        with patch("vacuum.engine.shutil.which", return_value="/usr/bin/xcrun"), patch("vacuum.engine.subprocess.run") as ran:
            freed, reason, status = self.engine()._simctl_delete_unavailable()
        self.assertEqual((freed, status), (0, StepStatus.SKIPPED))
        self.assertIn("CoreSimulator/Devices", reason)
        ran.assert_not_called()

    def test_brew_cleanup_uses_prune_all_and_waits_for_node_gyp(self) -> None:
        with patch("vacuum.engine.shutil.which", return_value="/usr/bin/true"), patch("vacuum.engine.subprocess.run") as ran:
            _freed, _reason, status = self.engine(Runner(pgrep_rc=1))._brew_cleanup()
        self.assertEqual(status, StepStatus.RAN)
        self.assertEqual(ran.call_args[0][0], ["brew", "cleanup", "--prune=all"])
        with patch("vacuum.engine.shutil.which", return_value="/usr/bin/true"), patch("vacuum.engine.subprocess.run") as ran:
            _freed, reason, status = self.engine(OnlyMatching("node-gyp"))._brew_cleanup()
        self.assertEqual((status, reason), (StepStatus.SKIPPED, "node-gyp build in progress"))
        ran.assert_not_called()

    def test_package_caches_wait_for_a_build(self) -> None:
        engine = self.engine(OnlyMatching("xcodebuild"))
        with patch("vacuum.engine.shutil.which", return_value="/usr/bin/true"), patch("vacuum.engine.subprocess.run") as ran:
            for step in (engine._npm_cache, engine._pnpm_store, engine._yarn_cache):
                _freed, reason, status = step()
                self.assertEqual((status, reason), (StepStatus.SKIPPED, "skipped: xcodebuild is running"))
        ran.assert_not_called()

    def test_npx_folder_is_kept_while_a_process_runs_from_it(self) -> None:
        npx = self.home / ".npm" / "_npx" / "abc"
        npx.mkdir(parents=True)
        (npx / "server.js").write_text("x\n", encoding="utf-8")
        with patch("vacuum.engine.shutil.which", return_value="/usr/bin/true"), patch("vacuum.engine.subprocess.run"):
            _freed, reason, status = self.engine(OnlyMatching("_npx"))._npm_cache()
        self.assertEqual((status, reason), (StepStatus.RAN, "npm cache cleaned; npx folder kept"))
        self.assertTrue((npx / "server.js").exists())


class TestEngineDependencies(unittest.TestCase):
    """pressure_apps_deps: regenerable folders only, from idle lanes the doctor lists, merged or not."""

    def setUp(self) -> None:
        self.sb = Sandbox(self)
        self.cfg = self.sb.cfg()
        self.now = time.time() + 3 * 86400  # the lanes' files were written "three days ago"
        self.lane = self.sb.lane("claude-deps")
        for name in ("node_modules", ".next", "dist"):
            (self.lane / name).mkdir()
            (self.lane / name / "blob.js").write_text("x" * 2048, encoding="utf-8")
        (self.lane / ".env").write_text("LOCAL_ONLY=1\n", encoding="utf-8")

    def engine(self, rows, runner=None, **top) -> VacuumEngine:
        report = self.sb.report(rows, now=self.now, **top)
        return VacuumEngine(
            self.cfg,
            self.sb.home,
            runner=runner or Runner(),
            doctor_runner=doctor_returning(report),
            clock=lambda: self.now,
        )

    def row(self, **over) -> dict:
        over.setdefault("pr_state", "NONE")  # a lane need not be merged
        over.setdefault("safety", "NEEDS-REVIEW")
        over.setdefault("idle_days", 2.0)
        over.setdefault("lane_age_days", 2.0)
        return self.sb.row(self.lane, **over)

    def test_removes_only_regenerable_folders_from_an_unmerged_nested_lane(self) -> None:
        engine = self.engine([self.row()])
        freed, reason, status = engine._pressure_apps_deps(dry_run=False)
        self.assertEqual(status, StepStatus.RAN, reason)
        for name in ("node_modules", ".next", "dist"):
            self.assertFalse((self.lane / name).exists(), name)
        self.assertTrue((self.lane / ".env").exists())
        self.assertTrue((self.lane / "README.md").exists())
        self.assertGreater(freed, 0)
        removed = [a for a in engine.plan if a["action"] == "removed-folder"]
        self.assertEqual(len(removed), 3)
        for item in removed:
            self.assertTrue(item["command"].startswith("shutil.rmtree "))
            self.assertGreater(item["size_bytes"], 0)
        log = (Path(self.cfg["data_dir"]) / lanes.ACTION_LOG_NAME).read_text(encoding="utf-8")
        self.assertEqual(len(log.splitlines()), 3)

    def test_dry_run_changes_nothing_and_itemizes(self) -> None:
        engine = self.engine([self.row()])
        freed, reason, status = engine._pressure_apps_deps(dry_run=True)
        self.assertEqual((freed, status), (0, StepStatus.RAN))
        self.assertIn("would clear 3 folders", reason)
        for name in ("node_modules", ".next", "dist"):
            self.assertTrue((self.lane / name).exists(), name)
        self.assertEqual(sorted(a["action"] for a in engine.plan), ["would-remove-folder"] * 3)
        self.assertFalse((Path(self.cfg["data_dir"]) / lanes.ACTION_LOG_NAME).exists())

    def assert_untouched(self, engine, needle: str = "") -> None:
        _freed, reason, status = engine._pressure_apps_deps(dry_run=False)
        self.assertEqual(status, StepStatus.SKIPPED, reason)
        for name in ("node_modules", ".next", "dist"):
            self.assertTrue((self.lane / name).exists(), name)
        if not needle:
            return
        engine.plan.clear()
        engine._pressure_apps_deps(dry_run=True)
        refusals = [a for a in engine.plan if a["action"] == "refused" and a["path"] == str(self.lane)]
        self.assertTrue(any(needle in r["reason"] for r in refusals), (needle, refusals))

    def test_report_gates_protect_lanes(self) -> None:
        for over, needle in (
            ({"idle_days": 0.5}, "idle_days"),
            ({"lane_age_days": 0.5}, "lane_age_days"),
            ({"cwd_procs": [4242]}, "process is using"),
            ({"cwd_procs": None}, "process is using"),
            ({"janitor_keep": True}, "keep marker"),
            ({"dirty_tracked": 2}, "tracked tree"),
            ({"dirty_tracked": None}, "tracked tree"),
            ({"location_class": "FORBIDDEN_TMP"}, ""),  # not lane-like: ignored, never even listed
            ({"location_class": "UNSANCTIONED"}, ""),
            ({"location_class": "INTEGRATION_TREE"}, ""),
            ({"location_class": None}, ""),
            ({"kind": "FULL-CLONE"}, "not a linked worktree"),
            ({"read_errors": ["x"]}, "could not read"),
        ):
            engine = self.engine([self.row(**over)])
            self.assert_untouched(engine, needle)

    def test_lsof_not_ok_skips_the_whole_step(self) -> None:
        engine = self.engine([self.row()], lsof="unavailable")
        _freed, reason, status = engine._pressure_apps_deps(dry_run=False)
        self.assertEqual(status, StepStatus.SKIPPED)
        self.assertIn("lane doctor unusable", reason)
        self.assertTrue((self.lane / "node_modules").exists())

    def test_gh_failure_does_not_block_dependency_cleanup(self) -> None:
        engine = self.engine([self.row()], gh="failed")
        _freed, reason, status = engine._pressure_apps_deps(dry_run=False)
        self.assertEqual(status, StepStatus.RAN, reason)
        self.assertFalse((self.lane / "node_modules").exists())

    def test_live_checks_protect_lanes(self) -> None:
        (self.lane / "README.md").write_text("edited\n", encoding="utf-8")
        self.assert_untouched(self.engine([self.row()]), "tracked changes")

    def test_keep_marker_on_disk_protects_a_lane(self) -> None:
        (self.lane / ".janitor-keep").write_text("", encoding="utf-8")
        self.assert_untouched(self.engine([self.row()]), "keep marker")

    def test_keep_regex_protects_a_lane(self) -> None:
        self.cfg["keep_worktree_regex"] = re.escape(str(self.lane)) + "$"
        self.assert_untouched(self.engine([self.row()]), "keep list")

    def test_process_in_the_lane_protects_it(self) -> None:
        self.assert_untouched(self.engine([self.row()], runner=Runner(lsof_paths=["/", str(self.lane)])), "working directory")

    def test_pgrep_error_skips_the_lane(self) -> None:
        self.assert_untouched(self.engine([self.row()], runner=Runner(pgrep_rc=2)), "treated as busy")

    def test_recently_changed_files_protect_a_lane(self) -> None:
        engine = VacuumEngine(
            self.cfg,
            self.sb.home,
            runner=Runner(),
            doctor_runner=doctor_returning(self.sb.report([self.row()], now=time.time())),
            clock=time.time,  # the clock says "now", and the files were just written
        )
        self.assert_untouched(engine, "files changed within")

    def test_tracked_dist_folder_is_never_deleted(self) -> None:
        (self.lane / "dist").rename(self.lane / "dist-old")
        (self.lane / "dist").mkdir()
        (self.lane / "dist" / "tracked.txt").write_text("keep me\n", encoding="utf-8")
        self.sb.git(self.lane, "add", "-f", "dist/tracked.txt")
        self.sb.git(self.lane, "commit", "-q", "-m", "track dist")
        engine = self.engine([self.row(head_sha=self.sb.head(self.lane))])
        engine._pressure_apps_deps(dry_run=False)
        self.assertTrue((self.lane / "dist" / "tracked.txt").exists())
        self.assertFalse((self.lane / "node_modules").exists())

    def test_untracked_unignored_dist_is_not_deleted_but_node_modules_is(self) -> None:
        sb = self.sb
        sb.exclude.write_text(".env\ndata/\nnode_modules/\n", encoding="utf-8")  # dist is no longer ignored
        for name in ("node_modules", "dist"):
            (self.lane / name).mkdir(exist_ok=True)
            (self.lane / name / "f.js").write_text("x\n", encoding="utf-8")
        self.engine([self.row()])._pressure_apps_deps(dry_run=False)
        self.assertFalse((self.lane / "node_modules").exists())
        self.assertTrue((self.lane / "dist" / "f.js").exists())

    def test_lane_with_nothing_to_clean_is_not_listed_as_refused(self) -> None:
        for name in ("node_modules", ".next", "dist"):
            shutil.rmtree(self.lane / name)
        engine = self.engine([self.row()])
        _freed, reason, status = engine._pressure_apps_deps(dry_run=True)
        self.assertEqual(status, StepStatus.SKIPPED)
        self.assertEqual([a for a in engine.plan if a["action"] == "refused"], [])
        self.assertIn("0 lanes refused", reason)

    def test_symlinked_folder_is_not_followed(self) -> None:
        elsewhere = self.sb.root / "precious"
        elsewhere.mkdir()
        (elsewhere / "keep.txt").write_text("x\n", encoding="utf-8")
        shutil.rmtree(self.lane / "node_modules")
        (self.lane / "node_modules").symlink_to(elsewhere)
        engine = self.engine([self.row()])
        engine._pressure_apps_deps(dry_run=False)
        self.assertTrue((elsewhere / "keep.txt").exists())

    def test_nested_regenerable_folders_in_a_monorepo_are_found(self) -> None:
        pkg = self.lane / "packages" / "web"
        pkg.mkdir(parents=True)
        (pkg / "package.json").write_text("{}\n", encoding="utf-8")
        self.sb.git(self.lane, "add", "packages/web/package.json")
        self.sb.git(self.lane, "commit", "-q", "-m", "add package")
        (pkg / "node_modules").mkdir()
        (pkg / "node_modules" / "x.js").write_text("x\n", encoding="utf-8")
        engine = self.engine([self.row()])
        engine._pressure_apps_deps(dry_run=False)
        self.assertFalse((pkg / "node_modules").exists())


class TestEngineRun(unittest.TestCase):
    """The engine wiring: planning once per run, hard-load skip, platform skip, dry run."""

    def setUp(self) -> None:
        self.sb = Sandbox(self)
        self.cfg = self.sb.cfg()
        only_step(self.cfg, "janitor_worktree_retire")
        self.lane = self.sb.lane("claude-run")
        self.calls = 0

        report = self.sb.report([self.sb.row(self.lane)])
        base = doctor_returning(report)

        def counting(argv, timeout):
            self.calls += 1
            return base(argv, timeout)

        self.doctor = counting

    def run_engine(self, trigger=TriggerKind.JANITOR, dry_run=False, mode="normal", platform="darwin", runner=None, pressure=False):
        engine = VacuumEngine(self.cfg, self.sb.home, runner=runner or Runner(), doctor_runner=self.doctor)
        sample = {"disk_free_gb": 100.0, "swap_used_pct": 0.0, "swap_used_gb": 0.0, "load1": 0.0}
        with patch("vacuum.engine.sample_mac", return_value=sample), patch(
            "vacuum.engine.janitor_pressure_mode", return_value=mode
        ), patch.object(sys, "platform", platform):
            record = engine.run(trigger, pressure=pressure, dry_run=dry_run)
        return engine, record

    def test_dry_run_plans_and_removes_nothing(self) -> None:
        engine, record = self.run_engine(dry_run=True)
        step = next(s for s in record.steps if s.step_id == "janitor_worktree_retire")
        self.assertEqual(step.status, StepStatus.RAN, step.reason)
        self.assertTrue(self.lane.exists())
        plan = [a for a in engine.plan if a["action"] == "would-retire"]
        self.assertEqual([a["path"] for a in plan], [str(self.lane)])
        self.assertIn("worktree remove", plan[0]["command"])
        self.assertGreater(plan[0]["size_bytes"], 0)
        self.assertEqual(step.bytes_freed, 0)
        json.dumps(engine.plan)  # JSON-ready

    def test_real_run_retires_and_reports_bytes_freed(self) -> None:
        _engine, record = self.run_engine()
        step = next(s for s in record.steps if s.step_id == "janitor_worktree_retire")
        self.assertEqual(step.status, StepStatus.RAN, step.reason)
        self.assertFalse(self.lane.exists())
        self.assertGreater(step.bytes_freed, 0)
        self.assertIn("worktree remove", step.reason)

    def test_unusable_doctor_skips_the_step_with_the_reason(self) -> None:
        self.doctor = doctor_returning({}, rc=2)
        _engine, record = self.run_engine()
        step = next(s for s in record.steps if s.step_id == "janitor_worktree_retire")
        self.assertEqual(step.status, StepStatus.SKIPPED)
        self.assertIn("lane doctor unusable", step.reason)
        self.assertTrue(self.lane.exists())

    def test_extreme_load_skips_lane_steps_without_calling_the_doctor(self) -> None:
        _engine, record = self.run_engine(mode="hard")
        step = next(s for s in record.steps if s.step_id == "janitor_worktree_retire")
        self.assertEqual(step.status, StepStatus.SKIPPED)
        self.assertEqual(self.calls, 0)
        self.assertTrue(self.lane.exists())

    def test_one_doctor_run_serves_both_lane_steps(self) -> None:
        only_step(self.cfg, "janitor_worktree_retire")
        self.cfg["steps"]["pressure_apps_deps"] = {"enabled": True}
        self.run_engine(trigger=TriggerKind.PRESSURE, pressure=True, dry_run=True)
        self.assertEqual(self.calls, 1)

    def test_disabled_retirement_never_runs_the_doctor(self) -> None:
        self.cfg["janitor"]["reap_worktrees"] = False
        engine, record = self.run_engine()
        step = next(s for s in record.steps if s.step_id == "janitor_worktree_retire")
        self.assertEqual(step.status, StepStatus.SKIPPED)
        self.assertEqual(step.reason, "worktree retirement disabled")
        self.assertEqual(self.calls, 0)
        self.assertTrue(self.lane.exists())

    def test_invalid_keep_regex_fails_the_step_before_the_doctor_runs(self) -> None:
        self.cfg["keep_worktree_regex"] = "[invalid"
        _engine, record = self.run_engine()
        step = next(s for s in record.steps if s.step_id == "janitor_worktree_retire")
        self.assertEqual(step.status, StepStatus.FAILED)
        self.assertEqual(self.calls, 0)

    def test_run_watch_tick_passes_dry_run_down(self) -> None:
        self.cfg["steps"]["pressure_apps_deps"] = {"enabled": True}
        engine = VacuumEngine(self.cfg, self.sb.home, runner=Runner(), doctor_runner=self.doctor)
        sample = {"disk_free_gb": 1.0, "swap_used_pct": 0.0, "swap_used_gb": 0.0, "load1": 0.0}
        with patch("vacuum.engine.sample_mac", return_value=sample), patch(
            "vacuum.engine.janitor_pressure_mode", return_value="normal"
        ), patch.object(sys, "platform", "darwin"):
            _record, hits, cleaned = engine.run_watch_tick({}, None, dry_run=True)
        self.assertTrue(hits)
        self.assertTrue(cleaned)
        self.assertTrue(self.lane.exists())
        self.assertTrue(all(a["action"] != "retired" for a in engine.plan))


# --------------------------------------------------------------------------- CLI dry run


class TestCliDryRun(unittest.TestCase):
    """robotic-vacuum.py --dry-run in a subprocess with a fake HOME and a fake doctor: pure JSON, nothing written."""

    def setUp(self) -> None:
        self.sb = Sandbox(self)
        self.lane = self.sb.lane("claude-cli")
        self.report_path = self.sb.root / "report.json"
        self.report_path.write_text(json.dumps(self.sb.report([self.sb.row(self.lane)])), encoding="utf-8")
        script = self.sb.root / "fake-doctor.py"
        script.write_text(
            textwrap.dedent(
                """
                import datetime, json, sys
                data = json.load(open(sys.argv[1]))
                data["generated_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
                print(json.dumps(data))
                """
            ),
            encoding="utf-8",
        )
        self.data_dir = self.sb.home / "Library" / "Application Support" / "HogHunter" / "RoboticVacuum"
        self.data_dir.mkdir(parents=True)
        cfg = self.sb.cfg()
        only_step(cfg, "janitor_worktree_retire")
        (self.data_dir / "config.json").write_text(
            json.dumps(
                {
                    "steps": cfg["steps"],
                    "housekeeper_lock": str(self.sb.root / "lock"),
                    "janitor": {"max_swap_pct_hard": 101},  # swap above 98 percent would also read as "hard" load
                }
            ),
            encoding="utf-8",
        )
        self.env = dict(
            os.environ,
            HOME=str(self.sb.home),
            PYTHONDONTWRITEBYTECODE="1",
            JANITOR_MAX_LOAD="1000000",  # a busy host must not turn the retire step into a "hard load" skip
        )
        self.env[lanes.DOCTOR_ENV_VAR] = f"{sys.executable} {script} {self.report_path}"

    def run_cli(self, *args: str):
        return subprocess.run(
            [sys.executable, str(REPO / "scripts" / "robotic-vacuum.py"), *args],
            capture_output=True,
            text=True,
            env=self.env,
            timeout=300,
        )

    def test_run_now_dry_run_prints_json_and_writes_nothing(self) -> None:
        res = self.run_cli("--run-now", "janitor", "--dry-run")
        self.assertEqual(res.returncode, 0, res.stderr)
        out = json.loads(res.stdout)
        self.assertTrue(out["dry_run"])
        self.assertEqual(len(out["records"]), 1)
        self.assertTrue(self.lane.exists())
        for name in ("history.json", "scheduler-state.json", "status.json", "alert-state.json", lanes.ACTION_LOG_NAME):
            self.assertFalse((self.data_dir / name).exists(), name)
        if sys.platform == "darwin":
            self.assertEqual([a["action"] for a in out["plan"] if a["step_id"] == "janitor_worktree_retire"][:1], ["would-retire"])

    def test_tick_dry_run_prints_json_and_writes_nothing(self) -> None:
        res = self.run_cli("--tick", "scheduler", "--dry-run")
        self.assertEqual(res.returncode, 0, res.stderr)
        out = json.loads(res.stdout)
        self.assertTrue(out["dry_run"])
        self.assertEqual(set(out["due"]), {"watch", "janitor", "full"})
        self.assertTrue(self.lane.exists())
        for name in ("history.json", "scheduler-state.json", "status.json", "alert-state.json"):
            self.assertFalse((self.data_dir / name).exists(), name)

    def test_bare_dry_run_means_the_whole_tick(self) -> None:
        res = self.run_cli("--dry-run")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("due", json.loads(res.stdout))

    def test_dry_run_does_not_combine_with_other_commands(self) -> None:
        for extra in (["--status"], ["--check-alerts"], ["--set-step", "npm_cache", "off"]):
            res = self.run_cli("--dry-run", *extra)
            self.assertEqual(res.returncode, 2, extra)
            self.assertEqual(res.stdout, "")
        self.assertFalse((self.data_dir / "history.json").exists())

    def test_dry_run_never_notifies_and_never_writes_alert_or_history_state(self) -> None:
        """The leak this guards: a dry run on a Mac once posted 'Robotic Vacuum is not loaded' for real.  The
        script runs in this process with every way to a banner patched, and an unloaded Vacuum, which is the
        state that makes evaluate_alerts want to notify."""
        cli = load_cli_module()
        runs = (["--dry-run"], ["--tick", "scheduler", "--dry-run"], ["--run-now", "janitor", "--dry-run"])
        for argv in runs:
            with contextlib.ExitStack() as stack:
                stack.enter_context(patch.dict(os.environ, self.env))
                notify = stack.enter_context(patch("vacuum.alerts.notify_macos"))
                cli_notify = stack.enter_context(patch.object(cli, "notify_macos"))
                evaluate = stack.enter_context(patch("vacuum.alerts.evaluate_alerts"))
                cli_evaluate = stack.enter_context(patch.object(cli, "evaluate_alerts"))
                stack.enter_context(patch("vacuum.alerts.launchd_loaded", return_value=False))
                out = stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                self.assertEqual(cli.main(argv), 0, argv)
            self.assertTrue(json.loads(out.getvalue())["dry_run"], argv)
            for mock in (notify, cli_notify, evaluate, cli_evaluate):
                mock.assert_not_called()
            for name in ("alert-state.json", "history.json"):
                self.assertFalse((self.data_dir / name).exists(), (argv, name))

    def test_dry_run_switches_notifications_off_for_anything_it_starts(self) -> None:
        cli = load_cli_module()
        with patch.dict(os.environ, self.env):
            os.environ.pop(alerts.NO_NOTIFY_ENV, None)
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(cli.main(["--dry-run", "--run-now", "janitor"]), 0)
            self.assertTrue(alerts.notifications_suppressed())


def load_cli_module():
    """scripts/robotic-vacuum.py as a module, so main() runs in this process where notify_macos can be patched.
    It binds notify_macos at import, which is the leak guard installed above."""
    spec = importlib.util.spec_from_file_location("robotic_vacuum_cli", REPO / "scripts" / "robotic-vacuum.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# --------------------------------------------------------------------------- no identity, no real HOME


class TestGitIdentityIndependence(unittest.TestCase):
    """The Ubuntu runner has no global git identity.  user.useConfigOnly makes this machine behave the same
    way (git then refuses to guess a name and address), whatever the Mac's own ~/.gitconfig holds."""

    def bare_machine(self) -> dict:
        home = tempfile.mkdtemp(prefix="hhbare-")
        self.addCleanup(shutil.rmtree, home, True)
        env = {k: v for k, v in os.environ.items() if not k.startswith(("GIT_AUTHOR", "GIT_COMMITTER", "GIT_CONFIG"))}
        env.update(
            HOME=home,
            GIT_CONFIG_NOSYSTEM="1",
            GIT_CONFIG_COUNT="1",
            GIT_CONFIG_KEY_0="user.useConfigOnly",
            GIT_CONFIG_VALUE_0="true",
        )
        return env

    def start_bare_machine(self) -> None:
        patcher = patch.dict(os.environ, self.bare_machine(), clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)  # before anything that starts a later patcher, so it unwinds last
        probe = Path(os.environ["HOME"]) / "probe"
        probe.mkdir()
        subprocess.run(["git", "-C", str(probe), "init", "-q"], check=True, capture_output=True)
        (probe / "f").write_text("x\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(probe), "add", "f"], check=True, capture_output=True)
        res = subprocess.run(["git", "-C", str(probe), "commit", "-q", "-m", "x"], capture_output=True, text=True)
        if res.returncode == 0:
            self.skipTest("this git guesses an identity even with user.useConfigOnly")

    def test_nested_clone_commits_without_any_machine_identity(self) -> None:
        self.start_bare_machine()
        root = Path(os.environ["HOME"])
        clone = nested_clone(root / "clone")
        log = subprocess.run(["git", "-C", str(clone), "log", "--format=%an"], capture_output=True, text=True, env=dict(os.environ, **git_identity_env()))
        self.assertEqual(log.stdout.strip(), "Vacuum Test")

    def test_sandbox_commits_without_any_machine_identity(self) -> None:
        self.start_bare_machine()
        sb = Sandbox(self)
        lane = sb.lane("claude-bare")
        sb.commit(lane)
        self.assertEqual(sb.git(lane, "log", "-1", "--format=%an"), "Vacuum Test")

    def test_the_run_itself_has_no_real_home_or_global_config(self) -> None:
        self.assertEqual(os.environ["HOME"], FAKE_HOME)
        self.assertEqual(Path.home(), Path(FAKE_HOME))
        self.assertEqual(os.environ["GIT_CONFIG_GLOBAL"], os.devnull)
        self.assertEqual(os.environ["GIT_CONFIG_NOSYSTEM"], "1")
        self.assertTrue(alerts.notifications_suppressed())
        for name in AMBIENT_ENV:
            self.assertNotIn(name, os.environ, name)


# --------------------------------------------------------------------------- keep regex from fleet-apps.json


class TestKeepRegex(unittest.TestCase):
    def home(self) -> Path:
        td = tempfile.mkdtemp(prefix="hhkeep-")
        self.addCleanup(shutil.rmtree, td, True)
        return Path(td)

    def registry(self, home: Path, text: str) -> None:
        path = home / "apps" / "lane-tools"
        path.mkdir(parents=True)
        (path / "fleet-apps.json").write_text(text, encoding="utf-8")

    def seats(self, home: Path) -> set:
        pattern = default_keep_worktree_regex(home, env={})
        inner = re.search(r"-\(([^)]*)\)\)\$$", pattern)
        self.assertIsNotNone(inner, pattern)
        return set(inner.group(1).split("|"))

    FULL = {"claude", "codex", "live", "antigravity", "cursor", "monet", "grok", "grok-build", "deepseek", "minimax", "mm"}

    def test_unreachable_file_keeps_the_whole_list(self) -> None:
        self.assertEqual(self.seats(self.home()), self.FULL)

    def test_retired_seats_leave_the_list_and_nothing_is_added(self) -> None:
        home = self.home()
        self.registry(
            home,
            json.dumps(
                {
                    "seats": [
                        {"tag": "CLAUDE", "worktreeSuffix": "claude"},
                        {"tag": "MONET", "worktreeSuffix": "monet", "retired": True},
                        {"tag": "DSH", "worktreeSuffix": "deepseek", "retired": True},
                        {"tag": "CLUTCH", "worktreeSuffix": "clutch"},
                        {"tag": "HARNESS", "worktreeSuffix": "harness", "retired": True},
                    ]
                }
            ),
        )
        seats = self.seats(home)
        self.assertEqual(seats, self.FULL - {"monet", "deepseek"})
        self.assertNotIn("clutch", seats)

    def test_a_suffix_shared_with_an_active_seat_stays(self) -> None:
        home = self.home()
        self.registry(
            home,
            json.dumps(
                {
                    "seats": [
                        {"tag": "A", "worktreeSuffix": "cursor", "retired": True},
                        {"tag": "B", "worktreeSuffix": "cursor"},
                    ]
                }
            ),
        )
        self.assertEqual(self.seats(home), self.FULL)

    def test_bad_files_change_nothing(self) -> None:
        for text in ("not json", "[]", '{"seats": 5}', '{"seats": [5, {"worktreeSuffix": 3}]}', ""):
            home = self.home()
            self.registry(home, text)
            self.assertEqual(self.seats(home), self.FULL, text)

    def test_env_path_is_used(self) -> None:
        home = self.home()
        elsewhere = home / "elsewhere.json"
        elsewhere.write_text(json.dumps({"seats": [{"worktreeSuffix": "mm", "retired": True}]}), encoding="utf-8")
        pattern = default_keep_worktree_regex(home, env={"FLEET_APPS_JSON": str(elsewhere)})
        self.assertNotIn("|mm)", pattern)


if __name__ == "__main__":
    unittest.main()
