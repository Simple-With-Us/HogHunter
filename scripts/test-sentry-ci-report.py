#!/usr/bin/env python3
"""Self-tests for scripts/sentry-ci-report.py; stdlib only, no network."""

import importlib.util
import json
import os
import re
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "sentry_ci_report", ROOT / "scripts/sentry-ci-report.py")
reporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reporter)


class DsnTests(unittest.TestCase):
    def test_valid_dsn_parses(self):
        key, host, project = reporter.parse_dsn("https://abc123@o1.ingest.example.test/42")
        self.assertEqual((key, host, project), ("abc123", "o1.ingest.example.test", "42"))

    def test_bad_dsns_rejected_without_echoing_the_value(self):
        for bad in ("", "http://abc@host/1", "https://nokey", "not-a-dsn"):
            with self.assertRaises(ValueError) as ctx:
                reporter.parse_dsn(bad)
            message = str(ctx.exception)
            if bad:
                self.assertNotIn(bad, message)
            self.assertNotIn("abc", message)


class FingerprintTests(unittest.TestCase):
    def test_app_identity_is_hoghunter(self):
        self.assertEqual(reporter.APP, "hoghunter")

    def test_alert_conclusions_cover_timeouts(self):
        self.assertEqual(
            reporter.ALERT_CONCLUSIONS,
            frozenset({"failure", "timed_out", "startup_failure"}),
        )

    def test_cron_schedules_map_the_scheduled_lanes(self):
        self.assertEqual(
            reporter.CRON_SCHEDULES,
            {
                "Hog Hunter iOS TestFlight": "41 * * * *",
            },
        )
        self.assertEqual(reporter.UNMONITORED_SCHEDULES, frozenset({"Auto-merge PRs"}))
        self.assertEqual(reporter.find_cron_schedule_drift(reporter.discover_workflow_names()), [])

    def test_every_scheduled_workflow_is_mapped_with_its_cron(self):
        """Reverse drift: a workflow `schedule:` must have a CRON_SCHEDULES entry,
        unless it is deliberately listed in UNMONITORED_SCHEDULES (AFC-626)."""
        found = {}
        for path in sorted(reporter.WORKFLOWS_DIR.glob("*.y*ml")):
            text = path.read_text(encoding="utf-8", errors="replace")
            crons = re.findall(
                r"^\s*-\s*cron:\s*['\"]?([^'\"#\n]+?)['\"]?\s*(?:#.*)?$", text, re.MULTILINE)
            if not crons:
                continue
            name_match = re.search(r"^name:\s*(.+?)\s*$", text, re.MULTILINE)
            self.assertIsNotNone(name_match, f"{path.name} has a schedule but no name:")
            name = name_match.group(1).strip().strip("\"'")
            self.assertEqual(len(crons), 1, f"{path.name}: one cron per workflow expected")
            found[name] = crons[0].strip()
        # Case-folded on both sides, like main() and find_cron_schedule_drift().
        unmonitored_folded = {name.casefold() for name in reporter.UNMONITORED_SCHEDULES}
        unmonitored = {name for name in found if name.casefold() in unmonitored_folded}
        self.assertEqual({name.casefold() for name in unmonitored}, unmonitored_folded)
        self.assertEqual(
            {name.casefold(): cron for name, cron in reporter.CRON_SCHEDULES.items()},
            {name.casefold(): cron for name, cron in found.items() if name not in unmonitored},
        )

    def test_monitor_slug_stays_under_fifty_chars(self):
        slug = reporter.monitor_slug("hoghunter", "Hog Hunter iOS TestFlight")
        self.assertLessEqual(len(slug), reporter.MONITOR_SLUG_MAX_LEN)
        self.assertTrue(slug.startswith("ci-hoghunter-"))


class EnvelopeTests(unittest.TestCase):
    def captured_send(self, env, conclusion="failure", event="push"):
        posts = []

        class FakeResponse:
            status = 200

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

        def fake_urlopen(request, timeout=15):
            posts.append({
                "url": request.full_url,
                "body": request.data,
                "auth": request.get_header("X-sentry-auth"),
            })
            return FakeResponse()

        base = {
            "WORKFLOW_NAME": "CI",
            "WORKFLOW_CONCLUSION": conclusion,
            "WORKFLOW_EVENT": event,
            "WORKFLOW_BRANCH": "cursor/hoghunter-sentry-1d2c",
            "WORKFLOW_ACTOR": "agent",
            "WORKFLOW_RUN_URL": "https://github.com/Simple-With-Us/HogHunter/actions/runs/1",
            "WORKFLOW_RUN_ID": "1",
        }
        base.update(env)
        # The stale-key drift guard is stubbed so these assertions do not depend
        # on the live checkout's workflow names; ConfigDriftTests covers it.
        with mock.patch.object(reporter.urllib.request, "urlopen", fake_urlopen), \
                mock.patch.object(reporter, "find_cron_schedule_drift", return_value=[]):
            with mock.patch.dict(os.environ, base, clear=False):
                if "SENTRY_FLEET_DSN" not in env:
                    os.environ.pop("SENTRY_FLEET_DSN", None)
                rc = reporter.main()
        return rc, posts

    def test_missing_dsn_noops(self):
        rc, posts = self.captured_send({})
        self.assertEqual(rc, 0)
        self.assertEqual(posts, [])

    def test_success_sends_nothing(self):
        rc, posts = self.captured_send(
            {"SENTRY_FLEET_DSN": "https://abc123@o1.ingest.example.test/42"},
            conclusion="success",
        )
        self.assertEqual(rc, 0)
        self.assertEqual(posts, [])

    def test_failure_fingerprints_without_branch(self):
        rc, posts = self.captured_send(
            {"SENTRY_FLEET_DSN": "https://abc123@o1.ingest.example.test/42"},
        )
        self.assertEqual(rc, 0)
        self.assertEqual(len(posts), 1)
        self.assertEqual(posts[0]["url"], "https://o1.ingest.example.test/api/42/envelope/")
        lines = posts[0]["body"].split(b"\n")
        payload = json.loads(lines[2])
        self.assertEqual(payload["fingerprint"], ["ci-failure", "hoghunter", "CI"])
        self.assertEqual(payload["tags"]["app"], "hoghunter")
        self.assertEqual(payload["tags"]["branch"], "cursor/hoghunter-sentry-1d2c")
        self.assertNotIn("cursor/hoghunter-sentry-1d2c", payload["fingerprint"])

    def test_scheduled_testflight_run_sends_checkin_not_drift(self):
        rc, posts = self.captured_send(
            {
                "SENTRY_FLEET_DSN": "https://abc123@o1.ingest.example.test/42",
                "WORKFLOW_NAME": "Hog Hunter iOS TestFlight",
                "WORKFLOW_BRANCH": "main",
            },
            conclusion="success",
            event="schedule",
        )
        self.assertEqual(rc, 0)
        self.assertEqual(len(posts), 1)
        items = [json.loads(line) for line in posts[0]["body"].split(b"\n") if line.strip()]
        checkins = [item for item in items if "monitor_slug" in item]
        self.assertEqual(len(checkins), 1)
        checkin = checkins[0]
        self.assertEqual(checkin["status"], "ok")
        self.assertEqual(
            checkin["monitor_config"]["schedule"], {"type": "crontab", "value": "41 * * * *"})
        self.assertEqual(checkin["monitor_config"]["checkin_margin"], 30)
        # AFC-626: GitHub drops hourly ship ticks; three misses in a row turn it red.
        self.assertEqual(checkin["monitor_config"]["failure_issue_threshold"], 3)
        self.assertEqual(checkin["monitor_config"]["recovery_threshold"], 1)
        self.assertFalse(
            any("ci-report-config-drift" in item.get("fingerprint", []) for item in items))

    def test_zero_failure_threshold_is_sent_not_dropped(self):
        with mock.patch.dict(reporter._CRON_FAILURE_THRESHOLD_FOLDED, {"ci": 0}):
            config = reporter.monitor_config_for("CI", "17 9 * * 1")
        self.assertEqual(config["failure_issue_threshold"], 0)
        self.assertEqual(config["recovery_threshold"], 1)

    def test_unlisted_monitor_keeps_sentry_default_threshold(self):
        config = reporter.monitor_config_for("CI", "17 9 * * 1")
        self.assertNotIn("failure_issue_threshold", config)
        self.assertNotIn("recovery_threshold", config)
        self.assertEqual(config["checkin_margin"], reporter.DEFAULT_CHECKIN_MARGIN_MINUTES)

    def test_scheduled_auto_merge_run_sends_no_checkin_and_no_drift(self):
        """AFC-626: the 15-minute sweep is unmonitored, and is not config drift."""
        rc, posts = self.captured_send(
            {
                "SENTRY_FLEET_DSN": "https://abc123@o1.ingest.example.test/42",
                "WORKFLOW_NAME": "Auto-merge PRs",
                "WORKFLOW_BRANCH": "main",
            },
            conclusion="success",
            event="schedule",
        )
        self.assertEqual(rc, 0)
        self.assertEqual(posts, [])

    def test_failed_auto_merge_sweep_still_raises_the_error_event(self):
        rc, posts = self.captured_send(
            {
                "SENTRY_FLEET_DSN": "https://abc123@o1.ingest.example.test/42",
                "WORKFLOW_NAME": "Auto-merge PRs",
                "WORKFLOW_BRANCH": "main",
            },
            conclusion="failure",
            event="schedule",
        )
        self.assertEqual(rc, 0)
        self.assertEqual(len(posts), 1)
        items = [json.loads(line) for line in posts[0]["body"].split(b"\n") if line.strip()]
        self.assertFalse(any("monitor_slug" in item for item in items))
        events = [item for item in items if "fingerprint" in item]
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["fingerprint"], ["ci-failure", "hoghunter", "Auto-merge PRs"])

    def test_malformed_dsn_never_fails_the_job(self):
        rc, posts = self.captured_send({"SENTRY_FLEET_DSN": "not-a-dsn"})
        self.assertEqual(rc, 0)
        self.assertEqual(posts, [])

    def test_send_errors_never_fail_the_job(self):
        with mock.patch.object(
            reporter.urllib.request, "urlopen", side_effect=RuntimeError("down")
        ):
            with mock.patch.dict(os.environ, {
                "SENTRY_FLEET_DSN": "https://abc123@o1.ingest.example.test/42",
                "WORKFLOW_NAME": "CI",
                "WORKFLOW_CONCLUSION": "failure",
                "WORKFLOW_EVENT": "push",
                "WORKFLOW_BRANCH": "main",
                "WORKFLOW_ACTOR": "agent",
                "WORKFLOW_RUN_URL": "https://example.test/run",
                "WORKFLOW_RUN_ID": "1",
            }, clear=False):
                self.assertEqual(reporter.main(), 0)


class ConfigDriftTests(unittest.TestCase):
    def test_stale_unmonitored_entry_is_reported_like_a_stale_cron_key(self):
        live = set(reporter.CRON_SCHEDULES)
        self.assertEqual(
            reporter.find_cron_schedule_drift(live), sorted(reporter.UNMONITORED_SCHEDULES))

    def test_unmonitored_entry_matches_live_names_case_insensitively(self):
        live = {name.casefold() for name in reporter.CRON_SCHEDULES}
        live |= {name.casefold() for name in reporter.UNMONITORED_SCHEDULES}
        self.assertEqual(reporter.find_cron_schedule_drift(live), [])

    def test_name_in_both_maps_is_reported_as_drift(self):
        live = set(reporter.CRON_SCHEDULES) | set(reporter.UNMONITORED_SCHEDULES)
        with mock.patch.dict(reporter.CRON_SCHEDULES, {"Auto-merge PRs": "*/15 * * * *"}):
            self.assertEqual(reporter.find_cron_schedule_drift(live), ["Auto-merge PRs"])
        # A duplicate that differs only by case reports both spellings.
        with mock.patch.dict(reporter.CRON_SCHEDULES, {"AUTO-MERGE PRS": "*/15 * * * *"}):
            self.assertEqual(
                reporter.find_cron_schedule_drift(live), ["AUTO-MERGE PRS", "Auto-merge PRs"])

    def test_stale_unmonitored_entry_raises_the_stale_cron_key_event(self):
        sent = []
        env = {
            "SENTRY_FLEET_DSN": "https://abc123@o1.ingest.example.test/42",
            "WORKFLOW_NAME": "CI",
            "WORKFLOW_CONCLUSION": "success",
            "WORKFLOW_EVENT": "push",
            "WORKFLOW_BRANCH": "main",
            "WORKFLOW_ACTOR": "agent",
            "WORKFLOW_RUN_URL": "https://example.test/run/1",
            "WORKFLOW_RUN_ID": "1",
        }
        with mock.patch.object(
            reporter, "discover_workflow_names", return_value=set(reporter.CRON_SCHEDULES)
        ), mock.patch.object(
            reporter, "send_envelope",
            lambda url, auth, item_type, payload: sent.append((item_type, payload)),
        ), mock.patch.dict(os.environ, env, clear=False):
            self.assertEqual(reporter.main(), 0)
        self.assertEqual([item_type for item_type, _ in sent], ["event"])
        payload = sent[0][1]
        self.assertEqual(
            payload["fingerprint"], ["ci-report-config-drift", "hoghunter", "stale-cron-key"])
        self.assertEqual(payload["extra"]["stale_keys"], sorted(reporter.UNMONITORED_SCHEDULES))


class WorkflowNameTests(unittest.TestCase):
    def test_discovers_the_observed_workflow_names(self):
        names = reporter.discover_workflow_names()
        self.assertIsNotNone(names)
        self.assertIn("CI", names)
        self.assertIn("Sentry CI Report", names)
        self.assertIn("Hog Hunter iOS TestFlight", names)
        self.assertIn("Auto-merge PRs", names)


if __name__ == "__main__":
    unittest.main()
