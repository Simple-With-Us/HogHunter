#!/usr/bin/env python3
"""Linux-runnable tests for Robotic Vacuum scheduler, alerts, and janitor helpers.

The lane doctor tests live in test-vacuum-lanes.py; load_tests at the bottom pulls them in, so the one CI
command (python3 scripts/test-robotic-vacuum.py) runs both files."""
from __future__ import annotations

import atexit
import errno
import json
import os
import shutil
import signal
import subprocess
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

    def test_partial_run_does_not_post_the_run_failed_alert_but_failed_does(self):
        """The decision, written down: a partial run keeps its failed step on the record and in the UI, and only
        a run where nothing worked posts the banner."""
        for steps, expect_alert in (
            ([_step("a", StepStatus.RAN), _step("b", StepStatus.FAILED)], False),
            ([_step("a", StepStatus.SKIPPED), _step("b", StepStatus.FAILED)], True),
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
        for _ in range(50):
            try:
                os.kill(grandchild, 0)
            except ProcessLookupError:
                break
            time.sleep(0.1)
        else:
            os.kill(grandchild, signal.SIGKILL)
            self.fail("the grandchild outlived its killed parent")


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
        self.assertEqual((freed, reason, status), (3000, "pruned 1 folder(s)", StepStatus.RAN))
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
        self.assertEqual((freed, reason, status), (51 * 1024 * 1024, "truncated 1 log(s) in place", StepStatus.RAN))
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
        self.assertEqual((freed, reason, status), (700, "removed 1 stale temp db(s)", StepStatus.RAN))
        self.assertTrue(fresh.exists())


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
