#!/usr/bin/env python3
"""Offline contract checks for the iPhone TestFlight auto-ship.

Never contacts Apple, GitHub or Infisical and never reads a credential.  It pins:

* the push paths and the scheduled gate prefixes of ios-testflight.yml to the
  sources project.yml compiles into the iOS app and the widget, so a file added
  to those targets cannot quietly stop shipping;
* the release contract the owner set on 2026-10-17 (fleet ship script, What to
  Test published, Fleet-OPS /asc key, no standing gate override);
* the vendored fleet files and the What to Test renderer (no agent names, no
  timezone abbreviation).
"""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/ios-testflight.yml"
PROJECT = ROOT / "project.yml"
FLEET = ROOT / "scripts/ios-fleet"
IOS_TARGETS = ("HogHunterIOS", "HogHunterWidgets")


def project_target_sources(text):
    """Return {target: [path, ...]} for the `sources:` entries of each target."""
    result, target, in_targets, in_sources = {}, None, False, False
    for line in text.splitlines():
        if re.match(r"^targets:\s*$", line):
            in_targets = True
            continue
        if in_targets and re.match(r"^\S", line):
            in_targets = False
        if not in_targets:
            continue
        match = re.match(r"^  (\w+):\s*$", line)
        if match:
            target, in_sources = match.group(1), False
            result[target] = []
            continue
        if target is None:
            continue
        if re.match(r"^    sources:\s*$", line):
            in_sources = True
            continue
        if in_sources and re.match(r"^    \S", line):
            in_sources = False
        if in_sources:
            item = re.match(r"^      - path:\s*(\S+)\s*$", line)
            if item:
                result[target].append(item.group(1))
    return result


def workflow_code(text):
    """The workflow without comment lines, so prose cannot satisfy or trip a check."""
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


def push_paths(text):
    lines = text.splitlines()
    start = None
    for index, line in enumerate(lines):
        if line == "  push:":
            start = index
            break
    assert start is not None, "no push trigger"
    paths, collecting = [], False
    for line in lines[start + 1:]:
        if re.match(r"^  \S", line):
            break
        if line == "    paths:":
            collecting = True
            continue
        if collecting:
            if line.strip().startswith("#") or not line.strip():
                continue
            item = re.match(r"^      - '([^']+)'\s*$", line)
            if not item:
                break
            paths.append(item.group(1))
    return paths


def gate_prefixes(text):
    return re.findall(r"--path-prefix '([^']+)'", text)


def glob_regex(pattern):
    """GitHub's filter glob:  ** crosses /, * and ? do not."""
    out, index = "", 0
    while index < len(pattern):
        if pattern.startswith("**", index):
            out += ".*"
            index += 2
        elif pattern[index] == "*":
            out += "[^/]*"
            index += 1
        elif pattern[index] == "?":
            out += "[^/]"
            index += 1
        else:
            out += re.escape(pattern[index])
            index += 1
    return re.compile("^" + out + "$")


def triggers(patterns, changed_file):
    """Would a push touching only `changed_file` start the workflow?"""
    selected = False
    for pattern in patterns:
        if pattern.startswith("!"):
            if glob_regex(pattern[1:]).match(changed_file):
                selected = False
        elif glob_regex(pattern).match(changed_file):
            selected = True
    return selected


def native_sources():
    """Sources the iOS targets compile, as the gate prefixes and push paths list them."""
    declared = project_target_sources(PROJECT.read_text(encoding="utf-8"))
    paths = []
    for target in IOS_TARGETS:
        for path in declared[target]:
            if path not in paths:
                paths.append(path)
    return paths


class NativeTreeTests(unittest.TestCase):
    def setUp(self):
        self.text = WORKFLOW.read_text(encoding="utf-8")
        self.push = push_paths(self.text)

    def test_project_yml_parser_reads_the_ios_targets(self):
        sample = (
            "targets:\n"
            "  HogHunter:\n"
            "    sources:\n"
            "      - path: Sources\n"
            "    dependencies:\n"
            "      - sdk: X\n"
            "  HogHunterIOS:\n"
            "    sources:\n"
            "      - path: ios/Sources\n"
            "      - path: Sources/Companion/CompanionPeer.swift\n"
            "        buildPhase: resources\n"
            "    settings:\n"
            "      base:\n"
            "        A: B\n"
            "schemes:\n"
            "  X: {}\n"
        )
        self.assertEqual(
            project_target_sources(sample),
            {"HogHunter": ["Sources"], "HogHunterIOS": ["ios/Sources", "Sources/Companion/CompanionPeer.swift"]},
        )

    def test_ios_targets_have_sources(self):
        declared = project_target_sources(PROJECT.read_text(encoding="utf-8"))
        for target in IOS_TARGETS:
            self.assertTrue(declared.get(target), f"{target} has no sources in project.yml")

    def test_every_compiled_source_starts_a_push_run(self):
        for path in native_sources():
            # A directory source is proven through a file inside it.
            sample = path if Path(path).suffix == ".swift" else f"{path}/Example.swift"
            self.assertTrue(triggers(self.push, sample), f"a push touching {sample} would not ship")

    def test_project_yml_and_ios_tree_start_a_push_run(self):
        for changed in ("project.yml", "ios/Sources/App.swift", "ios/Widgets/Info.plist", "ios/Info.plist"):
            self.assertTrue(triggers(self.push, changed), changed)

    def test_the_shared_files_the_audit_found_missing_now_ship(self):
        for changed in (
            "Sources/Companion/CompanionSnapshot.swift",
            "Sources/Companion/CompanionHTTP.swift",
            "Sources/Companion/CompanionPeer.swift",
            "Sources/UI/CpuSparklineView.swift",
            "Sources/Telemetry/SentryTelemetry.swift",
        ):
            self.assertTrue(triggers(self.push, changed), changed)

    def test_mac_only_edits_do_not_start_a_push_run(self):
        for changed in (
            "Sources/Companion/CompanionServer.swift",
            "Sources/Companion/CompanionAuthThrottle.swift",
            "Sources/Sampling/Sampler.swift",
            "Sources/UI/MenuBarView.swift",
            "macos/Info.plist",
            "Tests/HogHunterTests/CpuMathTests.swift",
            "docs/AUTO-UPDATE.md",
            "scripts/ios-fleet/test-scheduled-ship-gate.sh",
            "scripts/ios-fleet/README.md",
            "scripts/test-ios-release.py",
        ):
            self.assertFalse(triggers(self.push, changed), changed)

    def test_the_ship_machinery_starts_a_push_run(self):
        for changed in (
            ".github/workflows/ios-testflight.yml",
            "scripts/ios-ship-testflight.sh",
            "scripts/ios-appstore-gm-prepare.sh",
            "scripts/ios-stage-asc-key.sh",
            "scripts/ios-fleet/ship-testflight.sh",
            "scripts/ios-fleet/asc-api.mjs",
            "scripts/ios-fleet/apps.json",
        ):
            self.assertTrue(triggers(self.push, changed), changed)

    def test_glob_matcher_follows_github_semantics(self):
        self.assertFalse(triggers(["scripts/ios-*"], "scripts/ios-fleet/ship-testflight.sh"))
        self.assertTrue(triggers(["scripts/ios-*"], "scripts/ios-x.sh"))
        self.assertTrue(triggers(["scripts/ios-fleet/**"], "scripts/ios-fleet/a/b.sh"))
        self.assertFalse(triggers(["Assets.xcassets"], "Assets.xcassets/AppIcon.appiconset/Contents.json"))

    def test_scheduled_gate_prefixes_mirror_the_native_sources(self):
        expected = []
        for path in native_sources():
            prefix = "ios/" if path.startswith("ios/") else path
            if prefix not in expected:
                expected.append(prefix)
        # project.yml defines the iOS targets, so a change to it ships as well.
        expected.append("project.yml")
        self.assertEqual(sorted(gate_prefixes(self.text)), sorted(set(expected)))

    def test_no_native_source_is_missing_from_the_push_paths_text(self):
        for path in native_sources():
            if not path.startswith("ios/"):
                self.assertIn(f"- '{path}'", self.text)


class ReleaseContractTests(unittest.TestCase):
    def setUp(self):
        self.raw = WORKFLOW.read_text(encoding="utf-8")
        self.code = workflow_code(self.raw)

    def test_ships_through_the_fleet_script_and_publishes_what_to_test(self):
        self.assertIn("bash scripts/ios-ship-testflight.sh", self.code)
        self.assertIn('IOS_TF_RELEASE_NOTES: "1"', self.code)
        wrapper = (ROOT / "scripts/ios-ship-testflight.sh").read_text(encoding="utf-8")
        self.assertIn('scripts/ios-fleet/ship-testflight.sh', wrapper)
        self.assertIn("hoghunter", wrapper)

    def test_rate_gate_and_same_head_skip_stay_default(self):
        for forbidden in ("IOS_TF_MIN_INTERVAL_SEC", "--force-ship", "force_ship", "allow-unverified-seq"):
            self.assertNotIn(forbidden, self.code)
        fleet = (FLEET / "ship-testflight.sh").read_text(encoding="utf-8")
        self.assertRegex(fleet, r"(?m)^DEFAULT_MIN_INTERVAL_SEC=3600$")
        self.assertIn("ensure-tf-ready", fleet)
        self.assertIn("evaluate_ship_gate", fleet)

    def test_full_history_and_ship_state_are_restored_and_saved(self):
        self.assertRegex(self.code, r"fetch-depth:\s*0")
        self.assertIn("actions/cache/restore@", self.code)
        self.assertIn("actions/cache/save@", self.code)
        self.assertIn("ios-fleet-state-hoghunter-ios-", self.code)
        self.assertIn("lockdir", self.code)
        # An export-only run must not write state a real ship would inherit.
        self.assertRegex(self.code, r"(?s)Save iOS ship state.*export_only != '1'")

    def test_asc_key_comes_from_fleet_ops_asc_only(self):
        # The Fleet-OPS project id comes from the shared org secret;  this public
        # file never carries it as a literal.
        self.assertIn("ASC_INFISICAL_PROJECT_ID: ${{ secrets.INFISICAL_FLEET_OPS_PROJECT_ID }}", self.code)
        self.assertNotRegex(self.code, r"ASC_INFISICAL_PROJECT_ID:\s*[0-9a-f]{8}-")
        self.assertIn("--path=/asc", self.code)
        for name in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_P8"):
            self.assertNotRegex(self.code, rf"secrets\.{name}\b")
        # The multiline key never goes through GITHUB_ENV.
        self.assertNotRegex(self.code, r"for name in .*ASC_KEY_P8")
        self.assertIn("scripts/ios-stage-asc-key.sh", self.code)
        # The certificate stays out of GITHUB_ENV.
        self.assertNotRegex(self.code, r">>\s*\"?\$GITHUB_ENV\"?.*IOS_DIST")

    def test_triggers_and_dispatch_inputs(self):
        self.assertIn("workflow_dispatch:", self.code)
        self.assertIn("schedule:", self.code)
        self.assertRegex(self.code, r"(?m)^    - cron: '\d+ \* \* \* \*'")
        self.assertIn("scheduled-ship-gate.sh", self.code)
        # `upload` is what the freshness catch-up dispatches with;  build_number
        # would map to --build and ship the registry's default version train.
        self.assertRegex(self.code, r"(?m)^      upload:")
        self.assertNotIn("build_number", self.code)
        self.assertIn("HH_IOS_TESTFLIGHT_ENABLED", self.code)
        self.assertIn("runs-on: macos-latest", self.code)
        self.assertNotRegex(self.code, r"(?m)^  pull_request")

    def test_export_only_dispatch_is_the_only_branch_run(self):
        self.assertIn("github.ref == 'refs/heads/main'", self.code)
        self.assertIn("inputs.upload == false", self.code)
        self.assertIn("--export-only", self.code)

    def test_vendored_fleet_files_are_registered_for_hog_hunter(self):
        for name in (
            "ship-testflight.sh", "asc-api.mjs", "apps.json", "scheduled-ship-gate.sh",
            "ExportOptions-appstore.plist", "ExportOptions-export-ipa.plist",
        ):
            self.assertTrue((FLEET / name).is_file(), name)
        app = json.loads((FLEET / "apps.json").read_text(encoding="utf-8"))["apps"]["hoghunter"]
        self.assertEqual(app["bundleId"], "com.simplewithus.hoghunter.ios")
        self.assertEqual(app["appleId"], 6816633156)
        self.assertEqual(app["scheme"], "HogHunterIOS")
        self.assertEqual(app["xcodegenDir"], ".")
        project = PROJECT.read_text(encoding="utf-8")
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER: com.simplewithus.hoghunter.ios\n", project)
        self.assertIn("HogHunterIOS:", project)

    def test_export_compliance_is_declared_in_the_iphone_plist(self):
        text = (ROOT / "ios/Info.plist").read_text(encoding="utf-8")
        self.assertRegex(text, r"<key>ITSAppUsesNonExemptEncryption</key>\s*<false/>")

    def test_iphone_targets_carry_no_mac_entitlements(self):
        # The old release validator rejected an App Group on the iPhone signature.
        # Pinned here at the source:  the iPhone targets set no entitlements file.
        project = PROJECT.read_text(encoding="utf-8")
        section = project.split("  HogHunterIOS:", 1)[1].split("\nschemes:", 1)[0]
        self.assertNotIn("CODE_SIGN_ENTITLEMENTS", section)
        for path in (ROOT / "ios").rglob("*.entitlements"):
            self.assertNotIn("com.apple.security.application-groups", path.read_text(encoding="utf-8"), str(path))

    def test_wrapper_refuses_a_local_upload(self):
        env = {key: value for key, value in os.environ.items() if key != "GITHUB_ACTIONS"}
        result = subprocess.run(["/bin/bash", str(ROOT / "scripts/ios-ship-testflight.sh")],
                                capture_output=True, text=True, env=env)
        self.assertEqual(result.returncode, 1)
        self.assertIn("local upload is disabled", result.stderr)


@unittest.skipUnless(shutil.which("node"), "node is not installed")
class ReleaseNotesTests(unittest.TestCase):
    """Run the vendored What to Test renderer (asc-api.mjs) on synthetic commit subjects."""

    @classmethod
    def setUpClass(cls):
        source = (FLEET / "asc-api.mjs").read_text(encoding="utf-8")
        start = source.index("const AGENT_NAMES")
        end = source.index("async function setWhatToTest")
        cls.block = source[start:end]

    def render(self, subjects):
        script = (
            "import { execFileSync } from 'node:child_process';\n"
            + self.block
            + "\nprocess.stdout.write(JSON.stringify({\n"
            "  body: buildReleaseNotes({ marketing: '1.0.11', displayName: 'Hog Hunter', title: '',\n"
            f"    subjects: {json.dumps(subjects)}, iosPathPrefix: '', repoRoot: '', prevSha: '' }}),\n"
            "  stamp: centralTimestamp(new Date(Date.UTC(2026, 7, 12, 6, 15)))\n"
            "}));\n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "render.mjs"
            path.write_text(script, encoding="utf-8")
            result = subprocess.run(["node", str(path)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_stamp_is_owner_clock_with_no_timezone_abbreviation(self):
        stamp = self.render(["Add the maintenance tab to the iPhone app"])["stamp"]
        self.assertEqual(stamp, "Wed, Aug 12, 2026 at 1:15am")

    def test_notes_carry_no_agent_names_or_seat_tags(self):
        body = self.render([
            "fix(ios): keep the pairing code field focused [AG] (#201)",
            "feat: show the Mac sparkline on the widget [MM] (#202)",
            "feat: Claude wrote a faster refresh for the Mac list (#203)",
            "[HH][CLUTCH] harden the Bonjour browser retry (#204)",
            "Show the last refresh time in the widget (#205)",
        ])["body"]
        self.assertTrue(body.startswith("[1.0.11] Hog Hunter Update\nReleased: "))
        self.assertIn("What's New:", body)
        for leaked in ("[AG]", "[MM]", "[CLUTCH]", "Claude", "claude", "Agent:"):
            self.assertNotIn(leaked, body)
        self.assertIn("Keep the pairing code field focused", body)
        self.assertIn("Show the last refresh time in the widget", body)
        self.assertNotRegex(body, r"\b(?:AM|PM|CT|CDT|CST)\b")

    def test_empty_range_still_names_a_reason_for_the_build(self):
        body = self.render(["Merge branch main", "wip"])["body"]
        self.assertIn("- Maintenance and reliability updates", body)


if __name__ == "__main__":
    unittest.main()
