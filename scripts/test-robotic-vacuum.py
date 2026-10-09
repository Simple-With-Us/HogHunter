#!/usr/bin/env python3
"""Linux-runnable tests for Robotic Vacuum scheduler, alerts, and janitor helpers.

The lane doctor tests live in test-vacuum-lanes.py; load_tests at the bottom pulls them in, so the one CI
command (python3 scripts/test-robotic-vacuum.py) runs both files."""
from __future__ import annotations

import atexit
import os
import shutil
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

# Hermetic process, the same block as scripts/test-vacuum-lanes.py (either file can be the one that is run):
# HOME is an empty folder, git has a fixed identity and no global config, and no real banner can be posted.
# CI's Ubuntu runner has no git identity and no ~/.gitconfig, so nothing here may lean on the machine.
NO_NOTIFY = "HOGHUNTER_NO_NOTIFY"
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


def isolate_process_environment() -> str:
    home = tempfile.mkdtemp(prefix="hhtest-home-")
    atexit.register(shutil.rmtree, home, True)
    for name in AMBIENT_ENV:
        os.environ.pop(name, None)
    os.environ.update(
        GIT_CONFIG_GLOBAL=os.devnull,
        GIT_CONFIG_NOSYSTEM="1",
        GIT_AUTHOR_NAME="Vacuum Test",
        GIT_AUTHOR_EMAIL="vacuum-test@example.invalid",
        GIT_COMMITTER_NAME="Vacuum Test",
        GIT_COMMITTER_EMAIL="vacuum-test@example.invalid",
        GIT_TERMINAL_PROMPT="0",
        HOME=home,
    )
    os.environ[NO_NOTIFY] = "1"
    return home


FAKE_HOME = isolate_process_environment()

from vacuum import alerts  # noqa: E402
from vacuum.alerts import evaluate_alerts  # noqa: E402
from vacuum.config import load_config, step_enabled, steps_for_trigger  # noqa: E402
from vacuum import janitor  # noqa: E402
from vacuum.models import RunRecord, StepResult, StepStatus, TriggerKind  # noqa: E402
from vacuum.pressure import evaluate_hits, janitor_pressure_mode, sample_mac  # noqa: E402
from vacuum.scheduler import build_status, should_run  # noqa: E402
from vacuum.store import VacuumStore  # noqa: E402


def install_notify_leak_guard() -> None:
    """Make notify_macos raise unless a test patches it.  The environment switch already stops a real banner;
    this makes the call itself a failure, so a test that reaches a notification by accident cannot pass."""
    real = getattr(alerts.notify_macos, "real", alerts.notify_macos)

    def guard(title, body):
        raise AssertionError(f"notify_macos({title!r}, ...) was called by a test that did not expect a notification")

    guard.real = real  # type: ignore[attr-defined]
    alerts.notify_macos = guard


def real_notify_macos():
    """The real function, for the tests of notify_macos itself."""
    return getattr(alerts.notify_macos, "real", alerts.notify_macos)


install_notify_leak_guard()


class TestPressure(unittest.TestCase):
    def test_sample_non_mac(self):
        s = sample_mac()
        self.assertIn("disk_free_gb", s)

    def test_disk_hit(self):
        s = {"disk_free_gb": 10, "swap_used_pct": 0, "swap_used_gb": 0, "load1": 0}
        hits = evaluate_hits(s, None, {"disk_free_crit_gb": 15, "disk_free_warn_gb": 25})
        self.assertTrue(any(h["metric"] == "disk_free_gb" for h in hits))

    def test_janitor_modes(self):
        self.assertEqual(janitor_pressure_mode({"load1": 300, "swap_used_pct": 50}, {}), "hard")
        self.assertEqual(janitor_pressure_mode({"load1": 160, "swap_used_pct": 50}, {}), "lean")
        self.assertEqual(janitor_pressure_mode({"load1": 10, "swap_used_pct": 10}, {}), "normal")


class TestScheduler(unittest.TestCase):
    def test_should_run(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            data = home / "Library/Application Support/HogHunter/RoboticVacuum"
            data.mkdir(parents=True)
            cfg = load_config(home=home)
            cfg["data_dir"] = str(data)
            store = VacuumStore(cfg, home=home)
            self.assertTrue(should_run(store, cfg, "watch", now=1000))
            store.touch_scheduler("last_watch", 100)
            self.assertTrue(should_run(store, cfg, "watch", now=1000))


class TestAlerts(unittest.TestCase):
    def test_overdue_alert(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            data = home / "rv"
            data.mkdir(parents=True)
            cfg = load_config(home=home)
            cfg["data_dir"] = str(data)
            cfg["intervals_seconds"] = {"watch": 300, "janitor": 1800, "full": 14400}
            store = VacuumStore(cfg, home=home)
            old = RunRecord("x", TriggerKind.WATCH, started_at=time.time() - 99999, ended_at=time.time() - 99999)
            store.append_run(old)
            with patch("vacuum.alerts.launchd_loaded", return_value=True):  # the host's launchd is not under test
                decisions = evaluate_alerts(store, cfg, now=time.time())
            kinds = [d.kind for d in decisions if d.should_notify]
            self.assertIn("overdue_watch", kinds)


class _TempHomeCase(unittest.TestCase):
    """A store in a throwaway home, with `cfg` and `store` ready."""

    def setUp(self) -> None:
        self.home = Path(tempfile.mkdtemp(prefix="hhalerts-"))
        self.addCleanup(shutil.rmtree, str(self.home), True)
        data = self.home / "rv"
        data.mkdir()
        self.cfg = load_config(home=self.home)
        self.cfg["data_dir"] = str(data)
        self.store = VacuumStore(self.cfg, home=self.home)

    def add_plist(self, home: Path | None = None) -> Path:
        path = alerts.plist_path(home or self.home)
        path.parent.mkdir(parents=True)
        path.write_text("<plist/>\n", encoding="utf-8")
        return path

    def add_real_tick(self, now: float) -> None:
        self.store.append_run(RunRecord("tick", TriggerKind.WATCH, started_at=now - 10, ended_at=now - 5))


NOW = 1_800_000_000.0


class TestLaunchdAlertOnlyAfterInstall(_TempHomeCase):
    """The not-loaded alert is for a Vacuum that was installed and then unloaded.  One that was never installed
    has nothing to be unloaded, and nagging about it is what posted a real banner at 1:30 am."""

    def decisions(self, loaded: bool = False, **kwargs):
        """Evaluate as a Mac would, with launchctl scripted.  Returns (notifying kinds, launchd probe)."""
        with patch.object(alerts.sys, "platform", "darwin"), patch(
            "vacuum.alerts.launchd_loaded", return_value=loaded
        ) as probe:
            found = evaluate_alerts(self.store, self.cfg, now=NOW, **kwargs)
        return [d.kind for d in found if d.should_notify], probe

    def test_never_installed_does_not_alert(self) -> None:
        kinds, probe = self.decisions()
        self.assertNotIn("launchd_missing", kinds)
        probe.assert_not_called()  # no launchctl process for a Vacuum nobody installed
        self.assertFalse(self.store.load_alert_state()["launchd_missing"]["active"])

    def test_plist_present_but_not_loaded_alerts(self) -> None:
        self.add_plist()
        kinds, _probe = self.decisions()
        self.assertIn("launchd_missing", kinds)

    def test_a_real_tick_in_history_and_not_loaded_alerts(self) -> None:
        self.add_real_tick(NOW)
        kinds, _probe = self.decisions()
        self.assertIn("launchd_missing", kinds)

    def test_config_flag_true_alerts_even_when_never_installed(self) -> None:
        self.cfg["alerts"] = {"alert_when_not_installed": True}
        kinds, _probe = self.decisions()
        self.assertIn("launchd_missing", kinds)

    def test_config_flag_defaults_to_off_and_only_true_turns_it_on(self) -> None:
        for block in (None, {}, {"alert_when_not_installed": False}, {"alert_when_not_installed": "true"}, "yes"):
            if block is None:
                self.cfg.pop("alerts", None)
            else:
                self.cfg["alerts"] = block
            kinds, _probe = self.decisions()
            self.assertNotIn("launchd_missing", kinds, block)

    def test_a_dry_run_record_does_not_count_as_installed(self) -> None:
        self.store.history_path.write_text('[{"run_id": "x", "trigger": "watch", "dry_run": true}]', encoding="utf-8")
        kinds, _probe = self.decisions()
        self.assertNotIn("launchd_missing", kinds)

    def test_the_home_can_be_injected(self) -> None:
        elsewhere = Path(tempfile.mkdtemp(prefix="hhelsewhere-"))
        self.addCleanup(shutil.rmtree, str(elsewhere), True)
        self.add_plist(elsewhere)
        kinds, _probe = self.decisions()
        self.assertNotIn("launchd_missing", kinds)  # the store's own home has no plist
        kinds, _probe = self.decisions(home=elsewhere)
        self.assertIn("launchd_missing", kinds)

    def test_installed_and_loaded_is_quiet_and_recovery_still_reports(self) -> None:
        self.add_plist()
        kinds, _probe = self.decisions(loaded=True)
        self.assertNotIn("launchd_missing", kinds)
        kinds, _probe = self.decisions(loaded=False)
        self.assertIn("launchd_missing", kinds)
        with patch.object(alerts.sys, "platform", "darwin"), patch("vacuum.alerts.launchd_loaded", return_value=True):
            found = evaluate_alerts(self.store, self.cfg, now=NOW + 60)
        self.assertEqual([(d.kind, d.recovered) for d in found if d.should_notify], [("launchd_missing", True)])

    def test_an_alert_already_sent_is_not_repeated_within_the_hour(self) -> None:
        self.add_plist()
        self.assertIn("launchd_missing", self.decisions()[0])
        self.assertNotIn("launchd_missing", self.decisions()[0])

    def test_a_stale_active_flag_clears_silently_when_nothing_is_installed(self) -> None:
        """An earlier alert (the leaked one) left the flag set.  With nothing installed there is nothing to
        recover, so there must be no 'loaded again' banner either."""
        self.store.save_alert_state({"launchd_missing": {"active": True, "last_sent": NOW - 7200}})
        found_kinds, _probe = self.decisions()
        self.assertEqual(found_kinds, [])
        self.assertFalse(self.store.load_alert_state()["launchd_missing"]["active"])

    def test_non_mac_hosts_never_raise_the_alert(self) -> None:
        self.add_plist()
        with patch.object(alerts.sys, "platform", "linux"):
            found = evaluate_alerts(self.store, self.cfg, now=NOW)
        self.assertNotIn("launchd_missing", [d.kind for d in found if d.should_notify])


class TestNotifySuppression(unittest.TestCase):
    """HOGHUNTER_NO_NOTIFY.  The real function runs here on a pretend Mac; osascript is a patched
    subprocess.run, so nothing can reach the screen."""

    def post(self, value: str | None) -> Mock:
        with patch.dict(os.environ):
            if value is None:
                os.environ.pop(alerts.NO_NOTIFY_ENV, None)
            else:
                os.environ[alerts.NO_NOTIFY_ENV] = value
            with patch.object(alerts.sys, "platform", "darwin"), patch("vacuum.alerts.subprocess.run") as run:
                real_notify_macos()("Hog Hunter", 'Say "hi"')
        return run

    def test_truthy_values_stop_osascript(self) -> None:
        for value in ("1", "true", "TRUE", "yes", "on", " 1 ", "anything"):
            self.post(value).assert_not_called()

    def test_unset_empty_and_falsy_values_still_post(self) -> None:
        """The control: without it the tests above would also pass if the guard blocked everything."""
        for value in (None, "", "0", "false", "False", "no", "off"):
            run = self.post(value)
            self.assertEqual(run.call_count, 1, value)
            argv = run.call_args[0][0]
            self.assertEqual(argv[:2], ["osascript", "-e"], value)
            self.assertIn('display notification "Say \\"hi\\""', argv[2], value)

    def test_the_suite_runs_with_the_switch_on_and_the_guard_in_place(self) -> None:
        self.assertTrue(alerts.notifications_suppressed())
        with self.assertRaises(AssertionError):
            alerts.notify_macos("Hog Hunter", "not expected")


class TestAlertDecisionStillNotifies(_TempHomeCase):
    def test_a_real_decision_reaches_notify_macos_when_the_switch_is_off(self) -> None:
        from vacuum.scheduler import run_scheduler_tick

        self.add_plist()
        now = time.time()
        self.add_real_tick(now)
        self.cfg["intervals_seconds"] = {"watch": 99999, "janitor": 99999, "full": 99999}
        self.store.touch_scheduler("last_watch", now)
        self.store.touch_scheduler("last_janitor", now)
        self.store.touch_scheduler("last_full", now)
        with patch.dict(os.environ):
            os.environ.pop(alerts.NO_NOTIFY_ENV, None)
            with patch.object(alerts.sys, "platform", "darwin"), patch(
                "vacuum.alerts.launchd_loaded", return_value=False
            ), patch("vacuum.alerts.notify_macos") as notify:
                result = run_scheduler_tick(self.store, now=now)
        notify.assert_called_once()
        title, body = notify.call_args[0]
        self.assertEqual(title, "Hog Hunter")
        self.assertIn("not loaded in the background", body)
        self.assertEqual([a["kind"] for a in result["alerts"]], ["launchd_missing"])


class TestLegacyHeuristicsGone(unittest.TestCase):
    """Candidates come only from the lane doctor.  The old branch-name, plain git status, and mtime heuristics
    were weaker than the doctor contract (see test-vacuum-lanes.py), so they must not come back by accident."""

    def test_old_helpers_are_removed(self):
        for name in ("pr_merged", "retire_candidate", "_maybe_retire", "wt_blocking_dirt", "worktree_idle_hours", "github_repo"):
            self.assertFalse(hasattr(janitor, name), name)

    def test_planner_takes_no_gh_runner_and_uses_the_doctor(self):
        import inspect

        params = list(inspect.signature(janitor.plan_retire_worktrees).parameters)
        self.assertEqual(params[:3], ["cfg", "home", "runner"])
        self.assertNotIn("gh", params)


class TestSteps(unittest.TestCase):
    def test_catalog_steps_respect_toggle(self):
        cfg = load_config()
        cfg["steps"]["npm_cache"] = {"enabled": False}
        self.assertFalse(step_enabled(cfg, "npm_cache"))
        ids = steps_for_trigger(cfg, "full")
        self.assertNotIn("npm_cache", ids)

    def test_grok_sessions_on_pressure_trigger(self):
        cfg = load_config()
        ids = steps_for_trigger(cfg, "pressure", pressure=True)
        self.assertIn("grok_sessions", ids)


class TestLockSkip(unittest.TestCase):
    def test_run_skipped_for_lock(self):
        from vacuum.scheduler import run_skipped_for_lock

        record = RunRecord("x", TriggerKind.JANITOR, started_at=time.time())
        record.steps.append(
            StepResult("housekeeper_lock", "Housekeeper lock", StepStatus.SKIPPED, reason="peer holds housekeeper lock")
        )
        record.finish(0, summary="skipped; peer holds lock")
        self.assertTrue(run_skipped_for_lock(record))

    def test_scheduler_does_not_advance_on_lock_skip(self):
        from unittest.mock import patch

        from vacuum.scheduler import run_scheduler_tick

        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            data = home / "rv"
            data.mkdir(parents=True)
            cfg = load_config(home=home)
            cfg["data_dir"] = str(data)
            cfg["intervals_seconds"] = {"watch": 1, "janitor": 99999, "full": 99999}
            store = VacuumStore(cfg, home=home)
            now = time.time()
            store.touch_scheduler("last_janitor", now)
            store.touch_scheduler("last_full", now)
            record = RunRecord("x", TriggerKind.WATCH, started_at=now)
            record.steps.append(
                StepResult("housekeeper_lock", "Housekeeper lock", StepStatus.SKIPPED, reason="held")
            )
            record.finish(0, summary="watch skipped; lock held")

            # The tick appends a real record, so the Vacuum now counts as installed: say it is loaded, and
            # expect no banner at all.
            with patch("vacuum.scheduler.VacuumEngine") as engine_cls, patch(
                "vacuum.alerts.launchd_loaded", return_value=True
            ), patch("vacuum.alerts.notify_macos") as notify:
                engine = engine_cls.return_value
                engine.run_watch_tick.return_value = (record, [], False)
                run_scheduler_tick(store, now=now)
            notify.assert_not_called()
            state = store.scheduler_state()
            self.assertNotIn("last_watch", state)


    def test_invalid_keep_regex_fails_janitor_step_not_tick(self):
        from unittest.mock import patch

        from vacuum.engine import VacuumEngine
        from vacuum.models import StepStatus, TriggerKind

        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            cfg = load_config(home=home)
            cfg["keep_worktree_regex"] = "[invalid"
            cfg["repos"] = []
            cfg["housekeeper_lock"] = str(home / ".housekeeper.lock")
            cfg.setdefault("janitor", {})["reap_worktrees"] = True
            for step_id in steps_for_trigger(cfg, "janitor"):
                if step_id != "janitor_worktree_retire":
                    cfg.setdefault("steps", {})[step_id] = {"enabled": False}
            cfg["steps"]["janitor_worktree_retire"] = {"enabled": True}
            engine = VacuumEngine(cfg, home=home)
            with patch(
                "vacuum.engine.sample_mac",
                return_value={"disk_free_gb": 100.0, "swap_used_pct": 0.0, "swap_used_gb": 0.0, "load1": 0.0},
            ), patch("vacuum.engine.janitor_pressure_mode", return_value="normal"):
                record = engine.run(TriggerKind.JANITOR)
        step = next(s for s in record.steps if s.step_id == "janitor_worktree_retire")
        self.assertEqual(step.status, StepStatus.FAILED)
        self.assertTrue(all(s.step_id == "janitor_worktree_retire" for s in record.steps))


class TestDryRun(unittest.TestCase):
    def test_destructive_step_skipped_in_dry_run(self):
        from unittest.mock import patch

        from vacuum.engine import VacuumEngine

        cfg = load_config()
        cfg["hoghunter_clean"] = "/no/such/script"
        engine = VacuumEngine(cfg, Path("/tmp"))
        with patch.object(sys, "platform", "darwin"):
            _freed, reason, status = engine._dispatch("brew_cleanup", False, "cheap", {}, "normal", dry_run=True)
        self.assertEqual(status, StepStatus.SKIPPED)
        self.assertIn("dry run", reason)


class TestHealth(unittest.TestCase):
    def test_launchd_not_required_for_healthy(self):
        from unittest.mock import patch

        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            data = home / "rv"
            data.mkdir(parents=True)
            cfg = load_config(home=home)
            cfg["data_dir"] = str(data)
            store = VacuumStore(cfg, home=home)
            with patch("vacuum.alerts.launchd_loaded", return_value=False):
                status = build_status(store, cfg, now=time.time())
            self.assertEqual(status["health"], "healthy")
            self.assertFalse(status["launchd_loaded"])


def load_tests(loader, tests, pattern):
    """CI runs only this file, so load the lane doctor tests beside the others."""
    import importlib.util

    path = Path(__file__).resolve().parent / "test-vacuum-lanes.py"
    spec = importlib.util.spec_from_file_location("test_vacuum_lanes", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    tests.addTests(loader.loadTestsFromModule(module))
    return tests


if __name__ == "__main__":
    unittest.main()
