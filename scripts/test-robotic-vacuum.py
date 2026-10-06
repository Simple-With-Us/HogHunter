#!/usr/bin/env python3
"""Linux-runnable tests for Robotic Vacuum scheduler, alerts, and janitor helpers."""
from __future__ import annotations

import json
import os
import re
import sys
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

from vacuum.alerts import evaluate_alerts  # noqa: E402
from vacuum.config import load_config, step_enabled, steps_for_trigger  # noqa: E402
from vacuum.janitor import _maybe_retire, wt_blocking_dirt  # noqa: E402
from vacuum.models import RunRecord, StepResult, StepStatus, TriggerKind  # noqa: E402
from vacuum.pressure import evaluate_hits, janitor_pressure_mode, sample_mac  # noqa: E402
from vacuum.scheduler import build_status, should_run  # noqa: E402
from vacuum.store import VacuumStore  # noqa: E402


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
            decisions = evaluate_alerts(store, cfg, now=time.time())
            kinds = [d.kind for d in decisions if d.should_notify]
            self.assertIn("overdue_watch", kinds)


class TestJanitorHelpers(unittest.TestCase):
    def test_blocking_dirt_ignores_generated(self):
        class Res:
            returncode = 0
            stdout = "?? node_modules/foo\n"

        def git(cmd, **kwargs):
            return Res()

        self.assertFalse(wt_blocking_dirt(Path("/tmp/wt"), git))

    def test_blocking_dirt_tracks_modified(self):
        class Res:
            returncode = 0
            stdout = " M README.md\n"

        def git(cmd, **kwargs):
            return Res()

        self.assertTrue(wt_blocking_dirt(Path("/tmp/wt"), git))

    def test_unmerged_scratch_worktree_not_removed(self):
        removed: list[str] = []
        retired = 0

        def on_retire() -> None:
            nonlocal retired
            retired += 1

        def git(cmd, **kwargs):
            class R:
                returncode = 0
                stdout = ""

            cmd_s = " ".join(cmd)
            if "worktree remove" in cmd_s:
                removed.append(cmd[-1])
            return R()

        def gh(cmd, **kwargs):
            class R:
                returncode = 0
                stdout = "0"

            return R()

        with tempfile.TemporaryDirectory() as td:
            wt = Path(td) / ".grok/worktrees/agent"
            wt.mkdir(parents=True)
            old = time.time() - 8 * 86400
            os.utime(wt, (old, old))
            detail: list[str] = []
            keep_re = re.compile(r"^never-match$")
            _maybe_retire(
                str(wt),
                "refs/heads/kimi/test",
                keep_re,
                7,
                4,
                git,
                gh,
                False,
                on_retire,
                detail,
            )
        self.assertEqual(removed, [])
        self.assertEqual(retired, 0)


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

            with patch("vacuum.scheduler.VacuumEngine") as engine_cls:
                engine = engine_cls.return_value
                engine.run_watch_tick.return_value = (record, [], False)
                run_scheduler_tick(store, now=now)
            state = store.scheduler_state()
            self.assertNotIn("last_watch", state)


    def test_apply_retire_skips_dirty_since_planning(self):
        from vacuum.janitor import apply_retire_worktrees

        removed: list[str] = []

        def git(cmd, **kwargs):
            class R:
                returncode = 0
                stdout = ""

            cmd_s = " ".join(cmd)
            if "status" in cmd_s:
                R.stdout = " M tracked.txt\n"
            if "worktree remove" in cmd_s:
                removed.append(cmd[-1])
            return R()

        with tempfile.TemporaryDirectory() as td:
            wt = Path(td) / "wt"
            wt.mkdir()
            count, _est, detail = apply_retire_worktrees([(str(wt), "refs/heads/x")], git, dry_run=False)
        self.assertEqual(count, 0)
        self.assertEqual(removed, [])
        self.assertIn("dirty since planning", detail)

    def test_invalid_keep_regex_fails_janitor_step_not_tick(self):
        from unittest.mock import patch

        from vacuum.engine import VacuumEngine
        from vacuum.models import StepStatus, TriggerKind

        cfg = load_config()
        cfg["keep_worktree_regex"] = "[invalid"
        cfg["repos"] = []
        engine = VacuumEngine(cfg, Path("/tmp"))
        with patch.object(sys, "platform", "darwin"):
            record = engine.run(TriggerKind.JANITOR)
        step = next(s for s in record.steps if s.step_id == "janitor_worktree_retire")
        self.assertEqual(step.status, StepStatus.FAILED)


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


if __name__ == "__main__":
    unittest.main()
