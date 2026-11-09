#!/usr/bin/env python3
"""Offline contract checks for the iPhone TestFlight auto-ship.

Never contacts Apple, GitHub or Infisical and never reads a credential.  It pins:

* the push paths of ios-testflight.yml to the sources project.yml compiles
  into the iOS app and the widget, so a file added to those targets cannot
  quietly stop shipping, and the scheduled gate prefixes to those push paths
  verbatim (owner rule 2026-10-29: a merge the push trigger would have shipped
  must still ship when the push event was missed);
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
import zipfile

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
            item = re.match(r"""^\s+-\s+['"]?([^'"\s]+)['"]?\s*(?:#.*)?$""", line)
            if not item:
                break
            paths.append(item.group(1))
    return paths


_GATE_PREFIX_RE = re.compile(r"""--path-prefix\s+['"]?([^'"\s]+)['"]?""")
_TRAILING_COMMENT_RE = re.compile(r"\s*(?:#.*)?$")


def gate_prefixes(text):
    """--path-prefix values from the scheduled-gate call blocks only."""
    prefixes, in_gate = [], False
    for line in text.splitlines():
        code = _TRAILING_COMMENT_RE.sub("", line)
        if not in_gate:
            if "scheduled-ship-gate.sh" in code:
                in_gate = True
                prefixes.extend(_GATE_PREFIX_RE.findall(code))
                if not code.rstrip().endswith("\\"):
                    in_gate = False
            continue
        prefixes.extend(_GATE_PREFIX_RE.findall(code))
        if not code.rstrip().endswith("\\"):
            in_gate = False
    return prefixes


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

    def test_scheduled_gate_prefixes_match_push_paths_verbatim(self):
        # Owner rule 2026-10-29: the scheduled backstop catches every merge the
        # push trigger would have shipped, so both gates take on.push.paths
        # verbatim and in order (native tree AND ship machinery, with the same
        # ! exclusions last).  Both jobs run the gate (plan-build gates before
        # any ASC query; ship gates before any toolchain or secret step), so
        # the whole file carries the push list twice, in order.
        found = gate_prefixes(self.text)
        count = len(self.push)
        self.assertGreater(count, 0)
        self.assertEqual(len(found), 2 * count)
        self.assertEqual(found[:count], self.push)
        self.assertEqual(found[count:], self.push)

    def test_extractors_accept_any_quote_style(self):
        sample = (
            "on:\n"
            "  push:\n"
            "    branches:\n"
            "      - main\n"
            "    paths:\n"
            "      - 'ios/**' # kept, not - 'evil/**'\n"
            '      - "project.yml"\n'
            "      - scripts/ios-fleet/**\n"
            "    paths-ignore:\n"
            "      - 'docs/**'\n"
            "  schedule:\n"
        )
        self.assertEqual(push_paths(sample), ["ios/**", "project.yml", "scripts/ios-fleet/**"])
        gate_sample = (
            "# scripts/ios-fleet/scheduled-ship-gate.sh refuses unless a push path changed\n"
            "# --path-prefix 'commented/out/**'\n"
            "bash scripts/ios-fleet/scheduled-ship-gate.sh \\\n"
            "  --event schedule \\\n"
            "  --path-prefix 'ios/**' \\ # kept, not --path-prefix 'evil/**'\n"
            '  --path-prefix "project.yml" \\\n'
            "  --path-prefix scripts/ios-fleet/** \\\n"
            "  hoghunter\n"
            "--path-prefix 'after/block/**'\n"
        )
        self.assertEqual(gate_prefixes(gate_sample), ["ios/**", "project.yml", "scripts/ios-fleet/**"])

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
        self.assertIn("project-id: ${{ secrets.INFISICAL_FLEET_OPS_PROJECT_ID }}", self.code)
        self.assertNotRegex(self.code, r"project-id:\s*[0-9a-f]{8}-")
        self.assertEqual(self.code.count("secret-path: /asc"), 3)
        self.assertEqual(self.code.count("service-token: ${{ secrets.INFISICAL_ASC_READ_TOKEN }}"), 3)
        self.assertNotIn("INFISICAL_CLIENT_SECRET", self.code)
        self.assertNotIn("universal-auth", self.code)
        for name in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_P8"):
            self.assertNotRegex(self.code, rf"secrets\.{name}\b")
        # The multiline key never goes through GITHUB_ENV.
        self.assertNotRegex(self.code, r"for name in .*ASC_KEY_P8")
        self.assertEqual(self.code.count('asc-mode: "true"'), 3)
        # The certificate stays out of GITHUB_ENV.
        self.assertNotRegex(self.code, r">>\s*\"?\$GITHUB_ENV\"?.*IOS_DIST")

    def test_inventory_only_cannot_plan_archive_or_upload(self):
        inventory = self.code.split("  inventory:\n", 1)[1].split("  plan-build:\n", 1)[0]
        self.assertIn("inputs.inventory_only", inventory)
        self.assertIn("node scripts/release-inventory.mjs", inventory)
        self.assertNotIn("ship-testflight.sh", inventory)
        self.assertEqual(self.code.count("inputs.inventory_only != true"), 2)

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

    def test_plan_build_gates_before_any_asc_query(self):
        # A tick with nothing to ship must plan nothing and query nothing:
        # the plan-build job runs the scheduled gate before the credential
        # load and the plan, and both steps run only when the gate votes to
        # ship.  Otherwise every hourly tick pays a full ASC inventory and a
        # transient ASC hiccup reds a run that had nothing to ship.
        self.assertEqual(self.code.count("scheduled-ship-gate.sh"), 2)
        plan_job = self.code.split("plan-build:", 1)[1].split("\n  ship:", 1)[0]
        gate_at = plan_job.index("scheduled-ship-gate.sh")
        self.assertLess(gate_at, plan_job.index("uses: ./.github/actions/infisical-secrets"))
        self.assertLess(gate_at, plan_job.index("mode=--read-plan"))
        self.assertIn("actions/cache/restore@", plan_job)
        self.assertRegex(plan_job, r"(?s)Load ASC credentials.*steps\.gate\.outputs\.should_ship == '1'")
        self.assertRegex(plan_job, r"(?s)Plan the release build.*steps\.gate\.outputs\.should_ship == '1'")

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

    def test_ops1052_ship_helpers_avoid_mapfile_and_bash4_readarray(self):
        """Hosted ios-testflight uses macOS /bin/bash 3.2; post-sync helpers must stay portable."""
        paths = (
            ROOT / "scripts/ios-observe-ship.mjs",
            ROOT / "scripts/ios-report-post-sync-tf-ready.mjs",
            WORKFLOW,
        )
        for path in paths:
            text = path.read_text(encoding="utf-8")
            for forbidden in ("mapfile ", "mapfile\t", "readarray ", "readarray\t"):
                self.assertNotIn(forbidden, text, f"{path.name} must not use {forbidden.strip()}")
        # If a bash recheck wrapper is added later, pin it here too.
        recheck = ROOT / "scripts/ios-recheck-tf-ready.sh"
        if recheck.is_file():
            recheck_text = recheck.read_text(encoding="utf-8")
            for forbidden in ("mapfile ", "mapfile\t", "readarray ", "readarray\t"):
                self.assertNotIn(forbidden, recheck_text, "ios-recheck-tf-ready.sh must stay bash-3.2-safe")

    def test_standing_tester_sync_is_followed_by_post_sync_tf_ready_recheck(self):
        sync_at = self.code.index("name: Sync standing TestFlight testers")
        post_at = self.code.index("name: Re-verify TestFlight readiness after tester sync")
        self.assertGreater(post_at, sync_at)
        sync_step = self.code[sync_at:].split("\n      - name:")[0]
        post_step = self.code[post_at:].split("\n      - name:")[0]
        self.assertNotIn("steps.ship.outputs.uploaded", sync_step)
        self.assertIn("steps.ship.outputs.uploaded == 'true'", post_step)
        self.assertIn("ios-report-post-sync-tf-ready.mjs", post_step)
        self.assertIn("continue-on-error: true", post_step)
        self.assertIn('IOS_TF_READY_TIMEOUT_SEC: "300"', post_step)
        self.assertIn("id: recheck_tf", post_step)
        self.assertRegex(
            self.code,
            r"ios-observe-ship\.mjs bash scripts/ios-ship-testflight\.sh",
        )
        summary_at = self.code.index("name: TestFlight readiness summary (after tester sync)")
        self.assertGreater(summary_at, post_at)
        summary_step = self.code[summary_at:].split("\n      - name:")[0]
        self.assertIn("recheck_tf.outputs.tf_ready_summary", summary_step)
        self.assertIn('uploaded }}" = "unknown"', summary_step)
        self.assertNotIn("ios-report-post-sync-tf-ready.mjs", summary_step)

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
class PostSyncTfReadyTests(unittest.TestCase):
    """Offline checks for post-sync ensure-tf-ready summary labels (OPS-1052)."""

    @classmethod
    def setUpClass(cls):
        cls.mjs = (ROOT / "scripts/ios-report-post-sync-tf-ready.mjs").read_text(encoding="utf-8")
        cls.ship = (FLEET / "ship-testflight.sh").read_text(encoding="utf-8")

    def test_mjs_exports_distinct_outcome_lines_per_rc(self):
        mod = ROOT / "scripts/ios-report-post-sync-tf-ready.mjs"
        script = (
            f"import {{ tfReadyOutcomeLine }} from {json.dumps(mod.as_uri())};\n"
            "const ctx = { bundleId: 'com.example.app', buildNum: '202611091200' };\n"
            "const lines = [0, 2, 3, 4, 5, 6].map((rc) => tfReadyOutcomeLine(rc, ctx));\n"
            "process.stdout.write(JSON.stringify(lines));\n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "probe.mjs"
            path.write_text(script, encoding="utf-8")
            result = subprocess.run(
                ["node", str(path)],
                capture_output=True,
                text=True,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = json.loads(result.stdout)
        self.assertEqual(len(lines), 6)
        self.assertEqual(len(set(lines)), 6)
        self.assertIn("beta group has no tester who can install it", lines[4])
        self.assertIn("installability is unverified", lines[5])
        self.assertNotIn("export compliance not declared", lines[4])

    def test_rc5_and_rc6_branches_precede_export_compliance_catch_all(self):
        start = self.ship.index("ensure_tf_ready() {")
        end = self.ship.index("\nacquire_archive_lock", start)
        block = self.ship[start:end]
        five = block.index("if [[ $rc -eq 5 ]]")
        six = block.index("if [[ $rc -eq 6 ]]")
        catch = block.index("build may be stuck on export compliance")
        self.assertLess(five, six)
        self.assertLess(six, catch)

    def test_post_sync_script_does_not_write_github_step_summary(self):
        self.assertNotIn("GITHUB_STEP_SUMMARY", self.mjs)

    def test_observe_upload_regexes_match_prefixed_ship_log_lines(self):
        """ship-testflight.sh log() emits "[ios-ship] …"; patterns must not be line-anchored."""
        bundle = "com.example.hoghunter.ios"
        cases = (
            "[ios-ship] upload path succeeded via xcodebuild export (destination=upload)",
            f"[ios-ship] build 0.1.0 (202611091200) submitted for {bundle}",
            f"[ios-ship] upload submitted; watch TestFlight processing for {bundle} build 202611091200",
        )
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "github-output"
            output.touch()
            for index, line in enumerate(cases):
                fake = Path(tmp) / f"fake-upload-{index}.sh"
                fake.write_text(f"#!/usr/bin/env bash\nprintf '%s\\n' '{line}'\n", encoding="utf-8")
                fake.chmod(0o755)
                result = subprocess.run(
                    ["node", str(ROOT / "scripts/ios-observe-ship.mjs"), "bash", str(fake)],
                    capture_output=True,
                    text=True,
                    env={**os.environ, "GITHUB_OUTPUT": str(output)},
                )
                self.assertEqual(result.returncode, 0, (index, result.stderr))
                out = output.read_text(encoding="utf-8")
                self.assertIn("uploaded=true", out, line)
                self.assertIn("ship_observed=uploaded", out, line)
                output.write_text("", encoding="utf-8")

    def test_observe_ship_marks_rate_gate_skip_as_not_uploaded(self):
        observe = (ROOT / "scripts/ios-observe-ship.mjs").read_text(encoding="utf-8")
        self.assertIn("ship-gate: exiting 0 before any version is resolved", observe)
        self.assertNotIn("stdoutBuf", observe)
        self.assertNotIn("readFileSync", observe)
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "github-output"
            output.touch()
            fake = Path(tmp) / "fake-ship.sh"
            fake.write_text(
                "#!/usr/bin/env bash\n"
                'echo "[ios-ship] ship-gate: exiting 0 before any version is resolved (nothing consumed)"\n',
                encoding="utf-8",
            )
            fake.chmod(0o755)
            result = subprocess.run(
                ["node", str(ROOT / "scripts/ios-observe-ship.mjs"), "bash", str(fake)],
                capture_output=True,
                text=True,
                env={**os.environ, "GITHUB_OUTPUT": str(output)},
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            out = output.read_text(encoding="utf-8")
            self.assertIn("uploaded=false", out)
            self.assertIn("ship_observed=skipped", out)

    def test_observe_ship_does_not_stitch_stdout_stderr_for_false_upload(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "github-output"
            output.touch()
            fake = Path(tmp) / "fake-ship.sh"
            fake.write_text(
                "#!/usr/bin/env bash\n"
                "printf 'build 123'\n"
                "printf ' submitted for com.example.ios' >&2\n",
                encoding="utf-8",
            )
            fake.chmod(0o755)
            result = subprocess.run(
                ["node", str(ROOT / "scripts/ios-observe-ship.mjs"), "bash", str(fake)],
                capture_output=True,
                text=True,
                env={**os.environ, "GITHUB_OUTPUT": str(output)},
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            out = output.read_text(encoding="utf-8")
            self.assertIn("uploaded=unknown", out)
            self.assertNotIn("uploaded=true", out)

    def test_observe_ship_marks_unknown_success_without_disabling_sync(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "github-output"
            output.touch()
            fake = Path(tmp) / "fake-ship.sh"
            fake.write_text("#!/usr/bin/env bash\necho 'ship finished with no upload markers'\n", encoding="utf-8")
            fake.chmod(0o755)
            result = subprocess.run(
                ["node", str(ROOT / "scripts/ios-observe-ship.mjs"), "bash", str(fake)],
                capture_output=True,
                text=True,
                env={**os.environ, "GITHUB_OUTPUT": str(output)},
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            out = output.read_text(encoding="utf-8")
            self.assertIn("uploaded=unknown", out)
            self.assertIn("ship_observed=unknown_success", out)

    def test_observe_ship_writes_outputs_on_spawn_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "github-output"
            output.touch()
            missing = Path(tmp) / "definitely-missing-ship-cmd"
            result = subprocess.run(
                ["node", str(ROOT / "scripts/ios-observe-ship.mjs"), str(missing), "x"],
                capture_output=True,
                text=True,
                env={**os.environ, "GITHUB_OUTPUT": str(output)},
            )
            self.assertNotEqual(result.returncode, 0)
            out = output.read_text(encoding="utf-8")
            self.assertIn("uploaded=false", out)
            self.assertIn("ship_observed=spawn_error", out)

    def test_parse_apps_hoghunter_rejects_missing_bundle_id(self):
        mod = ROOT / "scripts/ios-report-post-sync-tf-ready.mjs"
        script = (
            f"import {{ parseAppsHoghunter }} from {json.dumps(mod.as_uri())};\n"
            "const bad = { apps: { hoghunter: { fixedMarketingVersion: '0.1.0', appleId: 1 } } };\n"
            "process.stdout.write(JSON.stringify(parseAppsHoghunter(bad)));\n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "probe.mjs"
            path.write_text(script, encoding="utf-8")
            result = subprocess.run(["node", str(path)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertFalse(payload["ok"])
        self.assertIn("bundleId", payload["error"])


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


@unittest.skipUnless(shutil.which("ditto"), "macOS archive extractor is unavailable")
class XcodeGenInstallTests(unittest.TestCase):
    def test_install_uses_fresh_roots_and_preserves_presets_on_rerun(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        start = workflow.index("      - name: Install xcodegen\n")
        end = workflow.index("\n      #", start)
        step = workflow[start:end]
        script = "\n".join(line[10:] for line in step.splitlines() if line.startswith("          "))
        with tempfile.TemporaryDirectory(prefix="hh-xcodegen-fixture-") as tmp:
            root = Path(tmp)
            archive = root / "fixture.zip"
            with zipfile.ZipFile(archive, "w") as stream:
                binary = zipfile.ZipInfo("xcodegen/bin/xcodegen")
                binary.external_attr = 0o100755 << 16
                stream.writestr(binary, "#!/bin/sh\nprintf 'Version: 2.46.0\\n'\n")
                stream.writestr("xcodegen/share/xcodegen/SettingPresets/fixture.yml", "fixture: true\n")
            stale = root / "xcodegen-2.46.0"
            stale.mkdir()
            (stale / "must-not-be-used").write_text("preserve")
            stubs = root / "stubs"
            stubs.mkdir()
            curl = stubs / "curl"
            curl.write_text('#!/bin/sh\nwhile [ "$#" -gt 0 ]; do\n'
                            '  if [ "$1" = "--output" ]; then /bin/cp "$FIXTURE_ZIP" "$2"; exit; fi\n'
                            '  shift\ndone\nexit 2\n')
            curl.chmod(0o755)
            path_file = root / "github-path"
            env = dict(os.environ, RUNNER_TEMP=str(root), GITHUB_PATH=str(path_file),
                       FIXTURE_ZIP=str(archive), PATH=str(stubs) + os.pathsep + os.environ["PATH"])
            for _ in range(2):
                result = subprocess.run(["/bin/bash", "-euo", "pipefail", "-c", script],
                                        capture_output=True, text=True, env=env, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
            paths = path_file.read_text().splitlines()
            self.assertEqual(len(set(paths)), 2)
            for value in paths:
                installed = Path(value)
                self.assertTrue((installed / "xcodegen").is_file())
                self.assertTrue((installed.parent / "share/xcodegen/SettingPresets/fixture.yml").is_file())
                self.assertNotEqual(installed.parent.parent, stale)
            self.assertEqual((stale / "must-not-be-used").read_text(), "preserve")


if __name__ == "__main__":
    unittest.main()
