#!/usr/bin/env python3
"""Static checks for the Hog Hunter Sentry wiring.  No network, no secrets."""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# A real Sentry DSN looks like https://<public>@<host>.ingest.sentry.io/<id>.
# The tests use obvious fakes (o1.ingest / public@) that must not match this.
HARDCODED_DSN = re.compile(
    r"https://[A-Za-z0-9._-]+@[A-Za-z0-9.-]+\.ingest\.(sentry\.io|us\.sentry\.io)/[0-9]+"
)

COLLECTED_TYPES = {
    "NSPrivacyCollectedDataTypeCrashData",
    "NSPrivacyCollectedDataTypePerformanceData",
    "NSPrivacyCollectedDataTypeOtherDiagnosticData",
}

SKIP_DIRS = {".git", "build", "build-ios", "DerivedData", "__pycache__"}


class WiringTests(unittest.TestCase):
    def test_no_hardcoded_sentry_dsn(self):
        hits = []
        for path in ROOT.rglob("*"):
            if any(part in SKIP_DIRS for part in path.parts):
                continue
            if not path.is_file():
                continue
            if path.suffix.lower() in {".png", ".jpg", ".jpeg", ".webp", ".ico", ".pdf"}:
                continue
            try:
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            if HARDCODED_DSN.search(text):
                hits.append(str(path.relative_to(ROOT)))
        self.assertEqual(hits, [], "hardcoded Sentry DSN in: " + ", ".join(hits))

    def test_project_yml_pins_sentry_cocoa(self):
        text = (ROOT / "project.yml").read_text(encoding="utf-8")
        self.assertIn("https://github.com/getsentry/sentry-cocoa", text)
        self.assertIn("product: Sentry", text)
        self.assertIn("Sources/Telemetry/SentryTelemetry.swift", text)
        match = re.search(
            r"^packages:\n  Sentry:\n((?:    .*\n)+)",
            text,
            re.M,
        )
        self.assertIsNotNone(match, "project.yml is missing the Sentry package block")
        block = match.group(1)
        # sentry-cocoa 9 depends on KSCrash.  SPM rejects `from`
        # (up-to-next-major) for a package with an unstable dependency.
        self.assertRegex(block, r'minorVersion:\s*"9\.\d+\.\d+"')
        self.assertNotRegex(block, r"^\s*from:", re.M)

    def test_info_plists_expand_the_build_setting(self):
        for relative in ("macos/Info.plist", "ios/Info.plist"):
            text = (ROOT / relative).read_text(encoding="utf-8")
            self.assertIn("<key>SentryDSN</key>", text)
            self.assertIn("$(SENTRY_DSN)", text)

    def test_privacy_manifests_declare_diagnostic_types(self):
        for relative in ("macos/PrivacyInfo.xcprivacy", "ios/PrivacyInfo.xcprivacy"):
            text = (ROOT / relative).read_text(encoding="utf-8")
            self.assertIn("<false/>", text)
            for collected in COLLECTED_TYPES:
                self.assertIn(collected, text, f"{relative} missing {collected}")

    def test_ci_report_workflow_exists_and_names_fleet_secret(self):
        text = (ROOT / ".github/workflows/sentry-ci-report.yml").read_text(encoding="utf-8")
        self.assertIn("secrets.SENTRY_FLEET_DSN", text)
        self.assertIn("name: Sentry CI Report", text)
        self.assertIn("- CI", text)

    def test_privacy_answers_exist(self):
        text = (ROOT / "ios/AppStore/privacy-answers.md").read_text(encoding="utf-8")
        self.assertIn("Sentry", text)
        self.assertIn("Crash Data", text)
        self.assertIn("sendDefaultPii", text)


if __name__ == "__main__":
    unittest.main()
