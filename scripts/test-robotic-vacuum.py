#!/usr/bin/env python3
"""Linux-runnable tests for Robotic Vacuum scheduler, alerts, and janitor helpers.

The lane doctor tests live in test-vacuum-lanes.py; load_tests at the bottom pulls them in, so the one CI
command (python3 scripts/test-robotic-vacuum.py) runs both files."""
from __future__ import annotations

import argparse
import atexit
import contextlib
import errno
import io
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
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
from vacuum.config import DEFAULT_HISTORY_MAX_RUNS, load_config, step_enabled, steps_for_trigger  # noqa: E402
from vacuum import janitor  # noqa: E402
from vacuum.models import RunOutcome, RunRecord, StepResult, StepStatus, TriggerKind, run_outcome  # noqa: E402
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

    def test_a_df_that_did_not_answer_is_not_a_full_disk(self):
        """A df that fails leaves disk_free_gb at zero, and zero free reads as
        a critical shortage that would put the tick into pressure cleanup."""
        s = {"disk_sample_ok": False, "disk_free_gb": 0, "swap_used_pct": 0,
             "swap_used_gb": 0, "load1": 0}
        hits = evaluate_hits(s, None, {"disk_free_crit_gb": 15, "disk_free_warn_gb": 25})
        self.assertFalse([h for h in hits if h["metric"].startswith("disk")], hits)

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

    def _status_with_disk(self, free_gb: float | None) -> dict:
        """Build a status whose scheduler state reports the given free disk space."""
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            data = home / "rv"
            data.mkdir(parents=True)
            cfg = load_config(home=home)
            cfg["data_dir"] = str(data)
            store = VacuumStore(cfg, home=home)
            if free_gb is not None:
                store.merge_scheduler_state({"prev_disk_free_gb": free_gb})
            with patch("vacuum.alerts.launchd_loaded", return_value=False):
                return build_status(store, cfg, now=time.time())

    def test_a_critically_low_disk_reports_critical_health(self):
        """The panel used to say healthy while the disk sat at 100% with 3 GB free.

        Free space below the critical threshold is an emergency the owner has to
        see, so it outranks the last run's exit code."""
        status = self._status_with_disk(5.9)
        self.assertEqual(status["health"], "critical")
        self.assertEqual(status["disk"]["health"], "critical")
        self.assertEqual(status["disk"]["free_gb"], 5.9)

    def test_a_low_disk_reports_degraded_health(self):
        status = self._status_with_disk(20.0)
        self.assertEqual(status["health"], "degraded")
        self.assertEqual(status["disk"]["health"], "acute")

    def test_a_roomy_disk_leaves_health_alone(self):
        status = self._status_with_disk(120.0)
        self.assertEqual(status["health"], "healthy")
        self.assertEqual(status["disk"]["health"], "ok")
        self.assertEqual(status["disk"]["free_gb"], 120.0)

    def test_disk_free_space_is_reported_even_when_nothing_is_known_yet(self):
        """No sample yet means no disk block value, and the health must not crash on it."""
        status = self._status_with_disk(None)
        self.assertEqual(status["health"], "healthy")
        self.assertIsNone(status["disk"]["free_gb"])
        self.assertEqual(status["disk"]["health"], "unknown")


class TestStatusStepResults(unittest.TestCase):
    """step_last_results holds each step's latest result, not just what the last record ran.  The Mac's Cleaning
    steps list reads it, and the last record is almost always a five minute watch tick."""

    @staticmethod
    def _record(trigger: TriggerKind, started: float, steps: list[StepResult], exit_code: int = 0) -> RunRecord:
        record = RunRecord(f"{trigger.value}-{int(started)}", trigger, started_at=started)
        record.steps.extend(steps)
        record.ended_at = started + 5
        record.exit_code = exit_code
        return record

    def _status(self, records: list[RunRecord]) -> dict:
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            data = home / "rv"
            data.mkdir(parents=True)
            cfg = load_config(home=home)
            cfg["data_dir"] = str(data)
            store = VacuumStore(cfg, home=home)
            for record in records:
                store.append_run(record)
            with patch("vacuum.alerts.launchd_loaded", return_value=False):
                return build_status(store, cfg, now=records[-1].ended_at + 1)

    def test_a_watch_tick_after_a_janitor_run_keeps_the_janitor_steps(self):
        t = 1_760_000_000.0
        janitor_run = self._record(
            TriggerKind.JANITOR,
            t,
            [
                StepResult("pm2_logs", "Cap oversized PM2 logs", StepStatus.RAN, reason="No log is over the limit."),
                StepResult("npm_cache", "Trim npm download cache", StepStatus.RAN, reason="Trimmed.", bytes_freed=400),
            ],
        )
        watch_tick = self._record(
            TriggerKind.WATCH, t + 300, [StepResult("resource_sample", "Check disk and memory", StepStatus.RAN)]
        )
        status = self._status([janitor_run, watch_tick])
        self.assertEqual(set(status["step_last_results"]), {"pm2_logs", "npm_cache", "resource_sample"})
        self.assertEqual(status["step_last_results"]["npm_cache"]["bytes_freed"], 400)
        self.assertEqual(status["step_last_results"]["pm2_logs"]["reason"], "No log is over the limit.")
        # Everything else about the status still describes the very last record.
        self.assertEqual(status["last_run"]["run_id"], watch_tick.run_id)
        self.assertEqual(status["history_count"], 2)

    def test_the_newest_result_of_a_step_wins(self):
        t = 1_760_000_000.0
        older = self._record(
            TriggerKind.JANITOR, t, [StepResult("pm2_logs", "Cap oversized PM2 logs", StepStatus.FAILED, reason="old")]
        )
        newer = self._record(
            TriggerKind.FULL, t + 3600, [StepResult("pm2_logs", "Cap oversized PM2 logs", StepStatus.RAN, reason="new")]
        )
        watch_tick = self._record(
            TriggerKind.WATCH, t + 3900, [StepResult("resource_sample", "Check disk and memory", StepStatus.RAN)]
        )
        status = self._status([older, newer, watch_tick])
        self.assertEqual(status["step_last_results"]["pm2_logs"]["reason"], "new")
        self.assertEqual(status["step_last_results"]["pm2_logs"]["status"], "ran")

    def test_health_still_follows_the_last_record_alone(self):
        t = 1_760_000_000.0
        good = self._record(TriggerKind.FULL, t, [StepResult("pm2_logs", "Cap oversized PM2 logs", StepStatus.RAN)])
        failed_tick = self._record(
            TriggerKind.WATCH, t + 60, [StepResult("resource_sample", "Check disk and memory", StepStatus.FAILED)], exit_code=1
        )
        self.assertEqual(self._status([good, failed_tick])["health"], "failed")
        recovered_tick = self._record(
            TriggerKind.WATCH, t + 120, [StepResult("resource_sample", "Check disk and memory", StepStatus.RAN)]
        )
        self.assertEqual(self._status([failed_tick, recovered_tick])["health"], "healthy")

    def test_no_history_means_no_step_results(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            data = home / "rv"
            data.mkdir(parents=True)
            cfg = load_config(home=home)
            cfg["data_dir"] = str(data)
            store = VacuumStore(cfg, home=home)
            with patch("vacuum.alerts.launchd_loaded", return_value=False):
                status = build_status(store, cfg, now=time.time())
        self.assertEqual(status["step_last_results"], {})
        self.assertIsNone(status["last_run"])


def _step(step_id: str, status: StepStatus, reason: str = "", freed: int = 0) -> StepResult:
    return StepResult(step_id, step_id, status, reason=reason, bytes_freed=freed)


class TestRunOutcome(unittest.TestCase):
    """One failed step must not fail a whole run whose other steps did their work (issue #111)."""

    def test_outcome_rules(self):
        ran, skipped, failed = StepStatus.RAN, StepStatus.SKIPPED, StepStatus.FAILED
        self.assertEqual(run_outcome([]), RunOutcome.OK)
        self.assertEqual(run_outcome([_step("a", ran), _step("b", skipped)]), RunOutcome.OK)
        self.assertEqual(run_outcome([_step("a", ran), _step("b", failed)]), RunOutcome.PARTIAL)
        self.assertEqual(run_outcome([_step("a", skipped), _step("b", failed)]), RunOutcome.FAILED)
        self.assertEqual(run_outcome([_step("b", failed)]), RunOutcome.FAILED)
        # The sampler only reads the host.  It never counts as the work that rescued a run.
        self.assertEqual(run_outcome([_step("resource_sample", ran), _step("b", failed)]), RunOutcome.FAILED)
        self.assertEqual(
            run_outcome([_step("resource_sample", ran), _step("b", failed), _step("c", ran)]), RunOutcome.PARTIAL
        )

    def test_partial_run_exits_zero_and_names_the_failed_step(self):
        record = RunRecord("x", TriggerKind.FULL, started_at=time.time())
        record.steps += [
            _step("pm2_logs", StepStatus.RAN, freed=1000),
            _step("hoghunter_reclaim", StepStatus.FAILED, "stopped"),
            _step("npm_cache", StepStatus.SKIPPED),
        ]
        record.finish()
        self.assertEqual(record.exit_code, 0)
        self.assertEqual(record.outcome, "partial")
        self.assertEqual(record.bytes_freed, 1000)
        self.assertIn("hoghunter_reclaim", record.summary)
        self.assertIn("1 of 3", record.summary)
        # The failure is not hidden: it is still on the step, and the alert module still sees it.
        self.assertEqual([s.step_id for s in record.steps if s.status == StepStatus.FAILED], ["hoghunter_reclaim"])

    def test_a_run_where_nothing_worked_still_fails(self):
        record = RunRecord("x", TriggerKind.JANITOR, started_at=time.time())
        record.steps += [_step("janitor_worktree_retire", StepStatus.SKIPPED), _step("janitor_cache_reclaim", StepStatus.FAILED)]
        record.finish()
        self.assertEqual((record.exit_code, record.outcome), (1, "failed"))

    def test_clean_run_is_ok_with_no_summary_noise(self):
        record = RunRecord("x", TriggerKind.JANITOR, started_at=time.time())
        record.steps.append(_step("pm2_logs", StepStatus.RAN))
        record.finish(summary="watch tick")
        self.assertEqual((record.exit_code, record.outcome, record.summary), (0, "ok", "watch tick"))

    def test_explicit_exit_codes_still_win(self):
        failed = RunRecord("x", TriggerKind.FULL, started_at=time.time())
        failed.steps.append(_step("a", StepStatus.RAN))
        failed.finish(1)
        self.assertEqual((failed.exit_code, failed.outcome), (1, "failed"))
        clean = RunRecord("y", TriggerKind.WATCH, started_at=time.time())
        clean.steps.append(_step("housekeeper_lock", StepStatus.SKIPPED, "held"))
        clean.finish(0, summary="watch skipped; lock held")
        self.assertEqual((clean.exit_code, clean.outcome, clean.summary), (0, "ok", "watch skipped; lock held"))
        odd = RunRecord("z", TriggerKind.FULL, started_at=time.time())
        odd.steps.append(_step("a", StepStatus.FAILED))
        odd.finish(0)
        self.assertEqual((odd.exit_code, odd.outcome), (0, "partial"), "zero is never worse than partial")

    def test_outcome_round_trips_and_old_records_get_one(self):
        record = RunRecord("x", TriggerKind.FULL, started_at=time.time())
        record.steps += [_step("a", StepStatus.RAN), _step("b", StepStatus.FAILED)]
        record.finish()
        again = RunRecord.from_dict(json.loads(json.dumps(record.as_dict())))
        self.assertEqual(again.outcome, "partial")
        old_ok = RunRecord.from_dict({"run_id": "o", "trigger": "watch", "started_at": 1, "exit_code": 0})
        old_bad = RunRecord.from_dict({"run_id": "o", "trigger": "watch", "started_at": 1, "exit_code": 1})
        self.assertEqual((old_ok.outcome, old_bad.outcome), ("ok", "failed"))

    def test_a_failure_summary_is_never_mistaken_for_a_lock_skip(self):
        from vacuum.scheduler import run_skipped_for_lock

        record = RunRecord("x", TriggerKind.FULL, started_at=time.time())
        record.steps += [_step("a", StepStatus.RAN)] + [_step(sid, StepStatus.FAILED) for sid in STEP_IDS_FOR_LOCK_CHECK]
        record.finish()
        self.assertFalse(run_skipped_for_lock(record), record.summary)

    def _engine(self, home: Path, only: list[str]):
        from vacuum.engine import VacuumEngine

        cfg = load_config(home=home)
        cfg["housekeeper_lock"] = str(home / ".housekeeper.lock")
        for step_id in cfg["steps"]:
            cfg["steps"][step_id] = {"enabled": step_id in only}
        return VacuumEngine(cfg, home=home)

    def test_engine_run_with_one_failing_step_is_partial(self):
        from vacuum.engine import VacuumEngine

        with tempfile.TemporaryDirectory() as td:
            engine = self._engine(Path(td), ["pm2_logs", "vitest_temp_dbs"])

            def dispatch(self, step_id, *args, **kwargs):
                if step_id == "vitest_temp_dbs":
                    raise RuntimeError("boom")
                return 4096, "fine", StepStatus.RAN

            with patch.object(VacuumEngine, "_dispatch", dispatch), patch(
                "vacuum.engine.sample_mac", return_value={"disk_free_gb": 100.0, "load1": 0.0, "swap_used_pct": 0.0}
            ):
                record = engine.run(TriggerKind.JANITOR)
        self.assertEqual((record.exit_code, record.outcome, record.bytes_freed), (0, "partial", 4096))

    def test_watch_escalation_with_one_failed_step_is_partial_not_failed(self):
        """Watch ticks were 11 of the 22 runs on Oct 9, and they had their own all-or-nothing exit."""
        from vacuum.engine import VacuumEngine

        def pressure_record(statuses):
            def run(self, trigger, pressure=False, band="cheap", dry_run=False):
                rec = RunRecord("p", trigger, started_at=time.time())
                for i, status in enumerate(statuses):
                    rec.steps.append(_step(f"step{i}", status))
                rec.finish()
                return rec

            return run

        hits = [{"metric": "disk_free_gb", "severity": "critical"}]
        for statuses, expected in (
            ([StepStatus.FAILED, StepStatus.RAN], (0, "partial")),
            ([StepStatus.FAILED, StepStatus.SKIPPED], (1, "failed")),
            ([StepStatus.RAN, StepStatus.RAN], (0, "ok")),
        ):
            with tempfile.TemporaryDirectory() as td:
                engine = self._engine(Path(td), [])
                with patch("vacuum.engine.sample_mac", return_value={"disk_free_gb": 8.0}), patch(
                    "vacuum.engine.evaluate_hits", return_value=hits
                ), patch.object(VacuumEngine, "run", pressure_record(statuses)):
                    record, _hits, cleaned = engine.run_watch_tick({}, None)
            self.assertTrue(cleaned)
            self.assertEqual((record.exit_code, record.outcome), expected, statuses)

    def test_the_watch_tick_reports_the_disk_after_its_own_cleanup(self):
        """The tick samples the disk before it cleans.  Persisting that made the
        status published moments later still call the disk critical, for the
        space the run had just freed, until the next tick five minutes on."""
        from vacuum.engine import VacuumEngine

        def sample(free):
            return {"disk_sample_ok": True, "disk_free_gb": free, "load1": 0.0,
                    "swap_used_pct": 0.0, "swap_used_gb": 0.0}

        def run(self, trigger, pressure=False, band="cheap", dry_run=False):
            rec = RunRecord("p", trigger, started_at=time.time())
            rec.finish()
            return rec

        with tempfile.TemporaryDirectory() as td:
            engine = self._engine(Path(td), [])
            state: dict = {}
            with patch("vacuum.engine.sample_mac", side_effect=[sample(8.0), sample(60.0)]), patch.object(
                VacuumEngine, "run", run
            ):
                _record, _hits, cleaned = engine.run_watch_tick(state, None)
        self.assertTrue(cleaned)
        self.assertEqual(state["prev_disk_free_gb"], 60.0)

    def test_a_failed_df_does_not_overwrite_the_last_known_free_space(self):
        """Zero free is the df answer when df does not answer, and the panel
        reads that number as a critical disk."""
        from vacuum.engine import VacuumEngine

        with tempfile.TemporaryDirectory() as td:
            engine = self._engine(Path(td), [])
            state = {"prev_disk_free_gb": 90.0}
            with patch("vacuum.engine.sample_mac", return_value={
                    "disk_sample_ok": False, "disk_free_gb": 0, "load1": 0.0,
                    "swap_used_pct": 0.0, "swap_used_gb": 0.0}):
                engine.run_watch_tick(state, 90.0)
        self.assertEqual(state["prev_disk_free_gb"], 90.0)

    def test_the_run_failed_banner_follows_failed_steps_so_a_partial_run_still_speaks(self):
        """The decision, written down: a partial run exits 0 and is not a failed run, but a step that fails
        every time must not go quiet, so the banner (whose text says "failed step(s)") is keyed on the steps.
        A run with no failed step stays silent."""
        for steps, expect_alert in (
            ([_step("a", StepStatus.RAN), _step("b", StepStatus.FAILED)], True),
            ([_step("a", StepStatus.SKIPPED), _step("b", StepStatus.FAILED)], True),
            ([_step("a", StepStatus.RAN), _step("b", StepStatus.SKIPPED)], False),
        ):
            with tempfile.TemporaryDirectory() as td:
                home = Path(td)
                cfg = load_config(home=home)
                cfg["data_dir"] = str(home / "rv")
                store = VacuumStore(cfg, home=home)
                now = time.time()
                record = RunRecord("r", TriggerKind.FULL, started_at=now - 5)
                record.steps += steps
                record.finish()
                record.ended_at = now - 1
                store.append_run(record)
                with patch("vacuum.alerts.launchd_loaded", return_value=True):
                    decisions = evaluate_alerts(store, cfg, now=now)
                kinds = [d.kind for d in decisions if d.should_notify]
                self.assertEqual("run_failed" in kinds, expect_alert, (steps, kinds))


STEP_IDS_FOR_LOCK_CHECK = ("hoghunter_reclaim", "spotlight_journals", "janitor_worktree_retire", "pm2_logs")


class _EngineHome(unittest.TestCase):
    def setUp(self) -> None:
        from vacuum.engine import VacuumEngine

        self.home = Path(tempfile.mkdtemp(prefix="hhengine-"))
        self.addCleanup(shutil.rmtree, str(self.home), True)
        self.cfg = load_config(home=self.home)
        self.cfg["housekeeper_lock"] = str(self.home / ".housekeeper.lock")
        self.engine = VacuumEngine(self.cfg, home=self.home)

    def fake_cleaner(self) -> str:
        path = self.home / "hoghunter-clean"
        path.write_text("#!/bin/sh\n", encoding="utf-8")
        path.chmod(0o755)
        self.cfg["hoghunter_clean"] = str(path)
        return str(path)


def _report(**overrides) -> str:
    report = {
        "applied_count": 1710,
        "actionable_count": 1710,
        "failed_count": 0,
        "applied_bytes": 69_000_000,
        "budget_exhausted": False,
        "remaining_count": 0,
    }
    report.update(overrides)
    return json.dumps(report)


class TestHogHunterReclaimStep(_EngineHome):
    def run_step(self, result, band="cheap"):
        """Run the step with _run_in_own_group answering `result`; returns (step result, the call)."""
        self.fake_cleaner()
        with patch("vacuum.engine._run_in_own_group", return_value=result) as run:
            return self.engine._hoghunter_reclaim(band), run.call_args

    def test_the_cleaner_gets_a_budget_under_its_hard_stop_and_asks_for_json(self):
        _out, call = self.run_step((0, _report(), "", False))
        cmd, timeout = call.args
        self.assertIn("--clean", cmd)
        self.assertIn("--band=cheap", cmd)
        self.assertIn("--json", cmd)
        self.assertIn("--budget-sec=600", cmd)
        self.assertLess(timeout, 900, "the hard stop stays under the 900 s the step used to get")
        self.assertGreater(timeout, 600)

    def test_a_finished_sweep_reports_the_real_bytes(self):
        (freed, reason, status), _call = self.run_step((0, _report(), "", False), band="full")
        self.assertEqual((freed, status), (69_000_000, StepStatus.RAN))
        self.assertIn("band=full", reason)
        self.assertIn("removed 1710 of 1710", reason)
        self.assertNotIn("budget", reason)

    def test_a_run_the_host_spent_further_frees_no_bytes_not_negative_ones(self):
        """`disk_free_delta_gb` is the NET change in free space, so a host that
        wrote more than the run deleted reports a negative delta.  `freed` is
        summed into RunRecord.bytes_freed and rendered by lanes.format_size,
        which would reach the panel as "reclaimed -51.2 MB"."""
        out = self.run_step((0, _report(disk_free_delta_gb=-0.05), "", False), band="cheap")[0]
        freed, reason, status = out
        self.assertEqual((freed, status), (0, StepStatus.RAN))
        self.assertNotIn("-", reason.split(": removed")[1])
        positive = self.run_step((0, _report(disk_free_delta_gb=1.5), "", False), band="cheap")[0]
        self.assertEqual(positive[0], int(1.5 * 1024 ** 3))

    def test_a_negative_measured_delta_still_says_what_the_host_did(self):
        """The count of bytes freed is clamped at zero, but the reason still
        reports what was measured.  A negative number printed next to "freed"
        reads as a bug, so the host-spending case is put in words: that is
        what actually happened, and it is not a number of bytes reclaimed."""
        (freed, reason, status), _call = self.run_step(
            (0, _report(applied_count=12, applied_bytes=500_000_000,
                        disk_free_delta_gb=-0.05), "", False))
        self.assertEqual(freed, 0, "bytes freed cannot be negative")
        self.assertEqual(status, StepStatus.RAN)
        self.assertIn("0 B freed", reason)
        self.assertIn("the host used 51.2 MB", reason)
        self.assertNotIn("-", reason.split(": removed")[1])

    def test_the_measured_delta_replaces_the_estimate(self):
        """The estimate is what the scan believed it would delete; the measured
        delta is what df saw.  The measured one wins, because a delete can
        free nothing and the estimate cannot know that."""
        (freed, reason, _status), _call = self.run_step(
            (0, _report(applied_count=12, applied_bytes=6_000_000_000,
                        disk_free_delta_gb=0.05), "", False))
        self.assertEqual(freed, 53_687_091)
        self.assertIn("51.2 MB freed", reason)
        self.assertIn("51.2 MB measured", reason)
        self.assertNotIn("5.7 GB", reason, "the estimate is not the outcome")

    def test_a_spent_budget_is_a_good_partial_run_not_a_failure(self):
        out = self.run_step((0, _report(applied_count=600, applied_bytes=1_200_000, budget_exhausted=True, remaining_count=1110), "", False))
        freed, reason, status = out[0]
        self.assertEqual((freed, status), (1_200_000, StepStatus.RAN))
        self.assertIn("1110 left for the next run", reason)

    def test_a_cleaner_that_overruns_its_hard_stop_fails_with_a_reason(self):
        (freed, reason, status), _call = self.run_step((-1, "", "", True))
        self.assertEqual((freed, status), (0, StepStatus.FAILED))
        self.assertIn("overran its 600s budget", reason)

    def test_nonzero_exit_reports_the_last_stderr_line(self):
        (_freed, reason, status), _call = self.run_step((2, "", "usage\n[hoghunter-clean] unknown category 'x'\n", False))
        self.assertEqual(status, StepStatus.FAILED)
        self.assertEqual(reason, "[hoghunter-clean] unknown category 'x'")

    def test_items_that_could_not_be_removed_are_named_and_all_failed_is_a_failure(self):
        some = self.run_step((0, _report(applied_count=10, failed_count=3), "", False))[0]
        self.assertEqual(some[2], StepStatus.RAN)
        self.assertIn("3 could not be removed", some[1])
        none = self.run_step((0, _report(applied_count=0, failed_count=5, applied_bytes=0), "", False))[0]
        self.assertEqual(none[2], StepStatus.FAILED)

    def test_an_older_cleaner_without_the_new_keys_still_runs(self):
        (freed, reason, status), _call = self.run_step((0, "hoghunter-clean 1.0.0 - CLEAN\nnothing reclaimable.\n", "", False))
        self.assertEqual((freed, reason, status), (0, "band=cheap", StepStatus.RAN))

    def test_missing_cleaner_is_a_skip(self):
        self.cfg["hoghunter_clean"] = str(self.home / "nope")
        self.assertEqual(self.engine._hoghunter_reclaim("cheap")[2], StepStatus.SKIPPED)

    def test_the_budget_knob_has_a_floor_and_ignores_junk(self):
        for value, expected in ((120, 120), ("90", 90), (5, 30), ("soon", 600), (None, 600)):
            self.cfg["hoghunter_clean_budget_sec"] = value
            self.assertEqual(self.engine._reclaim_budget(), expected, value)
        del self.cfg["hoghunter_clean_budget_sec"]
        self.assertEqual(self.engine._reclaim_budget(), 600)
        self.assertEqual(load_config(home=self.home)["hoghunter_clean_budget_sec"], 600)

    def test_the_janitor_cache_step_uses_the_same_bounded_path(self):
        self.fake_cleaner()
        with patch("vacuum.engine._run_in_own_group", return_value=(0, _report(), "", False)) as run:
            freed, _reason, status = self.engine._janitor_cache_reclaim({"disk_free_gb": 12.0}, "normal", dry_run=False)
        self.assertEqual((freed, status), (69_000_000, StepStatus.RAN))
        self.assertIn("--budget-sec=600", run.call_args.args[0])

    def test_the_disk_reclaim_step_runs_even_under_extreme_load(self):
        """The load guard that opened this step is gone.  Skipping the disk reclaim
        because the host is loaded is a deadlock: the disk pressure that loads the
        host is exactly what the step exists to clear, so the step never ran on a
        host that needed it and the disk slid to 100% with every run reporting zero
        bytes freed.  Owner ruling 2026-10-02: pressure changes the SHAPE of the
        work, never its SCOPE."""
        self.fake_cleaner()
        with patch("vacuum.engine._run_in_own_group", return_value=(0, _report(), "", False)) as run:
            freed, _reason, status = self.engine._janitor_cache_reclaim({"disk_free_gb": 12.0}, "hard", dry_run=False)
        self.assertEqual((freed, status), (69_000_000, StepStatus.RAN))
        self.assertIn("--budget-sec=600", run.call_args.args[0])

    def test_the_janitor_reclaim_does_not_act_on_a_disk_sample_that_failed(self):
        """A df that failed leaves disk_free_gb at zero, and zero free is below
        every threshold.  Without the disk_sample_ok guard this runs a full
        cheap-band reclaim -- deleting app caches and agent state -- on a disk
        that is actually healthy."""
        self.fake_cleaner()
        with patch("vacuum.engine._run_in_own_group", return_value=(0, _report(), "", False)) as run:
            freed, reason, status = self.engine._janitor_cache_reclaim(
                {"disk_sample_ok": False, "disk_free_gb": 0.0}, "normal", dry_run=False
            )
        self.assertEqual((freed, status), (0, StepStatus.SKIPPED))
        self.assertIn("disk sample unavailable", reason)
        self.assertEqual(run.call_count, 0, "nothing is deleted on an unmeasured disk")

    def test_a_hard_mode_janitor_run_still_reclaims_the_disk(self):
        from unittest.mock import patch

        from vacuum.engine import VacuumEngine
        from vacuum.models import TriggerKind

        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            cfg = load_config(home=home)
            cfg["hoghunter_clean"] = str(home / "hoghunter-clean")
            cfg["housekeeper_lock"] = str(home / ".housekeeper.lock")
            cfg.setdefault("janitor", {})["low_free_gib"] = 80
            for step_id in steps_for_trigger(cfg, "janitor"):
                cfg.setdefault("steps", {})[step_id] = {"enabled": False}
            cfg["steps"]["janitor_cache_reclaim"] = {"enabled": True}
            engine = VacuumEngine(cfg, home=home)
            with patch(
                "vacuum.engine.sample_mac",
                return_value={"disk_free_gb": 4.0, "swap_used_pct": 99.0, "swap_used_gb": 30.0, "load1": 400.0},
            ), patch("vacuum.engine.janitor_pressure_mode", return_value="hard"), patch.object(
                sys, "platform", "darwin"
            ), patch(
                "vacuum.engine.VacuumEngine._hoghunter_reclaim",
                return_value=(1234, "band=cheap", StepStatus.RAN),
            ):
                record = engine.run(TriggerKind.JANITOR)
        step = next(s for s in record.steps if s.step_id == "janitor_cache_reclaim")
        self.assertEqual(step.status, StepStatus.RAN)
        self.assertEqual(step.bytes_freed, 1234)


class TestCleanMyMacStep(_EngineHome):
    """The CleanMyMac CLI step is opt-in, invoke-only, and never required:
    off until the owner turns it on, a skip when the CLI is absent, and a
    failure with the tail when a sweep exits non-zero."""

    def engine_with(self, runner):
        from vacuum.engine import VacuumEngine

        return VacuumEngine(self.cfg, home=self.home, runner=runner)

    @staticmethod
    def ok_runner(argv, **kwargs):
        return subprocess.CompletedProcess(argv, 0, stdout="done\n", stderr="")

    def test_off_by_default_and_full_only_when_enabled(self):
        from vacuum.config import STEP_CATALOG, step_enabled, steps_for_trigger

        self.assertIn("cleanmymac_cli", STEP_CATALOG)
        self.assertEqual(STEP_CATALOG["cleanmymac_cli"]["triggers"], ["full"])
        fresh = load_config(home=self.home)
        self.assertFalse(step_enabled(fresh, "cleanmymac_cli"))
        self.assertNotIn("cleanmymac_cli", steps_for_trigger(fresh, "full"))
        fresh.setdefault("steps", {})["cleanmymac_cli"] = {"enabled": True}
        self.assertTrue(step_enabled(fresh, "cleanmymac_cli"))
        self.assertIn("cleanmymac_cli", steps_for_trigger(fresh, "full"))
        self.assertNotIn("cleanmymac_cli", steps_for_trigger(fresh, "janitor"))

    def test_missing_cli_is_a_skip(self):
        engine = self.engine_with(self.ok_runner)
        with patch("vacuum.engine.shutil.which", return_value=None):
            with patch.object(sys, "platform", "darwin"):
                _freed, reason, status = engine._cleanmymac_cli()
        self.assertEqual(status, StepStatus.SKIPPED)
        self.assertIn("not installed", reason)

    def test_success_runs_both_sweeps(self):
        seen = []

        def fake(argv, **kwargs):
            seen.append(list(argv))
            return subprocess.CompletedProcess(argv, 0, stdout="done\n", stderr="")

        engine = self.engine_with(fake)
        with patch("vacuum.engine.shutil.which", return_value="/opt/homebrew/bin/cleanmymac"):
            with patch.object(sys, "platform", "darwin"):
                freed, reason, status = engine._cleanmymac_cli()
        self.assertEqual((freed, status), (0, StepStatus.RAN))
        self.assertEqual(seen, [
            ["cleanmymac", "clean", "junk", "--force"],
            ["cleanmymac", "optimize", "purgeable"],
        ])
        self.assertIn("clean junk --force", reason)

    def test_connected_cli_picked_in_settings_is_the_one_run(self):
        """Settings > Maintenance writes the picked installation to tool_paths; the step runs that file.  A
        relative or non-executable pick is ignored and PATH decides, as before."""
        seen = []

        def fake(argv, **kwargs):
            seen.append(list(argv))
            return subprocess.CompletedProcess(argv, 0, stdout="done\n", stderr="")

        picked = self.home / "bin" / "CleanMyMac_5_CLI"
        picked.parent.mkdir(parents=True)
        picked.write_text("#!/bin/sh\n", encoding="utf-8")
        picked.chmod(0o755)
        self.cfg["tool_paths"] = {"cleanmymac": str(picked)}
        with patch("vacuum.engine.shutil.which", return_value=None):
            with patch.object(sys, "platform", "darwin"):
                _freed, _reason, status = self.engine_with(fake)._cleanmymac_cli()
        self.assertEqual(status, StepStatus.RAN)
        self.assertEqual([argv[0] for argv in seen], [str(picked), str(picked)])

        picked.chmod(0o644)
        for bad in (str(picked), "bin/CleanMyMac_5_CLI"):
            self.cfg["tool_paths"] = {"cleanmymac": bad}
            with patch("vacuum.engine.shutil.which", return_value=None):
                with patch.object(sys, "platform", "darwin"):
                    _freed, reason, status = self.engine_with(fake)._cleanmymac_cli()
            self.assertEqual(status, StepStatus.SKIPPED, bad)
            self.assertIn("not installed", reason)

    def test_nonzero_exit_fails_with_the_tail(self):
        def fake(argv, **kwargs):
            return subprocess.CompletedProcess(argv, 2, stdout="", stderr="line one\nboom\n")

        engine = self.engine_with(fake)
        with patch("vacuum.engine.shutil.which", return_value="/opt/homebrew/bin/cleanmymac"):
            with patch.object(sys, "platform", "darwin"):
                _freed, reason, status = engine._cleanmymac_cli()
        self.assertEqual(status, StepStatus.FAILED)
        self.assertIn("boom", reason)

    def test_never_runs_anything_real(self):
        """No test may launch the real CLI: with no `cleanmymac` on PATH the
        step skips before any runner is touched, and dry runs skip too."""
        from vacuum.engine import VacuumEngine

        engine = VacuumEngine(self.cfg, home=self.home, runner=Mock(side_effect=AssertionError("must not run")))
        with patch("vacuum.engine.shutil.which", return_value=None):
            with patch.object(sys, "platform", "darwin"):
                _freed, _reason, status = engine._cleanmymac_cli()
        self.assertEqual(status, StepStatus.SKIPPED)
        self.cfg.setdefault("steps", {})["cleanmymac_cli"] = {"enabled": True}
        with patch.object(sys, "platform", "darwin"):
            _freed, reason, status = self.engine._dispatch("cleanmymac_cli", False, "cheap", {}, "normal", dry_run=True)
        self.assertEqual(status, StepStatus.SKIPPED)
        self.assertIn("dry run", reason)


class TestStepReasonsArePlural(_EngineHome):
    """The Robotic Vacuum shows each step's reason to a person.  It read "1 threshold hit(s)", "removed 1 of 1
    item(s)" and "truncated 0 log(s)"; each count now takes the right form of its noun."""

    def test_the_helper_picks_the_form_by_the_count(self):
        from vacuum.engine import _plural

        self.assertEqual([_plural(n, "log") for n in (0, 1, 2)], ["0 logs", "1 log", "2 logs"])
        self.assertEqual(_plural(1, "stale temp db"), "1 stale temp db")
        self.assertEqual(_plural(3, "stale temp db"), "3 stale temp dbs")
        self.assertEqual(_plural(2, "entry", "entries"), "2 entries")
        self.assertEqual(_plural(1, "entry", "entries"), "1 entry")

    def test_no_step_reason_hedges_the_plural_in_parentheses(self):
        source = (REPO / "scripts" / "vacuum" / "engine.py").read_text(encoding="utf-8")
        self.assertEqual(re.findall(r"\w\(s\)", source), [])

    def test_the_resource_check_counts_its_threshold_hits(self):
        for hits, expected in (
            ([], "within limits"),
            ([{"metric": "disk_free_gb"}], "1 threshold hit"),
            ([{"metric": "disk_free_gb"}, {"metric": "swap_used_pct"}], "2 threshold hits"),
        ):
            with patch("vacuum.engine.sample_mac", return_value={"disk_free_gb": 8.0}), patch(
                "vacuum.engine.evaluate_hits", return_value=hits
            ):
                # A clean ran a moment ago, so a hit is counted and nothing is cleaned.
                record, _hits, cleaned = self.engine.run_watch_tick({"last_clean_at": time.time()}, None)
            self.assertFalse(cleaned)
            self.assertEqual(record.steps[0].reason, expected)

    def test_the_cleaner_reports_its_item_count_in_the_right_form(self):
        self.fake_cleaner()
        for applied, total, expected in (
            (1, 1, "band=cheap: removed 1 of 1 item, "),
            (0, 3, "band=cheap: removed 0 of 3 items, "),
            (0, 0, "band=cheap: removed 0 of 0 items, "),
        ):
            result = (0, _report(applied_count=applied, actionable_count=total, applied_bytes=0), "", False)
            with patch("vacuum.engine._run_in_own_group", return_value=result):
                _freed, reason, _status = self.engine._hoghunter_reclaim("cheap")
            self.assertTrue(reason.startswith(expected), reason)

    def test_the_pm2_log_step_counts_in_the_right_form(self):
        self.assertEqual(self.engine._pm2_logs()[1], "truncated 0 logs in place")

    def test_the_other_counted_steps(self):
        stamp = time.time() - 30 * 86400
        brain = self.home / ".gemini/antigravity/brain"
        for count, expected in ((1, "pruned 1 folder"), (2, "pruned 2 folders")):
            for child in brain.glob("*") if brain.exists() else []:
                shutil.rmtree(child)
            for n in range(count):
                old = brain / f"old{n}"
                old.mkdir(parents=True)
                os.utime(old, (stamp, stamp))
            self.assertEqual(self.engine._antigravity_brain()[1], expected)


class TestRunInOwnGroup(unittest.TestCase):
    def test_normal_exit_returns_code_and_output(self):
        from vacuum.engine import _run_in_own_group

        code, out, err, timed_out = _run_in_own_group(
            [sys.executable, "-c", "import sys; print('out'); print('err', file=sys.stderr); sys.exit(3)"], 30
        )
        self.assertEqual((code, out.strip(), err.strip(), timed_out), (3, "out", "err", False))

    def test_a_timeout_kills_the_child_and_everything_it_started(self):
        from vacuum.engine import _run_in_own_group

        script = (
            "import subprocess, sys, time\n"
            "child = subprocess.Popen(['sleep', '60'])\n"
            "print(child.pid, flush=True)\n"
            "time.sleep(60)\n"
        )
        started = time.time()
        code, out, _err, timed_out = _run_in_own_group([sys.executable, "-c", script], 2)
        self.assertTrue(timed_out)
        self.assertLess(time.time() - started, 30)
        grandchild = int(out.split()[0])

        def alive(pid: int) -> bool:
            # kill(pid, 0) succeeds on a zombie, which a container without an init never reaps.
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return False
            try:
                with open(f"/proc/{pid}/stat", encoding="utf-8") as fh:
                    return fh.read().rsplit(")", 1)[1].split()[0] != "Z"
            except (OSError, IndexError):
                return True

        for _ in range(50):
            if not alive(grandchild):
                break
            time.sleep(0.1)
        else:
            os.kill(grandchild, signal.SIGKILL)
            self.fail("the grandchild outlived its killed parent")


class TestRunInOwnGroupErrors(unittest.TestCase):
    def test_an_error_while_waiting_kills_the_group_and_is_raised(self):
        """Not reported as a budget overrun, and the child and its helpers do not outlive the failed wait."""
        from vacuum.engine import _run_in_own_group

        proc = Mock()
        proc.pid = 4242
        proc.communicate.side_effect = [OSError(errno.EIO, "Input/output error"), ("", "")]
        with patch("vacuum.engine.subprocess.Popen", return_value=proc), patch("vacuum.engine.os.killpg") as killpg:
            with self.assertRaises(OSError):
                _run_in_own_group(["/bin/true"], 5)
        killpg.assert_called_once_with(4242, signal.SIGKILL)

    def test_a_missing_group_falls_back_to_killing_the_child(self):
        from vacuum.engine import _run_in_own_group

        proc = Mock()
        proc.pid = 4242
        proc.communicate.side_effect = [subprocess.TimeoutExpired("x", 1), ("partial", "")]
        with patch("vacuum.engine.subprocess.Popen", return_value=proc), patch(
            "vacuum.engine.os.killpg", side_effect=ProcessLookupError
        ):
            code, out, _err, timed_out = _run_in_own_group(["/bin/true"], 1)
        proc.kill.assert_called_once()
        self.assertEqual((code, out, timed_out), (-1, "partial", True))


class TestSpotlightStep(_EngineHome):
    def setUp(self) -> None:
        super().setUp()
        self.pipe = self.home / "Library/Metadata/CoreSpotlight/DocumentProcessing/PipelineStorage"
        (self.pipe / "store-a" / "Journals").mkdir(parents=True)
        (self.pipe / "store-a" / "Journals" / "j1").write_bytes(b"x" * 1500)
        (self.pipe / "store-a" / "HistoricalReports").mkdir()
        (self.pipe / "store-a" / "HistoricalReports" / "h1").write_bytes(b"y" * 500)
        (self.pipe / "StateStore.db").write_bytes(b"db")

    def denied_listing(self, code):
        real = Path.iterdir
        pipe = self.pipe

        def iterdir(path):
            if path == pipe:
                raise PermissionError(code, os.strerror(code), str(path))
            return real(path)

        return patch.object(Path, "iterdir", iterdir)

    def test_a_macos_refusal_is_a_skip_and_touches_no_daemon(self):
        for code in (errno.EPERM, errno.EACCES):
            with self.denied_listing(code), patch("vacuum.engine.subprocess.run") as run:
                freed, reason, status = self.engine._spotlight_journals()
            self.assertEqual((freed, status), (0, StepStatus.SKIPPED), code)
            self.assertIn("Full Disk Access", reason)
            run.assert_not_called()  # the old step ran killall first, then failed
            self.assertTrue((self.pipe / "store-a" / "Journals" / "j1").exists())

    def test_the_refusal_is_not_a_failed_step_or_a_failed_run(self):
        from vacuum.engine import VacuumEngine

        for step_id in self.cfg["steps"]:
            self.cfg["steps"][step_id] = {"enabled": step_id in ("spotlight_journals", "pm2_logs")}
        engine = VacuumEngine(self.cfg, home=self.home)
        with self.denied_listing(errno.EPERM), patch("vacuum.engine.subprocess.run"), patch.object(
            sys, "platform", "darwin"
        ), patch("vacuum.engine.sample_mac", return_value={"disk_free_gb": 100.0, "load1": 0.0, "swap_used_pct": 0.0}):
            record = engine.run(TriggerKind.FULL)
        by_id = {s.step_id: s for s in record.steps}
        self.assertEqual(by_id["spotlight_journals"].status, StepStatus.SKIPPED)
        self.assertEqual((record.exit_code, record.outcome), (0, "ok"))

    def test_a_refusal_after_the_probe_is_still_a_skip(self):
        with patch("vacuum.engine.subprocess.run"), patch.object(
            Path, "mkdir", side_effect=PermissionError(errno.EPERM, "Operation not permitted")
        ):
            _freed, reason, status = self.engine._spotlight_journals()
        self.assertEqual(status, StepStatus.SKIPPED)
        self.assertIn("Full Disk Access", reason)

    def test_any_other_os_error_is_still_a_failure(self):
        real = Path.iterdir
        pipe = self.pipe

        def iterdir(path):
            if path == pipe:
                raise OSError(errno.EIO, "Input/output error", str(path))
            return real(path)

        with patch.object(Path, "iterdir", iterdir), self.assertRaises(OSError):
            self.engine._spotlight_journals()

    def test_with_access_it_resets_the_journals_and_counts_the_bytes(self):
        with patch("vacuum.engine.subprocess.run") as run:
            freed, reason, status = self.engine._spotlight_journals()
        run.assert_called_once()
        self.assertEqual((freed, reason, status), (2000, "journals reset", StepStatus.RAN))
        self.assertFalse((self.pipe / "store-a" / "Journals" / "j1").exists())
        self.assertTrue((self.pipe / "store-a" / "Journals").is_dir(), "an empty Journals folder is put back")
        self.assertFalse((self.pipe / "store-a" / "HistoricalReports").exists())
        self.assertFalse((self.pipe / "StateStore.db").exists())

    def test_missing_folder_is_a_skip(self):
        shutil.rmtree(self.pipe)
        self.assertEqual(self.engine._spotlight_journals()[2], StepStatus.SKIPPED)


class TestFreedBytesAreCounted(_EngineHome):
    """Total bytes freed was 0 on Oct 9 even though antigravity_brain pruned 12 folders."""

    def old(self, path: Path, days: int = 30) -> None:
        stamp = time.time() - days * 86400
        for target in [path, *path.rglob("*")]:
            os.utime(target, (stamp, stamp))

    def test_antigravity_brain(self):
        brain = self.home / ".gemini/antigravity/brain"
        (brain / "old").mkdir(parents=True)
        (brain / "old" / "f").write_bytes(b"z" * 3000)
        (brain / "new").mkdir()
        (brain / "new" / "f").write_bytes(b"z" * 100)
        self.old(brain / "old")
        freed, reason, status = self.engine._antigravity_brain()
        self.assertEqual((freed, reason, status), (3000, "pruned 1 folder", StepStatus.RAN))
        self.assertTrue((brain / "new").exists())

    def test_grok_sessions(self):
        session = self.home / ".grok/sessions/proj/019abcdef0123456789xyz"
        session.mkdir(parents=True)
        (session / "updates.jsonl").write_bytes(b"j" * 2500)
        self.old(session)
        freed, _reason, status = self.engine._grok_sessions(pressure=False)
        self.assertEqual((freed, status), (2500, StepStatus.RAN))
        self.assertFalse(session.exists())

    def test_pm2_logs(self):
        logs = self.home / ".pm2/logs"
        logs.mkdir(parents=True)
        big = logs / "app-out.log"
        with big.open("wb") as fh:
            fh.truncate(51 * 1024 * 1024)
        small = logs / "small.log"
        small.write_bytes(b"s" * 10)
        freed, reason, status = self.engine._pm2_logs()
        self.assertEqual((freed, reason, status), (51 * 1024 * 1024, "truncated 1 log in place", StepStatus.RAN))
        self.assertEqual(big.stat().st_size, 0)
        self.assertEqual(small.stat().st_size, 10)

    def test_vitest_temp_dbs(self):
        tmp = self.home / "T"
        stale = tmp / "agentic-old"
        stale.mkdir(parents=True)
        (stale / "db").write_bytes(b"d" * 700)
        self.old(stale, days=2)
        fresh = tmp / "agentic-new"
        fresh.mkdir()
        with patch("vacuum.engine.subprocess.check_output", return_value=str(tmp) + "/\n"):
            freed, reason, status = self.engine._vitest_temp_dbs()
        self.assertEqual((freed, reason, status), (700, "removed 1 stale temp db", StepStatus.RAN))
        self.assertTrue(fresh.exists())


class TestHistoryRetention(unittest.TestCase):
    """The Mac's Recent Runs line says "N checks today" from history.json, so the file has to reach back past local
    midnight.  The five minute watch tick is a record like any other, so a cap of 200 held about 14 hours."""

    @staticmethod
    def _records_per_day(intervals: dict) -> int:
        return sum(-(-86400 // int(seconds)) for seconds in intervals.values() if int(seconds) > 0)

    def test_default_cap_reaches_back_past_midnight(self):
        with tempfile.TemporaryDirectory() as td:
            cfg = load_config(home=Path(td))
        per_day = self._records_per_day(cfg["intervals_seconds"])
        # A local day is 25 hours long when the clocks go back.  Pressure and manual runs add a few more.
        needed = -(-per_day * 25 // 24) + 20
        self.assertGreaterEqual(
            cfg["history_max_runs"],
            needed,
            f"{per_day} records a day at these intervals; history_max_runs must be at least {needed} or the "
            "Mac's 'checks today' line would count a part of the day",
        )

    def test_the_fallback_matches_the_shipped_policy(self):
        policy = json.loads((REPO / "config" / "robotic-vacuum.json").read_text(encoding="utf-8"))
        self.assertEqual(policy["history_max_runs"], DEFAULT_HISTORY_MAX_RUNS)

    def _store_source(self) -> str:
        """The Mac store's source, found by content rather than by filename.

        This test reached into Sources/Storage/<name>.swift by a hardcoded name, so renaming the
        file broke it with a FileNotFoundError that said nothing about what it was looking for.
        It is the same class of coupling the Vacuum -> Maintain rename removed everywhere else,
        one layer down: the test pinned a path instead of pinning the behaviour.
        """
        matches = sorted((REPO / "Sources" / "Storage").glob("*.swift"))
        hits = [p for p in matches if "static let maxHistoryRuns" in p.read_text(encoding="utf-8")]
        self.assertEqual(
            len(hits),
            1,
            "exactly one Mac store should declare maxHistoryRuns; found "
            + ", ".join(p.name for p in hits),
        )
        return hits[0].read_text(encoding="utf-8")

    def test_the_mac_reads_at_least_what_the_engine_keeps(self):
        """MaintainStore.maxHistoryRuns bounds the rows the Mac app reads.  Below the cap it would drop the
        oldest rows, and the count would drift low."""
        found = re.search(r"static let maxHistoryRuns = (\d+)", self._store_source())
        self.assertIsNotNone(found, "MaintainStore.maxHistoryRuns not found")
        self.assertGreaterEqual(int(found.group(1)), DEFAULT_HISTORY_MAX_RUNS)

    def test_append_keeps_the_newest_runs_up_to_the_cap(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            cfg = load_config(home=home)
            cfg["data_dir"] = str(home / "rv")
            cfg["history_max_runs"] = 3
            store = VacuumStore(cfg, home=home)
            for n in range(5):
                record = RunRecord(f"r{n}", TriggerKind.WATCH, started_at=1_760_000_000.0 + n)
                store.append_run(record)
            self.assertEqual([r["run_id"] for r in store.load_history()], ["r2", "r3", "r4"])

    def test_a_config_without_the_key_uses_the_default_cap(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            cfg = load_config(home=home)
            cfg["data_dir"] = str(home / "rv")
            del cfg["history_max_runs"]
            store = VacuumStore(cfg, home=home)
            for n in range(DEFAULT_HISTORY_MAX_RUNS + 2):
                store.append_run(RunRecord(f"r{n}", TriggerKind.WATCH, started_at=1_760_000_000.0 + n))
            history = store.load_history()
            self.assertEqual(len(history), DEFAULT_HISTORY_MAX_RUNS)
            self.assertEqual(history[-1]["run_id"], f"r{DEFAULT_HISTORY_MAX_RUNS + 1}")


class TestMaintainSurface(unittest.TestCase):
    def test_maintain_py_is_the_canonical_entry(self) -> None:
        maintain = REPO / "scripts" / "maintain.py"
        self.assertTrue(maintain.is_file())
        text = maintain.read_text(encoding="utf-8")
        self.assertIn("def main(", text)

    def test_robotic_vacuum_aliases_maintain(self) -> None:
        shim = (REPO / "scripts" / "robotic-vacuum.py").read_text(encoding="utf-8")
        self.assertIn("maintain.py", shim)

    def test_registry_marks_shims_observed(self) -> None:
        from vacuum.script_registry import bootstrap_registry, is_invokable, load_registry

        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            bootstrap_registry(home, REPO, {})
            reg = load_registry(home)
            by_id = {e["id"]: e for e in reg["scripts"]}
            self.assertEqual(by_id["shim_janitor"]["mode"], "observed")
            self.assertFalse(is_invokable(by_id["shim_janitor"]))
            self.assertTrue(is_invokable(by_id["maintain_scheduler"]))

    def test_legacy_data_dir_migrates_to_maintain(self) -> None:
        from vacuum.config import migrate_legacy_support_if_needed

        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            legacy = home / "Library/Application Support/HogHunter/RoboticVacuum"
            legacy.mkdir(parents=True)
            (legacy / "status.json").write_text('{"health":"healthy"}', encoding="utf-8")
            new_root = migrate_legacy_support_if_needed(home)
            self.assertTrue((new_root / "status.json").is_file())
            self.assertFalse((legacy / "status.json").exists())

    def test_legacy_migration_continues_after_swift_moved_status(self) -> None:
        from vacuum.config import migrate_legacy_support_if_needed

        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            legacy = home / "Library/Application Support/HogHunter/RoboticVacuum"
            maintain = home / "Library/Application Support/HogHunter/Maintain"
            legacy.mkdir(parents=True)
            maintain.mkdir(parents=True)
            (maintain / "status.json").write_text('{"health":"healthy"}', encoding="utf-8")
            (legacy / "scheduler-state.json").write_text(
                '{"last_full":"2026-10-01T00:00:00Z"}', encoding="utf-8"
            )
            new_root = migrate_legacy_support_if_needed(home)
            self.assertTrue((new_root / "scheduler-state.json").is_file())
            self.assertFalse((legacy / "scheduler-state.json").exists())

    def test_load_config_reads_migrated_legacy_config(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            legacy = home / "Library/Application Support/HogHunter/RoboticVacuum"
            legacy.mkdir(parents=True)
            (legacy / "config.json").write_text(
                '{"coolify_ssh_host":"fleet.example","steps":{"coolify_remote":{"enabled":true}}}',
                encoding="utf-8",
            )
            cfg = load_config(home=home)
            self.assertEqual(cfg.get("coolify_ssh_host"), "fleet.example")
            self.assertTrue(cfg["steps"]["coolify_remote"]["enabled"])

    def test_registry_reconciles_coolify_when_host_changes(self) -> None:
        from vacuum.script_registry import bootstrap_registry, load_registry, save_registry

        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            bootstrap_registry(home, REPO, {})
            reg = load_registry(home)
            for entry in reg["scripts"]:
                if entry.get("id") == "coolify_remote":
                    entry["mode"] = "observed"
                    entry["owner"] = "stale"
            save_registry(home, reg)
            bootstrap_registry(home, REPO, {"coolify_ssh_host": "coolify.local"})
            reg = load_registry(home)
            coolify = next(e for e in reg["scripts"] if e["id"] == "coolify_remote")
            self.assertEqual(coolify["mode"], "owned")
            self.assertIn("coolify.local", coolify["owner"])

    def test_coolify_remote_stays_off_without_host(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            cfg = load_config(home=Path(td))
            self.assertFalse(cfg["steps"]["coolify_remote"]["enabled"])

    def test_status_includes_maintenance_scripts(self) -> None:
        from vacuum.scheduler import build_status

        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            cfg = load_config(home=home)
            store = VacuumStore(cfg, home=home)
            status = build_status(store, cfg)
            self.assertIn("maintenance_scripts", status)
            self.assertTrue(any(row.get("id") == "maintain_scheduler" for row in status["maintenance_scripts"]))


class TestTickWatchdog(unittest.TestCase):
    """launchd will not start a second instance of the job while one is running.

    A tick that wedges therefore stops the maintainer for good, and silently:
    the panel keeps showing the last status it wrote while the disk fills up
    anyway.  Measured 2026-10-19: a launchd tick sat in PyImport_ImportModule
    for 17 minutes and wrote nothing, while the same tick run by hand took
    seven seconds.
    """

    def test_the_watchdog_exits_the_process_when_the_tick_overruns(self):
        import maintain

        with patch.object(maintain.os, "_exit", create=True) as exit_mock:
            with patch.object(maintain.time, "sleep"):
                maintain._watchdog_exit(0.01)
        exit_mock.assert_called_once_with(3)

    def test_a_zero_budget_arms_nothing(self):
        import maintain

        before = threading.active_count()
        maintain._start_tick_watchdog(0)
        self.assertEqual(threading.active_count(), before)

    def test_the_watchdog_is_armed_for_a_scheduler_tick(self):
        import maintain

        with patch.object(maintain, "_start_tick_watchdog") as arm:
            with patch.object(maintain, "bootstrap_registry"):
                with patch.object(maintain, "run_scheduler_tick", return_value={}):
                    with patch.object(maintain, "VacuumStore") as store_cls:
                        store_cls.open.return_value.cfg = {}
                        maintain.main(["--tick", "scheduler"])
        arm.assert_called_once()
        self.assertGreater(arm.call_args[0][0], 0, "the watchdog needs a budget to fire")

    def test_the_watchdog_budget_outlasts_a_reclaim_step(self):
        """A watch tick that decides to clean runs hoghunter-clean with the
        reclaim budget plus its grace.  A watchdog shorter than that kills
        the tick mid-reclaim, leaving a half-deleted tree and no run record,
        which is the outcome the watchdog exists to prevent."""
        import maintain
        from vacuum import engine

        longest = engine._RECLAIM_BUDGET_SECONDS + engine._RECLAIM_GRACE_SECONDS
        self.assertGreater(
            maintain.TICK_WATCHDOG_SEC, longest,
            "the watchdog must sit above the longest step a tick can legitimately run",
        )

    def test_the_watchdog_is_armed_before_the_vacuum_imports(self):
        """The tick that prompted the watchdog sat in PyImport_ImportModule for
        17 minutes -- during the module-level vacuum imports, before main()
        exists.  A watchdog armed down in main() cannot see that wedge, and
        launchd still refuses to start the next tick."""
        import maintain

        source = (REPO / "scripts" / "maintain.py").read_text()
        arm_at = source.index("_start_tick_watchdog(_tick_timeout)")
        first_vacuum_import = source.index("from vacuum.alerts import")
        self.assertLess(
            arm_at, first_vacuum_import,
            "the watchdog has to be armed before the imports that wedged",
        )

    def test_the_pre_import_arm_reads_the_budget_off_argv(self):
        """main() cannot arm the watchdog early -- argparse has not run yet --
        so the pre-import arm reads --tick-timeout straight off argv."""
        import maintain

        self.assertIsNone(maintain._argv_tick_timeout(["--status"]))
        self.assertEqual(maintain._argv_tick_timeout(["--tick", "scheduler"]), maintain.TICK_WATCHDOG_SEC)
        self.assertEqual(maintain._argv_tick_timeout(["--tick", "scheduler", "--tick-timeout", "42"]), 42.0)
        self.assertEqual(maintain._argv_tick_timeout(["--tick", "scheduler", "--tick-timeout=42"]), 42.0)
        # 0 disables the watchdog, and a bad value falls back to the default.
        self.assertEqual(maintain._argv_tick_timeout(["--tick", "scheduler", "--tick-timeout", "0"]), 0.0)
        with contextlib.redirect_stderr(io.StringIO()):
            # argparse reports the bad value on the way to raising; the parse
            # is caught inside, so only main() should ever print it.
            self.assertEqual(
                maintain._argv_tick_timeout(["--tick", "scheduler", "--tick-timeout", "soon"]),
                maintain.TICK_WATCHDOG_SEC,
            )

    def test_the_pre_import_arm_agrees_with_main_on_how_to_read_the_flag(self):
        """The pre-import arm has to read --tick-timeout exactly the way main()
        does.  A scan of its own takes the first exact spelling and rejects
        abbreviations, so `--tick scheduler --tick-t 60` gave main() 60s and
        the watchdog 900s -- and because _watchdog_armed stops main() from
        arming again, the watchdog could never correct itself mid-run.

        The comparison is against main()'s real parser, built by the same
        helper main() uses.  A hand-built copy would keep passing while the
        production parsers drifted apart: the copy declared --tick without
        choices and three options where main() declares seven, so a change
        that made --tick-t ambiguous or renamed the flag would break the
        agreement the code exists to guarantee and the test would stay
        green."""
        import maintain

        for argv, expected in (
            (["--tick", "scheduler", "--tick-t", "60"], 60.0),
            (["--tick-timeout", "60", "--tick", "scheduler", "--tick-timeout", "900"], 900.0),
            (["--tick=scheduler", "--tick-timeout=60"], 60.0),
        ):
            with self.subTest(argv=argv):
                self.assertEqual(maintain._argv_tick_timeout(argv), expected)
                # Whatever the pre-import arm picks, main() must not disagree.
                parser = maintain._build_parser()
                self.assertEqual(parser.parse_args(argv).tick_timeout, expected)

    def test_both_parsers_are_built_from_one_definition(self):
        """main() and the pre-import arm must not drift apart.  They are
        separate parser objects -- one is quiet and has no help action, since
        it runs at import time -- but they have to declare the same options
        with the same defaults, or the watchdog and the tick it bounds
        disagree about the budget for the whole run."""
        import maintain

        main_parser = maintain._build_parser()
        arm_parser = maintain._build_parser(quiet=True)
        main_opts = {a.dest: a for a in main_parser._actions}
        arm_opts = {a.dest: a for a in arm_parser._actions}
        # The arm has no help action; every other option must match.
        self.assertEqual(set(arm_opts) - {"help"}, set(main_opts) - {"help"})
        for dest, action in arm_opts.items():
            if dest == "help":
                continue
            self.assertEqual(action.default, main_opts[dest].default, dest)
            self.assertEqual(action.type, main_opts[dest].type, dest)
            self.assertEqual(action.choices, main_opts[dest].choices, dest)

    def test_a_bad_flag_value_prints_nothing_from_the_pre_import_arm(self):
        """The pre-import arm parses before main() has had a chance to report
        a mistake.  argparse's default error() writes a usage block and the
        message to stderr and then exits, so a malformed --tick-timeout
        produced two usage blocks and two identical errors -- and the first
        advertised an option set the arm does not have.  The arm must be
        quiet so main() is the only reporter."""
        import maintain

        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            value = maintain._argv_tick_timeout(["--tick", "scheduler", "--tick-timeout", "soon"])
        self.assertEqual(value, maintain.TICK_WATCHDOG_SEC)
        self.assertEqual(buf.getvalue(), "", "the pre-import arm must not print anything")

    def test_a_dry_run_tick_never_arms_the_watchdog(self):
        """--dry-run promises one complete JSON document.  A watchdog armed at
        import time can fire mid-print and exit 3, truncating it, and the
        dry-run early-returns before main() would have armed anything."""
        import maintain

        self.assertIsNone(maintain._argv_tick_timeout(["--dry-run", "--tick", "scheduler"]))
        self.assertEqual(
            maintain._argv_tick_timeout(["--dry-run", "--tick", "scheduler", "--tick-timeout", "5"]),
            None,
            "a dry run must not get a watchdog at all, whatever budget it was given",
        )
        # A real tick beside it still arms.
        self.assertEqual(maintain._argv_tick_timeout(["--tick", "scheduler", "--tick-timeout", "5"]), 5.0)

    def test_a_second_arm_is_a_no_op(self):
        """The watchdog is armed once before the imports and once from main().
        Two threads would both be harmless, but one keeps the exit single."""
        import maintain

        with patch.object(maintain.threading, "Thread") as thread:
            maintain._watchdog_armed = False
            try:
                maintain._start_tick_watchdog(60)
                maintain._start_tick_watchdog(60)
            finally:
                maintain._watchdog_armed = False
        self.assertEqual(thread.call_count, 1)


class TestPartialRunRecord(unittest.TestCase):
    """A tick the watchdog kills still has to report what it reclaimed.

    A finished run is appended to the history when it completes, so a tick
    that was killed mid-work left no record at all: the panel kept showing
    the last completed run and the bytes it had already reclaimed were
    nowhere.  The engine now reports the run as it goes, and the store keeps
    the in-progress copy beside the history.
    """

    def setUp(self) -> None:
        from vacuum.engine import VacuumEngine

        self.home = Path(tempfile.mkdtemp(prefix="hhpartial-"))
        self.addCleanup(shutil.rmtree, str(self.home), True)
        self.cfg = load_config(home=self.home)
        self.cfg["housekeeper_lock"] = str(self.home / ".housekeeper.lock")
        self.cfg["data_dir"] = str(self.home / "rv")
        self.store = VacuumStore(self.cfg, home=self.home)
        self.seen = []
        self.engine = VacuumEngine(self.cfg, home=self.home, on_step=self.seen.append)

    def run_watch(self, dry_run: bool = False):
        """Run a watch tick with the disk sample and the thresholds stubbed."""
        from unittest.mock import patch

        sample = {"disk_free_gb": 100.0, "disk_sample_ok": True, "load1": 1.0}
        with patch("vacuum.engine.sample_mac", return_value=sample):
            with patch("vacuum.engine.evaluate_hits", return_value=[]):
                return self.engine.run_watch_tick({}, None, dry_run=dry_run)

    def test_a_step_reports_the_run_so_far(self):
        record, _hits, _cleaned = self.run_watch()
        self.assertEqual(len(self.seen), 1)
        self.assertEqual(self.seen[0].run_id, record.run_id)
        self.assertEqual(self.seen[0].steps[0].step_id, "resource_sample")

    def test_the_store_keeps_the_in_progress_copy(self):
        self.run_watch()
        self.store.write_partial_run(self.seen[-1])
        partial = self.store.load_partial_run()
        self.assertEqual(partial["run_id"], self.seen[-1].run_id)
        self.assertTrue(partial["steps"])

    def test_a_dry_run_writes_no_partial_record(self):
        # The dry-run contract: a plan reports what it would do and writes
        # nothing.  A plan has reclaimed nothing, so there is nothing to
        # record.
        self.run_watch(dry_run=True)
        self.assertEqual(self.seen, [])

    def test_a_finished_run_clears_the_partial_record(self):
        record, _hits, _cleaned = self.run_watch()
        self.store.write_partial_run(record)
        self.store.append_run(record)
        self.store.clear_partial_run()
        self.assertEqual(self.store.load_partial_run(), {})

    def test_the_status_shows_the_partial_run(self):
        record, _hits, _cleaned = self.run_watch()
        self.store.write_partial_run(record)
        with patch("vacuum.alerts.launchd_loaded", return_value=False):
            status = build_status(self.store, self.cfg, now=time.time())
        self.assertIsNotNone(status["partial_run"])
        self.assertEqual(status["partial_run"]["run_id"], record.run_id)

    def test_a_finished_run_leaves_no_partial_in_the_status(self):
        record, _hits, _cleaned = self.run_watch()
        self.store.append_run(record)
        self.store.clear_partial_run()
        with patch("vacuum.alerts.launchd_loaded", return_value=False):
            status = build_status(self.store, self.cfg, now=time.time())
        self.assertIsNone(status["partial_run"])

    def test_a_partial_older_than_a_completed_run_is_ignored(self):
        # A run that finishes through a path that never clears the partial
        # copy (the CLI's --run-now) must not be overwritten by a killed tick
        # that came before it.
        import dataclasses

        killed, _hits, _cleaned = self.run_watch()
        self.store.write_partial_run(killed)
        later = dataclasses.replace(killed, run_id="later-run", started_at=killed.started_at + 60)
        self.store.append_run(later)
        with patch("vacuum.alerts.launchd_loaded", return_value=False):
            status = build_status(self.store, self.cfg, now=time.time())
        self.assertIsNone(status["partial_run"])

    def test_a_partial_newer_than_every_completed_run_is_kept(self):
        import dataclasses

        done, _hits, _cleaned = self.run_watch()
        self.store.append_run(done)
        killed = dataclasses.replace(done, run_id="killed-run", started_at=done.started_at + 60)
        self.store.write_partial_run(killed)
        with patch("vacuum.alerts.launchd_loaded", return_value=False):
            status = build_status(self.store, self.cfg, now=time.time())
        self.assertEqual(status["partial_run"]["run_id"], "killed-run")


class TestTickBudget(unittest.TestCase):
    """The reclaim budget has to fit inside the tick the watchdog kills.

    The two numbers used to be written down in two files, so a change to one
    could leave the other too small -- and a reclaim step that overruns the
    watchdog gets cut off mid-work.  The budget is now derived from the
    watchdog, and these tests hold the two together.
    """

    def test_the_budget_is_derived_from_the_watchdog(self):
        from vacuum.config import TICK_WATCHDOG_SEC
        from vacuum.engine import (
            _RECLAIM_BUDGET_SECONDS,
            _RECLAIM_GRACE_SECONDS,
            _RECLAIM_RESERVE_SECONDS,
        )

        self.assertEqual(
            _RECLAIM_BUDGET_SECONDS,
            int(TICK_WATCHDOG_SEC) - _RECLAIM_GRACE_SECONDS - _RECLAIM_RESERVE_SECONDS,
        )

    def test_the_budget_plus_the_grace_stays_inside_the_watchdog(self):
        from vacuum.config import TICK_WATCHDOG_SEC
        from vacuum.engine import _RECLAIM_BUDGET_SECONDS, _RECLAIM_GRACE_SECONDS

        self.assertLess(
            _RECLAIM_BUDGET_SECONDS + _RECLAIM_GRACE_SECONDS,
            TICK_WATCHDOG_SEC,
            "a reclaim that overruns the watchdog gets cut off mid-work",
        )

    def test_maintain_arms_the_same_watchdog_the_engine_derives_from(self):
        import maintain
        from vacuum.config import TICK_WATCHDOG_SEC

        self.assertEqual(maintain.TICK_WATCHDOG_SEC, TICK_WATCHDOG_SEC)

    def test_the_watchdog_config_is_a_leaf_module(self):
        """maintain.py imports the watchdog number from vacuum.config before
        the watchdog is armed, because the number has to be known to arm it.

        That is only safe while vacuum.config stays a leaf module.  It must
        not pull in the engine, which is where the 17-minute import wedge
        lived, and a wedge there would happen before any watchdog was armed.
        """
        code = (
            "import sys; sys.path.insert(0, %r); import vacuum.config; "
            "print('vacuum.engine' in sys.modules)" % str(REPO / "scripts")
        )
        out = subprocess.run(
            [sys.executable, "-c", code], capture_output=True, text=True, timeout=120
        )
        self.assertEqual(out.stdout.strip(), "False", out.stderr)


class TestHousekeeperLock(unittest.TestCase):
    """The lock that keeps two reclaimers off the same files.

    The owner file is what makes a killed holder recoverable at once.  The
    watchdog in scripts/maintain.py exits with os._exit, which skips the
    lock's __exit__, so the lock directory used to survive a killed tick and
    every tick after it reported "peer holds lock" until the two hour stale
    window expired.  The Hog Hunter vacuum had not completed a tick in six
    days because of it.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.lock_path = Path(self.tmp.name) / ".housekeeper.lock"
        os.environ.pop("HOUSEKEEPER_LOCK_OWNER", None)

    def tearDown(self):
        os.environ.pop("HOUSEKEEPER_LOCK_OWNER", None)
        self.tmp.cleanup()

    def _owner_record(self, pid=None, host=None, start=None):
        """A well formed owner record: the shape this protocol publishes.

        The tests below used to write a bare ``{"pid": ...}``, which is not a
        record any implementation of this protocol accepts:  it names no
        host, no start time and no lock.  A record the readers reject is not
        evidence of anything, so those cases were passing without testing
        what they claimed to test.
        """
        import socket

        from vacuum.lock import _process_start_token

        if pid is None:
            pid = 999999
        if host is None:
            host = socket.gethostname()
        if start is None:
            # A pid that is not alive has no start time of its own, so a
            # placeholder stands in for it:  the record only has to be well
            # formed, and a dead pid is proven gone without reading a token.
            start = _process_start_token(pid) or "Mon Jan  1 00:00:00 2024"
        return {
            "pid": pid,
            "host": host,
            "acquired_at": time.time(),
            "lock": str(self.lock_path),
            "start": start,
        }

    def _write_owner_record(self, **kwargs):
        from vacuum.lock import owner_path_for

        owner_path_for(self.lock_path).write_text(json.dumps(self._owner_record(**kwargs)))

    def _live_process_pid(self):
        """The pid of a live process that is not this one.

        The "our own pid" guard decides the case before the start token is
        ever read, so a reused-pid case needs a holder that is somebody
        else.
        """
        child = subprocess.Popen(["sleep", "30"])

        def cleanup():
            child.terminate()
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                child.kill()

        self.addCleanup(cleanup)
        return child.pid

    def test_acquire_writes_an_owner_file_beside_the_lock(self):
        from vacuum.lock import HousekeeperLock, owner_path_for

        with HousekeeperLock(self.lock_path):
            owner = owner_path_for(self.lock_path)
            self.assertTrue(owner.is_file(), "the owner file records who holds the lock")
            data = json.loads(owner.read_text())
            self.assertEqual(data["pid"], os.getpid())

    def test_the_owner_record_has_exactly_the_shape_the_protocol_publishes(self):
        # All four implementations of this protocol publish the SAME shape.
        # A record one of them calls malformed and the other calls usable
        # leaves them with conflicting ownership decisions about one lock.
        from vacuum.lock import HousekeeperLock, owner_path_for

        with HousekeeperLock(self.lock_path):
            data = json.loads(owner_path_for(self.lock_path).read_text())
            self.assertEqual(
                set(data),
                {"pid", "host", "acquired_at", "lock", "start"},
                "every implementation of this protocol publishes the same shape",
            )

    def test_the_owner_record_carries_the_start_time_of_this_process(self):
        # The start time travels with the pid, because a pid the kernel has
        # since handed to somebody else would otherwise look exactly like a
        # live holder.
        from vacuum.lock import HousekeeperLock, _process_start_token, owner_path_for

        with HousekeeperLock(self.lock_path):
            data = json.loads(owner_path_for(self.lock_path).read_text())
            self.assertEqual(
                data["start"],
                _process_start_token(os.getpid()),
                "the record carries the start time of the process that holds the lock",
            )

    def test_the_owner_record_is_private_to_the_user(self):
        # The record names a pid and a host and sits in a shared directory.
        from vacuum.lock import HousekeeperLock, owner_path_for

        with HousekeeperLock(self.lock_path):
            owner = owner_path_for(self.lock_path)
            self.assertEqual(
                owner.stat().st_mode & 0o777,
                0o600,
                "the owner record is private to the user",
            )

    def test_the_lock_directory_stays_empty_for_the_shell_rmdir(self):
        # ~/apps/mac-auto-cleanup.sh releases the lock with a plain rmdir, and
        # rmdir refuses a directory that has anything in it.  An owner file
        # inside the lock would make the shell's release silently fail and
        # leak the lock forever.
        from vacuum.lock import HousekeeperLock, owner_path_for

        with HousekeeperLock(self.lock_path):
            self.assertEqual(list(self.lock_path.iterdir()), [])
            self.assertTrue(owner_path_for(self.lock_path).is_file())

    def test_release_removes_the_owner_file(self):
        from vacuum.lock import HousekeeperLock, owner_path_for

        with HousekeeperLock(self.lock_path):
            pass
        self.assertFalse(owner_path_for(self.lock_path).exists())
        self.assertFalse(self.lock_path.exists())

    def test_a_lock_whose_owner_is_gone_is_taken_over_at_once(self):
        from vacuum.lock import HousekeeperLock

        self.lock_path.mkdir(parents=True)
        # A pid above the system maximum cannot name a live process, so this
        # is what a lock left behind by a killed tick looks like.
        self._write_owner_record(pid=999999)

        with HousekeeperLock(self.lock_path):
            self.assertTrue(self.lock_path.is_dir(), "the dead owner's lock was taken over")

    def test_a_lock_whose_owner_is_alive_is_refused(self):
        from vacuum.lock import HousekeeperLock, LockHeld

        self.lock_path.mkdir(parents=True)
        self._write_owner_record(pid=os.getpid())

        with self.assertRaises(LockHeld):
            with HousekeeperLock(self.lock_path):
                pass

    def test_a_reused_pid_is_taken_over_at_once(self):
        # The kernel hands a pid to somebody else once the original exits, and
        # a reused pid that is ALIVE looks exactly like a live holder.  The
        # start time is what tells the two apart.
        from vacuum.lock import HousekeeperLock

        pid = self._live_process_pid()
        self.lock_path.mkdir(parents=True)
        self._write_owner_record(pid=pid, start="Mon Jan  1 00:00:00 2024")

        with HousekeeperLock(self.lock_path):
            self.assertTrue(
                self.lock_path.is_dir(),
                "a reused pid is taken over at once, not after the stale window",
            )

    def test_a_live_holder_with_the_right_start_time_is_refused(self):
        from vacuum.lock import HousekeeperLock, LockHeld, _process_start_token

        pid = self._live_process_pid()
        self.lock_path.mkdir(parents=True)
        self._write_owner_record(pid=pid, start=_process_start_token(pid))

        with self.assertRaises(LockHeld):
            with HousekeeperLock(self.lock_path):
                pass

    def test_an_owner_record_without_the_start_time_is_not_evidence(self):
        # A record that is not the record this protocol publishes names no
        # holder, so the age rule decides.
        import socket

        from vacuum.lock import HousekeeperLock, LockHeld, owner_path_for

        self.lock_path.mkdir(parents=True)
        owner_path_for(self.lock_path).write_text(
            json.dumps({"pid": 999999, "host": socket.gethostname()})
        )

        with self.assertRaises(LockHeld):
            with HousekeeperLock(self.lock_path):
                pass

    def test_an_owner_record_with_an_unknown_key_is_not_evidence(self):
        from vacuum.lock import HousekeeperLock, LockHeld, owner_path_for

        self.lock_path.mkdir(parents=True)
        record = self._owner_record(pid=999999)
        record["extra"] = "not part of the record"
        owner_path_for(self.lock_path).write_text(json.dumps(record))

        with self.assertRaises(LockHeld):
            with HousekeeperLock(self.lock_path):
                pass

    def test_an_owner_record_with_a_boolean_pid_is_not_evidence(self):
        from vacuum.lock import HousekeeperLock, LockHeld, owner_path_for

        self.lock_path.mkdir(parents=True)
        record = self._owner_record(pid=999999)
        record["pid"] = True
        owner_path_for(self.lock_path).write_text(json.dumps(record))

        with self.assertRaises(LockHeld):
            with HousekeeperLock(self.lock_path):
                pass

    def test_a_fresh_lock_with_no_owner_file_is_not_taken_over(self):
        # The shell holder never writes an owner file, so a missing one is not
        # proof of anything.  The age rule decides.
        from vacuum.lock import HousekeeperLock, LockHeld

        self.lock_path.mkdir(parents=True)
        with self.assertRaises(LockHeld):
            with HousekeeperLock(self.lock_path):
                pass

    def test_a_stale_lock_with_no_owner_file_is_still_taken_over(self):
        from vacuum.lock import HousekeeperLock

        self.lock_path.mkdir(parents=True)
        old = time.time() - (121 * 60)
        os.utime(self.lock_path, (old, old))
        with HousekeeperLock(self.lock_path):
            self.assertTrue(self.lock_path.is_dir())

    def test_force_release_gives_the_lock_back(self):
        from vacuum.lock import HousekeeperLock, force_release, owner_path_for

        lock = HousekeeperLock(self.lock_path)
        lock.__enter__()
        self.assertTrue(self.lock_path.is_dir())

        self.assertTrue(force_release(), "force_release releases the lock this process holds")
        self.assertFalse(self.lock_path.exists())
        self.assertFalse(owner_path_for(self.lock_path).exists())

    def test_force_release_leaves_a_peers_lock_alone(self):
        from vacuum.lock import HousekeeperLock, force_release

        self.lock_path.mkdir(parents=True)
        self._write_owner_record(pid=999999)

        self.assertFalse(force_release(), "a lock this process does not hold is not released")
        self.assertTrue(self.lock_path.is_dir())

    def test_a_leftover_owner_file_does_not_unlock_a_fresh_lock(self):
        # The shell holder never writes an owner file, so an owner file left
        # beside the lock can name a pid that is long gone.  Reading it as the
        # current holder would let a fresh, live lock be taken over.  The
        # owner file only describes the holder when it is STRICTLY newer than
        # the lock directory.
        from vacuum.lock import HousekeeperLock, LockHeld, owner_path_for

        self.lock_path.mkdir(parents=True)
        owner = owner_path_for(self.lock_path)
        self._write_owner_record(pid=999999)
        # The lock directory is newer than the owner file, so the owner file
        # is a leftover from an earlier holder.
        now = time.time()
        os.utime(owner, (now - 600, now - 600))
        os.utime(self.lock_path, (now, now))

        with self.assertRaises(LockHeld):
            with HousekeeperLock(self.lock_path):
                pass

    def test_a_stale_lock_is_moved_aside_and_leaves_nothing_behind(self):
        # The takeover is a rename, not a remove and a create: checking that
        # a lock is stale and then removing it is two steps, and two
        # reclaimers can interleave them so that both end up believing they
        # hold it.  Moving it aside lets only one caller win.
        from vacuum.lock import HousekeeperLock

        self.lock_path.mkdir(parents=True)
        old = time.time() - (121 * 60)
        os.utime(self.lock_path, (old, old))

        with HousekeeperLock(self.lock_path):
            self.assertTrue(self.lock_path.is_dir())
            leftovers = [p for p in Path(self.tmp.name).iterdir() if ".stale-" in p.name]
            self.assertEqual(leftovers, [], "a taken-over stale lock leaves no moved-aside copy")

    def test_a_fresh_lock_that_was_displaced_is_put_back(self):
        # The move acts on whatever is at the path at that instant.  When a
        # peer had already replaced the stale lock, that is the peer's fresh
        # lock, and it is put back rather than removed.
        from vacuum.lock import HousekeeperLock

        self.lock_path.mkdir(parents=True)
        lock = HousekeeperLock(self.lock_path)
        self.assertFalse(lock._takeover(), "a fresh lock is not taken")
        self.assertTrue(self.lock_path.is_dir(), "the displaced fresh lock was put back")

    def test_a_non_empty_lock_is_put_back(self):
        # The lock is a marker: a directory with contents in it is not the
        # marker we made, so it is put back rather than removed.
        from vacuum.lock import HousekeeperLock

        self.lock_path.mkdir(parents=True)
        (self.lock_path / "leftover.txt").write_text("not ours")
        old = time.time() - (121 * 60)
        os.utime(self.lock_path, (old, old))

        lock = HousekeeperLock(self.lock_path)
        self.assertFalse(lock._takeover(), "a lock with contents in it is not taken")
        self.assertTrue(self.lock_path.is_dir())
        self.assertTrue((self.lock_path / "leftover.txt").exists())

    def test_the_put_back_refuses_an_occupied_path_and_leaves_the_peer_alone(self):
        # os.rename onto an existing EMPTY directory SUCCEEDS and replaces it,
        # and the lock marker is an empty directory, so a put-back built on a
        # plain rename replaces a third reclaimer's fresh lock while that
        # reclaimer still believes it holds the lock and sweeps at the same
        # time.  The refusal has to be the atomic one.
        from vacuum.lock import HousekeeperLock

        aside = self.lock_path.with_name(f"{self.lock_path.name}.stale-test")
        aside.mkdir(parents=True)
        self.lock_path.mkdir(parents=True)
        # The peer's lock is an empty marker, and the inode is what tells the
        # two apart: a replaced directory has a new one.
        peer_inode = self.lock_path.stat().st_ino

        lock = HousekeeperLock(self.lock_path)
        lock._put_back(aside)

        self.assertEqual(
            self.lock_path.stat().st_ino,
            peer_inode,
            "the peer's lock must not have been replaced",
        )
        self.assertTrue(aside.is_dir(), "the moved-aside copy stays where it is")

    def test_the_put_back_moves_onto_a_free_path(self):
        from vacuum.lock import HousekeeperLock

        aside = self.lock_path.with_name(f"{self.lock_path.name}.stale-test")
        aside.mkdir(parents=True)

        lock = HousekeeperLock(self.lock_path)
        lock._put_back(aside)

        self.assertTrue(self.lock_path.is_dir())
        self.assertFalse(aside.exists())

    def test_the_put_back_never_goes_through_os_rename(self):
        # os.rename is the primitive that replaces an empty directory, so a
        # put-back that used it would still have the window even with a check
        # in front of it.
        #
        # This is a macOS property.  The atomic no-replace rename is
        # renamex_np, which only macOS has, and the fallback on any other
        # platform is a check followed by a rename.  The lock this file
        # guards runs on the Mac; the suite also runs on Linux in CI, where
        # the assertion below does not hold and the weaker fallback is used.
        from vacuum import lock as lock_module

        if lock_module._renamex_np() is None:
            self.skipTest("the atomic no-replace rename is macOS-only")

        calls = []
        real_rename = lock_module.os.rename

        def spy(src, dst, *args, **kwargs):
            calls.append((str(src), str(dst)))
            return real_rename(src, dst, *args, **kwargs)

        aside = self.lock_path.with_name(f"{self.lock_path.name}.stale-test")
        aside.mkdir(parents=True)
        lock_module.os.rename = spy
        try:
            lock = lock_module.HousekeeperLock(self.lock_path)
            lock._put_back(aside)
        finally:
            lock_module.os.rename = real_rename

        self.assertEqual(calls, [], "the put-back must not go through os.rename")
        self.assertTrue(self.lock_path.is_dir(), "the put-back still moved the copy back")

    def test_the_owner_file_is_only_removed_when_it_names_the_moved_holder(self):
        # The owner file belongs to the holder we moved aside.  Removing it
        # when it names somebody else takes away the new holder's own file.
        from vacuum.lock import HousekeeperLock, owner_path_for

        self.lock_path.mkdir(parents=True)
        owner = owner_path_for(self.lock_path)
        self._write_owner_record(pid=999999)
        old = time.time() - (121 * 60)
        os.utime(self.lock_path, (old, old))

        with HousekeeperLock(self.lock_path):
            data = json.loads(owner.read_text())
            self.assertEqual(data["pid"], os.getpid(), "the new holder's own owner file is in place")

    def test_only_one_of_two_takers_wins_the_stale_lock(self):
        from vacuum.lock import HousekeeperLock, LockHeld

        self.lock_path.mkdir(parents=True)
        old = time.time() - (121 * 60)
        os.utime(self.lock_path, (old, old))

        with HousekeeperLock(self.lock_path):
            # The re-entrancy token would let a second attempt through, so it
            # is cleared to model a second, independent reclaimer.
            os.environ.pop("HOUSEKEEPER_LOCK_OWNER", None)
            with self.assertRaises(LockHeld):
                with HousekeeperLock(self.lock_path):
                    pass

    def test_a_fresh_lock_whose_owner_died_a_minute_ago_is_taken_over(self):
        # A tick killed a minute ago leaves a *fresh* directory behind.  The
        # age rule alone would refuse it, and the vacuum would keep reporting
        # "peer holds lock" until the two hour window expired -- which is the
        # six day wedge the owner file was added to undo.
        from vacuum.lock import HousekeeperLock, owner_path_for

        self.lock_path.mkdir(parents=True)
        self._write_owner_record(pid=999999)

        with HousekeeperLock(self.lock_path):
            self.assertTrue(self.lock_path.is_dir(), "the dead owner's fresh lock was taken over")

    def test_an_owner_file_with_an_unreadable_pid_does_not_break_the_acquire(self):
        # The owner file is read by a peer that wants to know whether the
        # holder is still alive.  A pid that cannot be read is no owner at
        # all, and reading it must not raise out of the lock.
        from vacuum.lock import HousekeeperLock, LockHeld, owner_path_for

        self.lock_path.mkdir(parents=True)
        record = self._owner_record(pid=999999)
        record["pid"] = "not-a-pid"
        owner_path_for(self.lock_path).write_text(json.dumps(record))

        with self.assertRaises(LockHeld):
            with HousekeeperLock(self.lock_path):
                pass

    def test_an_owner_file_with_an_unreadable_pid_does_not_break_the_release(self):
        from vacuum.lock import HousekeeperLock, owner_path_for

        lock = HousekeeperLock(self.lock_path)
        lock.__enter__()
        record = self._owner_record(pid=os.getpid())
        record["pid"] = None
        owner_path_for(self.lock_path).write_text(json.dumps(record))
        lock.__exit__(None, None, None)
        self.assertFalse(self.lock_path.exists())

    def test_the_owner_file_is_published_with_a_replace(self):
        # The owner file is published with a replace rather than written in
        # place, so a reader never sees half of it.
        from vacuum import lock as lock_module

        owner = lock_module.owner_path_for(self.lock_path)
        owner.parent.mkdir(parents=True, exist_ok=True)
        calls = []
        real_replace = lock_module.os.replace

        def spy(src, dst, *args, **kwargs):
            calls.append((str(src), str(dst)))
            return real_replace(src, dst, *args, **kwargs)

        lock_module.os.replace = spy
        try:
            lock_module._write_owner(owner, self.lock_path)
        finally:
            lock_module.os.replace = real_replace

        self.assertTrue(calls, "the owner file is published with a replace")
        src, dst = calls[-1]
        self.assertEqual(dst, str(owner))
        self.assertEqual(Path(src).parent, owner.parent, "the temp file is beside the owner file")
        self.assertFalse(Path(src).exists(), "the temp file is gone")
        self.assertEqual(json.loads(owner.read_text())["pid"], os.getpid())

    def test_a_failed_owner_publish_leaves_the_owner_file_untouched(self):
        from vacuum import lock as lock_module

        owner = lock_module.owner_path_for(self.lock_path)
        owner.parent.mkdir(parents=True, exist_ok=True)
        owner.write_text(json.dumps({"pid": 1, "host": "keep-me"}))

        real_replace = lock_module.os.replace

        def boom(src, dst, *args, **kwargs):
            raise OSError("publish failed")

        lock_module.os.replace = boom
        try:
            lock_module._write_owner(owner, self.lock_path)
        finally:
            lock_module.os.replace = real_replace

        self.assertEqual(
            json.loads(owner.read_text()).get("host"),
            "keep-me",
            "a failed publish must leave the owner file exactly as it was",
        )

    def test_a_lock_held_on_another_host_is_not_taken_over_at_once(self):
        # A pid only means something on the machine that owns it, so a lock
        # held on another host may only be taken over once the stale window
        # has passed.
        from vacuum.lock import HousekeeperLock, LockHeld

        self.lock_path.mkdir(parents=True)
        self._write_owner_record(pid=999999, host="some-other-machine")

        with self.assertRaises(LockHeld):
            with HousekeeperLock(self.lock_path):
                pass

    def test_a_lock_whose_owner_is_gone_on_this_host_is_still_taken_over_at_once(self):
        from vacuum.lock import HousekeeperLock

        self.lock_path.mkdir(parents=True)
        self._write_owner_record(pid=999999)

        with HousekeeperLock(self.lock_path):
            self.assertTrue(self.lock_path.is_dir(), "a dead holder on this host is taken over")

    def test_a_failed_removal_leaves_the_owner_file_so_the_lock_is_still_recoverable(self):
        # The lock directory goes first and the owner file second.  The
        # other order strands the lock: a removal that fails after the
        # owner file is gone leaves a lock that nobody owns and that
        # nothing can take over until the whole stale window has passed.
        from vacuum.lock import HousekeeperLock, owner_path_for

        with HousekeeperLock(self.lock_path):
            (self.lock_path / "leftover.txt").write_text("not ours")

        # The lock directory has something in it, so it cannot be removed.
        self.assertTrue(self.lock_path.is_dir())
        self.assertTrue(
            owner_path_for(self.lock_path).is_file(),
            "a lock that could not be removed keeps its owner file",
        )

    def test_a_takeover_that_replaces_the_canonical_lock_between_the_check_and_the_removal_keeps_the_new_holders_lock(self):
        # The check and the removal are two steps, and a takeover can slip
        # between them: the check says "this is the lock I took", a new
        # holder replaces the path with its own lock, and the removal then
        # takes the NEW holder's lock away while that holder goes on
        # believing it holds the lock.
        from vacuum import lock as lock_module

        lock = lock_module.HousekeeperLock(self.lock_path)
        lock.__enter__()

        real_rmdir = lock_module.os.rmdir
        injected = {"done": False}

        def spy(path):
            if not injected["done"]:
                injected["done"] = True
                # The takeover: a new holder replaces the canonical lock
                # with its own, right here in the window.
                self.lock_path.mkdir(parents=True, exist_ok=True)
                lock_module.owner_path_for(self.lock_path).write_text(
                    json.dumps({
                        "pid": 999999,
                        "host": socket.gethostname(),
                        "acquired_at": time.time(),
                        "lock": str(self.lock_path),
                        "start": "Mon Jan  1 00:00:00 2024",
                    })
                )
            return real_rmdir(path)

        lock_module.os.rmdir = spy
        try:
            lock.__exit__(None, None, None)
        finally:
            lock_module.os.rmdir = real_rmdir

        self.assertTrue(
            self.lock_path.is_dir(),
            "the new holder's lock must not be lost by the release",
        )
        owner = lock_module.owner_path_for(self.lock_path)
        self.assertTrue(owner.is_file(), "the new holder's owner file must survive too")
        self.assertEqual(json.loads(owner.read_text())["pid"], 999999)


# A contender that tries to take the housekeeper lock the way a peer does.
# It writes a marker first, so the parent knows it is running, and it
# reports whether it got the lock.  It never releases the lock it took: the
# question is whether the lock survived the race.
CONTENDER_SCRIPT = """
import json, os, sys
from pathlib import Path
sys.path.insert(0, sys.argv[3])
from vacuum.lock import HousekeeperLock, LockHeld
lock_path = Path(sys.argv[1])
report = Path(sys.argv[2])
Path(sys.argv[4]).write_text("started")
result = {"acquired": False, "error": None}
try:
    lock = HousekeeperLock(lock_path)
    lock.__enter__()
    result["acquired"] = True
except LockHeld as exc:
    result["error"] = str(exc)
except Exception as exc:
    result["error"] = repr(exc)
report.write_text(json.dumps(result))
os._exit(0)
"""

# A process that takes the mutation guard and holds it for a while, the way
# the shell side does while it is clearing the lock.
GUARD_HOLDER_SCRIPT = """
import fcntl, os, sys, time
path = sys.argv[1]
ready = sys.argv[2]
seconds = float(sys.argv[3])
fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
open(ready, "w").write("held")
time.sleep(seconds)
fcntl.flock(fd, fcntl.LOCK_UN)
os.close(fd)
"""


class TestHousekeeperLockGuard(unittest.TestCase):
    """The mutation guard that every writer of the housekeeper protocol shares.

    The same guard is taken by HogHunter's Python lock and Swift lock, and
    by AFC's `mac-auto-cleanup.sh` and `mac-resource-watch.py`.  It is a
    plain file beside the lock directory, held with an exclusive `flock`
    over the whole critical section, and it is never deleted.

    The tests here use a REAL second process, because the whole point of
    the guard is that it works across processes.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.lock_path = Path(self.tmp.name) / ".housekeeper.lock"
        self.guard_path = self.lock_path.with_name(self.lock_path.name + ".guard")
        os.environ.pop("HOUSEKEEPER_LOCK_OWNER", None)

    def tearDown(self):
        os.environ.pop("HOUSEKEEPER_LOCK_OWNER", None)
        self.tmp.cleanup()

    def _child_env(self) -> dict:
        env = dict(os.environ)
        env.pop("HOUSEKEEPER_LOCK_OWNER", None)
        return env

    def test_the_guard_is_a_sibling_file_beside_the_lock(self):
        from vacuum.lock import HousekeeperLock

        with HousekeeperLock(self.lock_path):
            self.assertTrue(self.guard_path.is_file(), "the guard is a plain file")
            self.assertFalse(self.guard_path.is_dir(), "the guard is not a directory")
            self.assertEqual(self.guard_path.parent, self.lock_path.parent)
            self.assertEqual(self.guard_path.name, self.lock_path.name + ".guard")
            self.assertEqual(
                list(self.lock_path.iterdir()),
                [],
                "the guard is a sibling, never inside the lock",
            )

    def test_the_guard_file_is_never_deleted(self):
        from vacuum.lock import HousekeeperLock

        with HousekeeperLock(self.lock_path):
            self.assertTrue(self.guard_path.is_file())
        self.assertTrue(
            self.guard_path.is_file(),
            "the guard file is never deleted: deleting it would split the flock",
        )

    def test_a_contender_cannot_publish_an_owner_file_while_the_guard_is_held(self):
        # The guard is the cross-process mutex for the whole housekeeper
        # protocol.  A contender that tries to take the lock while another
        # process holds the guard has to wait, and it must not publish an
        # owner file while it waits.
        import fcntl

        from vacuum.lock import HousekeeperLock, owner_path_for

        self.guard_path.parent.mkdir(parents=True, exist_ok=True)
        report = Path(self.tmp.name) / "contender.json"
        started = Path(self.tmp.name) / "contender.started"
        fd = os.open(str(self.guard_path), os.O_RDWR | os.O_CREAT, 0o600)
        child = None
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            child = subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    CONTENDER_SCRIPT,
                    str(self.lock_path),
                    str(report),
                    str(REPO / "scripts"),
                    str(started),
                ],
                env=self._child_env(),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
            deadline = time.time() + 30
            while time.time() < deadline and not started.exists():
                time.sleep(0.02)
            self.assertTrue(started.exists(), "the contender started")
            # Give the contender time to reach the guard.
            time.sleep(0.5)
            self.assertFalse(
                owner_path_for(self.lock_path).exists(),
                "a contender must not publish an owner file while the guard is held",
            )
            self.assertFalse(report.exists(), "a contender must wait for the guard")
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)
        if child is not None:
            try:
                child.wait(timeout=30)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=10)
        self.assertTrue(
            report.exists(),
            "the contender goes through once the guard is free",
        )
        data = json.loads(report.read_text())
        self.assertTrue(data["acquired"], data)

    def test_the_release_waits_for_a_guard_another_process_holds(self):
        # The release holds the guard across its ownership check and its
        # removal, so a peer that holds the guard holds the release up.
        from vacuum.lock import HousekeeperLock

        self.guard_path.parent.mkdir(parents=True, exist_ok=True)
        # The lock is taken first, so the only thing the release has to wait
        # for is the guard.
        lock = HousekeeperLock(self.lock_path)
        lock.__enter__()
        ready = Path(self.tmp.name) / "holder.ready"
        holder = subprocess.Popen(
            [sys.executable, "-c", GUARD_HOLDER_SCRIPT, str(self.guard_path), str(ready), "2"],
            env=self._child_env(),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        try:
            deadline = time.time() + 30
            while time.time() < deadline and not ready.exists():
                time.sleep(0.02)
            self.assertTrue(ready.exists(), "the other process holds the guard")

            started = time.time()
            lock.__exit__(None, None, None)
            elapsed = time.time() - started
        finally:
            try:
                holder.wait(timeout=30)
            except subprocess.TimeoutExpired:
                holder.kill()
                holder.wait(timeout=10)
        self.assertGreaterEqual(
            elapsed,
            1.0,
            "the release must wait for the guard another process holds",
        )


class TestCadenceSelection(unittest.TestCase):
    """One cadence per tick.

    A tick used to run every due cadence back to back in the same process.
    Measured on this host 2026-10-21: watch took 279s and janitor 117s, and
    a full reclaim has a 600s budget plus a 180s grace, so a tick with all
    three due wanted 1176s against a 900s watchdog.  The watchdog killed the
    tick, and the kill leaked the housekeeper lock.
    """

    def _store(self, td: str, intervals: dict) -> "VacuumStore":
        home = Path(td)
        data = home / "rv"
        data.mkdir(parents=True)
        cfg = load_config(home=home)
        cfg["data_dir"] = str(data)
        cfg["intervals_seconds"] = intervals
        return VacuumStore(cfg, home=home)

    def test_only_one_cadence_is_selected(self):
        from vacuum.scheduler import select_cadences

        with tempfile.TemporaryDirectory() as td:
            store = self._store(td, {"watch": 1, "janitor": 1, "full": 1})
            now = time.time()
            selected = select_cadences(store, store.cfg, now=now)
            self.assertEqual(len(selected), 1, selected)

    def test_the_most_overdue_cadence_wins(self):
        from vacuum.scheduler import select_cadences

        with tempfile.TemporaryDirectory() as td:
            store = self._store(td, {"watch": 300, "janitor": 1800, "full": 14400})
            now = time.time()
            # The watch ran a moment ago, the janitor long ago, the full never.
            store.touch_scheduler("last_watch", now - 310)
            store.touch_scheduler("last_janitor", now - 3600)
            store.touch_scheduler("last_full", now - 40000)
            selected = select_cadences(store, store.cfg, now=now)
            self.assertEqual(selected, ["full"], selected)

    def test_a_tie_goes_to_the_longest_interval(self):
        # The four-hourly full reclaim must not be pushed aside by the
        # five-minute watch every time the two come due together.
        from vacuum.scheduler import select_cadences

        with tempfile.TemporaryDirectory() as td:
            store = self._store(td, {"watch": 300, "janitor": 1800, "full": 14400})
            now = time.time()
            store.touch_scheduler("last_watch", now - 300)
            store.touch_scheduler("last_janitor", now - 1800)
            store.touch_scheduler("last_full", now - 14400)
            selected = select_cadences(store, store.cfg, now=now)
            self.assertEqual(selected, ["full"], selected)

    def test_a_cadence_that_is_not_due_is_not_selected(self):
        from vacuum.scheduler import select_cadences

        with tempfile.TemporaryDirectory() as td:
            store = self._store(td, {"watch": 300, "janitor": 1800, "full": 14400})
            now = time.time()
            store.touch_scheduler("last_watch", now)
            store.touch_scheduler("last_janitor", now)
            store.touch_scheduler("last_full", now)
            self.assertEqual(select_cadences(store, store.cfg, now=now), [])

    def test_a_skipped_cadence_stays_due_and_grows_more_overdue(self):
        # Nothing waits long: a cadence the tick did not run keeps its
        # overdue time growing, so it is the next one to be picked.  The
        # simulation below walks the real intervals and asserts that every
        # cadence gets a turn, so no one of them is starved.
        from vacuum.scheduler import overdue_seconds, select_cadences

        with tempfile.TemporaryDirectory() as td:
            store = self._store(td, {"watch": 300, "janitor": 1800, "full": 14400})
            now = time.time()
            store.touch_scheduler("last_watch", now - 300)
            store.touch_scheduler("last_janitor", now - 1800)
            store.touch_scheduler("last_full", now - 14400)

            # The full reclaim has been waiting longest and has the longest
            # interval, so it is the one that runs.
            self.assertEqual(select_cadences(store, store.cfg, now=now), ["full"])

            ran = []
            clock = now
            for _ in range(120):
                clock += 300
                selected = select_cadences(store, store.cfg, now=clock)
                if not selected:
                    continue
                kind = selected[0]
                ran.append(kind)
                store.touch_scheduler(f"last_{kind}", clock)

            self.assertIn("watch", ran, "the watch tick keeps running")
            self.assertIn("janitor", ran, "the janitor is not starved by the watch")
            self.assertIn("full", ran, "the full reclaim is not starved")
            # The janitor is due every 1800s and a tick is 300s, so it must
            # run at least once in a 120 tick window.
            self.assertGreaterEqual(ran.count("janitor"), 1, ran)
            self.assertGreaterEqual(ran.count("full"), 1, ran)

    def test_the_dry_run_reports_the_cadence_the_real_tick_would_pick(self):
        from vacuum.scheduler import run_dry_tick

        with tempfile.TemporaryDirectory() as td:
            store = self._store(td, {"watch": 1, "janitor": 1, "full": 1})
            now = time.time()
            result = run_dry_tick(store, now=now)
            self.assertEqual(len(result["selected"]), 1, result["selected"])
            self.assertEqual(len(result["records"]), 1, "the dry run plans one cadence, like the real tick")


class TestCadenceOccupancy(unittest.TestCase):
    """One cadence per tick, and what that means for the cadences it leaves behind.

    A tick runs at most one cadence.  The other due cadences wait their
    turn, and a cadence that is waiting is not a cadence that has failed:
    the alert layer must not send an overdue banner for it, and the status
    must not call it overdue either.  The two surfaces read the same fact,
    so they must not disagree about it.
    """

    INTERVALS = {"watch": 300, "janitor": 1800, "full": 14400}

    def _store(self, td: str) -> "VacuumStore":
        home = Path(td)
        data = home / "rv"
        data.mkdir(parents=True)
        cfg = load_config(home=home)
        cfg["data_dir"] = str(data)
        cfg["intervals_seconds"] = dict(self.INTERVALS)
        cfg["housekeeper_lock"] = str(home / ".housekeeper.lock")
        return VacuumStore(cfg, home=home)

    def _watch_run(self, store: VacuumStore, ended_at: float, failed: bool = False) -> None:
        """A finished watch run, the way the history keeps it."""
        step = StepResult(
            "resource_sample",
            "Resource sample",
            StepStatus.FAILED if failed else StepStatus.RAN,
            reason="no answer" if failed else "",
        )
        record = RunRecord(
            run_id="watch-1",
            trigger=TriggerKind.WATCH,
            started_at=ended_at - 1,
            ended_at=ended_at,
            steps=[step],
        )
        if failed:
            record.exit_code = 1
            record.outcome = RunOutcome.FAILED.value
        store.append_run(record)

    def _scenario(self, store: VacuumStore, now: float, watch_failed: bool = False) -> None:
        """A watch cadence that is overdue, and a janitor that occupies the tick.

        The watch last ran well over its own interval ago, so it is
        overdue by the rule the alert layer uses, and it is due now.  The
        janitor is due as well and more overdue, so it is the cadence that
        takes the tick and the watch is the one that waits.
        """
        self._watch_run(store, ended_at=now - 1000, failed=watch_failed)
        store.touch_scheduler("last_watch", now - 1000)
        store.touch_scheduler("last_janitor", now - 3600)
        store.touch_scheduler("last_full", now)

    def _tick(self, store: VacuumStore, now: float):
        """Run one tick with the engine stubbed out, and return the result."""
        from vacuum.scheduler import run_scheduler_tick

        def fake_run(self, trigger, band="cheap", dry_run=False):
            record = RunRecord(run_id="tick-1", trigger=trigger, started_at=now, ended_at=now)
            record.steps = [StepResult("housekeeper_lock", "Housekeeper lock", StepStatus.SKIPPED)]
            return record

        with patch("vacuum.engine.VacuumEngine.run", fake_run):
            with patch("vacuum.alerts.notify_macos") as notify:
                with patch("vacuum.alerts.launchd_loaded", return_value=True):
                    result = run_scheduler_tick(store, now=now)
        return result, notify

    def _messages(self, notify) -> list:
        return [call.args[1] for call in notify.call_args_list]

    # MARK: - The alert layer

    def test_a_cadence_another_cadence_occupied_is_not_reported_overdue(self):
        with tempfile.TemporaryDirectory() as td:
            store = self._store(td)
            now = time.time()
            self._scenario(store, now)
            _result, notify = self._tick(store, now)
            messages = self._messages(notify)
            self.assertFalse(
                any("pressure check" in m for m in messages),
                f"a cadence that waited its turn must not be reported overdue: {messages}",
            )

    def test_a_cadence_whose_last_run_failed_is_still_reported_overdue(self):
        # A cadence that broke is not a cadence that waited.  The banner has
        # to keep saying so.
        with tempfile.TemporaryDirectory() as td:
            store = self._store(td)
            now = time.time()
            self._scenario(store, now, watch_failed=True)
            _result, notify = self._tick(store, now)
            messages = self._messages(notify)
            self.assertTrue(
                any("pressure check" in m for m in messages),
                f"a cadence whose last run failed must still be reported: {messages}",
            )

    # MARK: - The status the panel reads

    def test_the_status_does_not_call_a_skipped_cadence_overdue(self):
        with tempfile.TemporaryDirectory() as td:
            store = self._store(td)
            now = time.time()
            self._scenario(store, now)
            result, _notify = self._tick(store, now)
            status = result["status"]
            self.assertNotEqual(
                status["health"],
                "overdue",
                "the panel must not call a waiting cadence overdue while the banner stays quiet",
            )

    def test_the_status_publishes_a_next_run_that_is_not_in_the_past(self):
        # The published next run must never be a time that has gone by: the
        # panel shows it, and a time in the past reads as "this never runs".
        with tempfile.TemporaryDirectory() as td:
            store = self._store(td)
            now = time.time()
            self._scenario(store, now)
            result, _notify = self._tick(store, now)
            status = result["status"]
            self.assertGreater(
                float(status["next_run_at"]["watch"]),
                now,
                "the published next run of a waiting cadence must not be in the past",
            )

    def test_the_status_still_calls_a_failed_cadence_overdue(self):
        with tempfile.TemporaryDirectory() as td:
            store = self._store(td)
            now = time.time()
            self._scenario(store, now, watch_failed=True)
            result, _notify = self._tick(store, now)
            status = result["status"]
            self.assertEqual(
                status["health"],
                "overdue",
                "a cadence whose last run failed must still be reported overdue",
            )

    def test_the_status_records_the_cadence_that_occupied_the_tick(self):
        with tempfile.TemporaryDirectory() as td:
            store = self._store(td)
            now = time.time()
            self._scenario(store, now)
            result, _notify = self._tick(store, now)
            occupancy = result["status"]["tick_occupancy"]
            self.assertEqual(occupancy["occupied"], "janitor", occupancy)
            self.assertIn("watch", occupancy["skipped"], occupancy)
            self.assertIn("occupied the tick", occupancy["skipped"]["watch"], occupancy)


class TestOccupancyClaimFallback(unittest.TestCase):
    """A reader that joined no tick still has to see the same truth.

    The tick hands the occupancy to the surfaces it builds.  Every other
    reader -- the status command, and a manual run that publishes a status
    afterwards -- has to learn it from the store, and it has to learn the
    same thing, or the panel and the banner disagree about the same fact.
    The claim expires, because a scheduler that stopped ticking is a
    different thing from a cadence that is waiting its turn.
    """

    INTERVALS = {"watch": 300, "janitor": 1800, "full": 14400}

    def _store(self, td: str) -> "VacuumStore":
        home = Path(td)
        data = home / "rv"
        data.mkdir(parents=True)
        cfg = load_config(home=home)
        cfg["data_dir"] = str(data)
        cfg["intervals_seconds"] = dict(self.INTERVALS)
        cfg["housekeeper_lock"] = str(home / ".housekeeper.lock")
        return VacuumStore(cfg, home=home)

    def _watch_run(self, store: VacuumStore, ended_at: float) -> None:
        step = StepResult("resource_sample", "Resource sample", StepStatus.RAN)
        record = RunRecord(
            run_id="watch-1",
            trigger=TriggerKind.WATCH,
            started_at=ended_at - 1,
            ended_at=ended_at,
            steps=[step],
        )
        store.append_run(record)

    def _scenario(self, store: VacuumStore, now: float) -> None:
        """A watch cadence that is overdue, and a janitor that occupies the tick."""
        self._watch_run(store, ended_at=now - 1000)
        store.touch_scheduler("last_watch", now - 1000)
        store.touch_scheduler("last_janitor", now - 3600)
        store.touch_scheduler("last_full", now)

    def _tick(self, store: VacuumStore, now: float):
        from vacuum.scheduler import run_scheduler_tick

        def fake_run(self, trigger, band="cheap", dry_run=False):
            record = RunRecord(run_id="tick-1", trigger=trigger, started_at=now, ended_at=now)
            record.steps = [StepResult("housekeeper_lock", "Housekeeper lock", StepStatus.SKIPPED)]
            return record

        with patch("vacuum.engine.VacuumEngine.run", fake_run):
            with patch("vacuum.alerts.notify_macos"):
                with patch("vacuum.alerts.launchd_loaded", return_value=True):
                    return run_scheduler_tick(store, now=now)

    def test_a_reader_that_joined_no_tick_does_not_call_a_waiting_cadence_overdue(self):
        with tempfile.TemporaryDirectory() as td:
            store = self._store(td)
            now = time.time()
            self._scenario(store, now)
            self._tick(store, now)
            status = build_status(store, store.cfg)
            self.assertNotEqual(
                status["health"],
                "overdue",
                "a reader that joined no tick must not call a waiting cadence overdue",
            )

    def test_a_reader_that_joined_no_tick_publishes_a_next_run_that_is_not_in_the_past(self):
        with tempfile.TemporaryDirectory() as td:
            store = self._store(td)
            now = time.time()
            self._scenario(store, now)
            self._tick(store, now)
            status = build_status(store, store.cfg)
            self.assertGreater(
                float(status["next_run_at"]["watch"]),
                now,
                "the published next run of a waiting cadence must not be in the past",
            )

    def test_an_expired_claim_brings_the_overdue_report_back(self):
        # A claim that a cadence was waiting only stays believable while a
        # tick could still arrive to service it.  Once it expires, the
        # cadence reads overdue again, because that is what a scheduler that
        # stopped ticking looks like.
        with tempfile.TemporaryDirectory() as td:
            store = self._store(td)
            now = time.time()
            self._scenario(store, now)
            self._tick(store, now)
            occupancy = dict(store.scheduler_state().get("tick_occupancy") or {})
            occupancy["at"] = now - 100000
            store.merge_scheduler_state({"tick_occupancy": occupancy})
            status = build_status(store, store.cfg)
            self.assertEqual(
                status["health"],
                "overdue",
                "an expired claim must not keep a cadence quiet forever",
            )

    def test_the_alert_reader_agrees_with_the_status_reader(self):
        # The alert reader builds its view the way the command line does,
        # from the claim in the store, and it has to reach the same answer
        # the status reader reaches.
        from vacuum.scheduler import current_occupancy, occupancy_view

        with tempfile.TemporaryDirectory() as td:
            store = self._store(td)
            now = time.time()
            self._scenario(store, now)
            self._tick(store, now)
            view = occupancy_view(store, current_occupancy(store, store.cfg))
            with patch("vacuum.alerts.launchd_loaded", return_value=True):
                decisions = evaluate_alerts(view, store.cfg)
            messages = [d.message for d in decisions if d.should_notify]
            self.assertFalse(
                any("pressure check" in m for m in messages),
                f"a cadence that waited its turn must not raise a banner: {messages}",
            )

    def test_a_fresh_claim_outlives_a_tick_that_ran_late(self):
        # The claim survives two tick periods, so a tick that ran late does
        # not make a waiting cadence look overdue.
        from vacuum.scheduler import current_occupancy, occupancy_claim_lifetime

        with tempfile.TemporaryDirectory() as td:
            store = self._store(td)
            now = time.time()
            self._scenario(store, now)
            self._tick(store, now)
            occupancy = dict(store.scheduler_state().get("tick_occupancy") or {})
            occupancy["at"] = now - (occupancy_claim_lifetime(store.cfg) - 1)
            store.merge_scheduler_state({"tick_occupancy": occupancy})
            self.assertIsNotNone(
                current_occupancy(store, store.cfg),
                "a claim inside its lifetime must still be believable",
            )
# A fixed host sample, so nothing here reads the disk or the load of the machine the tests run on.
SAMPLE = {
    "at": 1_800_000_000,
    "disk_sample_ok": True,
    "disk_free_gb": 100.0,
    "disk_used_pct": 50.0,
    "swap_total_gb": 0.0,
    "swap_used_gb": 0.0,
    "swap_used_pct": 0.0,
    "load1": 0.0,
    "load5": 0.0,
    "load15": 0.0,
}


class _RunStepCase(unittest.TestCase):
    """A store in a throwaway home, with the housekeeper lock and the data dir inside it.

    Everything here is hermetic: the home is a temp folder, the host sample is a fixed dictionary, and the
    dispatcher is stubbed, so no step can reach this Mac and nothing is deleted anywhere.
    """

    def setUp(self) -> None:
        self.home = Path(tempfile.mkdtemp(prefix="hhrunstep-"))
        self.addCleanup(shutil.rmtree, str(self.home), True)
        data = self.home / "rv"
        data.mkdir()
        self.cfg = load_config(home=self.home)
        self.cfg["data_dir"] = str(data)
        self.cfg["housekeeper_lock"] = str(self.home / ".housekeeper.lock")
        self.store = VacuumStore(self.cfg, home=self.home)
        self.dispatched: list[str] = []

    def stub_dispatch(self, status: StepStatus = StepStatus.RAN):
        """A dispatcher that records the step ids it is asked for and does nothing else."""
        calls: list[str] = self.dispatched

        def fake_dispatch(engine, step_id, *args, **kwargs):
            calls.append(step_id)
            return 0, "stubbed", status

        return fake_dispatch

    def run_cli(self, argv: list[str]) -> tuple[int, str, str]:
        """Run maintain.main() against the throwaway store.  Returns (exit code, stdout, stderr)."""
        import maintain
        from vacuum.engine import VacuumEngine

        out, err = io.StringIO(), io.StringIO()
        with patch.object(maintain.VacuumStore, "open", return_value=self.store):
            with patch.object(maintain, "bootstrap_registry"):
                with patch("vacuum.script_registry.bootstrap_registry"):
                    with patch("vacuum.alerts.launchd_loaded", return_value=True):
                        with patch("vacuum.engine.sample_mac", return_value=SAMPLE):
                            with patch.object(VacuumEngine, "_dispatch", self.stub_dispatch()):
                                with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                                    code = maintain.main(argv)
        return code, out.getvalue(), err.getvalue()

    def assert_nothing_written(self) -> None:
        """No history, no status, no scheduler state."""
        self.assertFalse(self.store.history_path.exists(), "history was written")
        self.assertFalse(self.store.status_path.exists(), "status was written")
        self.assertEqual(self.store.scheduler_state(), {}, "scheduler state was written")


class TestRunStepCli(_RunStepCase):
    """`maintain.py --run-step STEP_ID` runs exactly one step, so a server-scoped page can reach it.

    The scope of the Hog Hunter panel is display-only for servers, so the one step that acts on a remote
    host (coolify_remote) could not be run from it.  This is the entry point the Mac side calls.
    """

    def test_an_unknown_step_exits_two_and_writes_nothing(self) -> None:
        code, out, err = self.run_cli(["--run-step", "not_a_step"])
        self.assertEqual(code, 2)
        self.assertIn("Unknown maintain step: not_a_step", err)
        self.assertEqual(out, "")
        self.assertEqual(self.dispatched, [], "an unknown step must not run anything")
        self.assert_nothing_written()

    def test_a_step_whose_toggle_is_off_exits_two_and_names_the_step(self) -> None:
        self.store.cfg["steps"]["pm2_logs"] = {"enabled": False}
        code, out, err = self.run_cli(["--run-step", "pm2_logs"])
        self.assertEqual(code, 2)
        self.assertIn("Cap oversized PM2 logs", err)
        self.assertIn("off", err)
        self.assertEqual(out, "")
        self.assertEqual(self.dispatched, [], "a step that is off must not run")
        self.assert_nothing_written()

    def test_a_step_that_ships_off_is_refused_until_the_owner_turns_it_on(self) -> None:
        """coolify_remote ships off, and it is the step the server-scoped page needs."""
        self.assertFalse(step_enabled(self.store.cfg, "coolify_remote"))
        code, out, err = self.run_cli(["--run-step", "coolify_remote"])
        self.assertEqual(code, 2)
        self.assertIn("Remote server maintenance is off", err)
        self.assertEqual(out, "")
        self.assertEqual(self.dispatched, [])
        self.assert_nothing_written()

    def test_an_enabled_step_runs_that_one_step_and_is_appended_to_history(self) -> None:
        code, out, err = self.run_cli(["--run-step", "pm2_logs", "--json"])
        self.assertEqual(code, 0, err)
        self.assertEqual(self.dispatched, ["pm2_logs"], "exactly one step, the one that was named")
        history = self.store.load_history()
        self.assertEqual(len(history), 1)
        record = history[0]
        self.assertEqual([s["step_id"] for s in record["steps"]], ["pm2_logs"])
        self.assertEqual(record["trigger"], "manual")
        self.assertTrue(self.store.status_path.exists(), "the status must be published")
        payload = json.loads(out)
        self.assertEqual(payload["run_id"], record["run_id"])

    def test_a_step_turned_on_runs(self) -> None:
        self.store.cfg["steps"]["coolify_remote"] = {"enabled": True}
        code, _out, err = self.run_cli(["--run-step", "coolify_remote"])
        self.assertEqual(code, 0, err)
        self.assertEqual(self.dispatched, ["coolify_remote"])

    def test_a_dry_run_writes_nothing(self) -> None:
        code, out, err = self.run_cli(["--run-step", "pm2_logs", "--dry-run"])
        self.assertEqual(code, 0, err)
        payload = json.loads(out)
        self.assertTrue(payload["dry_run"])
        self.assertEqual([r["steps"][0]["step_id"] for r in payload["records"]], ["pm2_logs"])
        self.assert_nothing_written()

    def test_a_single_step_run_does_not_advance_the_scheduler_clock(self) -> None:
        """A manual step is not a cadence, so it must not make one look like it has already run."""
        self.store.touch_scheduler("last_full", 1000.0)
        before = self.store.scheduler_state()
        code, _out, err = self.run_cli(["--run-step", "pm2_logs"])
        self.assertEqual(code, 0, err)
        self.assertEqual(self.store.scheduler_state(), before)
        self.assertEqual(self.store.scheduler_state().get("last_full"), 1000.0)

    def test_run_step_and_run_now_cannot_be_combined(self) -> None:
        with self.assertRaises(SystemExit) as caught:
            self.run_cli(["--run-step", "pm2_logs", "--run-now", "full"])
        self.assertEqual(caught.exception.code, 2)
        self.assertEqual(self.dispatched, [])

    def test_a_dry_run_still_refuses_the_other_flags(self) -> None:
        with self.assertRaises(SystemExit) as caught:
            self.run_cli(["--run-step", "pm2_logs", "--dry-run", "--status"])
        self.assertEqual(caught.exception.code, 2)
        self.assertEqual(self.dispatched, [])


class TestRunSingleStep(_RunStepCase):
    """The engine side of the single-step run: the lock, one step, and nothing else."""

    def engine(self):
        from vacuum.engine import VacuumEngine

        return VacuumEngine(self.cfg, home=self.home)

    def test_it_runs_only_the_named_step(self) -> None:
        from vacuum.engine import VacuumEngine

        engine = self.engine()
        with patch("vacuum.engine.sample_mac", return_value=SAMPLE):
            with patch.object(VacuumEngine, "_dispatch", self.stub_dispatch()):
                record = engine.run_single_step("pm2_logs")
        self.assertEqual(self.dispatched, ["pm2_logs"])
        self.assertEqual([s.step_id for s in record.steps], ["pm2_logs"])
        self.assertEqual(record.exit_code, 0)

    def test_a_step_that_is_off_is_skipped_and_never_dispatched(self) -> None:
        from vacuum.engine import VacuumEngine

        engine = self.engine()
        self.cfg["steps"]["pm2_logs"] = {"enabled": False}
        with patch("vacuum.engine.sample_mac", return_value=SAMPLE):
            with patch.object(VacuumEngine, "_dispatch", self.stub_dispatch()):
                record = engine.run_single_step("pm2_logs")
        self.assertEqual(self.dispatched, [])
        self.assertEqual(record.steps[0].status, StepStatus.SKIPPED)
        self.assertEqual(record.exit_code, 2)

    def test_a_heavy_step_skipped_under_extreme_load_is_not_a_successful_run(self) -> None:
        """Nothing ran, so the run is not a success:  the exit code has to say so.

        A heavy step is refused when the host is under extreme load, and the refusal is
        a skip rather than a failure.  The run still ends with an exit code of zero,
        which is how `maintain.py --run-step` told the owner that nothing had run.
        """
        from vacuum.engine import VacuumEngine

        engine = self.engine()
        self.cfg["steps"]["janitor_worktree_retire"] = {"enabled": True}
        with patch("vacuum.engine.sample_mac", return_value=SAMPLE):
            with patch("vacuum.engine.janitor_pressure_mode", return_value="hard"):
                with patch.object(VacuumEngine, "_dispatch", self.stub_dispatch()):
                    record = engine.run_single_step("janitor_worktree_retire")
        self.assertEqual(self.dispatched, [])
        self.assertEqual(record.steps[0].status, StepStatus.SKIPPED)
        self.assertNotEqual(record.exit_code, 0)
        self.assertIn("host under extreme load", record.summary)

    def test_the_cli_reports_a_load_skipped_step_as_a_failure(self) -> None:
        """`--run-step` hands back the run's exit code, so a load skip must not read as success."""
        import maintain
        from vacuum.engine import VacuumEngine

        self.cfg["steps"]["janitor_worktree_retire"] = {"enabled": True}
        out, err = io.StringIO(), io.StringIO()
        with patch.object(maintain.VacuumStore, "open", return_value=self.store):
            with patch.object(maintain, "bootstrap_registry"):
                with patch("vacuum.script_registry.bootstrap_registry"):
                    with patch("vacuum.alerts.launchd_loaded", return_value=True):
                        with patch("vacuum.engine.sample_mac", return_value=SAMPLE):
                            with patch("vacuum.engine.janitor_pressure_mode", return_value="hard"):
                                with patch.object(VacuumEngine, "_dispatch", self.stub_dispatch()):
                                    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                                        code = maintain.main(["--run-step", "janitor_worktree_retire"])
        self.assertNotEqual(code, 0)
        self.assertEqual(self.dispatched, [])

    def test_a_peer_holding_the_lock_is_reported_as_skipped(self) -> None:
        from vacuum.engine import VacuumEngine

        engine = self.engine()
        Path(self.cfg["housekeeper_lock"]).mkdir(parents=True)
        with patch("vacuum.engine.sample_mac", return_value=SAMPLE):
            with patch.object(VacuumEngine, "_dispatch", self.stub_dispatch()):
                record = engine.run_single_step("pm2_logs")
        self.assertEqual(self.dispatched, [])
        self.assertEqual(record.summary, "skipped; peer holds lock")
        self.assertEqual([s.step_id for s in record.steps], ["housekeeper_lock"])
        self.assertEqual(record.exit_code, 0)

    def test_a_dry_run_hands_the_step_the_plan_only_flag(self) -> None:
        """The dispatcher takes (pressure, band, sample, mode, dry_run), so the last argument is the flag."""
        from vacuum.engine import VacuumEngine

        engine = self.engine()
        seen: list[tuple[str, object]] = []

        def fake_dispatch(engine_self, step_id, *args, **kwargs):
            seen.append((step_id, args[-1]))
            return 0, "dry run; no changes", StepStatus.SKIPPED

        with patch("vacuum.engine.sample_mac", return_value=SAMPLE):
            with patch.object(VacuumEngine, "_dispatch", fake_dispatch):
                record = engine.run_single_step("pm2_logs", dry_run=True)
        self.assertEqual(seen, [("pm2_logs", True)])
        self.assertEqual(record.steps[0].status, StepStatus.SKIPPED)


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
